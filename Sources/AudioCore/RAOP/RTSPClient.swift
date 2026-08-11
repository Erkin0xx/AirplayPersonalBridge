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

    /// Chiffrement du canal, activé après un pair-setup AirPlay 2 réussi.
    ///
    /// Reste `nil` pour RAOP, dont le canal RTSP est en clair : le comportement du sender
    /// du jalon 2 est donc rigoureusement inchangé. Ajouté ici plutôt que dans une
    /// sous-classe parce que le chiffrement s'applique au **transport**, en dessous de la
    /// sémantique RTSP qui, elle, est identique pour les deux protocoles.
    private var controlChannel: AirPlay2ControlChannel?

    /// Tampon des octets chiffrés reçus mais pas encore déchiffrables (bloc incomplet).
    private var pendingCiphertext = Data()

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

    /// Signale la rupture de la connexion de contrôle, une fois celle-ci établie.
    ///
    /// ## Pourquoi ce détour
    ///
    /// Le flux audio circule en **UDP** : un récepteur qui disparaît ne provoque aucune
    /// erreur d'émission, les datagrammes partent indéfiniment dans le vide. La connexion
    /// RTSP, elle, est en TCP et sa rupture est immédiate et sans ambiguïté. C'est donc le
    /// seul signal franc de perte de session côté RAOP — l'équivalent du canal d'événements
    /// pour AirPlay 2.
    ///
    /// Le premier candidat, l'arrêt des requêtes d'horloge du récepteur, s'est révélé
    /// **inutilisable comme critère** : shairport-sync interroge densément pendant la
    /// trentaine de secondes qui suit le `RECORD`, puis se tait pendant que la session se
    /// porte parfaitement (mesuré au jalon 4). En faire une condition de perte déclenchait une
    /// reconnexion sur une session saine.
    ///
    /// Remplace le gestionnaire d'état posé par ``connect(timeout:)``, dont la continuation
    /// est déjà reprise à ce stade.
    public func onConnectionLost(_ handler: @escaping @Sendable () -> Void) {
        connection?.stateUpdateHandler = { state in
            switch state {
            case .failed, .cancelled:
                handler()
            default:
                break
            }
        }
    }

    public func disconnect() {
        // Le gestionnaire doit partir avant l'annulation : sans cela, un arrêt volontaire se
        // signalerait lui-même comme une perte de session et déclencherait une reconnexion.
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
        pendingData.removeAll(keepingCapacity: false)
        pendingCiphertext.removeAll(keepingCapacity: false)
        controlChannel = nil
    }

    /// Bascule le canal en chiffré, à l'issue d'un pair-setup AirPlay 2.
    ///
    /// À n'appeler qu'une fois la réponse M4 **entièrement lue** : le récepteur chiffre à
    /// partir du message suivant, et anticiper ferait déchiffrer une réponse en clair.
    /// Sans appel, le client reste en clair — c'est le cas RAOP.
    public func enableEncryption(keys: AirPlay2PairingSession.SessionKeys) throws {
        controlChannel = try AirPlay2ControlChannel(keys: keys)
        log.info("canal de contrôle chiffré (ChaCha20-Poly1305)")
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
        // Ces deux en-têtes ne sont ajoutés que si l'appelant ne les a pas déjà posés. Sans
        // cette garde, une requête AirPlay 2 — qui fixe son propre `User-Agent` et son
        // `Client-Instance` — partait avec chacun **en double**. airplay2-receiver l'acceptait ;
        // un HomePod réel ne répond alors tout simplement pas au `SETUP` (constaté le
        // 2026-08-11 : 810 octets émis, aucun octet en retour, connexion laissée ouverte).
        func appendIfAbsent(_ name: String, _ value: String) {
            guard !outgoing.headers.contains(where: { $0.name.lowercased() == name.lowercased() })
            else { return }
            outgoing.headers.append((name, value))
        }
        appendIfAbsent("User-Agent", "AirPlayMultiOutput/1.0")
        appendIfAbsent("Client-Instance", clientInstance)

        var payload = outgoing.serialized()
        if let controlChannel {
            payload = try controlChannel.outbound.seal(payload)
        }
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
            let chunk = try await receiveChunk(deadline: deadline, method: method)
            guard !chunk.isEmpty else { throw RTSPError.malformedResponse }
            if let controlChannel {
                // Canal chiffré : les octets reçus sont accumulés jusqu'à former des blocs
                // complets. Un bloc partiel reste en attente — c'est le cas normal en TCP.
                pendingCiphertext.append(chunk)
                let (plaintext, consumed) = try controlChannel.inbound.open(pendingCiphertext)
                if consumed > 0 {
                    pendingCiphertext.removeFirst(consumed)
                }
                pendingData.append(plaintext)
            } else {
                pendingData.append(chunk)
            }
        }
    }

    /// Lit un fragment, avec une échéance **propre à la lecture**.
    ///
    /// `NWConnection.receive` peut ne jamais rappeler : c'est le cas quand le pair disparaît
    /// sans fermer proprement — précisément ce que fait le mock RAOP, qui quitte dès le
    /// `TEARDOWN` reçu. Sans échéance ici, l'attente est infinie et le processus ne se
    /// termine jamais, alors même que toute la diffusion s'est bien passée.
    ///
    /// Vérifier le délai seulement **entre** deux lectures, comme le faisait la première
    /// version, ne suffit pas : le contrôle n'y revient jamais.
    private func receiveChunk(deadline: ContinuousClock.Instant, method: String) async throws -> Data {
        guard let connection else { throw RTSPError.notConnected }
        let box = ReceiveResumeBox()
        return try await withCheckedThrowingContinuation { continuation in
            box.attach(continuation)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) {
                data, _, isComplete, error in
                if let error {
                    box.fail(RTSPError.connectionFailed(String(describing: error)))
                } else if let data, !data.isEmpty {
                    box.succeed(data)
                } else if isComplete {
                    box.fail(RTSPError.connectionFailed("flux RTSP fermé"))
                } else {
                    box.succeed(Data())
                }
            }
            Task {
                let remaining = deadline - ContinuousClock.now
                if remaining > .zero {
                    try? await Task.sleep(for: remaining)
                }
                box.fail(RTSPError.timedOut(method: method))
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

/// Garantit qu'une continuation de lecture n'est reprise qu'une seule fois.
///
/// Deux chemins peuvent la reprendre en concurrence : le callback de `NWConnection.receive`
/// et l'échéance de lecture. Reprendre deux fois une `CheckedContinuation` est une erreur
/// fatale à l'exécution, d'où ce verrou.
private final class ReceiveResumeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data, Error>?

    func attach(_ continuation: CheckedContinuation<Data, Error>) {
        lock.lock()
        self.continuation = continuation
        lock.unlock()
    }

    func succeed(_ data: Data) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: data)
    }

    func fail(_ error: Error) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(throwing: error)
    }
}
