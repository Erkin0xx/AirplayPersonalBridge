import Foundation
import Network
import Testing

@testable import AudioCore

/// Le client RTSP contre un serveur qui se comporte mal : réponses en miettes, en retard,
/// absentes, connexion coupée. Tout passe par une vraie connexion TCP sur la boucle locale.
@Suite("Client RTSP", .serialized)
struct RTSPClientTests {
    private func connectedClient(
        to server: FakeRAOPReceiver
    ) async throws -> RTSPClient {
        let client = RTSPClient(host: "127.0.0.1", port: server.port)
        try await client.connect(timeout: .seconds(3))
        return client
    }

    private func options() -> RTSPRequest { RTSPRequest(method: "OPTIONS", uri: "*") }

    /// Relu sur la pile de protocoles effective : ces réglages ont longtemps été posés sur
    /// `internetProtocol`, où le transtypage vers les options TCP échoue sans bruit.
    @Test("Le keepalive du noyau et l'absence de délai sont bien sur la couche TCP")
    func tcpOptions() throws {
        let parameters = RTSPClient.connectionParameters()
        let tcp = try #require(
            parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options
        )
        #expect(tcp.enableKeepalive)
        #expect(tcp.keepaliveIdle == 5)
        #expect(tcp.keepaliveInterval == 2)
        #expect(tcp.keepaliveCount == 3)
        #expect(tcp.noDelay)
    }

    /// La sonde du noyau ne remonte jamais jusqu'au flux : 6 s d'inactivité, soit au moins une
    /// sonde, puis un échange normal. En clair ici ; le canal chiffré repose sur le même flux.
    @Test("Une connexion inactive au-delà du seuil de sonde reste saine")
    func idleBeyondKeepaliveThreshold() async throws {
        let server = try await FakeRAOPReceiver()
        defer { server.shutdown() }
        let client = try await connectedClient(to: server)
        let lost = LostFlag()
        await client.onConnectionLost { lost.set() }

        try await Task.sleep(for: .seconds(6))

        #expect(!lost.value)
        let response = try await client.send(options(), timeout: .seconds(2))
        #expect(response.statusCode == 200)
        await client.disconnect()
    }

    @Test("Une réponse livrée octet par octet est reconstituée, corps compris")
    func fragmentedResponse() async throws {
        let raw = "RTSP/1.0 200 OK\r\ncseq: 1\r\nAUDIO-LATENCY: 4096\r\nconTENT-lengTH: 5\r\n\r\nhello"
        let bytes = raw.utf8.map { Data([$0]) }
        let server = try await FakeRAOPReceiver { _ in
            .chunks(bytes, spacing: .milliseconds(2))
        }
        defer { server.shutdown() }
        let client = try await connectedClient(to: server)

        let response = try await client.send(options(), timeout: .seconds(5))
        #expect(response.statusCode == 200)
        #expect(response.body == Data("hello".utf8))
        #expect(response.headers["audio-latency"] == "4096", "en-têtes insensibles à la casse")
        await client.disconnect()
    }

    @Test("Deux réponses dans le même segment : la seconde attend sa requête")
    func coalescedResponses() async throws {
        let both = Data(
            "RTSP/1.0 200 OK\r\nCSeq: 1\r\n\r\nRTSP/1.0 204 Vide\r\nCSeq: 2\r\n\r\n".utf8
        )
        let server = try await FakeRAOPReceiver { request in
            request.headers["cseq"] == "1" ? .chunks([both], spacing: .zero) : .silence
        }
        defer { server.shutdown() }
        let client = try await connectedClient(to: server)

        let first = try await client.send(options(), timeout: .seconds(2))
        let second = try await client.send(options(), timeout: .seconds(2))
        #expect(first.statusCode == 200)
        #expect(second.statusCode == 204)
        #expect(second.body.isEmpty)
        await client.disconnect()
    }

    @Test("Une requête restée sans réponse n'empoisonne pas la suivante")
    func unansweredRequestDoesNotPoisonTheNext() async throws {
        let server = try await FakeRAOPReceiver { request in
            request.headers["cseq"] == "1" ? .silence : .standard
        }
        defer { server.shutdown() }
        let client = try await connectedClient(to: server)

        await #expect(throws: RTSPError.self) {
            try await client.send(options(), timeout: .milliseconds(150))
        }
        // Avec une lecture armée par requête, celle de la requête expirée restait en attente et
        // avalait la réponse à celle-ci.
        let response = try await client.send(options(), timeout: .seconds(2))
        #expect(response.headers["cseq"] == "2")
        await client.disconnect()
    }

    @Test("Une réponse tardive est écartée au lieu d'être prise pour la suivante")
    func lateResponseIsDiscarded() async throws {
        let server = try await FakeRAOPReceiver { request in
            request.headers["cseq"] == "1"
                ? .delayed(.milliseconds(300), body: "tardive")
                : .delayed(.milliseconds(500), body: "attendue")
        }
        defer { server.shutdown() }
        let client = try await connectedClient(to: server)

        await #expect(throws: RTSPError.self) {
            try await client.send(options(), timeout: .milliseconds(100))
        }
        let response = try await client.send(options(), timeout: .seconds(3))
        #expect(String(decoding: response.body, as: UTF8.self) == "attendue")
        await client.disconnect()
    }

    @Test("Des requêtes concurrentes partent une à une, chacune avec sa réponse")
    func concurrentRequestsAreSerialized() async throws {
        let server = try await FakeRAOPReceiver { request in
            .delayed(.milliseconds(50), body: request.headers["cseq"] ?? "?")
        }
        defer { server.shutdown() }
        let client = try await connectedClient(to: server)

        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<5 {
                group.addTask {
                    let request = RTSPRequest(method: "OPTIONS", uri: "*")
                    let response = try await client.send(request, timeout: .seconds(5))
                    let echoed = String(decoding: response.body, as: UTF8.self)
                    #expect(response.headers["cseq"] == echoed)
                }
            }
            try await group.waitForAll()
        }
        #expect(server.requests.count == 5)
        #expect(server.requestOverlap == 1, "une seule requête à la fois sur la connexion")
        await client.disconnect()
    }

    @Test("Le délai couvre l'attente de son tour : un TEARDOWN ne reste pas bloqué derrière")
    func queueWaitCountsInTimeout() async throws {
        let server = try await FakeRAOPReceiver { _ in .silence }
        defer { server.shutdown() }
        let client = try await connectedClient(to: server)

        let blocker = Task {
            try await client.send(RTSPRequest(method: "OPTIONS", uri: "*"), timeout: .seconds(10))
        }
        try await Task.sleep(for: .milliseconds(50))

        let start = ContinuousClock.now
        await #expect(throws: RTSPError.self) {
            try await client.send(
                RTSPRequest(method: "TEARDOWN", uri: "rtsp://x/1"), timeout: .milliseconds(200)
            )
        }
        #expect(secondsSince(start) < 1)
        blocker.cancel()
        await client.disconnect()
        _ = try? await blocker.value
    }

    @Test("Connexion refusée : échec immédiat, message clair, et nouvelle tentative possible")
    func connectionRefused() async throws {
        let client = RTSPClient(host: "127.0.0.1", port: try LateTCPPort().port)
        let start = ContinuousClock.now
        do {
            try await client.connect(timeout: .seconds(10))
            Issue.record("la connexion aurait dû être refusée")
        } catch {
            #expect(String(describing: error).contains("refusée"), "\(error)")
        }
        #expect(secondsSince(start) < 3, "un refus n'a pas à attendre le délai de 10 s")

        // La connexion échouée ne doit pas rester en place : elle ferait passer le prochain
        // `connect` pour un succès, sans rien avoir établi.
        await #expect(throws: RTSPError.self) {
            try await client.connect(timeout: .seconds(1))
        }
    }

    @Test("Une fermeture propre du récepteur est signalée, sans requête en cours")
    func finIsReportedAsConnectionLoss() async throws {
        let server = try await FakeRAOPReceiver()
        defer { server.shutdown() }
        let client = try await connectedClient(to: server)
        _ = try await client.send(options(), timeout: .seconds(2))

        let lost = LostFlag()
        await client.onConnectionLost { lost.set() }
        server.closeConnections()

        // `NWConnection` reste `.ready` sur un FIN tant qu'aucune lecture ne le constate : avant
        // la lecture permanente, ce signal ne venait jamais.
        #expect(await raopEventually(within: .seconds(3)) { lost.value })

        await #expect(throws: RTSPError.self) {
            try await client.send(RTSPRequest(method: "OPTIONS", uri: "*"), timeout: .seconds(1))
        }
        await client.disconnect()
    }

    @Test("Une coupure brutale du récepteur (RST) est signalée elle aussi")
    func rstIsReportedAsConnectionLoss() async throws {
        let server = try await FakeRAOPReceiver()
        defer { server.shutdown() }
        let client = try await connectedClient(to: server)
        _ = try await client.send(options(), timeout: .seconds(2))

        let lost = LostFlag()
        await client.onConnectionLost { lost.set() }
        server.abortConnections()
        #expect(await raopEventually(within: .seconds(3)) { lost.value })
        await client.disconnect()
    }

    @Test("Une réponse suivie d'un FIN est remise, et la perte signalée ensuite")
    func responseFollowedByFinIsDelivered() async throws {
        let server = try await FakeRAOPReceiver { _ in .standardThenClose }
        defer { server.shutdown() }
        let client = try await connectedClient(to: server)

        // La fermeture arrive avec la réponse, voire avant que le lecteur ne la traite : elle ne
        // doit pas passer devant des octets déjà reçus.
        let response = try await client.send(options(), timeout: .seconds(2))
        #expect(response.isSuccess)

        let lost = LostFlag()
        await client.onConnectionLost { lost.set() }
        #expect(await raopEventually(within: .seconds(3)) { lost.value })
        await client.disconnect()
    }

    @Test("Une requête en cours échoue dès le FIN, sans attendre son délai")
    func pendingRequestFailsFastOnFin() async throws {
        let server = try await FakeRAOPReceiver { _ in .close }
        defer { server.shutdown() }
        let client = try await connectedClient(to: server)

        let start = ContinuousClock.now
        do {
            try await client.send(options(), timeout: .seconds(30))
            Issue.record("la connexion a été fermée sans réponse")
        } catch {
            #expect(String(describing: error).contains("fermée"), "\(error)")
        }
        #expect(secondsSince(start) < 1)
        await client.disconnect()
    }

    @Test("Une connexion déjà tombée le signale dès l'abonnement")
    func lossBeforeSubscriptionIsReported() async throws {
        let server = try await FakeRAOPReceiver()
        defer { server.shutdown() }
        let client = try await connectedClient(to: server)
        // Un aller-retour d'abord : le serveur n'a pas forcément accepté la connexion avant.
        _ = try await client.send(options(), timeout: .seconds(2))
        server.closeConnections()
        try await Task.sleep(for: .milliseconds(200))

        let lost = LostFlag()
        await client.onConnectionLost { lost.set() }
        #expect(lost.value)
        await client.disconnect()
    }

    @Test("Un arrêt volontaire n'est pas une perte de connexion")
    func disconnectIsNotALoss() async throws {
        let server = try await FakeRAOPReceiver()
        defer { server.shutdown() }
        let client = try await connectedClient(to: server)

        let lost = LostFlag()
        await client.onConnectionLost { lost.set() }
        await client.disconnect()
        try await Task.sleep(for: .milliseconds(200))
        #expect(!lost.value)
    }

    @Test("Déconnecter débloque aussitôt une requête en attente")
    func disconnectUnblocksPendingRequest() async throws {
        let server = try await FakeRAOPReceiver { _ in .silence }
        defer { server.shutdown() }
        let client = try await connectedClient(to: server)

        let start = ContinuousClock.now
        let pending = Task {
            try await client.send(RTSPRequest(method: "OPTIONS", uri: "*"), timeout: .seconds(30))
        }
        try await Task.sleep(for: .milliseconds(100))
        await client.disconnect()
        await #expect(throws: RTSPError.self) { try await pending.value }
        #expect(secondsSince(start) < 1)
    }

    @Test("Annuler une requête sensible à l'annulation la fait abandonner sur-le-champ")
    func cancellationInterruptsRequest() async throws {
        let server = try await FakeRAOPReceiver { _ in .silence }
        defer { server.shutdown() }
        let client = try await connectedClient(to: server)

        let start = ContinuousClock.now
        let pending = Task {
            try await client.send(
                RTSPRequest(method: "ANNOUNCE", uri: "rtsp://x/1"),
                timeout: .seconds(30),
                honoringCancellation: true
            )
        }
        try await Task.sleep(for: .milliseconds(100))
        pending.cancel()
        await #expect(throws: CancellationError.self) { try await pending.value }
        #expect(secondsSince(start) < 1)
        await client.disconnect()
    }

    @Test("Par défaut, une tâche annulée envoie quand même : c'est le chemin du TEARDOWN")
    func cancelledCallerStillSendsByDefault() async throws {
        let server = try await FakeRAOPReceiver()
        defer { server.shutdown() }
        let client = try await connectedClient(to: server)

        let pending = Task {
            // Attend d'être annulée avant d'émettre, comme un `stop()` appelé depuis une tâche
            // de sortie que `BridgeEngine` vient d'annuler.
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(5))
            }
            return try await client.send(
                RTSPRequest(method: "TEARDOWN", uri: "rtsp://x/1"), timeout: .seconds(2)
            )
        }
        pending.cancel()
        let response = try await pending.value
        #expect(response.isSuccess)
        #expect(server.requests.last?.method == "TEARDOWN")
        await client.disconnect()
    }

    @Test("Des octets illisibles échouent vite et ne bloquent pas la requête suivante")
    func garbageFailsFastAndConnectionRecovers() async throws {
        let server = try await FakeRAOPReceiver { request in
            request.headers["cseq"] == "1"
                ? .chunks([Data("n'importe quoi\r\n\r\n".utf8)], spacing: .zero)
                : .standard
        }
        defer { server.shutdown() }
        let client = try await connectedClient(to: server)

        let start = ContinuousClock.now
        await #expect(throws: RTSPError.self) {
            try await client.send(RTSPRequest(method: "OPTIONS", uri: "*"), timeout: .seconds(10))
        }
        #expect(secondsSince(start) < 1, "pas besoin d'attendre le délai pour le savoir")

        let response = try await client.send(options(), timeout: .seconds(2))
        #expect(response.isSuccess)
        await client.disconnect()
    }

    @Test("Un refus du récepteur arrive avec un message rédigé pour l'affichage")
    func refusalsAreReadable() async throws {
        for (code, reason, expected) in [
            (453, "Not Enough Bandwidth", "occupé"),
            (401, "Unauthorized", "mot de passe"),
            (400, "Bad Request", "invalide"),
            (500, "Internal Server Error", "interne"),
        ] {
            let server = try await FakeRAOPReceiver { _ in .status(code, reason) }
            let client = try await connectedClient(to: server)
            do {
                try await client.send(options(), timeout: .seconds(2))
                Issue.record("\(code) aurait dû lever une erreur")
            } catch let error as RTSPError {
                #expect(String(describing: error).contains(expected), "\(error)")
                #expect(error.statusCode == code)
                #expect(error.isReceiverBusy == (code == 453))
                #expect(error.requiresPassword == (code == 401))
            }
            await client.disconnect()
            server.shutdown()
        }
    }
}

private final class LostFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = false

    func set() {
        lock.lock()
        stored = true
        lock.unlock()
    }

    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}

/// L'analyse des réponses, sans réseau : c'est ce qui doit tenir face à n'importe quels octets.
@Suite("Analyse des réponses RTSP")
struct RTSPResponseParsingTests {
    private func analyse(_ text: String) -> RTSPResponse.Parsing {
        RTSPResponse.analyse(Data(text.utf8))
    }

    private func isMalformed(_ text: String) -> Bool {
        if case .malformed = analyse(text) { return true }
        return false
    }

    private func isIncomplete(_ text: String) -> Bool {
        if case .incomplete = analyse(text) { return true }
        return false
    }

    @Test("Une longueur négative ne fait pas tomber le processus")
    func negativeContentLengthDoesNotCrash() {
        // Une plage à l'envers est fatale à l'exécution : c'est ce que faisait cette valeur.
        #expect(isMalformed("RTSP/1.0 200 OK\r\nContent-Length: -5\r\n\r\nabc"))
    }

    @Test("Une longueur illisible ou démesurée est un refus, pas une attente sans fin")
    func absurdContentLength() {
        #expect(isMalformed("RTSP/1.0 200 OK\r\nContent-Length: beaucoup\r\n\r\n"))
        #expect(isMalformed("RTSP/1.0 200 OK\r\nContent-Length: 99999999999\r\n\r\n"))
    }

    @Test("Un en-tête sans fin finit par être tenu pour illisible")
    func endlessHeader() {
        #expect(isIncomplete("RTSP/1.0 200 OK\r\nX: " + String(repeating: "a", count: 1_000)))
        #expect(isMalformed("RTSP/1.0 200 OK\r\nX: " + String(repeating: "a", count: 70_000)))
    }

    @Test("Une ligne de statut qui n'en est pas une est illisible")
    func invalidStatusLine() {
        #expect(isMalformed("bonjour\r\n\r\n"))
        #expect(isMalformed("RTSP/1.0 abc OK\r\n\r\n"))
        #expect(isMalformed("POST /feedback RTSP/1.0\r\n\r\n"))
        #expect(isMalformed("\r\n\r\n"))
    }

    @Test("Un octet non UTF-8 dans un en-tête ne rend pas la réponse illisible")
    func nonUTF8Header() throws {
        var raw = Data("RTSP/1.0 200 OK\r\nCSeq: 7\r\nX-Nom: ".utf8)
        raw.append(contentsOf: [0xE9, 0xFF])
        raw.append(Data("\r\n\r\n".utf8))
        let parsed = try #require(RTSPResponse.parse(raw))
        #expect(parsed.response.statusCode == 200)
        #expect(parsed.response.headers["cseq"] == "7")
    }

    @Test("Le corps peut contenir la séquence de fin d'en-têtes")
    func bodyContainingHeaderTerminator() throws {
        let raw = Data("RTSP/1.0 200 OK\r\nContent-Length: 6\r\n\r\na\r\n\r\nb".utf8)
        let parsed = try #require(RTSPResponse.parse(raw))
        #expect(parsed.response.body == Data("a\r\n\r\nb".utf8))
        #expect(parsed.consumed == raw.count)
    }

    @Test("L'analyse fonctionne sur une tranche, dont les indices ne partent pas de zéro")
    func parsesASlice() throws {
        let raw = Data("xxxxRTSP/1.0 200 OK\r\nContent-Length: 2\r\n\r\nabRTSP".utf8)
        let slice = raw.dropFirst(4)
        #expect(slice.startIndex != 0)
        let parsed = try #require(RTSPResponse.parse(slice))
        #expect(parsed.response.body == Data("ab".utf8))
        #expect(parsed.consumed == slice.count - 4)
    }

    @Test("Sans Content-Length, le corps est vide ; le pairing AirPlay 2 répond en HTTP")
    func noContentLengthAndHTTP() throws {
        let parsed = try #require(RTSPResponse.parse(Data("HTTP/1.1 200 OK\r\n\r\n".utf8)))
        #expect(parsed.response.body.isEmpty)
        #expect(parsed.response.reasonPhrase == "OK")
    }

    @Test("Une ligne de statut sans raison, et des en-têtes aux espaces variés")
    func looseFormatting() throws {
        let parsed = try #require(
            RTSPResponse.parse(Data("RTSP/1.0 200\r\nCSeq:3\r\n  Session :  12 \r\n\r\n".utf8))
        )
        #expect(parsed.response.reasonPhrase == "")
        #expect(parsed.response.headers["cseq"] == "3")
        #expect(parsed.response.headers["session"] == "12")
    }
}

@Suite("Paquet de retransmission")
struct RTPRetransmissionPacketTests {
    @Test("80 D6, séquence d'origine, puis le paquet complet")
    func format() throws {
        let original = RTPPacketBuilder.audio(
            sequenceNumber: 0x1234, timestamp: 1, ssrc: 2, marker: false, payload: [0xAA]
        )
        let response = try #require(RTPPacketBuilder.retransmissionResponse(originalPacket: original))
        #expect(Array(response.prefix(4)) == [0x80, 0xD6, 0x12, 0x34])
        #expect(response.dropFirst(4) == original)
    }

    @Test("Fonctionne sur une tranche, et refuse un paquet sans en-tête")
    func sliceAndTooShort() throws {
        let slice = Data([0, 0, 0x80, 0x60, 0x00, 0x07]).dropFirst(2)
        let response = try #require(RTPPacketBuilder.retransmissionResponse(originalPacket: slice))
        #expect(Array(response.prefix(4)) == [0x80, 0xD6, 0x00, 0x07])
        #expect(RTPPacketBuilder.retransmissionResponse(originalPacket: Data([0x80])) == nil)
    }
}

@Suite("Canal UDP")
struct UDPChannelTests {
    @Test("Arrêter un canal le libère, même si son gestionnaire le retient")
    func stopBreaksRetainCycle() throws {
        weak var released: UDPChannel?
        do {
            let channel = try UDPChannel(label: "test-cycle")
            released = channel
            // Exactement ce que fait un répondeur d'horloge : il répond sur le canal qu'il écoute.
            channel.onReceive = { data, _ in try? channel.send(data) }
            channel.startReceiving()
            channel.stop()
        }
        #expect(released == nil, "le socket de chaque session restait ouvert derrière elle")
    }

    @Test("Un datagramme reçu arrive au gestionnaire, puis plus rien après l'arrêt")
    func receivesUntilStopped() async throws {
        let receiver = try UDPChannel(label: "test-recv")
        let sender = try UDPChannel(label: "test-send")
        try sender.setDestination(host: "127.0.0.1", port: receiver.localPort)

        let count = Counter()
        receiver.onReceive = { _, _ in count.increment() }
        receiver.startReceiving()

        try sender.send(Data([1, 2, 3]))
        #expect(await raopEventually(within: .seconds(2)) { count.value == 1 })

        receiver.stop()
        try sender.send(Data([4]))
        try await Task.sleep(for: .milliseconds(100))
        #expect(count.value == 1)
    }

    @Test("Seule une adresse IPv4 littérale est une destination")
    func ipv4Literals() {
        #expect(UDPChannel.isIPv4Literal("192.168.1.21"))
        #expect(!UDPChannel.isIPv4Literal("fe80::1"))
        #expect(!UDPChannel.isIPv4Literal("geneva.local"))
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = 0

    func increment() {
        lock.lock()
        stored += 1
        lock.unlock()
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}
