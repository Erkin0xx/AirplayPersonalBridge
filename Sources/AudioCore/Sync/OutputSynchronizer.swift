import Foundation
import OSLog

/// Correction de dérive à appliquer au prochain paquet.
public enum DriftCorrection: String, Sendable {
    /// Rien à faire : l'écart est dans la bande morte.
    case none
    /// Supprimer une trame : le pipeline a pris du retard, il faut le rattraper.
    case removeFrame
    /// Ajouter une trame : le pipeline a pris de l'avance, il faut le retenir.
    case insertFrame
}

/// Alignement et correction de dérive **d'une** sortie (CDC 4.5, jalon 4).
///
/// ## Les trois choses qu'elle fait
///
/// 1. **Aligner automatiquement**, en calculant l'ancrage NTP des paquets de synchronisation
///    à partir de l'horloge de restitution commune (``PlaybackClockProtocol``). Deux sorties
///    ancrées sur la même horloge restituent la même trame captée au même instant, quelles
///    que soient leurs latences respectives — c'est le récepteur qui fait le calage, sur la
///    foi de cet ancrage. C'est le mécanisme natif du protocole, pas une mesure de trajet.
/// 2. **Offrir un réglage manuel** par sortie, en secondes, appliqué au même ancrage. Le CDC
///    le veut en fine-tune et filet de sécurité, pas en mécanisme principal : il s'ajoute à
///    l'alignement automatique au lieu de le remplacer.
/// 3. **Corriger la dérive** entre l'horloge de la capture (matérielle, celle du
///    périphérique audio) et celle qui cadence l'émission (`ContinuousClock`, celle de
///    l'hôte). Ces deux horloges ne sont pas la même : quelques dizaines de ppm d'écart
///    suffisent à déplacer le calage de plus de 100 ms en une heure. La correction se fait
///    par ajout ou suppression d'**une** trame avec fondu (voir ``SampleSplice``).
///
/// ## Ce qui est mesuré pour piloter la correction
///
/// Le **délai de pipeline** : la quantité d'audio captée mais pas encore émise (arriéré du
/// ring buffer plus échantillons convertis en attente), exprimée en trames de sortie. Si
/// l'émission est plus lente que la capture, il enfle ; plus rapide, il fond. Le maintenir
/// constant, c'est exactement maintenir constant le décalage entre capture et restitution —
/// donc l'alignement.
///
/// La cible n'est pas fixée a priori mais **observée** : pendant la phase de stabilisation,
/// le régime établi s'installe (démarrage de la boucle, remplissage initial), et la moyenne
/// obtenue devient la consigne. Choisir une constante arbitraire obligerait au contraire la
/// correction à rattraper d'emblée un écart qui n'est pas de la dérive.
///
/// La mesure instantanée est bruitée : le ring buffer se remplit par blocs de ~256 trames et
/// se vide par paquets de 352, ce qui fait osciller le délai de plusieurs millisecondes d'un
/// paquet à l'autre. D'où le lissage exponentiel : c'est la tendance qui est de la dérive,
/// pas l'oscillation.
///
/// ## Invariant section 12
///
/// Cet objet ne touche à aucun tampon partagé : il reçoit une mesure et rend une décision.
/// La correction elle-même est appliquée par le sender sur **sa** copie des échantillons, en
/// aval du ring buffer. Il ne connaît par ailleurs aucune autre sortie : il ne voit que
/// l'horloge commune, qui est une graduation et non un coordinateur.
public final class OutputSynchronizer: @unchecked Sendable {

    // MARK: - Réglages

    /// Durée de la phase de stabilisation avant d'arrêter la consigne, en secondes.
    private static let settleSeconds: Double = 10
    /// Bande morte, en trames de sortie. 64 trames = 1,45 ms à 44,1 kHz, soit un vingtième
    /// du seuil de perception de 20 à 30 ms visé par le CDC section 8 : corriger en deçà
    /// serait s'agiter dans le bruit de mesure.
    private static let deadbandFrames: Double = 64
    /// Constante de temps du lissage, en secondes.
    private static let smoothingSeconds: Double = 5
    /// Bornes de la consigne, en secondes. Un délai de pipeline hors de ces bornes signale
    /// autre chose qu'une dérive (récepteur bloqué, capture arrêtée) : la corriger à
    /// l'échantillon n'aurait aucun sens.
    private static let minimumTargetSeconds: Double = 0.005
    private static let maximumTargetSeconds: Double = 0.500

    // MARK: - État

    public let label: String
    private let clock: PlaybackClockProtocol
    private let outputSampleRate: Double
    private let log = AudioLog.sync
    private let lock = NSLock()

    /// Mesure issue du canal de timing natif du récepteur.
    public let timing = TimingEstimator()

    private var manualOffset: TimeInterval = 0
    private var receiverLatencyFrames: Int = 0

    /// Trame de capture correspondant au premier échantillon émis.
    private var startCaptureFrame: Double?
    /// Trames de sortie consommées depuis le début de la diffusion, **corrections
    /// comprises** : c'est cette valeur, et non le nombre de paquets, qui situe le flux sur
    /// l'horloge de capture — une trame supprimée avance bien le flux d'une trame.
    private var consumedOutputFrames: Double = 0

    private var smoothedDelayFrames: Double?
    private var targetDelayFrames: Double?
    private var settleAccumulator: Double = 0
    private var settleSamples: Int = 0
    private var packetsSinceCorrection = Int.max
    private var framesInserted = 0
    private var framesRemoved = 0
    private var lastErrorFrames: Double = 0

    /// - Parameters:
    ///   - label: nom de la sortie, pour les journaux uniquement.
    ///   - clock: horloge de restitution commune. Injectée par protocole (règle de code
    ///     CDC section 13) : les tests fournissent la leur.
    ///   - outputSampleRate: fréquence du flux émis (44 100 Hz pour les deux protocoles).
    public init(label: String, clock: PlaybackClockProtocol, outputSampleRate: Double) {
        precondition(outputSampleRate > 0, "fréquence de sortie nulle")
        self.label = label
        self.clock = clock
        self.outputSampleRate = outputSampleRate
    }

    // MARK: - Réglage manuel (CDC 4.5 : fine-tune et filet de sécurité)

    /// Décalage manuel de cette sortie, en secondes. Positif = restituer **plus tard**.
    ///
    /// Modifiable en cours de diffusion : il n'agit que sur l'ancrage annoncé au récepteur,
    /// aucun échantillon n'est manipulé pour l'appliquer. Le récepteur redate sa restitution
    /// dès l'annonce de synchronisation suivante, sans rupture de flux.
    public var manualOffsetSeconds: TimeInterval {
        get { lock.lock(); defer { lock.unlock() }; return manualOffset }
        set {
            lock.lock()
            let previous = manualOffset
            manualOffset = newValue
            lock.unlock()
            if previous != newValue {
                log.info(
                    "\(self.label, privacy: .public) : décalage manuel \(newValue * 1000, format: .fixed(precision: 1)) ms"
                )
            }
        }
    }

    /// Latence annoncée par le récepteur, en trames à la fréquence du flux.
    ///
    /// C'est la profondeur de tampon interne du récepteur — l'information qu'aucune mesure de
    /// trajet réseau ne donne, et la raison pour laquelle le CDC 4.5 écarte le ping.
    public var declaredReceiverLatencyFrames: Int {
        get { lock.lock(); defer { lock.unlock() }; return receiverLatencyFrames }
        set { lock.lock(); receiverLatencyFrames = newValue; lock.unlock() }
    }

    // MARK: - Cycle de diffusion

    /// Ancre le flux sur l'horloge de capture, au démarrage de la diffusion.
    ///
    /// - Parameter captureFrame: valeur de `AudioRingBuffer.totalFramesRead` au moment où le
    ///   premier échantillon émis a été extrait — c'est-à-dire la position du flux sur
    ///   l'horloge de capture commune aux deux sorties.
    public func beginStreaming(atCaptureFrame captureFrame: Int) {
        lock.lock()
        defer { lock.unlock() }
        startCaptureFrame = Double(captureFrame)
        consumedOutputFrames = 0
        smoothedDelayFrames = nil
        targetDelayFrames = nil
        settleAccumulator = 0
        settleSamples = 0
        packetsSinceCorrection = .max
        lastErrorFrames = 0
    }

    /// Consulte l'état de la dérive et rend la correction à appliquer au prochain paquet.
    ///
    /// - Parameter pipelineDelayOutputFrames: audio capté mais pas encore émis, en trames à
    ///   la fréquence de sortie.
    public func observe(pipelineDelayOutputFrames: Double) -> DriftCorrection {
        lock.lock()
        defer { lock.unlock() }

        // Lissage exponentiel, de constante de temps `smoothingSeconds`. Le pas de temps est
        // une durée de paquet : la boucle appelle cette méthode une fois par paquet.
        let packetSeconds = Double(ALACEncoder.framesPerPacket) / outputSampleRate
        let alpha = min(1.0, packetSeconds / Self.smoothingSeconds)
        let smoothed = smoothedDelayFrames.map { $0 + alpha * (pipelineDelayOutputFrames - $0) }
            ?? pipelineDelayOutputFrames
        smoothedDelayFrames = smoothed

        packetsSinceCorrection = packetsSinceCorrection == .max ? .max : packetsSinceCorrection + 1

        guard let target = targetDelayFrames else {
            // Phase de stabilisation : on observe, on ne corrige pas.
            settleAccumulator += pipelineDelayOutputFrames
            settleSamples += 1
            if Double(settleSamples) * packetSeconds >= Self.settleSeconds {
                let mean = settleAccumulator / Double(settleSamples)
                let clamped = min(
                    max(mean, Self.minimumTargetSeconds * outputSampleRate),
                    Self.maximumTargetSeconds * outputSampleRate
                )
                targetDelayFrames = clamped
                packetsSinceCorrection = 0
                log.info(
                    """
                    \(self.label, privacy: .public) : consigne de délai de pipeline arrêtée à \
                    \(clamped / self.outputSampleRate * 1000, format: .fixed(precision: 1)) ms \
                    (moyenne observée \(mean / self.outputSampleRate * 1000, format: .fixed(precision: 1)) ms)
                    """
                )
            }
            return .none
        }

        let error = smoothed - target
        lastErrorFrames = error
        guard abs(error) > Self.deadbandFrames else { return .none }

        // Deux vitesses : on rattrape franchement un écart important (changement de réglage
        // manuel, à-coup réseau), et on ne fait que grignoter une dérive ordinaire. Corriger
        // toujours au maximum ferait osciller la boucle autour de la consigne.
        let interval = abs(error) > 10 * Self.deadbandFrames ? 2 : 16
        guard packetsSinceCorrection >= interval else { return .none }
        packetsSinceCorrection = 0

        if error > 0 {
            // Trop d'arriéré : la restitution prend du retard sur la capture. Supprimer une
            // trame avance le flux d'une trame.
            framesRemoved += 1
            return .removeFrame
        }
        framesInserted += 1
        return .insertFrame
    }

    /// Comptabilise les trames de sortie réellement consommées pour fabriquer un paquet.
    ///
    /// Vaut la taille d'un paquet en régime normal, une trame de plus ou de moins quand une
    /// correction a été appliquée.
    public func didConsume(outputFrames: Int) {
        lock.lock()
        consumedOutputFrames += Double(outputFrames)
        lock.unlock()
    }

    // MARK: - Ancrage

    /// Trame de capture correspondant au **prochain** paquet à émettre.
    public var currentCaptureFrame: Double? {
        lock.lock()
        defer { lock.unlock() }
        guard let start = startCaptureFrame else { return nil }
        return start + consumedOutputFrames * (clock.captureSampleRate / outputSampleRate)
    }

    /// Instant NTP à annoncer dans le paquet de synchronisation.
    ///
    /// ## Le calcul
    ///
    /// Une annonce de synchronisation RAOP dit au récepteur : « l'estampille RTP
    /// `courante − latence` doit être restituée à l'instant NTP que voici ». Le récepteur en
    /// déduit que l'estampille `courante` sera restituée `latence / fréquence` plus tard.
    ///
    /// On veut que la trame de capture `F` que porte cette estampille soit restituée à
    /// `horloge.presentationUnixTime(F) + décalage manuel`. L'instant à annoncer est donc ce
    /// même instant **diminué** de la latence annoncée.
    ///
    /// Les deux sorties partageant la même horloge, elles aboutissent au même instant de
    /// restitution pour la même trame captée : c'est là, et nulle part ailleurs, que se fait
    /// l'alignement automatique.
    ///
    /// - Parameter latencyFrames: latence annoncée dans le même paquet de synchronisation.
    /// - Returns: `nil` si l'horloge n'a pas encore démarré ou si la diffusion n'a pas
    ///   commencé — l'appelant retombe alors sur « maintenant », comportement du jalon 2.
    public func syncAnchorUnixTime(latencyFrames: UInt32) -> TimeInterval? {
        lock.lock()
        let start = startCaptureFrame
        let consumed = consumedOutputFrames
        let offset = manualOffset
        lock.unlock()
        guard let start else { return nil }
        let captureFrame = start + consumed * (clock.captureSampleRate / outputSampleRate)
        guard let presentation = clock.presentationUnixTime(forCaptureFrame: captureFrame) else {
            return nil
        }
        return presentation + offset - Double(latencyFrames) / outputSampleRate
    }

    // MARK: - Compte rendu

    public func snapshot(now: TimeInterval = Date().timeIntervalSince1970) -> SyncSnapshot {
        lock.lock()
        let smoothed = smoothedDelayFrames
        let target = targetDelayFrames
        let error = lastErrorFrames
        let inserted = framesInserted
        let removed = framesRemoved
        let manual = manualOffset
        let latency = receiverLatencyFrames
        lock.unlock()

        return SyncSnapshot(
            label: label,
            manualOffsetSeconds: manual,
            receiverLatencySeconds: Double(latency) / outputSampleRate,
            pipelineDelaySeconds: smoothed.map { $0 / outputSampleRate },
            targetDelaySeconds: target.map { $0 / outputSampleRate },
            residualErrorSeconds: target == nil ? nil : error / outputSampleRate,
            framesInserted: inserted,
            framesRemoved: removed,
            timing: timing.snapshot(now: now)
        )
    }
}

/// État de synchronisation d'une sortie, pour le compte rendu et le diagnostic.
public struct SyncSnapshot: Sendable {
    public let label: String
    public let manualOffsetSeconds: TimeInterval
    /// Latence interne annoncée par le récepteur — la part qu'un ping ne verrait pas.
    public let receiverLatencySeconds: TimeInterval
    /// Délai de pipeline lissé : audio capté et pas encore émis.
    public let pipelineDelaySeconds: TimeInterval?
    /// Consigne arrêtée en fin de stabilisation. `nil` pendant celle-ci.
    public let targetDelaySeconds: TimeInterval?
    /// Écart courant à la consigne. C'est **la** grandeur à comparer au seuil de perception
    /// de 20 à 30 ms du CDC section 8.
    public let residualErrorSeconds: TimeInterval?
    public let framesInserted: Int
    public let framesRemoved: Int
    public let timing: TimingSnapshot

    public init(
        label: String,
        manualOffsetSeconds: TimeInterval,
        receiverLatencySeconds: TimeInterval,
        pipelineDelaySeconds: TimeInterval?,
        targetDelaySeconds: TimeInterval?,
        residualErrorSeconds: TimeInterval?,
        framesInserted: Int,
        framesRemoved: Int,
        timing: TimingSnapshot
    ) {
        self.label = label
        self.manualOffsetSeconds = manualOffsetSeconds
        self.receiverLatencySeconds = receiverLatencySeconds
        self.pipelineDelaySeconds = pipelineDelaySeconds
        self.targetDelaySeconds = targetDelaySeconds
        self.residualErrorSeconds = residualErrorSeconds
        self.framesInserted = framesInserted
        self.framesRemoved = framesRemoved
        self.timing = timing
    }

    /// Latence totale estimée de la sortie : ce que l'application retient, plus ce que le
    /// récepteur retient, plus le réglage manuel.
    public var estimatedTotalLatencySeconds: TimeInterval? {
        guard let pipeline = pipelineDelaySeconds else { return nil }
        return pipeline + receiverLatencySeconds + manualOffsetSeconds
    }
}
