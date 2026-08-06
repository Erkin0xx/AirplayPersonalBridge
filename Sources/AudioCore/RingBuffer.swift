import Foundation
import Atomics

/// Ring buffer lock-free à producteur unique / consommateur unique (SPSC).
///
/// Invariant section 12, littéralement : « Transfert du callback de capture temps réel vers
/// les threads réseau uniquement via un ring buffer lock-free (un par pipeline de sortie),
/// jamais via une structure verrouillée (mutex, sémaphore) ni via Swift Concurrency à cet
/// endroit précis. L'écriture dans ces ring buffers, effectuée depuis le callback de
/// capture, doit elle-même rester lock-free et sans allocation. »
///
/// Conséquences concrètes sur cette implémentation :
/// - toute la mémoire est allouée **une seule fois** dans `init` ; `write` et `read`
///   n'allouent jamais, ne verrouillent jamais et ne peuvent pas bloquer ;
/// - la synchronisation repose sur deux index atomiques, avec un ordonnancement
///   acquire/release qui garantit que le consommateur voit les échantillons écrits avant
///   la publication de l'index ;
/// - **un seul producteur et un seul consommateur** : ce contrat n'est pas vérifiable par
///   le compilateur, il est structurellement garanti par l'architecture (un callback de
///   capture, une tâche de sender par pipeline).
///
/// En cas de saturation (consommateur trop lent), `write` abandonne les échantillons les
/// plus récents et les comptabilise dans `droppedFrames` plutôt que de bloquer le thread
/// temps réel : perdre de l'audio est préférable à un glitch sur toute la sortie.
public final class AudioRingBuffer: @unchecked Sendable {
    private let storage: UnsafeMutableBufferPointer<Float>
    private let capacityFrames: Int
    private let channelCount: Int

    /// Index en trames. Seul le producteur écrit `writeIndex`, seul le consommateur écrit
    /// `readIndex` ; chacun lit l'index de l'autre.
    private let writeIndex = ManagedAtomic<Int>(0)
    private let readIndex = ManagedAtomic<Int>(0)
    private let dropped = ManagedAtomic<Int>(0)

    /// - Parameters:
    ///   - capacityFrames: nombre de trames tamponnées. Dimensionner largement au-dessus
    ///     de la taille de bloc du tap (constatée à ~256 trames) pour absorber la gigue du
    ///     consommateur réseau.
    ///   - channelCount: nombre de canaux entrelacés.
    public init(capacityFrames: Int, channelCount: Int) {
        precondition(capacityFrames > 0, "capacité nulle")
        precondition(channelCount > 0, "nombre de canaux nul")
        self.capacityFrames = capacityFrames
        self.channelCount = channelCount
        // Allocation unique, hors du chemin temps réel.
        let sampleCount = capacityFrames * channelCount
        let pointer = UnsafeMutablePointer<Float>.allocate(capacity: sampleCount)
        pointer.initialize(repeating: 0, count: sampleCount)
        self.storage = UnsafeMutableBufferPointer(start: pointer, count: sampleCount)
    }

    deinit {
        storage.baseAddress?.deinitialize(count: storage.count)
        storage.baseAddress?.deallocate()
    }

    /// Nombre de trames disponibles à la lecture.
    public var availableFrames: Int {
        let write = writeIndex.load(ordering: .acquiring)
        let read = readIndex.load(ordering: .relaxed)
        return write - read
    }

    /// Nombre total de trames **écrites** depuis la création du tampon, sans repli modulo.
    ///
    /// C'est l'horloge de capture exprimée en trames : le producteur étant unique et commun
    /// à tous les pipelines de sortie, deux ring buffers alimentés par la même capture
    /// portent la **même** valeur au même instant. C'est ce qui donne aux deux sorties une
    /// référence temporelle commune sans qu'aucune ne connaisse l'existence de l'autre
    /// (invariant section 12) : elles lisent toutes deux la même graduation, pas l'état de
    /// leur voisine.
    public var totalFramesWritten: Int { writeIndex.load(ordering: .acquiring) }

    /// Nombre total de trames **lues** depuis la création, sans repli modulo.
    ///
    /// Permet au consommateur de situer l'échantillon qu'il vient d'extraire sur l'horloge
    /// de capture ci-dessus, donc de dater ce qu'il émet.
    public var totalFramesRead: Int { readIndex.load(ordering: .relaxed) }

    /// Trames refusées depuis la création, faute de place.
    ///
    /// Compte chaque trame que `write` n'a pas pu accepter, y compris celles qu'un
    /// producteur réessayant finit par écrire : c'est un indicateur de pression sur le
    /// tampon, pas nécessairement une perte définitive d'audio. Depuis le callback temps
    /// réel, qui ne réessaie jamais, un compteur non nul signale en revanche bien de
    /// l'audio perdu et donc un tampon sous-dimensionné.
    public var droppedFrames: Int { dropped.load(ordering: .relaxed) }

    /// Écrit des trames entrelacées. **Appelé depuis le callback temps réel.**
    ///
    /// Sans allocation, sans verrou, sans appel bloquant.
    /// - Returns: le nombre de trames effectivement écrites.
    @discardableResult
    public func write(from source: UnsafePointer<Float>, frameCount: Int) -> Int {
        guard frameCount > 0 else { return 0 }
        let write = writeIndex.load(ordering: .relaxed)
        let read = readIndex.load(ordering: .acquiring)
        let freeFrames = capacityFrames - (write - read)
        guard freeFrames > 0 else {
            dropped.wrappingIncrement(by: frameCount, ordering: .relaxed)
            return 0
        }
        let toWrite = min(frameCount, freeFrames)
        if toWrite < frameCount {
            dropped.wrappingIncrement(by: frameCount - toWrite, ordering: .relaxed)
        }

        guard let base = storage.baseAddress else { return 0 }
        let offsetFrames = write % capacityFrames
        // Le bloc peut chevaucher la fin du tampon : au plus deux copies contiguës.
        let firstChunk = min(toWrite, capacityFrames - offsetFrames)
        base.advanced(by: offsetFrames * channelCount)
            .update(from: source, count: firstChunk * channelCount)
        if firstChunk < toWrite {
            base.update(
                from: source.advanced(by: firstChunk * channelCount),
                count: (toWrite - firstChunk) * channelCount
            )
        }

        // `releasing` : publie les échantillons avant l'index qui les rend visibles.
        writeIndex.store(write + toWrite, ordering: .releasing)
        return toWrite
    }

    /// Lit des trames entrelacées. Appelé depuis la tâche du sender, hors temps réel.
    /// - Returns: le nombre de trames effectivement lues.
    @discardableResult
    public func read(into destination: UnsafeMutablePointer<Float>, frameCount: Int) -> Int {
        guard frameCount > 0 else { return 0 }
        let read = readIndex.load(ordering: .relaxed)
        let write = writeIndex.load(ordering: .acquiring)
        let available = write - read
        guard available > 0 else { return 0 }
        let toRead = min(frameCount, available)

        guard let base = storage.baseAddress else { return 0 }
        let offsetFrames = read % capacityFrames
        let firstChunk = min(toRead, capacityFrames - offsetFrames)
        destination.update(
            from: base.advanced(by: offsetFrames * channelCount),
            count: firstChunk * channelCount
        )
        if firstChunk < toRead {
            destination.advanced(by: firstChunk * channelCount)
                .update(from: base, count: (toRead - firstChunk) * channelCount)
        }

        readIndex.store(read + toRead, ordering: .releasing)
        return toRead
    }
}
