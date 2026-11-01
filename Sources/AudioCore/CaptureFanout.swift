import AVFoundation
import Atomics
import Foundation

/// Duplique le flux capturé vers un ring buffer par pipeline de sortie.
///
/// ## Le chemin temps réel
///
/// `write` est appelé depuis le callback de capture : ni allocation, ni verrou, ni Swift
/// Concurrency (invariant section 12). Concrètement :
///
/// - **tous les tampons sont créés à l'initialisation**, jamais pendant la diffusion ; ajouter
///   une sortie revient à en armer un qui existe déjà ;
/// - **le jeu de sorties actives tient dans un mot atomique**, ce qui permet d'en changer sans
///   structure partagée à remplacer ni période de grâce à attendre ;
/// - **les tampons sont tenus par références non comptées** : itérer un `[AudioRingBuffer]`
///   retiendrait et relâcherait chaque élément à chaque bloc, et un relâchement qui tomberait
///   à zéro sur ce thread y exécuterait une désallocation.
///
/// ## La bascule d'un tampon est faite par le producteur lui-même
///
/// C'est ce qui évite tout protocole de quiescence. Le contrôle exprime une intention dans
/// `requestedMask` ; le producteur, au début de chaque bloc, compare à `activeMask` qu'il est
/// seul à écrire. Deux conséquences qu'on obtiendrait difficilement autrement :
///
/// - une sortie ajoutée est située sur la graduation **à la trame exacte de sa première
///   écriture**, sans lecture à cheval sur deux blocs ;
/// - une fois qu'un bit a disparu d'`activeMask`, le producteur n'écrira plus jamais dans ce
///   tampon : le remettre à neuf est alors sûr.
///
/// Si la capture est à l'arrêt, ces bascules attendent le prochain bloc : elles n'ont de toute
/// façon rien à protéger tant qu'aucun bloc ne circule.
///
/// ## Contrat de concurrence
///
/// Un seul producteur à la fois (`write`), comme pour chaque ring buffer. Les méthodes de
/// contrôle (`acquireSlot`, `releaseSlot`) sont appelées depuis un seul contexte, l'acteur du
/// moteur.
final class CaptureFanout: @unchecked Sendable {
    /// Assez large pour l'installation visée (une Geneva, deux HomePod, un Apple TV) avec de la
    /// marge, assez petit pour que le coût mémoire reste négligeable : ~3 Mo à 48 kHz stéréo.
    static let defaultSlotCount = 8

    let format: AVAudioFormat
    let slotCount: Int
    private let channelCount: Int
    /// Références non comptées vers `ownedRings`, seule forme lue par le callback.
    private let ringPointers: UnsafeMutableBufferPointer<Unmanaged<AudioRingBuffer>>
    /// Maintient les tampons en vie aussi longtemps que le fanout.
    private let ownedRings: [AudioRingBuffer]

    /// Intention du contrôle. Seul le contrôle l'écrit.
    private let requestedMask = ManagedAtomic<UInt64>(0)
    /// Tampons que le producteur alimente. Seul le producteur l'écrit.
    private let activeMask = ManagedAtomic<UInt64>(0)
    /// Trames produites depuis le démarrage : la graduation de capture. Seul le producteur
    /// l'écrit.
    private let timeline = ManagedAtomic<Int>(0)
    /// Position de fin du dernier bloc contenant au moins un échantillon non nul.
    private let lastSignalEnd = ManagedAtomic<Int>(0)

    /// Tampons attribués à une sortie. Propre au contexte de contrôle : le producteur ne le lit
    /// jamais.
    private var ownedSlots: UInt64 = 0

    /// - Parameters:
    ///   - format: format des blocs écrits, toujours entrelacé (voir `CaptureBlockAdapter`).
    ///   - slotCount: nombre maximal de sorties simultanées.
    ///   - capacityFrames: capacité de chaque tampon.
    init(
        format: AVAudioFormat,
        slotCount: Int = CaptureFanout.defaultSlotCount,
        capacityFrames: Int = 48_000
    ) {
        precondition(slotCount > 0 && slotCount <= UInt64.bitWidth, "nombre de tampons invalide")
        self.format = format
        self.slotCount = slotCount
        self.channelCount = Int(format.channelCount)
        let rings = (0..<slotCount).map { _ in
            AudioRingBuffer(capacityFrames: capacityFrames, channelCount: Int(format.channelCount))
        }
        self.ownedRings = rings
        self.ringPointers = .allocate(capacity: slotCount)
        for (index, ring) in rings.enumerated() {
            ringPointers.initializeElement(at: index, to: Unmanaged.passUnretained(ring))
        }
    }

    deinit {
        ringPointers.deinitialize()
        ringPointers.deallocate()
    }

    // MARK: - Contrôle (hors temps réel)

    /// Trames produites depuis le démarrage de la capture.
    var framesCaptured: Int { timeline.load(ordering: .acquiring) }

    /// Trames produites depuis le dernier échantillon non nul.
    ///
    /// **Silence strict** : un seul échantillon non nul remet le compteur à zéro. Un passage
    /// calme d'un vrai morceau conserve du bruit de fond ; seuls une autorisation manquante, un
    /// tap mal câblé ou l'absence de toute lecture donnent un zéro parfait (`CLAUDE.md`).
    var framesSinceLastSignal: Int {
        timeline.load(ordering: .acquiring) - lastSignalEnd.load(ordering: .acquiring)
    }

    /// Attribue un tampon à une nouvelle sortie et le met en service.
    ///
    /// - Returns: l'indice du tampon, ou `nil` si aucun n'est libre. Un tampon rendu n'est
    ///   réattribué qu'une fois le producteur assuré de ne plus y écrire.
    func acquireSlot() -> Int? {
        let active = activeMask.load(ordering: .acquiring)
        for index in 0..<slotCount {
            let bit = UInt64(1) << UInt64(index)
            guard ownedSlots & bit == 0, active & bit == 0 else { continue }
            let ring = ownedRings[index]
            // Sûr : bit absent d'`activeMask` et d'`ownedSlots`, donc ni producteur ni
            // consommateur sur ce tampon.
            ring.resetForReuse()
            // Valeur provisoire, que le producteur précise à son premier bloc : elle ne reste
            // en vigueur que si aucun bloc ne circule, et alors la graduation est immobile.
            ring.placeOnTimeline(at: framesCaptured)
            ownedSlots |= bit
            // `releasing` : le producteur qui voit ce bit voit aussi le tampon remis à neuf.
            requestedMask.store(requestedMask.load(ordering: .relaxed) | bit, ordering: .releasing)
            return index
        }
        return nil
    }

    func ring(atSlot index: Int) -> AudioRingBuffer { ownedRings[index] }

    /// Rend un tampon au pool. Son ancien consommateur doit être terminé.
    func releaseSlot(_ index: Int) {
        let bit = UInt64(1) << UInt64(index)
        requestedMask.store(requestedMask.load(ordering: .relaxed) & ~bit, ordering: .releasing)
        ownedSlots &= ~bit
    }

    // MARK: - Chemin temps réel

    /// Recopie le bloc vers **tous** les pipelines actifs. Aucun sender ne voit le tampon d'un
    /// autre, et un pipeline saturé ne retient pas les autres : son tampon refuse, c'est tout.
    ///
    /// - Parameter samples: échantillons entrelacés, `frameCount * channelCount` valeurs.
    func write(_ samples: UnsafePointer<Float>, frameCount: Int) {
        guard frameCount > 0 else { return }
        let position = timeline.load(ordering: .relaxed)

        var active = activeMask.load(ordering: .relaxed)
        let requested = requestedMask.load(ordering: .acquiring)
        if requested != active {
            // Sorties ajoutées depuis le bloc précédent : elles entrent sur la graduation à
            // cette trame-ci, ce qui les aligne sur l'horloge commune.
            var added = requested & ~active
            while added != 0 {
                let index = added.trailingZeroBitCount
                added &= added - 1
                ringPointers[index]._withUnsafeGuaranteedRef {
                    $0.placeOnTimeline(at: position)
                }
            }
            active = requested
            // `releasing` : qui observe un bit retiré sait que plus aucune écriture ne suivra.
            activeMask.store(active, ordering: .releasing)
        }

        var remaining = active
        while remaining != 0 {
            let index = remaining.trailingZeroBitCount
            remaining &= remaining - 1
            ringPointers[index]._withUnsafeGuaranteedRef {
                _ = $0.write(from: samples, frameCount: frameCount)
            }
        }

        // Sortie dès le premier échantillon non nul : sur un signal réel la boucle s'arrête
        // presque aussitôt, et sur un silence elle ne coûte qu'un parcours du bloc.
        let sampleCount = frameCount * channelCount
        var offset = 0
        while offset < sampleCount {
            if samples[offset] != 0 {
                lastSignalEnd.store(position + frameCount, ordering: .relaxed)
                break
            }
            offset += 1
        }

        timeline.store(position + frameCount, ordering: .releasing)
    }
}
