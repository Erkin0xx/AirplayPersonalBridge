import AVFoundation
import Foundation
import Network
import Testing

@testable import AudioCore

/// Identité long terme de l'accessoire simulé, pour le `pair-verify`.
struct SimulatedIdentity: Sendable {
    let identifier: Data
    let seed: Data

    static func random(identifier: String) -> SimulatedIdentity {
        var generator = SystemRandomNumberGenerator()
        return SimulatedIdentity(
            identifier: Data(identifier.utf8),
            seed: Data((0..<32).map { _ in UInt8.random(in: 0...255, using: &generator) })
        )
    }

    var publicKey: Data {
        get throws { try Ed25519KeyPair(seed: seed).publicKey }
    }
}

/// Récepteur AirPlay 2 simulé **en processus**, sur la boucle locale.
///
/// Écrit à partir du code de pyatv, en particulier de son propre accessoire simulé
/// (`protocols/airplay/server_auth.py`) et de `hap_srp.py`, et complété de ce que le vrai matériel
/// exige et que ces deux-là ignorent : mesurer notre horloge avant de répondre au `SETUP`,
/// contrôler la signature du client au `pair-verify`.
///
/// **Ce qu'il prouve** : que le sender tient ses engagements envers un pair conforme à la lecture
/// qu'on a de pyatv, y compris dans les chemins d'erreur qu'aucun récepteur ne déclenche à la
/// demande. **Ce qu'il ne prouve pas** : qu'un HomePod ou un Apple TV réel se comporte ainsi.
///
/// Tout l'état vit sur `queue` ; les accesseurs y font un aller-retour synchrone.
final class FakeAirPlay2Receiver: @unchecked Sendable {

    struct Request: Sendable {
        let method: String
        let uri: String
        let protocolVersion: String
        /// Noms en minuscules.
        let headers: [String: String]
        let body: Data
        let wasEncrypted: Bool
    }

    /// Ce que le récepteur fait d'une requête.
    enum Action: Sendable {
        case normal
        case status(Int, String)
        /// Ne répond jamais, connexion laissée ouverte.
        case silent
        /// Ferme la connexion de contrôle sans répondre.
        case close
        /// Répond normalement, mais plus tard.
        case delayed(TimeInterval)
    }

    /// Réaction à un `pair-verify` qui n'annonce pas `X-Apple-HKP: 3`.
    enum WrongDomainBehaviour: Sendable {
        /// `501`, comme l'accessoire simulé de pyatv.
        case reject
        /// Répond sous une autre identité, ce qui reproduit le symptôme relevé contre l'Apple TV
        /// (commit d2886e4) : échange abouti, mais identifiant et signature étrangers.
        case otherIdentity(SimulatedIdentity)
    }

    struct Options: Sendable {
        /// `nil` : refuse le transitoire en `470`, comme un Apple TV.
        var transientEnabled = true
        /// `nil` : pas d'appairage système.
        var identity: SimulatedIdentity?
        /// Clé publique du contrôleur autorisé, dont la signature M3 est vérifiée.
        var pairedClient: (identifier: Data, publicKey: Data)?
        var wrongDomainBehaviour = WrongDomainBehaviour.reject
        /// Comme le HomePod : pas de réponse au `SETUP` tant que notre horloge n'a pas répondu.
        var requiresTimingBeforeSetup = true
        var eventChannelEnabled = true
    }

    /// Tout ce qui concerne une session, c'est-à-dire une connexion de contrôle.
    final class Session: @unchecked Sendable {
        var requests: [Request] = []
        var inbound: AirPlay2ControlChannel.Direction?
        var outbound: AirPlay2ControlChannel.Direction?
        var cipherBuffer = Data()
        var plainBuffer = Data()
        var srp: TransientSRPServer?
        var verifyKeyPair: Curve25519KeyPair?
        var verifyShared: Data?
        var verifyClientPublic: Data?
        var verifyReceiverPublic: Data?
        var sharedSecret: Data?

        var timingPort: UInt16 = 0
        var senderControlPort: UInt16 = 0
        var streamKey = Data()
        var timingProbe: UDPChannel?
        var timingAnswered = false
        var dataChannel: UDPChannel?
        var controlChannel: UDPChannel?
        var eventListener: NWListener?
        var eventConnection: NWConnection?
        var eventInbound: AirPlay2ControlChannel.Direction?
        var eventOutbound: AirPlay2ControlChannel.Direction?
        var eventCipher = Data()
        var eventPlain = Data()

        var audioPackets: [Data] = []
        var audioArrivalTimes: [Date] = []
        var resendPackets: [Data] = []
        var syncPackets: [Data] = []
        var timingResponses = 0
        var volumes: [String] = []
        var connection: NWConnection?
    }

    let options: Options
    /// Décide du sort de chaque requête. `occurrence` compte à partir de 0, toutes sessions
    /// confondues, les requêtes de même méthode et de même URI (ou de même domaine de pairing).
    var script: (@Sendable (Request, Int) -> Action)? {
        get { queue.sync { storedScript } }
        set { queue.sync { storedScript = newValue } }
    }

    private let queue = DispatchQueue(label: "test.fake-airplay2-receiver")
    private var storedScript: (@Sendable (Request, Int) -> Action)?
    private var occurrences: [String: Int] = [:]
    private var listener: NWListener?
    private var sessions: [Session] = []
    private var overlappingRequests = 0
    private var requestInProgress: [ObjectIdentifier: Bool] = [:]
    private(set) var port: UInt16 = 0

    init(options: Options = Options()) {
        self.options = options
    }

    /// Ouvre l'écoute et rend la main une fois le port connu.
    func start() async throws {
        let listener = try Self.makeLoopbackListener()
        self.listener = listener
        let assigned = await Self.waitUntilReady(listener, queue: queue) { [weak self] connection in
            self?.accept(connection)
        }
        port = assigned
    }

    func stop() {
        queue.sync {
            listener?.cancel()
            listener = nil
            for session in sessions {
                session.connection?.cancel()
                session.eventListener?.cancel()
                session.eventConnection?.cancel()
                session.dataChannel?.stop()
                session.controlChannel?.stop()
                session.timingProbe?.stop()
            }
        }
    }

    func device(name: String = "Récepteur simulé") -> AirPlay2Device {
        AirPlay2Device(
            serviceName: name, host: "127.0.0.1", port: port,
            // Le pairing transitoire annoncé : bit 48 du mot de poids fort.
            txt: ["features": "0x405f4200,0x1c300", "deviceid": "AA:BB:CC:DD:EE:FF"]
        )
    }

    // MARK: - Observation

    var sessionCount: Int { queue.sync { sessions.count } }

    func requests(inSession index: Int? = nil) -> [Request] {
        queue.sync {
            if let index { return index < sessions.count ? sessions[index].requests : [] }
            return sessions.flatMap(\.requests)
        }
    }

    func count(method: String, uri: String? = nil) -> Int {
        requests().filter { $0.method == method && (uri == nil || $0.uri == uri) }.count
    }

    func audioPackets(inSession index: Int) -> [Data] {
        queue.sync { index < sessions.count ? sessions[index].audioPackets : [] }
    }

    func audioArrivalTimes(inSession index: Int) -> [Date] {
        queue.sync { index < sessions.count ? sessions[index].audioArrivalTimes : [] }
    }

    func resendPackets(inSession index: Int) -> [Data] {
        queue.sync { index < sessions.count ? sessions[index].resendPackets : [] }
    }

    func syncPacketCount(inSession index: Int) -> Int {
        queue.sync { index < sessions.count ? sessions[index].syncPackets.count : 0 }
    }

    func streamKey(inSession index: Int) -> Data {
        queue.sync { index < sessions.count ? sessions[index].streamKey : Data() }
    }

    func timingPort(inSession index: Int) -> UInt16 {
        queue.sync { index < sessions.count ? sessions[index].timingPort : 0 }
    }

    func timingWasAnswered(inSession index: Int) -> Bool {
        queue.sync { index < sessions.count ? sessions[index].timingAnswered : false }
    }

    func volumes(inSession index: Int) -> [String] {
        queue.sync { index < sessions.count ? sessions[index].volumes : [] }
    }

    func eventPlaintext(inSession index: Int) -> Data {
        queue.sync { index < sessions.count ? sessions[index].eventPlain : Data() }
    }

    func eventChannelIsOpen(inSession index: Int) -> Bool {
        queue.sync { index < sessions.count && sessions[index].eventConnection != nil }
    }

    /// Une requête est arrivée alors que la précédente n'avait pas reçu sa réponse.
    var overlappingRequestCount: Int { queue.sync { overlappingRequests } }

    // MARK: - Actions à la demande

    /// Demande une retransmission sur le canal de contrôle, en big-endian : `80 D5 00 01 ...`.
    func requestRetransmission(first: UInt16, count: UInt16, inSession index: Int) {
        queue.sync {
            guard index < sessions.count, let control = sessions[index].controlChannel else { return }
            let session = sessions[index]
            var packet = Data([0x80, 0xD5, 0x00, 0x01])
            packet.append(UInt8(first >> 8))
            packet.append(UInt8(first & 0xFF))
            packet.append(UInt8(count >> 8))
            packet.append(UInt8(count & 0xFF))
            try? control.setDestination(host: "127.0.0.1", port: session.senderControlPort)
            try? control.send(packet)
        }
    }

    /// Ferme la connexion de contrôle de la session, sans adieu.
    func dropControlConnection(inSession index: Int) {
        queue.sync {
            guard index < sessions.count else { return }
            sessions[index].connection?.cancel()
            sessions[index].connection = nil
        }
    }

    func dropEventChannel(inSession index: Int) {
        queue.sync {
            guard index < sessions.count else { return }
            sessions[index].eventConnection?.cancel()
            sessions[index].eventConnection = nil
        }
    }

    /// Pousse des octets bruts sur le canal d'événements.
    func sendRawEvent(_ bytes: Data, inSession index: Int) {
        queue.sync {
            guard index < sessions.count else { return }
            sessions[index].eventConnection?.send(
                content: bytes, completion: .contentProcessed { _ in })
        }
    }

    /// Chiffre un message du récepteur vers le sender, en respectant le cadrage du canal.
    func sealEvent(_ plaintext: Data, inSession index: Int) throws -> Data {
        try queue.sync {
            guard index < sessions.count, let outbound = sessions[index].eventOutbound else {
                return Data()
            }
            return try outbound.seal(plaintext)
        }
    }

    /// Envoie une requête d'horloge et attend la réponse, sur un socket jetable.
    func probeTiming(port: UInt16, timeout: TimeInterval) async throws -> Bool {
        let probe = try UDPChannel(label: "test-probe")
        let answered = LockedFlag()
        probe.onReceive = { _, _ in answered.set() }
        probe.startReceiving()
        try probe.setDestination(host: "127.0.0.1", port: port)
        try probe.send(Self.timingRequest())
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if answered.value { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        probe.stop()
        return answered.value
    }

    static func timingRequest() -> Data {
        var packet = Data([0x80, 0xD2, 0x00, 0x07])
        packet.append(Data(repeating: 0, count: 20))
        packet.append(contentsOf: NTPTime.now().bigEndianBytes)
        return packet
    }

    // MARK: - Connexion de contrôle

    private func accept(_ connection: NWConnection) {
        let session = Session()
        session.connection = connection
        sessions.append(session)
        connection.start(queue: queue)
        receive(on: connection, session: session)
    }

    private func receive(on connection: NWConnection, session: Session) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) {
            [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.absorb(data, session: session)
            }
            if isComplete || error != nil {
                connection.cancel()
                return
            }
            self.receive(on: connection, session: session)
        }
    }

    private func absorb(_ data: Data, session: Session) {
        if let inbound = session.inbound {
            session.cipherBuffer.append(data)
            guard let (plain, consumed) = try? inbound.open(session.cipherBuffer) else { return }
            session.cipherBuffer.removeFirst(consumed)
            session.plainBuffer.append(plain)
        } else {
            session.plainBuffer.append(data)
        }

        while let (request, consumed) = Self.parseRequest(
            session.plainBuffer, encrypted: session.inbound != nil)
        {
            session.plainBuffer.removeFirst(consumed)
            handle(request, session: session)
        }
    }

    private func handle(_ request: Request, session: Session) {
        session.requests.append(request)
        let identifier = ObjectIdentifier(session)
        if requestInProgress[identifier] == true { overlappingRequests += 1 }
        requestInProgress[identifier] = true

        let key = "\(request.method) \(request.uri)"
        let occurrence = occurrences[key, default: 0]
        occurrences[key] = occurrence + 1

        switch storedScript?(request, occurrence) ?? .normal {
        case .normal:
            route(request, session: session)
        case let .status(code, reason):
            respond(to: request, session: session, status: code, reason: reason)
        case .silent:
            break
        case .close:
            session.connection?.cancel()
            session.connection = nil
        case let .delayed(delay):
            queue.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.route(request, session: session)
            }
        }
    }

    private func route(_ request: Request, session: Session) {
        switch (request.method, request.uri) {
        case ("POST", "/pair-setup"):
            handlePairSetup(request, session: session)
        case ("POST", "/pair-verify"):
            handlePairVerify(request, session: session)
        case ("POST", "/feedback"):
            respond(to: request, session: session)
        case ("SETUP", _):
            handleSetup(request, session: session)
        case ("SET_PARAMETER", _):
            if let text = String(data: request.body, encoding: .utf8) {
                session.volumes.append(text)
            }
            respond(to: request, session: session)
        case ("RECORD", _), ("TEARDOWN", _):
            respond(to: request, session: session)
        default:
            respond(to: request, session: session, status: 404, reason: "Not Found")
        }
    }

    private func respond(
        to request: Request,
        session: Session,
        status: Int = 200,
        reason: String = "OK",
        body: Data = Data(),
        contentType: String? = nil,
        enableEncryptionAfterwards: Data? = nil
    ) {
        requestInProgress[ObjectIdentifier(session)] = false
        var text = "\(request.protocolVersion) \(status) \(reason)\r\n"
        text += "Server: AirTunes/366.0\r\n"
        if let cseq = request.headers["cseq"] { text += "CSeq: \(cseq)\r\n" }
        if let contentType { text += "Content-Type: \(contentType)\r\n" }
        text += "Content-Length: \(body.count)\r\n\r\n"
        var message = Data(text.utf8)
        message.append(body)

        if let outbound = session.outbound, let sealed = try? outbound.seal(message) {
            message = sealed
        }
        session.connection?.send(content: message, completion: .contentProcessed { _ in })

        if let secret = enableEncryptionAfterwards {
            session.sharedSecret = secret
            session.inbound = try? AirPlay2ControlChannel.Direction(
                key: HKDF512.derive(
                    secret: secret,
                    salt: AirPlay2ControlChannel.cipherSalt,
                    info: AirPlay2ControlChannel.writeKeyInfo))
            session.outbound = try? AirPlay2ControlChannel.Direction(
                key: HKDF512.derive(
                    secret: secret,
                    salt: AirPlay2ControlChannel.cipherSalt,
                    info: AirPlay2ControlChannel.readKeyInfo))
        }
    }

    // MARK: - Pairing

    private func handlePairSetup(_ request: Request, session: Session) {
        guard options.transientEnabled else {
            respond(
                to: request, session: session,
                status: 470, reason: "Connection Authorization Required")
            return
        }
        guard request.headers["x-apple-hkp"] == "4",
            let items = PairingTLV8.decode(request.body),
            let state = PairingTLV8.state(in: items)
        else {
            respond(to: request, session: session, status: 501, reason: "Not implemented")
            return
        }

        switch state {
        case .m1:
            let srp = TransientSRPServer()
            session.srp = srp
            respond(
                to: request, session: session,
                body: PairingTLV8.encode([
                    (.state, PairingTLV8.byte(PairingTLV8.State.m2.rawValue)),
                    (.salt, TransientSRPServer.salt),
                    (.publicKey, srp.publicB),
                ]))
        case .m3:
            guard let srp = session.srp, let publicA = items[.publicKey], let proof = items[.proof],
                let outcome = srp.verify(clientPublic: publicA, clientProof: proof)
            else {
                respond(
                    to: request, session: session,
                    body: PairingTLV8.encode([
                        (.state, PairingTLV8.byte(PairingTLV8.State.m4.rawValue)),
                        (.error, PairingTLV8.byte(PairingTLV8.PairingError.authentication.rawValue)),
                    ]))
                return
            }
            respond(
                to: request, session: session,
                body: PairingTLV8.encode([
                    (.state, PairingTLV8.byte(PairingTLV8.State.m4.rawValue)),
                    (.proof, outcome.serverProof),
                ]),
                enableEncryptionAfterwards: outcome.sessionKey)
        default:
            respond(to: request, session: session, status: 400, reason: "Bad Request")
        }
    }

    private func handlePairVerify(_ request: Request, session: Session) {
        var identity = options.identity
        if request.headers["x-apple-hkp"] != "3" {
            switch options.wrongDomainBehaviour {
            case .reject:
                respond(to: request, session: session, status: 501, reason: "Not implemented")
                return
            case let .otherIdentity(other):
                identity = other
            }
        }
        guard let identity,
            let items = PairingTLV8.decode(request.body),
            let state = PairingTLV8.state(in: items)
        else {
            respond(
                to: request, session: session,
                status: 470, reason: "Connection Authorization Required")
            return
        }

        do {
            switch state {
            case .m1:
                guard let clientPublic = items[.publicKey] else { throw PairingTLV8.PairingError.unknown }
                let keyPair = try Curve25519KeyPair()
                let shared = try keyPair.sharedSecret(withPublicKey: clientPublic)
                session.verifyKeyPair = keyPair
                session.verifyShared = shared
                session.verifyClientPublic = clientPublic
                session.verifyReceiverPublic = keyPair.publicKey

                // Le sous-TLV : l'accessoire signe sa clé éphémère ‖ son identifiant ‖ la nôtre.
                let signer = try Ed25519KeyPair(seed: identity.seed)
                let signature = signer.sign(keyPair.publicKey + identity.identifier + clientPublic)
                let inner = PairingTLV8.encode([
                    (.identifier, identity.identifier),
                    (.signature, signature),
                ])
                let cipher = try ChaChaPoly1305(key: Self.verifyKey(shared))
                let sealed = try cipher.seal(inner, nonce: Self.pairingNonce("PV-Msg02"))
                respond(
                    to: request, session: session,
                    body: PairingTLV8.encode([
                        (.state, PairingTLV8.byte(PairingTLV8.State.m2.rawValue)),
                        (.publicKey, keyPair.publicKey),
                        (.encryptedData, sealed),
                    ]))

            case .m3:
                guard let shared = session.verifyShared,
                    let clientPublic = session.verifyClientPublic,
                    let receiverPublic = session.verifyReceiverPublic,
                    let sealed = items[.encryptedData]
                else { throw PairingTLV8.PairingError.unknown }
                let cipher = try ChaChaPoly1305(key: Self.verifyKey(shared))
                let inner = try cipher.open(sealed, nonce: Self.pairingNonce("PV-Msg03"))
                guard let proof = PairingTLV8.decode(inner),
                    let identifier = proof[.identifier],
                    let signature = proof[.signature],
                    let client = options.pairedClient,
                    identifier == client.identifier,
                    try Ed25519KeyPair.verify(
                        signature: signature,
                        message: clientPublic + identifier + receiverPublic,
                        publicKey: client.publicKey)
                else { throw PairingTLV8.PairingError.authentication }
                respond(
                    to: request, session: session,
                    body: PairingTLV8.encode([
                        (.state, PairingTLV8.byte(PairingTLV8.State.m4.rawValue))
                    ]),
                    enableEncryptionAfterwards: shared)

            default:
                throw PairingTLV8.PairingError.unknown
            }
        } catch {
            respond(
                to: request, session: session,
                body: PairingTLV8.encode([
                    (.state, PairingTLV8.byte(state.rawValue &+ 1)),
                    (.error, PairingTLV8.byte(PairingTLV8.PairingError.authentication.rawValue)),
                ]))
        }
    }

    private static func verifyKey(_ shared: Data) -> Data {
        HKDF512.derive(
            secret: shared,
            salt: HKDF512.Label.verifyEncryptSalt,
            info: HKDF512.Label.verifyEncryptInfo)
    }

    private static func pairingNonce(_ label: String) -> Data {
        Data(repeating: 0, count: 4) + Data(label.utf8)
    }

    // MARK: - SETUP

    private func handleSetup(_ request: Request, session: Session) {
        guard let plist = try? PropertyListSerialization.propertyList(
            from: request.body, options: [], format: nil) as? [String: Any]
        else {
            respond(to: request, session: session, status: 400, reason: "Bad Request")
            return
        }

        if let streams = plist["streams"] as? [[String: Any]], let stream = streams.first {
            setupStream(stream, request: request, session: session)
        } else {
            setupSession(plist, request: request, session: session)
        }
    }

    private func setupSession(_ plist: [String: Any], request: Request, session: Session) {
        session.timingPort = UInt16(truncatingIfNeeded: plist["timingPort"] as? Int ?? 0)

        let answer: @Sendable (UInt16) -> Void = { [weak self] eventPort in
            guard let self else { return }
            self.queue.async {
                let body = try? PropertyListSerialization.data(
                    fromPropertyList: ["eventPort": Int(eventPort), "timingPort": 0],
                    format: .binary, options: 0)
                self.respond(
                    to: request, session: session, body: body ?? Data(),
                    contentType: "application/x-apple-binary-plist")
            }
        }

        let proceed: @Sendable () -> Void = { [weak self] in
            guard let self else { return }
            guard self.options.eventChannelEnabled else {
                answer(0)
                return
            }
            self.queue.async {
                guard let listener = try? Self.makeLoopbackListener() else {
                    answer(0)
                    return
                }
                session.eventListener = listener
                listener.newConnectionHandler = { [weak self] connection in
                    self?.acceptEvents(connection, session: session)
                }
                listener.stateUpdateHandler = { state in
                    if case .ready = state, let port = listener.port?.rawValue {
                        answer(port)
                    }
                }
                listener.start(queue: self.queue)
            }
        }

        guard options.requiresTimingBeforeSetup else {
            proceed()
            return
        }

        // Comme le HomePod : mesurer l'horloge du sender **avant** de répondre.
        do {
            let probe = try UDPChannel(label: "fake-timing")
            session.timingProbe = probe
            let fired = LockedFlag()
            probe.onReceive = { [weak self] data, _ in
                guard data.count == 32, data[1] & 0x7F == 0x53 else { return }
                self?.queue.async { session.timingResponses += 1; session.timingAnswered = true }
                if !fired.value {
                    fired.set()
                    proceed()
                }
            }
            probe.startReceiving()
            try probe.setDestination(host: "127.0.0.1", port: session.timingPort)
            try probe.send(Self.timingRequest())
        } catch {
            respond(to: request, session: session, status: 500, reason: "Internal Error")
        }
    }

    private func setupStream(_ stream: [String: Any], request: Request, session: Session) {
        session.senderControlPort = UInt16(truncatingIfNeeded: stream["controlPort"] as? Int ?? 0)
        session.streamKey = stream["shk"] as? Data ?? Data()
        guard let data = try? UDPChannel(label: "fake-data"),
            let control = try? UDPChannel(label: "fake-control")
        else {
            respond(to: request, session: session, status: 500, reason: "Internal Error")
            return
        }
        data.onReceive = { [weak self] packet, _ in
            let arrival = Date()
            self?.queue.async {
                session.audioPackets.append(packet)
                session.audioArrivalTimes.append(arrival)
            }
        }
        data.startReceiving()
        control.onReceive = { [weak self] packet, _ in
            guard packet.count >= 2 else { return }
            let type = packet[packet.startIndex + 1] & 0x7F
            self?.queue.async {
                if type == 0x56 {
                    session.resendPackets.append(packet)
                } else if type == 0x54 {
                    session.syncPackets.append(packet)
                }
            }
        }
        control.startReceiving()
        session.dataChannel = data
        session.controlChannel = control

        let response: [String: Any] = [
            "streams": [
                [
                    "dataPort": Int(data.localPort),
                    "controlPort": Int(control.localPort),
                    "streamID": 1,
                    "type": 96,
                    "audioBufferSize": 8_388_608,
                ] as [String: Any]
            ]
        ]
        let body = try? PropertyListSerialization.data(
            fromPropertyList: response, format: .binary, options: 0)
        respond(
            to: request, session: session, body: body ?? Data(),
            contentType: "application/x-apple-binary-plist")
    }

    // MARK: - Canal d'événements

    private func acceptEvents(_ connection: NWConnection, session: Session) {
        session.eventConnection = connection
        if let secret = session.sharedSecret {
            // Vu du récepteur : il écrit avec la clé « Write » et lit avec la clé « Read ».
            session.eventOutbound = try? AirPlay2ControlChannel.Direction(
                key: HKDF512.derive(
                    secret: secret, salt: AirPlay2EventDecoder.salt,
                    info: AirPlay2EventDecoder.writeInfo))
            session.eventInbound = try? AirPlay2ControlChannel.Direction(
                key: HKDF512.derive(
                    secret: secret, salt: AirPlay2EventDecoder.salt,
                    info: AirPlay2EventDecoder.readInfo))
        }
        connection.start(queue: queue)
        receiveEvents(on: connection, session: session)
    }

    private func receiveEvents(on connection: NWConnection, session: Session) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4_096) {
            [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, let inbound = session.eventInbound {
                session.eventCipher.append(data)
                if let (plain, consumed) = try? inbound.open(session.eventCipher) {
                    session.eventCipher.removeFirst(consumed)
                    session.eventPlain.append(plain)
                }
            }
            if isComplete || error != nil { return }
            self.receiveEvents(on: connection, session: session)
        }
    }

    // MARK: - Outils

    private static func makeLoopbackListener() throws -> NWListener {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        return try NWListener(using: parameters)
    }

    private static func waitUntilReady(
        _ listener: NWListener,
        queue: DispatchQueue,
        onConnection: @escaping @Sendable (NWConnection) -> Void
    ) async -> UInt16 {
        await withCheckedContinuation { continuation in
            let resumed = ManagedFlag()
            listener.newConnectionHandler = onConnection
            listener.stateUpdateHandler = { state in
                if case .ready = state, resumed.claim() {
                    continuation.resume(returning: listener.port?.rawValue ?? 0)
                }
            }
            listener.start(queue: queue)
        }
    }

    private static func parseRequest(_ data: Data, encrypted: Bool) -> (Request, Int)? {
        guard let parsed = try? AirPlay2EventRequest.parse(data) else { return nil }
        let request = Request(
            method: parsed.request.method,
            uri: parsed.request.uri,
            protocolVersion: parsed.request.protocolVersion,
            headers: parsed.request.headers,
            body: parsed.request.body,
            wasEncrypted: encrypted
        )
        return (request, parsed.consumed)
    }

    /// Décrypte un paquet audio comme le ferait le récepteur : AAD = octets 4 à 12 de l'en-tête,
    /// nonce = 4 octets nuls puis les 8 derniers octets du paquet.
    static func decryptAudio(_ packet: Data, key: Data) throws -> Data {
        let cipher = try ChaChaPoly1305(key: key)
        let bytes = Data(packet)
        let associated = bytes[4..<12]
        let nonce = Data(repeating: 0, count: 4) + bytes.suffix(8)
        let sealed = bytes[12..<(bytes.count - 8)]
        return try cipher.open(Data(sealed), nonce: nonce, additionalData: Data(associated))
    }

    static func sequence(of packet: Data) -> UInt16 {
        let bytes = [UInt8](packet.prefix(4))
        return UInt16(bytes[2]) << 8 | UInt16(bytes[3])
    }
}

final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var value: Bool { lock.withLock { flag } }
    func set() { lock.withLock { flag = true } }
}

/// Alimente un ring buffer en temps réel, comme le ferait la capture.
///
/// Une sinusoïde à 440 Hz sur la minuterie d'un fil dédié, jamais depuis une tâche asynchrone : la
/// capture réelle n'a pas à attendre le pool coopératif, et le sender ne doit pas s'en apercevoir.
final class SineFeeder: @unchecked Sendable {
    private let ring: AudioRingBuffer
    private let sampleRate: Double
    private let queue = DispatchQueue(label: "test.sine-feeder", qos: .userInitiated)
    private var timer: DispatchSourceTimer?
    private var written = 0
    private var startTime = Date()

    init(ring: AudioRingBuffer, sampleRate: Double = 48_000) {
        self.ring = ring
        self.sampleRate = sampleRate
    }

    func start() {
        startTime = Date()
        written = 0
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(5))
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    private func tick() {
        let target = Int(Date().timeIntervalSince(startTime) * sampleRate)
        let frames = min(target - written, 4_096)
        guard frames > 0 else { return }
        var samples = [Float](repeating: 0, count: frames * 2)
        for frame in 0..<frames {
            let phase = Double(written + frame) / sampleRate * 440 * 2 * .pi
            let value = Float(sin(phase) * 0.5)
            samples[frame * 2] = value
            samples[frame * 2 + 1] = value
        }
        samples.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            _ = ring.write(from: base, frameCount: frames)
        }
        written += frames
    }
}

/// Un sender branché sur un récepteur simulé, alimenté en continu.
struct SenderHarness {
    let sender: AirPlay2Sender
    let ring: AudioRingBuffer
    let feeder: SineFeeder

    static func captureFormat() throws -> AVAudioFormat {
        try #require(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2,
                interleaved: true))
    }

    init(
        receiver: FakeAirPlay2Receiver,
        reconnects: Bool = true,
        credentials: HapCredentials? = nil
    ) throws {
        ring = AudioRingBuffer(capacityFrames: 48_000, channelCount: 2)
        feeder = SineFeeder(ring: ring)
        sender = AirPlay2Sender(
            device: receiver.device(),
            ring: ring,
            captureFormat: try Self.captureFormat(),
            reconnects: reconnects,
            credentials: credentials
        )
        feeder.start()
    }
}

/// Attend qu'une condition devienne vraie, sans jamais attendre plus que `timeout`.
@discardableResult
func eventually(
    timeout: Duration = .seconds(8),
    _ condition: () async -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return await condition()
}
