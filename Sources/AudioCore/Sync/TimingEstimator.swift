import Foundation

/// Mesure de l'écart d'horloge avec un récepteur, à partir du **canal de timing natif
/// AirPlay** (CDC 4.5).
///
/// ## Pourquoi pas un ping
///
/// Un aller-retour ICMP ne mesure que le trajet réseau — quelques centaines de microsecondes
/// sur un réseau local — alors que le décalage réellement audible vient du **tampon interne
/// du récepteur**, de l'ordre de plusieurs centaines de millisecondes. Le canal de timing,
/// lui, est le mécanisme par lequel le récepteur cale son horloge sur celle du sender : les
/// estampilles qui y circulent portent l'information qui compte.
///
/// ## Ce qui est mesuré, et comment
///
/// En RAOP c'est le **récepteur** qui interroge, à sa propre initiative (~toutes les 3 s
/// chez shairport-sync). Chaque requête porte, à l'offset 24, l'instant NTP d'émission `T1`
/// lu sur *son* horloge ; nous l'apparions avec `T2`, notre instant de réception :
///
/// ```
/// T2 − T1 = décalage d'horloge + délai de trajet aller
/// ```
///
/// Le délai de trajet étant positif et variable, le **minimum** de cet écart sur une fenêtre
/// glissante est la meilleure estimation du décalage seul : c'est l'échantillon le moins
/// pollué par la file d'attente, exactement le filtre qu'emploie NTP. L'étendue de la
/// fenêtre (`spreadSeconds`) donne la gigue du canal.
///
/// ## Ce que cette mesure ne fait pas
///
/// Elle ne sépare pas le décalage d'horloge du délai aller, faute d'aller-retour complet
/// (le protocole RAOP ne prévoit pas que le sender interroge le récepteur). Sur un réseau
/// local ce délai est inférieur à la milliseconde, deux ordres de grandeur sous le seuil de
/// perception de 20 à 30 ms visé par le CDC section 8 : la confusion est sans conséquence
/// pratique, et elle est signalée plutôt que masquée.
///
/// **Elle dépend entièrement du bon vouloir du récepteur.** Le champ d'estampille existe dans
/// la requête, mais rien n'oblige un récepteur à le remplir : shairport-sync 5.2.1 envoie ses
/// requêtes **intégralement à zéro** (vérifié en capture, voir `CLAUDE.md`). Les échantillons
/// invraisemblables sont donc rejetés et comptés à part — annoncer un décalage de 3 995 s
/// parce que l'estampille valait zéro serait bien pire que d'annoncer « pas de mesure ».
///
/// Le flux de requêtes reste, lui, un **signal de vie** du récepteur, indépendamment de son
/// contenu : leur interruption prolongée est le premier indice d'une perte de session, et
/// c'est ce qui déclenche la reconnexion automatique.
public final class TimingEstimator: @unchecked Sendable {
    /// Nombre d'écarts conservés. À une requête toutes les 3 s, 32 échantillons couvrent
    /// environ 1 min 30 — assez pour lisser la gigue sans traîner une mesure périmée.
    private static let windowSize = 32

    /// Écart maximal admis entre l'horloge du récepteur et la nôtre, en secondes.
    ///
    /// Une heure : largement au-delà de toute dérive ou de tout décalage de fuseau plausible
    /// entre deux appareils d'un même réseau local, et largement en deçà des 2 209 s… pardon,
    /// des 2 208 988 800 s que produit une estampille laissée à zéro. Le tri est donc franc,
    /// sans zone grise.
    private static let plausibleOffsetLimit: TimeInterval = 3_600

    private var deltas: [TimeInterval] = []
    private var lastSampleUnix: TimeInterval?
    private var totalSamples = 0
    private var unstampedSamples = 0
    private let lock = NSLock()

    public init() {}

    /// Enregistre une requête d'horloge reçue du récepteur.
    ///
    /// Une estampille invraisemblable — typiquement zéro, cas de shairport-sync — est comptée
    /// comme requête reçue (le signal de vie compte) mais **exclue** de la mesure de décalage.
    ///
    /// - Parameters:
    ///   - remoteTransmitUnix: instant d'émission lu dans la requête, sur l'horloge du
    ///     récepteur, converti en temps Unix.
    ///   - localReceiveUnix: instant de réception, sur notre horloge.
    public func record(remoteTransmitUnix: TimeInterval, localReceiveUnix: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        totalSamples += 1
        lastSampleUnix = localReceiveUnix

        let delta = localReceiveUnix - remoteTransmitUnix
        guard abs(delta) <= Self.plausibleOffsetLimit else {
            unstampedSamples += 1
            return
        }
        deltas.append(delta)
        if deltas.count > Self.windowSize { deltas.removeFirst(deltas.count - Self.windowSize) }
    }

    /// État courant de la mesure. Sans échantillon, `offsetSeconds` vaut `nil` : une
    /// estimation absente doit se voir, pas se confondre avec un décalage nul.
    public func snapshot(now: TimeInterval = Date().timeIntervalSince1970) -> TimingSnapshot {
        lock.lock()
        defer { lock.unlock() }
        guard let minimum = deltas.min(), let maximum = deltas.max() else {
            return TimingSnapshot(
                offsetSeconds: nil, spreadSeconds: nil, sampleCount: totalSamples,
                unstampedCount: unstampedSamples,
                secondsSinceLastSample: lastSampleUnix.map { now - $0 }
            )
        }
        return TimingSnapshot(
            offsetSeconds: minimum,
            spreadSeconds: maximum - minimum,
            sampleCount: totalSamples,
            unstampedCount: unstampedSamples,
            secondsSinceLastSample: lastSampleUnix.map { now - $0 }
        )
    }
}

/// Photographie de la mesure de timing d'une sortie.
public struct TimingSnapshot: Sendable, Equatable {
    /// Décalage estimé entre l'horloge du récepteur et la nôtre, en secondes (minimum de la
    /// fenêtre). `nil` tant qu'aucune requête n'a été reçue.
    public let offsetSeconds: TimeInterval?
    /// Étendue des écarts sur la fenêtre : gigue du canal de timing.
    public let spreadSeconds: TimeInterval?
    /// Nombre total de requêtes reçues depuis le début de la session. C'est **ce compteur**,
    /// et non le décalage, qui fait office de signal de vie.
    public let sampleCount: Int
    /// Requêtes reçues sans estampille exploitable (typiquement à zéro). Un compteur égal à
    /// `sampleCount` signifie que ce récepteur n'horodate pas ses requêtes : la mesure de
    /// décalage est impossible avec lui, et son absence n'est pas un défaut du sender.
    public let unstampedCount: Int
    /// Temps écoulé depuis la dernière requête. `nil` s'il n'y en a jamais eu.
    public let secondsSinceLastSample: TimeInterval?

    public init(
        offsetSeconds: TimeInterval?,
        spreadSeconds: TimeInterval?,
        sampleCount: Int,
        unstampedCount: Int = 0,
        secondsSinceLastSample: TimeInterval?
    ) {
        self.offsetSeconds = offsetSeconds
        self.spreadSeconds = spreadSeconds
        self.sampleCount = sampleCount
        self.unstampedCount = unstampedCount
        self.secondsSinceLastSample = secondsSinceLastSample
    }
}
