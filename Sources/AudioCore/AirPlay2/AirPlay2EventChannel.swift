import Foundation
import Network
import OSLog

/// Canal d'événements AirPlay 2.
///
/// Le premier `SETUP` (celui **sans** clé `streams`) rend un `eventPort` : une écoute TCP
/// côté récepteur, sur laquelle il pousse ses changements d'état. Le jalon 3 récupérait ce
/// port sans jamais s'y connecter ; c'est fait ici.
///
/// ## Ce qu'il apporte
///
/// D'abord la **détection de perte de session**. Le canal audio étant en UDP, un récepteur qui
/// disparaît ne provoque aucune erreur d'émission : les datagrammes partent dans le vide
/// indéfiniment. La rupture de cette connexion TCP, elle, est immédiate et sans ambiguïté.
///
/// Ensuite la **politesse protocolaire** : sur du matériel réel, le récepteur pose ici des
/// requêtes de type RTSP, chiffrées, et attend une réponse. pyatv répond `200` à chacune
/// « pour satisfaire l'autre bout du canal » (`EventChannel.handle_received`, dans
/// `airplay/channels.py`). Ce canal fait de même dès qu'on lui confie le secret de session.
///
/// ## Ce qu'il n'apporte pas
///
/// **Le contenu des événements n'est pas interprété**, et c'est délibéré. pyatv lui-même ne
/// s'en sert pas : aucune référence disponible n'établit le format d'un volume changé à distance
/// ou d'un arrêt côté récepteur, et le mock n'émet rien (`EventGeneric` lit et jette). Les
/// décoder à l'aveugle serait de la fiction : les requêtes sont comptées et journalisées, un
/// arrêt côté récepteur se voyant de toute façon à la fermeture de la connexion.
///
/// ## Invariant section 12
///
/// Une panne ici est confinée : l'échec de connexion est journalisé et signalé, jamais
/// propagé au point d'interrompre la diffusion. Un contenu indéchiffrable arrête le décodage,
/// pas le canal. Ce canal est un observateur, pas un maillon du chemin audio.
public final class AirPlay2EventChannel: @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "fr.baptiste.airplaymultioutput.airplay2.events")
    private let log = AudioLog.airplay2
    private let lock = NSLock()

    private var bytesReceived = 0
    private var messagesReceived = 0
    private var deferredAttempts = 0
    private var connected = false
    private var closed = false
    /// Appelé si la connexion tombe alors qu'elle avait été établie.
    private var onDisconnect: (@Sendable () -> Void)?
    /// Appelé pour chaque requête déchiffrée, sur la file du canal.
    private let onMessage: (@Sendable (AirPlay2EventRequest) -> Void)?
    /// Confiné à `queue`. `nil` tant qu'on n'a pas de secret : les octets sont alors seulement
    /// comptés, comme aux jalons précédents.
    private let decoder: AirPlay2EventDecoder?

    /// - Parameters:
    ///   - sessionSecret: secret issu du pairing, dont dérivent les clés de ce canal. Sans lui,
    ///     les octets reçus sont comptés sans être déchiffrés.
    ///   - onMessage: appelé pour chaque requête déchiffrée.
    public init(
        host: String,
        port: UInt16,
        sessionSecret: Data? = nil,
        onMessage: (@Sendable (AirPlay2EventRequest) -> Void)? = nil
    ) {
        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port) ?? .any
        )
        self.connection = NWConnection(to: endpoint, using: .tcp)
        self.onMessage = onMessage
        self.decoder = sessionSecret.flatMap { try? AirPlay2EventDecoder(sessionSecret: $0) }
    }

    /// Ouvre la connexion. Rend `true` si le récepteur l'a acceptée avant l'échéance.
    ///
    /// Ne lève jamais : un canal d'événements indisponible ne doit pas empêcher de diffuser.
    @discardableResult
    public func connect(
        timeout: Duration = .seconds(3),
        onDisconnect: (@Sendable () -> Void)? = nil
    ) async -> Bool {
        // `withLock` et non `lock()`/`unlock()` : ces derniers sont interdits en contexte
        // asynchrone, un verrou ne devant jamais chevaucher un point de suspension.
        lock.withLock { self.onDisconnect = onDisconnect }

        let established = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            // Reprise unique garantie : une `CheckedContinuation` reprise deux fois est
            // fatale, et le piège relevé au jalon 3 (échéance et état concurrents) s'applique
            // ici mot pour mot.
            let resumed = ManagedFlag()
            let connection = self.connection
            connection.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    if resumed.claim() { continuation.resume(returning: true) }
                case let .failed(error):
                    self.log.error(
                        "Canal d'événements indisponible : \(String(describing: error), privacy: .public)"
                    )
                    if resumed.claim() { continuation.resume(returning: false) }
                    else { self.reportDisconnect() }
                case .waiting:
                    // Un port pas encore ouvert laisse la connexion en attente d'un changement
                    // de réseau qui ne viendra pas. pyatv le constate contre le mock, qui ouvre
                    // ce canal un peu après avoir répondu au `SETUP`, et réessaie : idem ici,
                    // dans la limite de l'échéance.
                    self.lock.withLock { self.deferredAttempts += 1 }
                    self.queue.asyncAfter(deadline: .now() + 0.5) {
                        if case .waiting = connection.state { connection.restart() }
                    }
                case .cancelled:
                    if resumed.claim() { continuation.resume(returning: false) }
                    else { self.reportDisconnect() }
                default:
                    break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout.timeIntervalValue) {
                if resumed.claim() {
                    continuation.resume(returning: false)
                    // Ne pas laisser une tentative en suspens aboutir plus tard : personne ne
                    // lirait cette connexion.
                    connection.cancel()
                }
            }
        }

        lock.withLock { connected = established }
        if established {
            log.info("Canal d'événements AirPlay 2 ouvert")
            receiveLoop()
        }
        return established
    }

    /// Lecture continue : voir la connexion tomber, et répondre aux requêtes du récepteur.
    private func receiveLoop() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4_096) {
            [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.lock.withLock { self.bytesReceived += data.count }
                self.absorb(data)
            }
            if isComplete || error != nil {
                self.reportDisconnect()
                return
            }
            self.receiveLoop()
        }
    }

    /// Déchiffre ce qui peut l'être et répond au récepteur. Exécuté sur `queue`.
    private func absorb(_ data: Data) {
        guard let decoder else {
            log.debug("Canal d'événements : \(data.count) octets reçus (non décodés)")
            return
        }
        let wasFailed = decoder.hasFailed
        let (requests, reply) = decoder.absorb(data)
        if decoder.hasFailed, !wasFailed {
            log.error("Canal d'événements : contenu indéchiffrable, décodage abandonné")
        }
        for request in requests {
            lock.withLock { messagesReceived += 1 }
            log.info(
                "Événement du récepteur : \(request.method, privacy: .public) \(request.uri, privacy: .public)"
            )
            onMessage?(request)
        }
        if !reply.isEmpty {
            connection.send(content: reply, completion: .contentProcessed { [weak self] error in
                if let error {
                    self?.log.error(
                        "Réponse au canal d'événements en échec : \(String(describing: error), privacy: .public)"
                    )
                }
            })
        }
    }

    private func reportDisconnect() {
        lock.lock()
        let shouldReport = connected && !closed
        connected = false
        let handler = onDisconnect
        lock.unlock()
        guard shouldReport else { return }
        log.error("Canal d'événements AirPlay 2 rompu")
        handler?()
    }

    public var isConnected: Bool {
        lock.lock(); defer { lock.unlock() }; return connected
    }

    public var eventBytesReceived: Int {
        lock.lock(); defer { lock.unlock() }; return bytesReceived
    }

    /// Requêtes du récepteur déchiffrées et acquittées.
    public var eventMessagesReceived: Int {
        lock.lock(); defer { lock.unlock() }; return messagesReceived
    }

    /// Fois où la connexion a dû attendre un port pas encore ouvert. C'est ce qui permet à un test
    /// d'ouvrir ce port après un refus constaté, plutôt qu'après un délai supposé suffisant.
    var connectionAttemptsDeferred: Int {
        lock.lock(); defer { lock.unlock() }; return deferredAttempts
    }

    public func close() {
        lock.lock()
        closed = true
        connected = false
        onDisconnect = nil
        lock.unlock()
        connection.cancel()
    }

    deinit {
        connection.cancel()
    }
}

/// Une requête reçue sur le canal d'événements, sous sa forme `POST /x RTSP/1.0`.
public struct AirPlay2EventRequest: Sendable, Equatable {
    public let method: String
    public let uri: String
    /// `RTSP/1.0`, repris tel quel dans la réponse.
    public let protocolVersion: String
    /// Noms en minuscules, comme dans `RTSPResponse`.
    public let headers: [String: String]
    public let body: Data

    /// Analyse une requête complète en tête de `data`.
    ///
    /// - Returns: `nil` si le message est encore incomplet, le cas normal en TCP.
    /// - Throws: ``Malformed`` si la ligne de requête est illisible : attendre davantage
    ///   d'octets n'y changerait rien.
    static func parse(_ data: Data) throws -> (request: AirPlay2EventRequest, consumed: Int)? {
        guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        guard let text = String(data: data[data.startIndex..<headerEnd.lowerBound], encoding: .utf8)
        else { throw Malformed() }

        var lines = text.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { throw Malformed() }
        let requestLine = lines.removeFirst().split(separator: " ").map(String.init)
        guard requestLine.count == 3, requestLine[2].contains("/") else { throw Malformed() }

        var headers: [String: String] = [:]
        for line in lines {
            guard let separator = line.firstIndex(of: ":") else { continue }
            headers[line[line.startIndex..<separator].lowercased()] =
                line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
        }

        let bodyLength = headers["content-length"].flatMap(Int.init) ?? 0
        guard bodyLength >= 0 else { throw Malformed() }
        let bodyStart = headerEnd.upperBound
        guard data.distance(from: bodyStart, to: data.endIndex) >= bodyLength else { return nil }
        let bodyEnd = data.index(bodyStart, offsetBy: bodyLength)

        let request = AirPlay2EventRequest(
            method: requestLine[0],
            uri: requestLine[1],
            protocolVersion: requestLine[2],
            headers: headers,
            body: Data(data[bodyStart..<bodyEnd])
        )
        return (request, data.distance(from: data.startIndex, to: bodyEnd))
    }

    struct Malformed: Error {}
}

/// Déchiffre le canal d'événements et prépare les réponses.
///
/// Même cadrage que le canal de contrôle (blocs de 1 024 o, compteurs distincts par sens), avec
/// ses propres clés. **Les infos HKDF sont inversées par rapport au canal de contrôle**, la
/// connexion étant vue comme émanant du récepteur : on écrit avec la clé « Read » et on lit avec
/// la clé « Write » (`ap2_session.py` et `airplayv2.py` de pyatv, qui le signalent en commentaire).
///
/// Pur et sans réseau, pour être testable. Non `Sendable` : confiné à la file du canal.
final class AirPlay2EventDecoder {
    static let salt = "Events-Salt"
    static let writeInfo = "Events-Write-Encryption-Key"
    static let readInfo = "Events-Read-Encryption-Key"
    /// Identifie ce sender dans ses réponses, comme le `Server: pyatv-www/…` de pyatv.
    private static let serverName = "AirPlayMultiOutput/1.0"

    private let outbound: AirPlay2ControlChannel.Direction
    private let inbound: AirPlay2ControlChannel.Direction
    private var ciphertext = Data()
    private var plaintext = Data()

    /// Vrai dès qu'un contenu n'a pas pu être lu. Le flux TCP ne se resynchronise pas : tout ce
    /// qui suit est ignoré, sans fermer la connexion — elle garde son rôle de signal de vie.
    private(set) var hasFailed = false

    init(sessionSecret: Data) throws {
        outbound = try AirPlay2ControlChannel.Direction(
            key: HKDF512.derive(secret: sessionSecret, salt: Self.salt, info: Self.readInfo)
        )
        inbound = try AirPlay2ControlChannel.Direction(
            key: HKDF512.derive(secret: sessionSecret, salt: Self.salt, info: Self.writeInfo)
        )
    }

    /// Absorbe des octets chiffrés.
    ///
    /// - Returns: les requêtes complètes, et les réponses chiffrées à émettre pour elles.
    func absorb(_ bytes: Data) -> (requests: [AirPlay2EventRequest], reply: Data) {
        guard !hasFailed else { return ([], Data()) }
        ciphertext.append(bytes)

        var requests: [AirPlay2EventRequest] = []
        var reply = Data()
        do {
            let (clear, consumed) = try inbound.open(ciphertext)
            ciphertext.removeFirst(consumed)
            plaintext.append(clear)

            while let (request, consumed) = try AirPlay2EventRequest.parse(plaintext) {
                plaintext.removeFirst(consumed)
                requests.append(request)
                reply.append(try outbound.seal(Self.acknowledgement(of: request)))
            }
        } catch {
            hasFailed = true
            ciphertext.removeAll()
            plaintext.removeAll()
        }
        return (requests, reply)
    }

    /// Réponse positive, à l'identique de `EventChannel.handle_received` de pyatv.
    static func acknowledgement(of request: AirPlay2EventRequest) -> Data {
        var text = "\(request.protocolVersion) 200 OK\r\n"
        text += "Server: \(request.headers["server"] ?? serverName)\r\n"
        text += "Content-Length: 0\r\n"
        text += "Audio-Latency: 0\r\n"
        if let cseq = request.headers["cseq"] {
            text += "CSeq: \(cseq)\r\n"
        }
        text += "\r\n"
        return Data(text.utf8)
    }
}

/// Drapeau à usage unique, pour garantir qu'une continuation n'est reprise qu'une fois.
final class ManagedFlag: @unchecked Sendable {
    private var taken = false
    private let lock = NSLock()
    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if taken { return false }
        taken = true
        return true
    }
}

extension Duration {
    /// Conversion vers `TimeInterval`, pour les API GCD qui ne connaissent pas `Duration`.
    var timeIntervalValue: TimeInterval {
        let (seconds, attoseconds) = components
        return Double(seconds) + Double(attoseconds) * 1e-18
    }
}
