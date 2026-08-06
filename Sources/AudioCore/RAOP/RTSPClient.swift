import Foundation
import Network
import OSLog

public enum RTSPError: Error, CustomStringConvertible {
    case connectionFailed(String)
    case notConnected
    case timedOut(method: String)
    case unexpectedStatus(method: String, code: Int, reason: String)
    case missingHeader(String)
    case malformedResponse

    public var description: String {
        switch self {
        case let .connectionFailed(reason):
            return "connexion RTSP impossible : \(reason)"
        case .notConnected:
            return "requête RTSP émise hors connexion"
        case let .timedOut(method):
            return "pas de réponse du récepteur à \(method)"
        case let .unexpectedStatus(method, code, reason):
            return "\(method) refusé par le récepteur : \(code) \(reason)"
        case let .missingHeader(name):
            return "en-tête « \(name) » absent de la réponse"
        case .malformedResponse:
            return "réponse RTSP illisible"
        }
    }
}

/// Connexion RTSP vers un récepteur RAOP : une requête à la fois, réponses appariées par
/// ordre d'émission.
///
/// Un acteur plutôt qu'une classe verrouillée : RTSP est séquentiel par nature, et l'isolement
/// d'acteur exprime directement cette contrainte. On est ici sur le canal de contrôle, hors
/// de la frontière temps réel — Swift Concurrency y est le bon outil (CDC section 13).
public actor RTSPClient {
    private let host: String
    private let port: UInt16
    private var connection: NWConnection?
    private var pendingData = Data()
    private var sequenceNumber = 0
    private let log = AudioLog.raop

    /// Identifiant de client, repris tel quel dans `Client-Instance` et l'URI de session.
    /// Aléatoire par session, comme le fait tout sender RAOP.
    public let clientInstance: String
    /// Adresse locale vue par le récepteur, connue seulement une fois la connexion établie.
    /// Elle alimente le champ `o=` du SDP, que certains récepteurs recoupent.
    public private(set) var localAddress: String = "0.0.0.0"

    public init(host: String, port: UInt16, clientInstance: String? = nil) {
        self.host = host
        self.port = port
        self.clientInstance = clientInstance
            ?? String(format: "%016llX", UInt64.random(in: .min ... .max))
    }

    // MARK: - Cycle de vie

    public func connect(timeout: Duration = .seconds(10)) async throws {
        guard connection == nil else { return }
        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port) ?? .any
        )
        // TCP sans délai : les requêtes RTSP sont petites et l'algorithme de Nagle
        // ajouterait une latence inutile à chaque aller-retour du handshake.
        let parameters = NWParameters.tcp
        if let tcp = parameters.defaultProtocolStack.internetProtocol as? NWProtocolTCP.Options {
            tcp.noDelay = true
        }
        let connection = NWConnection(to: endpoint, using: parameters)
        self.connection = connection

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let box = ConnectResumeBox(continuation: continuation)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    box.succeed()
                case let .failed(error):
                    box.fail(RTSPError.connectionFailed(String(describing: error)))
                case .cancelled:
                    box.fail(RTSPError.connectionFailed("connexion annulée"))
                default:
                    break
                }
            }
            connection.start(queue: .global(qos: .userInitiated))
            Task {
                try? await Task.sleep(for: timeout)
                box.fail(RTSPError.connectionFailed("délai d'établissement dépassé"))
            }
        }

        if case let .hostPort(localHost, _) = connection.currentPath?.localEndpoint {
            localAddress = Self.literal(from: localHost)
        }
        log.info("RTSP connecté à \(self.host, privacy: .public):\(self.port) (local \(self.localAddress, privacy: .public))")
    }

    public func disconnect() {
        connection?.cancel()
        connection = nil
        pendingData.removeAll(keepingCapacity: false)
    }

    // MARK: - Requêtes

    /// Émet une requête et attend sa réponse.
    ///
    /// `CSeq` et `Client-Instance` sont ajoutés ici : les oublier fait échouer le handshake
    /// sur certains récepteurs sans message d'erreur explicite.
    @discardableResult
    public func send(
        _ request: RTSPRequest,
        timeout: Duration = .seconds(10)
    ) async throws -> RTSPResponse {
        guard let connection else { throw RTSPError.notConnected }
        sequenceNumber += 1

        var outgoing = request
        outgoing.headers.insert(("CSeq", String(sequenceNumber)), at: 0)
        outgoing.headers.append(("User-Agent", "AirPlayMultiOutput/1.0"))
        outgoing.headers.append(("Client-Instance", clientInstance))

        let payload = outgoing.serialized()
        log.debug("→ \(outgoing.method, privacy: .public) \(outgoing.uri, privacy: .public) (CSeq \(self.sequenceNumber))")

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: payload, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: RTSPError.connectionFailed(String(describing: error)))
                } else {
                    continuation.resume()
                }
            })
        }

        let response = try await readResponse(method: outgoing.method, timeout: timeout)
        log.debug("← \(response.statusCode) \(response.reasonPhrase, privacy: .public)")
        guard response.isSuccess else {
            throw RTSPError.unexpectedStatus(
                method: outgoing.method, code: response.statusCode, reason: response.reasonPhrase
            )
        }
        return response
    }

    /// Lit jusqu'à disposer d'une réponse complète, en conservant le surplus éventuel.
    private func readResponse(method: String, timeout: Duration) async throws -> RTSPResponse {
        let deadline = ContinuousClock.now + timeout
        while true {
            if let (response, consumed) = RTSPResponse.parse(pendingData) {
                pendingData.removeFirst(consumed)
                return response
            }
            guard ContinuousClock.now < deadline else {
                throw RTSPError.timedOut(method: method)
            }
            let chunk = try await receiveChunk()
            guard !chunk.isEmpty else { throw RTSPError.malformedResponse }
            pendingData.append(chunk)
        }
    }

    private func receiveChunk() async throws -> Data {
        guard let connection else { throw RTSPError.notConnected }
        return try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) {
                data, _, isComplete, error in
                if let error {
                    continuation.resume(
                        throwing: RTSPError.connectionFailed(String(describing: error)))
                } else if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                } else if isComplete {
                    continuation.resume(throwing: RTSPError.connectionFailed("flux RTSP fermé"))
                } else {
                    continuation.resume(returning: Data())
                }
            }
        }
    }

    private static func literal(from host: NWEndpoint.Host) -> String {
        switch host {
        case let .ipv4(address):
            return address.debugDescription.components(separatedBy: "%")[0]
        case let .ipv6(address):
            return address.debugDescription.components(separatedBy: "%")[0]
        case let .name(name, _):
            return name
        @unknown default:
            return String(describing: host)
        }
    }
}

/// Reprise unique d'une continuation, que ce soit par succès, échec ou expiration du délai.
private final class ConnectResumeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?

    init(continuation: CheckedContinuation<Void, Error>) {
        self.continuation = continuation
    }

    func succeed() {
        take()?.resume()
    }

    func fail(_ error: Error) {
        take()?.resume(throwing: error)
    }

    private func take() -> CheckedContinuation<Void, Error>? {
        lock.lock()
        defer { lock.unlock() }
        let pending = continuation
        continuation = nil
        return pending
    }
}
