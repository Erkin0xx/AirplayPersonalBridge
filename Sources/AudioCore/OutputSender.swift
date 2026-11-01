import AVFoundation
import Foundation

/// État d'une sortie vu du moteur, commun aux deux protocoles.
public enum OutputSenderState: String, Sendable {
    case idle
    case connecting
    case streaming
    /// Session perdue, le sender la rétablit de lui-même (CDC section 8).
    case reconnecting
    case failed
}

/// Une sortie, quel que soit son protocole.
///
/// Injectée par protocole (CDC section 13) pour tester le moteur sans récepteur. Invariant
/// section 12 : un sender lit son ring buffer, et ignore la source comme les autres sorties.
public protocol OutputSender: Actor {
    /// Alignement et dérive de cette sortie. Lisible sans suspension.
    nonisolated var synchronizer: OutputSynchronizer { get }

    /// Établit la session et démarre la diffusion.
    func start(volume: Float) async throws
    /// Arrête la diffusion et libère la session. Idempotent.
    func stop() async
    func setVolume(_ volume: Float) async throws
    func setManualDelay(seconds: TimeInterval)
    /// Renfort de basses, en dB. Applicable à tout moment, et conservé d'une reconnexion à l'autre.
    func setBassBoost(decibels: Float)

    /// État courant. Lu périodiquement : c'est ce qui fait remonter une reconnexion.
    func currentOutputState() -> OutputSenderState
    /// Dernière erreur de session, rédigée pour l'affichage, ou `nil`. N'est lue qu'en
    /// `reconnecting` et en `failed` : c'est la raison d'un état, pas un historique.
    func currentOutputError() -> String?
    /// Compteurs courants, ramenés à la forme commune.
    func currentOutputStatistics() -> OutputStatistics
}

/// Compteurs d'une sortie, reflet fidèle des `Statistics` de chaque sender.
///
/// **Un compteur qu'un protocole ne mesure pas reste `nil`**, jamais zéro : le panneau de
/// diagnostic doit pouvoir distinguer « aucune retransmission demandée » de « cette notion
/// n'existe pas pour cette sortie ».
public struct OutputStatistics: Sendable, Equatable {
    public var packetsSent = 0
    public var framesRead = 0
    public var errors = 0
    public var resyncs = 0
    public var syncPacketsSent = 0
    /// Annonces portant un ancrage issu de l'horloge commune. L'écart avec `syncPacketsSent`
    /// mesure celles qui ont dû retomber sur « maintenant ».
    public var anchoredSyncPackets = 0
    public var framesInserted = 0
    public var framesRemoved = 0
    public var reconnections = 0
    public var reconnectionAttempts = 0
    /// Trames refusées par le ring buffer avant le premier paquet émis, imputables à la seule
    /// négociation.
    public var droppedBeforeStreaming = 0

    /// RAOP : réponses aux requêtes d'horloge du récepteur.
    public var timingResponsesSent: Int?
    /// RAOP : `Audio-Latency` annoncée par le récepteur, en trames. `nil` s'il n'annonce rien.
    public var reportedLatencyFrames: Int?
    /// RAOP : dernier volume accepté par le récepteur, en dB.
    public var volumeDB: Float?
    /// AirPlay 2 : demandes de retransmission reçues.
    public var retransmitRequests: Int?
    /// AirPlay 2 : `audioBufferSize` brut, unité non établie (voir `AirPlay2Statistics`).
    public var receiverBufferSize: Int?
    /// AirPlay 2 : canal d'événements ouvert.
    public var eventChannelConnected: Bool?

    public init() {}
}

extension RAOPSender: OutputSender {
    public func currentOutputError() -> String? { lastErrorMessage }

    public func currentOutputState() -> OutputSenderState {
        switch state {
        case .idle: return .idle
        case .connecting: return .connecting
        case .streaming: return .streaming
        case .reconnecting: return .reconnecting
        case .failed: return .failed
        }
    }

    public func currentOutputStatistics() -> OutputStatistics {
        let source = statistics
        var result = OutputStatistics()
        result.packetsSent = source.packetsSent
        result.framesRead = source.framesRead
        result.errors = source.errors
        result.resyncs = source.resyncs
        result.syncPacketsSent = source.syncPacketsSent
        result.anchoredSyncPackets = source.anchoredSyncPackets
        result.framesInserted = source.framesInserted
        result.framesRemoved = source.framesRemoved
        result.reconnections = source.reconnections
        result.reconnectionAttempts = source.reconnectionAttempts
        result.droppedBeforeStreaming = source.droppedBeforeStreaming
        result.timingResponsesSent = source.timingResponsesSent
        // Zéro veut dire « non annoncée », le sender ne touchant au champ que si l'en-tête
        // `Audio-Latency` est présent.
        result.reportedLatencyFrames =
            source.reportedLatencyFrames > 0 ? source.reportedLatencyFrames : nil
        result.volumeDB = source.volume
        return result
    }
}

extension AirPlay2Sender: OutputSender {
    /// Le CDC ne prévoit le renfort que pour la Geneva : les HomePod gardent une stéréo pleine
    /// bande intacte. Le moteur ne l'appelle d'ailleurs pas sur cette sortie.
    public func setBassBoost(decibels: Float) {}

    public func currentOutputError() -> String? { statistics.lastFailure }

    public func currentOutputState() -> OutputSenderState {
        switch state {
        case .idle: return .idle
        case .connecting: return .connecting
        case .streaming: return .streaming
        case .reconnecting: return .reconnecting
        case .failed: return .failed
        }
    }

    public func currentOutputStatistics() -> OutputStatistics {
        let source = statistics
        var result = OutputStatistics()
        result.packetsSent = source.packetsSent
        result.framesRead = source.framesRead
        result.errors = source.errors
        result.resyncs = source.resyncs
        result.syncPacketsSent = source.syncPacketsSent
        result.anchoredSyncPackets = source.anchoredSyncPackets
        result.framesInserted = source.framesInserted
        result.framesRemoved = source.framesRemoved
        result.reconnections = source.reconnections
        result.reconnectionAttempts = source.reconnectionAttempts
        result.droppedBeforeStreaming = source.droppedBeforeStreaming
        result.retransmitRequests = source.retransmitRequests
        result.receiverBufferSize = source.receiverBufferSize
        result.eventChannelConnected = source.eventChannelConnected
        return result
    }
}

/// Ce dont un sender a besoin pour se brancher sur la capture.
public struct OutputSenderContext: @unchecked Sendable {
    /// Le tampon **propre à cette sortie** (invariant section 12).
    public let ring: AudioRingBuffer
    /// `AVAudioFormat` est immuable une fois créé, d'où le `@unchecked`.
    public let captureFormat: AVAudioFormat
    /// L'horloge commune à toutes les sorties : c'est elle qui les aligne.
    public let clock: PlaybackClockProtocol

    public init(ring: AudioRingBuffer, captureFormat: AVAudioFormat, clock: PlaybackClockProtocol) {
        self.ring = ring
        self.captureFormat = captureFormat
        self.clock = clock
    }
}

/// Fabrique un sender pour une sortie demandée. La découverte Bonjour se fait ici, ce qui permet
/// aux tests de s'en passer.
public protocol OutputSenderFactory: Sendable {
    func makeSender(
        for request: BridgeEngine.OutputRequest,
        context: OutputSenderContext
    ) async throws -> any OutputSender
}

/// Fabrique réelle : découverte Bonjour, puis `RAOPSender` ou `AirPlay2Sender`.
public struct LiveOutputSenderFactory: OutputSenderFactory {
    /// Cherche un récepteur : nom, façon de le comparer, nombre de parcours (`nil` : le défaut de la
    /// découverte). Injecté : aucun test ne doit interroger le réseau, où se trouve le vrai matériel.
    typealias RAOPFinder =
        @Sendable (String, ReceiverNameMatching, Int?) async throws -> RAOPDevice
    typealias AirPlay2Finder =
        @Sendable (String, ReceiverNameMatching, Int?) async throws -> AirPlay2Device

    private let findRAOP: RAOPFinder
    private let findAirPlay2: AirPlay2Finder

    public init() {
        self.init(
            findRAOP: { name, matching, passes in
                guard let passes else {
                    return try await RAOPDiscovery().find(named: name, matching: matching)
                }
                return try await RAOPDiscovery().find(
                    named: name, matching: matching, attempts: passes)
            },
            findAirPlay2: { name, matching, passes in
                guard let passes else {
                    return try await AirPlay2Discovery().find(named: name, matching: matching)
                }
                return try await AirPlay2Discovery().find(
                    named: name, matching: matching, attempts: passes)
            }
        )
    }

    init(findRAOP: @escaping RAOPFinder, findAirPlay2: @escaping AirPlay2Finder) {
        self.findRAOP = findRAOP
        self.findAirPlay2 = findAirPlay2
    }

    public func makeSender(
        for request: BridgeEngine.OutputRequest,
        context: OutputSenderContext
    ) async throws -> any OutputSender {
        // La découverte s'écoule toujours jusqu'au bout de son délai, annulation ou non. Elle
        // part donc à côté : une sortie retirée pendant le parcours rend la main aussitôt, et
        // le parcours se termine de lui-même sans rien retenir.
        switch request.proto {
        case .raop:
            let device = try await untilCancelled { [findRAOP] in
                try await findRAOP(request.deviceName, request.nameMatching, nil)
            }
            return RAOPSender(
                device: device, ring: context.ring, captureFormat: context.captureFormat,
                clock: context.clock
            )
        case .airplay2:
            let device = try await untilCancelled { [findAirPlay2] in
                try await findAirPlay2(request.deviceName, request.nameMatching, nil)
            }
            return AirPlay2Sender(
                device: device, ring: context.ring, captureFormat: context.captureFormat,
                clock: context.clock, credentials: request.credentials
            )
        }
    }
}

/// Exécute une opération qu'on ne sait pas interrompre, en rendant la main dès l'annulation.
///
/// L'opération continue alors dans son coin et son résultat est perdu : à réserver à ce qui se
/// termine de soi-même dans un délai borné.
func untilCancelled<T: Sendable>(
    _ operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    let once = OnceThrowingResumer<T>()
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
            once.attach(continuation)
            Task {
                do { once.resume(returning: try await operation()) } catch {
                    once.resume(throwing: error)
                }
            }
        }
    } onCancel: {
        once.resume(throwing: CancellationError())
    }
}

/// Garantit la reprise unique d'une continuation entre plusieurs chemins concurrents, l'annulation
/// pouvant survenir avant même que la continuation existe.
final class OnceThrowingResumer<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    private var earlyResult: Result<T, Error>?
    private var finished = false

    func attach(_ continuation: CheckedContinuation<T, Error>) {
        lock.lock()
        if let earlyResult {
            self.earlyResult = nil
            lock.unlock()
            continuation.resume(with: earlyResult)
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    func resume(returning value: T) { finish(.success(value)) }
    func resume(throwing error: Error) { finish(.failure(error)) }

    private func finish(_ result: Result<T, Error>) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        guard let pending = continuation else {
            earlyResult = result
            lock.unlock()
            return
        }
        continuation = nil
        lock.unlock()
        pending.resume(with: result)
    }
}

/// Un échec qu'un nouvel essai ne peut pas résoudre.
///
/// Réessayer indéfiniment ne se justifie que si le récepteur peut revenir : une enceinte éteinte
/// ou un réseau coupé, oui ; un récepteur qui n'implémente pas ce qu'on lui demande, non. Le
/// défaut est donc de réessayer, et ne sont permanents que les refus explicites de capacité ou
/// d'authentification.
func isPermanentOutputFailure(_ error: Error) -> Bool {
    switch error {
    case is RAOPSenderError:
        return true
    case let airplay2 as AirPlay2SenderError:
        // Le sender traduit ses erreurs pour l'affichage : sans ce cas, un Apple TV qui répond
        // 470 serait relancé sans fin, chaque tentative refaisant une négociation pour rien.
        return airplay2.isPermanent
    case let rtsp as RTSPError:
        // 401/403/470 : le récepteur réclame une authentification que ce client n'a pas. Un
        // Apple TV refuse ainsi le pairing transitoire. Les autres statuts (453 « occupé »,
        // 5xx) peuvent se résorber d'eux-mêmes.
        if case let .unexpectedStatus(_, code, _) = rtsp {
            return code == 401 || code == 403 || code == 470
        }
        return false
    case let pairing as AirPlay2PairingSession.Failure:
        switch pairing {
        case .transientPairingUnsupported, .receiverIdentityMismatch, .receiverSignatureInvalid:
            return true
        case let .receiverRejected(reason, _):
            switch reason {
            case .authentication, .maxPeers, .unavailable: return true
            case .unknown, .backoff, .maxTries, .busy: return false
            }
        case .malformedResponse, .unexpectedState:
            return false
        }
    default:
        return false
    }
}
