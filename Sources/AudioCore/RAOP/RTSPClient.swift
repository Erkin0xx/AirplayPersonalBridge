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

    /// Message destiné à l'affichage : c'est ce texte qui remonte jusqu'à la ligne de la sortie
    /// dans l'interface. Il dit ce qui se passe et, quand on le sait, quoi faire.
    public var description: String {
        switch self {
        case let .connectionFailed(reason):
            return "connexion au récepteur impossible : \(reason)"
        case .notConnected:
            return "requête RTSP émise hors connexion"
        case let .timedOut(method):
            return "pas de réponse du récepteur à \(method)"
        case let .unexpectedStatus(method, code, reason):
            return Self.message(forStatus: code, reason: reason, method: method)
        case let .missingHeader(name):
            return "en-tête « \(name) » absent de la réponse"
        case .malformedResponse:
            return "réponse RTSP illisible"
        }
    }

    /// Code de statut, pour une réponse de refus.
    public var statusCode: Int? {
        if case let .unexpectedStatus(_, code, _) = self { return code }
        return nil
    }

    /// 453 : le récepteur sert déjà un autre sender. Il ne se libérera qu'à la fin de cette
    /// autre diffusion, ou à l'expiration de sa session s'il s'agit de la nôtre, perdue.
    public var isReceiverBusy: Bool { statusCode == 453 }

    /// 401 : le récepteur exige un mot de passe, ce que le sender ne sait pas fournir.
    /// Réessayer ne changera rien.
    public var requiresPassword: Bool { statusCode == 401 }

    private static func message(forStatus code: Int, reason: String, method: String) -> String {
        let detail = reason.isEmpty ? "\(code)" : "\(code) \(reason)"
        switch code {
        case 453:
            return "récepteur occupé : un autre appareil diffuse déjà vers lui (\(detail)). "
                + "Arrêtez cette diffusion, ou patientez s'il s'agit d'une session précédente."
        case 401:
            return "le récepteur demande un mot de passe (\(detail)), ce que l'application ne "
                + "sait pas fournir. Retirez-le dans les réglages AirPlay de l'enceinte."
        case 403:
            return "le récepteur refuse l'accès (\(detail)). Vérifiez ses réglages AirPlay."
        case 470:
            return "le récepteur exige un appairage (\(detail))."
        case 400..<500:
            return "\(method) refusé par le récepteur comme invalide (\(detail)). "
                + "Il ne comprend probablement pas ce format de session."
        case 500..<600:
            return "erreur interne du récepteur à \(method) (\(detail)). "
                + "Éteindre et rallumer l'enceinte règle le plus souvent ce cas."
        default:
            return "\(method) refusé par le récepteur : \(detail)"
        }
    }

    /// Une erreur réseau en français, sans le jargon `POSIXErrorCode` de `NWError`.
    static func reason(for error: NWError) -> String {
        guard case let .posix(code) = error else { return String(describing: error) }
        switch code {
        case .ECONNREFUSED:
            return "connexion refusée, le récepteur n'écoute pas (il redémarre peut-être)"
        case .EHOSTUNREACH, .EHOSTDOWN:
            return "récepteur injoignable, il est éteint ou hors du réseau"
        case .ENETUNREACH, .ENETDOWN:
            return "réseau indisponible"
        case .ETIMEDOUT:
            return "le récepteur ne répond plus"
        case .ECONNRESET, .EPIPE:
            return "connexion coupée par le récepteur"
        case .ECONNABORTED, .ECANCELED:
            return "connexion annulée"
        default:
            return String(cString: strerror(code.rawValue))
        }
    }
}

/// Connexion RTSP vers un récepteur RAOP : une requête à la fois, réponses appariées par
/// `CSeq`.
///
/// Un acteur plutôt qu'une classe verrouillée : RTSP est séquentiel par nature. L'isolement
/// d'acteur ne suffit pourtant pas à garantir « une requête à la fois », car un acteur est
/// réentrant à chaque `await` : un changement de volume arrivant pendant une autre requête
/// aurait lu sa réponse. D'où le tour de parole explicite (``acquireTurn``). On est ici sur le
/// canal de contrôle, hors de la frontière temps réel — Swift Concurrency y est le bon outil
/// (CDC section 13).
///
/// ## Une seule lecture, toujours active
///
/// Une fois connecté, une lecture reste en permanence armée sur la connexion. C'est le seul
/// moyen de voir une fermeture propre du récepteur (FIN) : `NWConnection` reste `.ready` tant
/// qu'aucune lecture ne la constate. C'est aussi ce qui garantit qu'une réponse tardive n'est
/// ni perdue ni attribuée à la requête suivante — une lecture armée par requête laissait, après
/// un délai dépassé, une lecture orpheline qui avalait la réponse d'après.
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

    /// Fin constatée de la connexion. Toute requête ou lecture ultérieure échoue avec elle.
    private var closure: RTSPError?
    /// Échec survenu en réception (bloc indéchiffrable), à remettre au prochain lecteur.
    private var inboundFailure: Error?
    private var connectionLostHandler: (@Sendable () -> Void)?

    private var connectWaiter: OneShotSignal?
    private var readWaiter: OneShotSignal?
    private var requestInFlight = false
    private var turnQueue: [OneShotSignal] = []

    public init(host: String, port: UInt16, clientInstance: String? = nil) {
        self.host = host
        self.port = port
        self.clientInstance = clientInstance
            ?? String(format: "%016llX", UInt64.random(in: .min ... .max))
    }

    deinit {
        connection?.stateUpdateHandler = nil
        connection?.cancel()
    }

    // MARK: - Cycle de vie

    /// Établit la connexion.
    ///
    /// - Parameter honoringCancellation: abandonne dès que la tâche appelante est annulée.
    ///   Facultatif plutôt que systématique : un `TEARDOWN` part souvent d'une tâche déjà
    ///   annulée, et c'est précisément lui qui ne doit pas être abandonné.
    public func connect(
        timeout: Duration = .seconds(10), honoringCancellation: Bool = false
    ) async throws {
        guard connection == nil else { return }
        if honoringCancellation { try Task.checkCancellation() }
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
        closure = nil

        let signal = OneShotSignal()
        connectWaiter = signal
        let lastProblem = LockedValue<String?>(nil)
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                signal.succeed()
            case let .waiting(error):
                // `NWConnection` ne passe jamais en `.failed` pour un port fermé : il attend un
                // changement de réseau pour réessayer, indéfiniment. Un refus est pourtant une
                // réponse claire : le rapporter tout de suite plutôt qu'au bout du délai. Les
                // autres causes méritent d'attendre (une enceinte en veille se réveille à la
                // première sollicitation, ce qui peut prendre plusieurs secondes).
                if case .posix(.ECONNREFUSED) = error {
                    signal.fail(RTSPError.connectionFailed(RTSPError.reason(for: error)))
                } else {
                    lastProblem.value = RTSPError.reason(for: error)
                }
            case let .failed(error):
                signal.fail(RTSPError.connectionFailed(RTSPError.reason(for: error)))
            case .cancelled:
                signal.fail(RTSPError.connectionFailed("connexion annulée"))
            default:
                break
            }
        }
        connection.start(queue: .global(qos: .userInitiated))

        do {
            try await wait(
                for: signal,
                deadline: ContinuousClock.now + timeout,
                honoringCancellation: honoringCancellation,
                onTimeout: {
                    RTSPError.connectionFailed(lastProblem.value ?? "délai d'établissement dépassé")
                }
            )
        } catch {
            // Sans annulation explicite, une connexion en échec continue d'essayer en silence
            // tant que le processus vit : chaque tentative de reconnexion en laissait une.
            connectWaiter = nil
            connection.stateUpdateHandler = nil
            connection.cancel()
            if self.connection === connection { self.connection = nil }
            throw error
        }
        connectWaiter = nil

        if case let .hostPort(localHost, _) = connection.currentPath?.localEndpoint {
            localAddress = Self.literal(from: localHost)
        }
        log.info("RTSP connecté à \(self.host, privacy: .public):\(self.port) (local \(self.localAddress, privacy: .public))")

        // Dès qu'elle est établie, la connexion est surveillée et lue en continu.
        connection.stateUpdateHandler = { [weak self] state in
            let reason: String
            switch state {
            case let .failed(error): reason = RTSPError.reason(for: error)
            case .cancelled: reason = "connexion annulée"
            default: return
            }
            Task { await self?.connectionEnded(connection, reason: reason) }
        }
        pump(connection)
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
    /// Le gestionnaire est appelé une seule fois, immédiatement si la connexion est déjà tombée.
    /// Il ne l'est jamais après ``disconnect()`` : un arrêt volontaire n'est pas une perte.
    public func onConnectionLost(_ handler: @escaping @Sendable () -> Void) {
        if closure != nil {
            handler()
        } else {
            connectionLostHandler = handler
        }
    }

    public func disconnect() {
        // Le gestionnaire doit partir avant l'annulation : sans cela, un arrêt volontaire se
        // signalerait lui-même comme une perte de session et déclencherait une reconnexion.
        connectionLostHandler = nil
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
        pendingData.removeAll(keepingCapacity: false)
        pendingCiphertext.removeAll(keepingCapacity: false)
        controlChannel = nil
        closure = nil
        inboundFailure = nil
        // Quiconque attendait quelque chose de cette connexion ne l'obtiendra plus.
        connectWaiter?.fail(RTSPError.notConnected)
        connectWaiter = nil
        readWaiter?.fail(RTSPError.notConnected)
        readWaiter = nil
        let queued = turnQueue
        turnQueue.removeAll()
        for waiter in queued { waiter.fail(RTSPError.notConnected) }
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
    ///
    /// - Parameters:
    ///   - timeout: délai total, attente de son tour comprise. Un `stop()` ne doit pas pouvoir
    ///     rester bloqué derrière une autre requête qui tarde.
    ///   - honoringCancellation: abandonne dès que la tâche appelante est annulée. Voir
    ///     ``connect(timeout:honoringCancellation:)``.
    @discardableResult
    public func send(
        _ request: RTSPRequest,
        timeout: Duration = .seconds(10),
        honoringCancellation: Bool = false
    ) async throws -> RTSPResponse {
        let deadline = ContinuousClock.now + timeout
        try await acquireTurn(
            deadline: deadline, method: request.method, honoringCancellation: honoringCancellation
        )
        defer { releaseTurn() }

        guard let connection else { throw RTSPError.notConnected }
        if let closure { throw closure }
        if honoringCancellation { try Task.checkCancellation() }

        var outgoing = request
        var expectedCSeq: Int?
        // Le compteur n'avance que pour les requêtes RTSP : celles du pairing AirPlay 2 sont
        // des `POST` HTTP/1.1 sans `CSeq`, et elles ne doivent pas décaler la numérotation du
        // `SETUP` qui suit.
        if outgoing.usesRTSP {
            sequenceNumber += 1
            expectedCSeq = sequenceNumber
            outgoing.headers.insert(("CSeq", String(sequenceNumber)), at: 0)
        }
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

        // Le rappel d'émission n'a lui non plus aucune garantie d'arriver si le pair disparaît.
        let sent = OneShotSignal()
        connection.send(content: payload, completion: .contentProcessed { error in
            if let error {
                sent.fail(RTSPError.connectionFailed(RTSPError.reason(for: error)))
            } else {
                sent.succeed()
            }
        })
        let method = outgoing.method
        try await wait(
            for: sent, deadline: deadline, honoringCancellation: honoringCancellation,
            onTimeout: { RTSPError.timedOut(method: method) }
        )

        let response = try await readResponse(
            method: method, expectedCSeq: expectedCSeq, deadline: deadline,
            honoringCancellation: honoringCancellation
        )
        log.debug("← \(response.statusCode) \(response.reasonPhrase, privacy: .public)")
        guard response.isSuccess else {
            throw RTSPError.unexpectedStatus(
                method: outgoing.method, code: response.statusCode, reason: response.reasonPhrase
            )
        }
        return response
    }

    /// Attend d'avoir le droit d'émettre. Une seule requête à la fois, dans l'ordre d'arrivée.
    private func acquireTurn(
        deadline: ContinuousClock.Instant, method: String, honoringCancellation: Bool
    ) async throws {
        guard requestInFlight else {
            requestInFlight = true
            return
        }
        let turn = OneShotSignal()
        turnQueue.append(turn)
        do {
            try await wait(
                for: turn, deadline: deadline, honoringCancellation: honoringCancellation,
                onTimeout: { RTSPError.timedOut(method: method) }
            )
        } catch {
            turnQueue.removeAll { $0 === turn }
            throw error
        }
    }

    /// Passe la main au suivant. Un candidat déjà expiré, pas encore retiré de la file parce que
    /// sa tâche n'a pas repris la main, est sauté : lui donner le tour le perdrait pour tous.
    private func releaseTurn() {
        while !turnQueue.isEmpty {
            if turnQueue.removeFirst().succeed() { return }
        }
        requestInFlight = false
    }

    /// Attend qu'une réponse complète soit disponible, en conservant le surplus éventuel.
    ///
    /// Une réponse à un `CSeq` antérieur est celle d'une requête dont l'appelant a déjà renoncé
    /// (délai dépassé) : elle est écartée, sinon toutes les réponses suivantes seraient
    /// décalées d'un cran. Sans `CSeq` dans la réponse, l'ordre d'arrivée fait foi : rien
    /// n'oblige un récepteur à le renvoyer.
    private func readResponse(
        method: String,
        expectedCSeq: Int?,
        deadline: ContinuousClock.Instant,
        honoringCancellation: Bool
    ) async throws -> RTSPResponse {
        while true {
            if let failure = inboundFailure {
                inboundFailure = nil
                throw failure
            }
            switch RTSPResponse.analyse(pendingData) {
            case let .complete(response, consumed):
                pendingData.removeFirst(consumed)
                if let expectedCSeq,
                    let received = response.headers["cseq"].flatMap({ Int($0) }),
                    received < expectedCSeq
                {
                    log.info("Réponse tardive à CSeq \(received) écartée (attendu \(expectedCSeq))")
                    continue
                }
                return response
            case .malformed:
                // Vider le tampon : ces octets ne deviendront jamais une réponse, et ils
                // bloqueraient sinon toutes les requêtes à venir sur cette connexion.
                pendingData.removeAll(keepingCapacity: true)
                throw RTSPError.malformedResponse
            case .incomplete:
                break
            }
            if let closure { throw closure }
            guard connection != nil else { throw RTSPError.notConnected }

            let arrival = OneShotSignal()
            readWaiter = arrival
            defer { readWaiter = nil }
            try await wait(
                for: arrival, deadline: deadline, honoringCancellation: honoringCancellation,
                onTimeout: { RTSPError.timedOut(method: method) }
            )
        }
    }

    // MARK: - Réception

    /// Arme la lecture suivante. Une seule à la fois, la suivante n'étant armée qu'une fois la
    /// précédente traitée sur l'acteur : l'ordre des octets est ainsi garanti.
    ///
    /// `NWConnection.receive` peut ne jamais rappeler quand le pair disparaît sans fermer
    /// proprement. Rien n'attend donc directement ce rappel : les lecteurs attendent un signal
    /// assorti de leur propre échéance (voir ``wait(for:deadline:honoringCancellation:onTimeout:)``).
    private nonisolated func pump(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) {
            [weak self] data, _, isComplete, error in
            Task {
                await self?.didReceive(data, isComplete: isComplete, error: error, on: connection)
            }
        }
    }

    private func didReceive(
        _ data: Data?, isComplete: Bool, error: NWError?, on source: NWConnection
    ) {
        guard source === connection else { return }
        if let data, !data.isEmpty {
            absorb(data)
        }
        if let error {
            connectionEnded(source, reason: RTSPError.reason(for: error))
        } else if isComplete {
            connectionEnded(source, reason: "connexion fermée par le récepteur")
        } else {
            pump(source)
        }
    }

    private func absorb(_ chunk: Data) {
        if let controlChannel {
            // Canal chiffré : les octets reçus sont accumulés jusqu'à former des blocs
            // complets. Un bloc partiel reste en attente — c'est le cas normal en TCP.
            pendingCiphertext.append(chunk)
            do {
                let (plaintext, consumed) = try controlChannel.inbound.open(pendingCiphertext)
                if consumed > 0 {
                    pendingCiphertext.removeFirst(consumed)
                }
                pendingData.append(plaintext)
            } catch {
                inboundFailure = error
            }
        } else {
            pendingData.append(chunk)
        }
        readWaiter?.succeed()
    }

    private func connectionEnded(_ source: NWConnection, reason: String) {
        guard source === connection, closure == nil else { return }
        log.info("Connexion RTSP terminée : \(reason, privacy: .public)")
        closure = RTSPError.connectionFailed(reason)
        readWaiter?.succeed()
        let handler = connectionLostHandler
        connectionLostHandler = nil
        handler?()
    }

    // MARK: - Attente

    /// Attend un signal, avec une échéance et, sur demande, sensible à l'annulation.
    private func wait(
        for signal: OneShotSignal,
        deadline: ContinuousClock.Instant,
        honoringCancellation: Bool,
        onTimeout: @escaping @Sendable () -> Error
    ) async throws {
        let timer = Task {
            do {
                try await Task.sleep(until: deadline, clock: .continuous)
            } catch {
                return
            }
            signal.fail(onTimeout())
        }
        defer { timer.cancel() }

        if honoringCancellation {
            try await withTaskCancellationHandler {
                try await signal.wait()
            } onCancel: {
                signal.fail(CancellationError())
            }
        } else {
            try await signal.wait()
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

/// Une attente à issue unique, tranchée par le premier arrivé (réponse, délai, annulation).
///
/// Reprendre deux fois une `CheckedContinuation` est fatal à l'exécution, et ces chemins sont
/// concurrents par nature. L'issue peut aussi précéder l'attente : elle est alors conservée et
/// rendue dès que l'attente commence.
private final class OneShotSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var outcome: Result<Void, Error>?

    /// - Returns: vrai si c'est cet appel qui a tranché.
    @discardableResult
    func succeed() -> Bool { settle(.success(())) }

    /// - Returns: vrai si c'est cet appel qui a tranché.
    @discardableResult
    func fail(_ error: Error) -> Bool { settle(.failure(error)) }

    func wait() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            lock.lock()
            if let outcome {
                lock.unlock()
                continuation.resume(with: outcome)
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }
    }

    private func settle(_ result: Result<Void, Error>) -> Bool {
        lock.lock()
        guard outcome == nil else {
            lock.unlock()
            return false
        }
        outcome = result
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(with: result)
        return true
    }
}

/// Une valeur partagée entre le rappel d'état d'une connexion et le délai qui la surveille.
private final class LockedValue<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) { stored = value }

    var value: Value {
        get {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }
        set {
            lock.lock()
            stored = newValue
            lock.unlock()
        }
    }
}
