import Foundation
import OSLog

/// Horloge de restitution commune à toutes les sorties (CDC 4.5, « horloge maître unique
/// côté application »).
///
/// ## Ce qu'elle résout
///
/// Chaque sender lit **son** ring buffer, à **son** rythme, et démarre à un instant
/// différent (la négociation RAOP dure ~4 s, celle d'AirPlay 2 davantage à cause du
/// pair-setup). Sans référence commune, rien ne garantit qu'un même échantillon capté soit
/// restitué au même instant par les deux récepteurs.
///
/// Cette horloge fournit cette référence : elle traduit un **numéro de trame de capture** en
/// **instant de restitution attendu**, identique pour tout le monde. Chaque sender s'en sert
/// pour calculer l'ancrage NTP de ses paquets de synchronisation — c'est le récepteur, et
/// non l'application, qui aligne ensuite sa restitution sur cet ancrage. C'est précisément
/// le mécanisme natif dont parle le CDC 4.5, par opposition à une mesure de type ping.
///
/// ## Invariant section 12
///
/// Elle ne connaît **aucune** sortie et n'en distingue aucune : c'est une graduation, pas un
/// coordinateur. Deux senders qui la consultent ne s'échangent rien et ignorent toujours
/// l'existence l'un de l'autre. Les dépendances pointent vers le cœur, jamais l'inverse.
///
/// ## Pourquoi une classe verrouillée et non un acteur
///
/// Elle est consultée depuis les boucles de diffusion, à chaque paquet (~125 fois par seconde
/// et par sortie), et **jamais** depuis le callback de capture temps réel — l'interdiction de
/// verrou de la section 12 ne porte que sur ce dernier. Un acteur imposerait un `await` à
/// chaque paquet dans du code déjà asynchrone, sans rien apporter.
public protocol PlaybackClockProtocol: Sendable {
    /// Fréquence d'échantillonnage de la capture, en Hz.
    var captureSampleRate: Double { get }
    /// Délai de restitution commun, en secondes : l'avance que l'application se donne entre
    /// la capture d'un échantillon et sa restitution par les récepteurs.
    var playoutDelaySeconds: Double { get }
    /// Instant de restitution attendu d'une trame de capture, en temps Unix.
    /// Renvoie `nil` tant que la capture n'a pas démarré.
    func presentationUnixTime(forCaptureFrame frame: Double) -> TimeInterval?
}

public final class SharedPlaybackClock: PlaybackClockProtocol, @unchecked Sendable {
    /// Le délai commun de restitution par défaut. **La seule constante du retard de bout en bout** :
    /// la latence annoncée par les senders (`SyncLatency`) et celle que la sortie virtuelle annonce
    /// aux applications (`VideoSyncLatency`) en découlent.
    ///
    /// 0,4 s, choisi par Baptiste à l'écoute le 2026-11-10 sur la Geneva et les deux HomePod : 2 s
    /// (la valeur d'Apple) faisait attendre chaque vidéo et chaque clic. Essayés le même soir : 1 s
    /// et 0,5 s tiennent, **0,3 s et 0,25 s décrochent** (trous en rafale). Un récepteur ajoutant
    /// 0,25 s de lui-même, 0,4 s ne lui annonce que 0,15 s : un paquet perdu sur le Wi-Fi n'a
    /// presque plus le temps d'être renvoyé. Tenu quelques minutes à l'écoute, pas en endurance.
    public static let defaultPlayoutDelaySeconds = 0.4

    public let captureSampleRate: Double
    public let playoutDelaySeconds: Double

    /// Instant Unix auquel la trame de capture n° 0 a été produite.
    private var captureEpoch: TimeInterval?
    private let lock = NSLock()
    private let log = AudioLog.sync

    /// - Parameters:
    ///   - captureSampleRate: fréquence de la capture (48 000 Hz sur cette machine).
    ///   - playoutDelaySeconds: délai commun de restitution, voir
    ///     ``defaultPlayoutDelaySeconds``. Les senders Apple emploient 2 s.
    public init(
        captureSampleRate: Double, playoutDelaySeconds: Double = SharedPlaybackClock.defaultPlayoutDelaySeconds
    ) {
        precondition(captureSampleRate > 0, "fréquence de capture nulle")
        self.captureSampleRate = captureSampleRate
        self.playoutDelaySeconds = playoutDelaySeconds
    }

    /// Date l'origine de l'horloge sur l'instant présent.
    ///
    /// À appeler une seule fois, au démarrage de la capture, avant que le moindre sender ne
    /// négocie. Les appels suivants sont ignorés : réancrer l'horloge en cours de route
    /// décalerait les deux sorties l'une par rapport à l'autre, exactement ce que cette
    /// classe existe pour empêcher.
    ///
    /// - Parameter framesAlreadyWritten: trames déjà écrites par la capture au moment de
    ///   l'appel, pour que l'origine corresponde bien à la trame n° 0 et non à « maintenant ».
    public func startIfNeeded(framesAlreadyWritten: Int = 0) {
        lock.lock()
        defer { lock.unlock() }
        guard captureEpoch == nil else { return }
        let epoch = Date().timeIntervalSince1970 - Double(framesAlreadyWritten) / captureSampleRate
        captureEpoch = epoch
        log.info(
            "Horloge de restitution ancrée (délai commun \(self.playoutDelaySeconds, format: .fixed(precision: 3)) s)"
        )
    }

    /// Reporte l'origine de l'horloge après une interruption de la capture.
    ///
    /// La graduation ne compte que les trames produites : quand la capture s'interrompt, elle
    /// s'immobilise pendant que l'heure avance, et les instants annoncés prennent autant de
    /// retard sur le réel. Passé les 2 s de marge, les trames arriveraient après l'heure qu'on
    /// leur annonce et le récepteur les jetterait. Cela survient à la reconstruction du tap, et
    /// surtout avant le premier son : le tap ne livre aucun bloc tant que rien ne joue
    /// (`kAudioAggregateDeviceTapAutoStartKey`).
    ///
    /// **Ce n'est pas le réancrage que ``startIfNeeded(framesAlreadyWritten:)`` interdit** :
    /// l'horloge étant commune, le report vaut pour toutes les sorties au même instant et ne
    /// change rien à leur alignement mutuel.
    public func shiftOrigin(bySeconds seconds: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        guard let epoch = captureEpoch else { return }
        captureEpoch = epoch + seconds
    }

    public var hasStarted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return captureEpoch != nil
    }

    public func presentationUnixTime(forCaptureFrame frame: Double) -> TimeInterval? {
        lock.lock()
        let epoch = captureEpoch
        lock.unlock()
        guard let epoch else { return nil }
        return epoch + frame / captureSampleRate + playoutDelaySeconds
    }
}
