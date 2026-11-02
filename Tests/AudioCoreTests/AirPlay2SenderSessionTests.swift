import Foundation
import Testing

@testable import AudioCore

/// Le sender complet contre un récepteur simulé : tout ce qu'aucun récepteur réel ne déclenche à
/// la demande, chemins d'erreur compris. Le pairing y est le transitoire, celui des HomePod.
@Suite("Sender AirPlay 2 — session complète")
struct AirPlay2SenderSessionTests {

    private final class LockedCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0

        func increment() { lock.withLock { count += 1 } }
        var value: Int { lock.withLock { count } }
    }

    private func makeReceiver(
        options: FakeAirPlay2Receiver.Options = .init()
    ) async throws -> FakeAirPlay2Receiver {
        let receiver = FakeAirPlay2Receiver(options: options)
        try await receiver.start()
        return receiver
    }

    // MARK: - Conformité à pyatv

    /// Le jeu de clés du `SETUP` a été aligné sur pyatv pour les HomePod (commit 824f16d). Toute
    /// clé perdue en route ferait réapparaître un `400` qu'aucun test n'attraperait.
    @Test("Les plists de SETUP portent exactement les clés de pyatv")
    func plistConformes() async throws {
        let receiver = try await makeReceiver()
        defer { receiver.stop() }
        let harness = try SenderHarness(receiver: receiver)
        defer { harness.feeder.stop() }

        try await harness.sender.start(volume: -20)
        await harness.sender.stop()

        let setups = receiver.requests().filter { $0.method == "SETUP" }
        try #require(setups.count == 2)
        let session = try #require(
            try PropertyListSerialization.propertyList(from: setups[0].body, format: nil)
                as? [String: Any])
        #expect(
            Set(session.keys) == [
                "deviceID", "sessionUUID", "timingPort", "timingProtocol", "isMultiSelectAirPlay",
                "groupContainsGroupLeader", "macAddress", "model", "name", "osBuildVersion",
                "osName", "osVersion", "senderSupportsRelay", "sourceVersion",
                "statsCollectionEnabled",
            ])
        #expect(session["timingProtocol"] as? String == "NTP")

        let flux = try #require(
            try PropertyListSerialization.propertyList(from: setups[1].body, format: nil)
                as? [String: Any])
        let stream = try #require((flux["streams"] as? [[String: Any]])?.first)
        #expect(
            Set(stream.keys) == [
                "audioFormat", "audioMode", "controlPort", "ct", "isMedia", "latencyMax",
                "latencyMin", "shk", "spf", "sr", "type", "supportsDynamicStreamID",
                "streamConnectionID",
            ])
        #expect(stream["audioFormat"] as? Int == 0x800)
        #expect(stream["ct"] as? Int == 1)
        #expect(stream["type"] as? Int == 0x60)
        #expect(stream["spf"] as? Int == 352)
        #expect(stream["sr"] as? Int == 44_100)
        #expect((stream["shk"] as? Data)?.count == 32)
    }

    /// Le transitoire : `X-Apple-HKP: 4`, en HTTP/1.1 sans `CSeq`, sans `/pair-pin-start`, et
    /// tout ce qui suit passe chiffré.
    @Test("Le pair-setup transitoire reste celui des HomePod")
    func pairSetupTransitoire() async throws {
        let receiver = try await makeReceiver()
        defer { receiver.stop() }
        let harness = try SenderHarness(receiver: receiver)
        defer { harness.feeder.stop() }

        try await harness.sender.start(volume: -20)
        await harness.sender.stop()

        let requests = receiver.requests()
        let pairing = requests.filter { $0.uri == "/pair-setup" }
        #expect(pairing.count == 2)
        #expect(pairing.allSatisfy { $0.headers["x-apple-hkp"] == "4" })
        #expect(pairing.allSatisfy { $0.protocolVersion == "HTTP/1.1" && !$0.wasEncrypted })
        #expect(!requests.contains { $0.uri == "/pair-pin-start" })
        #expect(requests.filter { $0.uri != "/pair-setup" }.allSatisfy { $0.wasEncrypted })

        let sequence = requests.filter { $0.uri != "/pair-setup" && $0.uri != "/feedback" }.map(\.method)
        #expect(sequence == ["SETUP", "SETUP", "SET_PARAMETER", "RECORD", "TEARDOWN"])
    }

    /// Le format relevé sur les vrais HomePod : PCM big-endian, AAD 4..<12, nonce en queue.
    @Test("Les paquets audio sont déchiffrables et au format annoncé")
    func paquetsConformes() async throws {
        let receiver = try await makeReceiver()
        defer { receiver.stop() }
        let harness = try SenderHarness(receiver: receiver)
        defer { harness.feeder.stop() }

        try await harness.sender.start(volume: -20)
        #expect(await waitUntil { receiver.audioPackets(inSession: 0).count >= 200 })
        await harness.sender.stop()

        let packets = receiver.audioPackets(inSession: 0)
        let key = receiver.streamKey(inSession: 0)
        let first = try #require(packets.first)
        #expect(first[first.startIndex + 1] == 0xE0)  // bit marker sur le premier paquet
        #expect(packets.dropFirst().allSatisfy { $0[$0.startIndex + 1] == 0x60 })
        // 12 d'en-tête, 1408 de PCM, 16 d'étiquette, 8 de nonce.
        #expect(packets.allSatisfy { $0.count == 12 + 1_408 + 16 + 8 })

        // Le PCM déchiffré doit porter une sinusoïde à -6 dB : des échantillons big-endian lus
        // correctement restent bornés et continus d'une trame à l'autre.
        let pcm = try FakeAirPlay2Receiver.decryptAudio(packets[100], key: key)
        #expect(pcm.count == 1_408)
        var previous: Int32?
        var largestStep: Int32 = 0
        var peak: Int32 = 0
        for frame in stride(from: 0, to: pcm.count, by: 4) {
            let sample = Int32(Int16(bitPattern: UInt16(pcm[frame]) << 8 | UInt16(pcm[frame + 1])))
            peak = max(peak, abs(sample))
            if let previous { largestStep = max(largestStep, abs(sample - previous)) }
            previous = sample
        }
        #expect(peak > 8_000)
        #expect(peak < 20_000)
        #expect(largestStep < 2_000)

        // Horodatages croissants de 352 trames, séquences consécutives.
        for (a, b) in zip(packets, packets.dropFirst()).prefix(50) {
            #expect(FakeAirPlay2Receiver.sequence(of: b) == FakeAirPlay2Receiver.sequence(of: a) &+ 1)
        }
    }

    /// Le blocage le plus coûteux des essais réels (commit 824f16d) : le HomePod ne répond au
    /// `SETUP` qu'une fois notre horloge mesurée.
    @Test("L'horloge répond avant le SETUP, comme l'exige le HomePod")
    func horlogeAvantSetup() async throws {
        let receiver = try await makeReceiver()
        defer { receiver.stop() }
        let harness = try SenderHarness(receiver: receiver)
        defer { harness.feeder.stop() }

        try await harness.sender.start(volume: -20)
        #expect(receiver.timingWasAnswered(inSession: 0))
        await harness.sender.stop()
    }

    @Test("Un TEARDOWN part à l'arrêt, avec l'URI de la session")
    func teardownALArret() async throws {
        let receiver = try await makeReceiver()
        defer { receiver.stop() }
        let harness = try SenderHarness(receiver: receiver)
        defer { harness.feeder.stop() }

        try await harness.sender.start(volume: -20)
        await harness.sender.stop()

        let teardown = try #require(receiver.requests().last { $0.method == "TEARDOWN" })
        let record = try #require(receiver.requests().last { $0.method == "RECORD" })
        #expect(teardown.uri == record.uri)
        #expect(await harness.sender.state == .idle)
    }

    // MARK: - Identité du contrôleur

    /// Le défaut relevé sur les HomePod (firmware 27.2) : le volume, le `RECORD` et le `TEARDOWN`
    /// partaient sans l'identité du `SETUP`, et le HomePod refusait le volume en `403`. Le
    /// récepteur simulé applique la même règle, si bien que sans le correctif la session échoue dès
    /// le `SET_PARAMETER`.
    @Test("Toutes les requêtes de session portent l'identité du SETUP, une fois chacune")
    func identiteDuControleur() async throws {
        let receiver = try await makeReceiver()
        defer { receiver.stop() }
        let harness = try SenderHarness(receiver: receiver)
        defer { harness.feeder.stop() }

        try await harness.sender.start(volume: -20)
        try await harness.sender.setVolume(-10)
        #expect(await waitUntil { receiver.count(method: "POST", uri: "/feedback") >= 1 })
        await harness.sender.stop()

        #expect(receiver.forbiddenRequests().isEmpty)
        let session = receiver.requests(inSession: 0).filter { $0.protocolVersion == "RTSP/1.0" }
        #expect(
            Set(session.map(\.method)) == ["SETUP", "SET_PARAMETER", "RECORD", "POST", "TEARDOWN"])
        let reference = try #require(session.first)
        let dacp = try #require(reference.headers["dacp-id"])
        let remote = try #require(reference.headers["active-remote"])
        for request in session {
            let label = "\(request.method) \(request.uri)"
            #expect(request.headers["user-agent"] == "AirPlay/550.10", "\(label)")
            #expect(request.headers["dacp-id"] == dacp, "\(label)")
            #expect(request.headers["client-instance"] == dacp, "\(label)")
            #expect(request.headers["active-remote"] == remote, "\(label)")
        }
        // `RTSPClient` ajoute `User-Agent` et `Client-Instance` quand ils manquent : rien ne doit
        // partir deux fois, pairing compris. Un HomePod ne répond pas à un `SETUP` qui en double un.
        for request in receiver.requests() {
            let names = request.headerNames
            #expect(names.count == Set(names).count, "\(request.method) \(request.uri) : \(names)")
        }
    }

    /// La règle elle-même, hors du sender : sans quoi le test précédent pourrait passer à vide.
    @Test("Le récepteur simulé refuse en 403 une requête qui ne porte pas l'identité du SETUP")
    func regleDIdentiteDuRecepteur() async throws {
        var options = FakeAirPlay2Receiver.Options()
        options.requiresTimingBeforeSetup = false
        options.eventChannelEnabled = false
        let receiver = try await makeReceiver(options: options)
        defer { receiver.stop() }
        let client = RTSPClient(host: "127.0.0.1", port: receiver.port)
        try await client.connect()

        let identity = [("DACP-ID", "ABCDEF"), ("Client-Instance", "ABCDEF")]
        let plist = try PropertyListSerialization.data(
            fromPropertyList: ["timingPort": 0], format: .binary, options: 0)
        _ = try await client.send(
            RTSPRequest(
                method: "SETUP", uri: "rtsp://127.0.0.1/1",
                headers: identity + [("Content-Length", String(plist.count))], body: plist))

        // Sans identité, `RTSPClient` pose son propre `Client-Instance` : un autre contrôleur.
        do {
            _ = try await client.send(RTSPRequest(method: "RECORD", uri: "rtsp://127.0.0.1/1"))
            Issue.record("RECORD accepté sous une autre identité")
        } catch let error as RTSPError {
            #expect(error.statusCode == 403)
        }
        _ = try await client.send(
            RTSPRequest(method: "RECORD", uri: "rtsp://127.0.0.1/1", headers: identity))
        #expect(receiver.forbiddenRequests(inSession: 0).map(\.method) == ["RECORD"])
        await client.disconnect()
    }

    // MARK: - Retransmission

    /// Le cœur du point 1 : ce que le récepteur reçoit doit être le paquet d'origine, à l'octet
    /// près, précédé de `80 D6 | séquence`.
    @Test("Une demande de retransmission rend le paquet d'origine à l'identique")
    func retransmissionIdentique() async throws {
        let receiver = try await makeReceiver()
        defer { receiver.stop() }
        let harness = try SenderHarness(receiver: receiver)
        defer { harness.feeder.stop() }

        try await harness.sender.start(volume: -20)
        #expect(await waitUntil { receiver.audioPackets(inSession: 0).count >= 50 })

        let packets = receiver.audioPackets(inSession: 0)
        let wanted = Array(packets[10..<13])
        let first = FakeAirPlay2Receiver.sequence(of: wanted[0])
        receiver.requestRetransmission(first: first, count: 3, inSession: 0)

        #expect(await waitUntil { receiver.resendPackets(inSession: 0).count >= 3 })
        let resent = receiver.resendPackets(inSession: 0)
        try #require(resent.count == 3)
        for (response, original) in zip(resent, wanted) {
            #expect(response.prefix(2) == Data([0x80, 0xD6]))
            #expect(response.dropFirst(2).prefix(2) == original.dropFirst(2).prefix(2))
            #expect(Data(response.dropFirst(4)) == original)
        }

        // Et le contenu reste déchiffrable par le récepteur : le nonce a suivi.
        let key = receiver.streamKey(inSession: 0)
        _ = try FakeAirPlay2Receiver.decryptAudio(Data(resent[0].dropFirst(4)), key: key)

        #expect(
            await waitUntil {
                let statistics = await harness.sender.statistics
                return statistics.retransmitRequests == 1 && statistics.retransmittedPackets == 3
            })
        await harness.sender.stop()
    }

    @Test("Un paquet trop ancien est compté, et rien ne part")
    func retransmissionHorsHistorique() async throws {
        let receiver = try await makeReceiver()
        defer { receiver.stop() }
        let harness = try SenderHarness(receiver: receiver)
        defer { harness.feeder.stop() }

        try await harness.sender.start(volume: -20)
        #expect(await waitUntil { receiver.audioPackets(inSession: 0).count >= 20 })

        let current = FakeAirPlay2Receiver.sequence(of: try #require(receiver.audioPackets(inSession: 0).first))
        receiver.requestRetransmission(first: current &- 2_000, count: 5, inSession: 0)

        #expect(
            await waitUntil {
                let statistics = await harness.sender.statistics
                return statistics.retransmitRequests == 1 && statistics.retransmitMisses == 5
            })
        #expect(receiver.resendPackets(inSession: 0).isEmpty)
        await harness.sender.stop()
    }

    /// Une rafale ne passe pas par l'acteur : le flux garde sa cadence. Avant la correction du
    /// point 1, cela se serait joué sur un seul fil.
    @Test("Une rafale de demandes ne retarde pas le flux")
    func rafaleSansEffetSurLeFlux() async throws {
        let receiver = try await makeReceiver()
        defer { receiver.stop() }
        let harness = try SenderHarness(receiver: receiver)
        defer { harness.feeder.stop() }

        try await harness.sender.start(volume: -20)
        #expect(await waitUntil { receiver.audioPackets(inSession: 0).count >= 300 })

        let before = receiver.audioPackets(inSession: 0).count
        let start = Date()
        let first = FakeAirPlay2Receiver.sequence(of: receiver.audioPackets(inSession: 0)[100])
        for _ in 0..<50 {
            // `count` absurde compris : il doit être borné à l'historique.
            receiver.requestRetransmission(first: first, count: 65_535, inSession: 0)
        }
        try await Task.sleep(for: .milliseconds(500))

        let elapsed = Date().timeIntervalSince(start)
        let produced = receiver.audioPackets(inSession: 0).count - before
        let expected = elapsed / (352.0 / 44_100)
        #expect(Double(produced) > expected * 0.8, "\(produced) paquets en \(elapsed) s")
        await harness.sender.stop()
    }

    @Test("Une demande mal formée est ignorée")
    func demandeMalFormee() {
        #expect(RTPRetransmitRequest(datagram: Data([0x80, 0xD5, 0x00])) == nil)
        #expect(RTPRetransmitRequest(datagram: Data([0x80, 0xD4, 0, 1, 0, 2, 0, 3])) == nil)
    }

    @Test("La borne des 65 535 paquets et le passage par zéro")
    func enveloppeRetransmission() throws {
        let retransmitter = AirPlay2Retransmitter()
        let packet = Data([0x80, 0x60, 0xFF, 0xFF, 1, 2, 3])
        retransmitter.record(sequence: 0xFFFF, packet: packet)
        retransmitter.record(sequence: 0x0000, packet: Data([0x80, 0x60, 0x00, 0x00, 4]))

        let request = RTPRetransmitRequest(datagram: Data([0x80, 0xD5, 0, 1, 0xFF, 0xFF, 0, 2]))
        let (responses, missing) = retransmitter.responses(for: try #require(request))
        #expect(responses.count == 2)
        #expect(missing == 0)
        #expect(responses[0] == Data([0x80, 0xD6, 0xFF, 0xFF]) + packet)
        #expect(responses[1].prefix(4) == Data([0x80, 0xD6, 0x00, 0x00]))
    }

    // MARK: - Maintien de session

    /// `POST /feedback` toutes les 2 s, comme pyatv : RTSP/1.0, `CSeq`, trois en-têtes
    /// d'identification, sans corps.
    @Test("Un feedback part à la cadence de pyatv")
    func feedbackPeriodique() async throws {
        let receiver = try await makeReceiver()
        defer { receiver.stop() }
        let harness = try SenderHarness(receiver: receiver)
        defer { harness.feeder.stop() }

        try await harness.sender.start(volume: -20)
        #expect(await waitUntil(timeout: .seconds(5)) { receiver.count(method: "POST", uri: "/feedback") >= 2 })
        await harness.sender.stop()

        let feedback = try #require(receiver.requests().first { $0.uri == "/feedback" })
        #expect(feedback.protocolVersion == "RTSP/1.0")
        #expect(feedback.wasEncrypted)
        #expect(feedback.headers["cseq"] != nil)
        #expect(feedback.headers["user-agent"] == "AirPlay/550.10")
        #expect(feedback.headers["dacp-id"] != nil)
        #expect(feedback.headers["active-remote"] != nil)
        #expect(feedback.headers["client-instance"] == feedback.headers["dacp-id"])
        #expect(feedback.headers["content-length"] == nil)
        #expect(feedback.body.isEmpty)

        // Rien entre le TEARDOWN et la fin : la tâche s'arrête avec la session.
        let count = receiver.count(method: "POST", uri: "/feedback")
        try await Task.sleep(for: .milliseconds(2_200))
        #expect(receiver.count(method: "POST", uri: "/feedback") == count)
    }

    /// Le récepteur a répondu : il est donc là. Refuser ce message ne vaut pas une panne.
    @Test("Un feedback refusé ne tue pas la session")
    func feedbackRefuse() async throws {
        let receiver = try await makeReceiver()
        defer { receiver.stop() }
        receiver.script = { request, _ in
            request.uri == "/feedback" ? .status(500, "Internal Server Error") : .normal
        }
        let harness = try SenderHarness(receiver: receiver)
        defer { harness.feeder.stop() }

        try await harness.sender.start(volume: -20)
        await harness.sender.setKeepAlivePolicy(.init(interval: .milliseconds(100)))
        #expect(await waitUntil { await harness.sender.statistics.feedbackRefused >= 1 })
        try await Task.sleep(for: .seconds(1))

        #expect(await harness.sender.state == .streaming)
        #expect(await harness.sender.statistics.reconnections == 0)
        #expect(receiver.sessionCount == 1)
        await harness.sender.stop()
    }

    /// Un récepteur qui n'a jamais répondu à ce message ne le connaît peut-être pas : on ne le
    /// condamne pas sur ce seul indice.
    @Test("Un récepteur qui ignore le feedback depuis le début n'est pas condamné")
    func feedbackJamaisRepondu() async throws {
        let receiver = try await makeReceiver()
        defer { receiver.stop() }
        receiver.script = { request, _ in request.uri == "/feedback" ? .silent : .normal }
        let harness = try SenderHarness(receiver: receiver)
        defer { harness.feeder.stop() }

        await harness.sender.setKeepAlivePolicy(
            .init(interval: .milliseconds(10), timeout: .milliseconds(100)))
        try await harness.sender.start(volume: -20)
        try await Task.sleep(for: .seconds(1))

        #expect(await harness.sender.state == .streaming)
        #expect(receiver.sessionCount == 1)
        await harness.sender.stop()
    }

    /// Trois silences valaient perte, donc `TEARDOWN` et nouveau pair-setup, sur un son qui marchait
    /// peut-être très bien. Chez pyatv ce message est « best effort », et la perte réelle a son signal.
    @Test("Un récepteur qui répondait puis se tait n'est pas condamné pour autant")
    func feedbackSilence() async throws {
        let receiver = try await makeReceiver()
        defer { receiver.stop() }
        receiver.script = { request, occurrence in
            request.uri == "/feedback" && occurrence >= 1 ? .silent : .normal
        }
        let harness = try SenderHarness(receiver: receiver)
        defer { harness.feeder.stop() }

        await harness.sender.setKeepAlivePolicy(
            .init(interval: .milliseconds(20), timeout: .milliseconds(100)))
        try await harness.sender.start(volume: -20)

        #expect(await waitUntil { await harness.sender.statistics.feedbackUnanswered >= 5 })
        #expect(await harness.sender.statistics.feedbackSent >= 1)
        #expect(await harness.sender.state == .streaming)
        #expect(await harness.sender.statistics.reconnections == 0)
        #expect(receiver.sessionCount == 1)
        #expect(!receiver.requests(inSession: 0).contains { $0.method == "TEARDOWN" })
        #expect(receiver.requests().filter { $0.uri == "/pair-setup" }.count == 2)
        // Le relevé remonte jusqu'à l'affichage, et le son n'a pas cessé de partir.
        #expect(await harness.sender.currentOutputStatistics().feedbackUnanswered ?? 0 >= 5)
        let packets = receiver.audioPackets(inSession: 0).count
        #expect(await waitUntil { receiver.audioPackets(inSession: 0).count > packets })
        await harness.sender.stop()
    }

    /// Une coupure de courant ne se simule pas sur la boucle locale, le noyau y acquitte les sondes :
    /// le keepalive lui-même se vérifie sur ses réglages (`RTSPClientTests.tcpOptions`). Ce test en
    /// couvre la suite, ce que devient sa fin de connexion une fois le silence devenu inoffensif.
    @Test("Une rupture de la connexion reste une perte, même après des feedback sans réponse")
    func ruptureApresSilence() async throws {
        let receiver = try await makeReceiver()
        defer { receiver.stop() }
        receiver.script = { request, occurrence in
            request.uri == "/feedback" && occurrence >= 1 ? .silent : .normal
        }
        let harness = try SenderHarness(receiver: receiver)
        defer { harness.feeder.stop() }

        await harness.sender.setKeepAlivePolicy(
            .init(interval: .milliseconds(20), timeout: .milliseconds(100)))
        try await harness.sender.start(volume: -20)
        #expect(await waitUntil { await harness.sender.statistics.feedbackUnanswered >= 3 })

        receiver.dropControlConnection(inSession: 0)

        #expect(await waitUntil { receiver.audioPackets(inSession: 1).count >= 5 })
        #expect(await harness.sender.state == .streaming)
        #expect(await harness.sender.statistics.reconnections == 1)
        await harness.sender.stop()
    }

    // MARK: - Perte et reconnexion

    /// Fermeture de la connexion de contrôle : le keep-alive la voit, et tout le chemin est refait.
    @Test("Une rupture RTSP déclenche une reconnexion complète, SRP compris")
    func reconnexionApresRuptureRTSP() async throws {
        let receiver = try await makeReceiver()
        defer { receiver.stop() }
        let harness = try SenderHarness(receiver: receiver)
        defer { harness.feeder.stop() }

        await harness.sender.setKeepAlivePolicy(.init(interval: .milliseconds(100)))
        try await harness.sender.start(volume: -20)
        #expect(await waitUntil { receiver.audioPackets(inSession: 0).count >= 10 })

        receiver.dropControlConnection(inSession: 0)

        #expect(await waitUntil { receiver.audioPackets(inSession: 1).count >= 10 })
        #expect(await harness.sender.state == .streaming)
        #expect(await harness.sender.statistics.reconnections == 1)

        // Pair-setup refait : deux messages par session.
        #expect(receiver.requests(inSession: 1).filter { $0.uri == "/pair-setup" }.count == 2)
        // Clé de flux neuve, et marqueur de début de flux.
        #expect(receiver.streamKey(inSession: 0) != receiver.streamKey(inSession: 1))
        let restart = try #require(receiver.audioPackets(inSession: 1).first)
        #expect(restart[restart.startIndex + 1] == 0xE0)

        // Pas de fuite d'une session à l'autre : l'ancien socket d'horloge est fermé, le nouveau
        // répond. Chaque reconnexion en laissait un de plus, qui continuait de répondre.
        #expect(try await receiver.probeTiming(port: receiver.timingPort(inSession: 1), timeout: 1))
        #expect(try await receiver.probeTiming(port: receiver.timingPort(inSession: 0), timeout: 0.3) == false)
        #expect(await portIsFree(receiver.timingPort(inSession: 0)))
        await harness.sender.stop()
    }

    @Test("Une rupture du canal d'événements déclenche une reconnexion")
    func reconnexionApresRuptureEvenements() async throws {
        let receiver = try await makeReceiver()
        defer { receiver.stop() }
        let harness = try SenderHarness(receiver: receiver)
        defer { harness.feeder.stop() }

        try await harness.sender.start(volume: -20)
        #expect(await waitUntil { receiver.eventChannelIsOpen(inSession: 0) })

        receiver.dropEventChannel(inSession: 0)

        #expect(await waitUntil { receiver.audioPackets(inSession: 1).count >= 10 })
        // La connexion de contrôle vivait encore : la session a été fermée proprement.
        #expect(receiver.requests(inSession: 0).contains { $0.method == "TEARDOWN" })
        await harness.sender.stop()
    }

    /// Un paquet de la session précédente, chiffré sous une autre clé, serait indéchiffrable : le
    /// renvoyer perturberait le récepteur au lieu de l'aider.
    @Test("L'historique de retransmission est vidé à la reconnexion")
    func historiqueVide() async throws {
        let receiver = try await makeReceiver()
        defer { receiver.stop() }
        let harness = try SenderHarness(receiver: receiver)
        defer { harness.feeder.stop() }

        await harness.sender.setKeepAlivePolicy(.init(interval: .milliseconds(100)))
        try await harness.sender.start(volume: -20)
        #expect(await waitUntil { receiver.audioPackets(inSession: 0).count >= 20 })
        let old = FakeAirPlay2Receiver.sequence(of: receiver.audioPackets(inSession: 0)[5])

        receiver.dropControlConnection(inSession: 0)
        #expect(await waitUntil { receiver.audioPackets(inSession: 1).count >= 5 })

        receiver.requestRetransmission(first: old, count: 1, inSession: 1)
        #expect(
            await waitUntil {
                await harness.sender.statistics.retransmitMisses == 1
            })
        #expect(receiver.resendPackets(inSession: 1).isEmpty)

        // La session courante, elle, reste servie.
        let fresh = FakeAirPlay2Receiver.sequence(of: try #require(receiver.audioPackets(inSession: 1).first))
        receiver.requestRetransmission(first: fresh, count: 1, inSession: 1)
        #expect(await waitUntil { receiver.resendPackets(inSession: 1).count == 1 })
        await harness.sender.stop()
    }

    /// `setVolume` ne retenait pas la consigne : après une perte réseau, la sortie revenait au
    /// volume de son démarrage.
    @Test("La reconnexion réapplique le dernier volume demandé")
    func volumeConserve() async throws {
        let receiver = try await makeReceiver()
        defer { receiver.stop() }
        let harness = try SenderHarness(receiver: receiver)
        defer { harness.feeder.stop() }

        await harness.sender.setKeepAlivePolicy(.init(interval: .milliseconds(100)))
        try await harness.sender.start(volume: -20)
        try await harness.sender.setVolume(-7.5)
        #expect(receiver.volumes(inSession: 0).last == "volume: -7.5\r\n")

        receiver.dropControlConnection(inSession: 0)
        #expect(await waitUntil { !receiver.volumes(inSession: 1).isEmpty })
        #expect(receiver.volumes(inSession: 1) == ["volume: -7.5\r\n"])
        await harness.sender.stop()
    }

    @Test("Sans reconnexion, l'état dit que la session est perdue")
    func sansReconnexion() async throws {
        let receiver = try await makeReceiver()
        defer { receiver.stop() }
        let harness = try SenderHarness(receiver: receiver, reconnects: false)
        defer { harness.feeder.stop() }

        await harness.sender.setKeepAlivePolicy(.init(interval: .milliseconds(100)))
        try await harness.sender.start(volume: -20)
        #expect(await waitUntil { receiver.audioPackets(inSession: 0).count >= 5 })

        receiver.dropControlConnection(inSession: 0)

        #expect(await waitUntil { await harness.sender.state == .failed })
        #expect(await harness.sender.statistics.lastFailure != nil)
        await harness.sender.stop()
    }

    /// Chaque tentative refait un pairing complet : un récepteur occupé ne doit pas être
    /// martelé, et il faut pouvoir dire pourquoi la sortie ne revient pas.
    @Test("Un récepteur occupé à la reconnexion n'entraîne pas de boucle serrée")
    func occupeSansBoucleSerree() async throws {
        let receiver = try await makeReceiver()
        defer { receiver.stop() }
        let busy = LockedFlag()
        receiver.script = { request, _ in
            if busy.value, request.method == "SETUP" { return .status(453, "Not Enough Bandwidth") }
            return .normal
        }
        let harness = try SenderHarness(receiver: receiver)
        defer { harness.feeder.stop() }

        await harness.sender.setKeepAlivePolicy(.init(interval: .milliseconds(100)))
        try await harness.sender.start(volume: -20)
        #expect(await waitUntil { receiver.audioPackets(inSession: 0).count >= 5 })

        busy.set()
        receiver.dropControlConnection(inSession: 0)

        #expect(await waitUntil { await harness.sender.statistics.reconnectionAttempts >= 1 })
        let failure = try #require(await harness.sender.statistics.lastFailure)
        #expect(failure.contains("occupé"))
        #expect(await harness.sender.state == .reconnecting)

        // Le délai suivant est d'au moins 10 s : aucune nouvelle tentative dans ce laps de temps.
        let attempts = receiver.sessionCount
        try await Task.sleep(for: .seconds(3))
        #expect(receiver.sessionCount == attempts)
        await harness.sender.stop()
        #expect(await harness.sender.state == .idle)
    }

    /// Un appairage refusé ne se corrigera pas seul, et insister finit sanctionné.
    @Test("Un appairage refusé à la reconnexion arrête les tentatives")
    func appairageRefuseArrete() async throws {
        let receiver = try await makeReceiver()
        defer { receiver.stop() }
        let refused = LockedFlag()
        receiver.script = { request, _ in
            if refused.value, request.uri == "/pair-setup" {
                return .status(470, "Connection Authorization Required")
            }
            return .normal
        }
        let harness = try SenderHarness(receiver: receiver)
        defer { harness.feeder.stop() }

        await harness.sender.setKeepAlivePolicy(.init(interval: .milliseconds(100)))
        try await harness.sender.start(volume: -20)
        #expect(await waitUntil { receiver.audioPackets(inSession: 0).count >= 5 })

        refused.set()
        receiver.dropControlConnection(inSession: 0)

        #expect(await waitUntil { await harness.sender.state == .failed })
        let failure = try #require(await harness.sender.statistics.lastFailure)
        #expect(failure.contains("appairage"))
        await harness.sender.stop()
    }

    // MARK: - Arrêt et annulation

    /// Le moteur attend ses sorties à l'arrêt : un récepteur muet ne doit jamais le retenir.
    @Test("stop() rend la main même si le récepteur ne répond pas au TEARDOWN")
    func stopNonBloque() async throws {
        let receiver = try await makeReceiver()
        defer { receiver.stop() }
        receiver.script = { request, _ in request.method == "TEARDOWN" ? .silent : .normal }
        let harness = try SenderHarness(receiver: receiver)
        defer { harness.feeder.stop() }

        try await harness.sender.start(volume: -20)

        let start = ContinuousClock.now
        await harness.sender.stop()
        #expect(ContinuousClock.now - start < .seconds(4))
        #expect(await harness.sender.state == .idle)
    }

    /// Le moteur appelle `stop()` depuis une tâche déjà annulée : le TEARDOWN doit partir malgré
    /// tout, et les délais internes ne doivent pas s'en trouver court-circuités.
    @Test("stop() depuis une tâche annulée envoie quand même le TEARDOWN")
    func stopDepuisTacheAnnulee() async throws {
        let receiver = try await makeReceiver()
        defer { receiver.stop() }
        let harness = try SenderHarness(receiver: receiver)
        defer { harness.feeder.stop() }

        try await harness.sender.start(volume: -20)

        let sender = harness.sender
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await sender.stop()
        }
        await task.value

        #expect(await waitUntil(timeout: .seconds(2)) { receiver.count(method: "TEARDOWN") == 1 })
        #expect(await sender.state == .idle)
    }

    /// `stop()` est idempotent, et un sender arrêté redémarre proprement.
    @Test("Un sender arrêté peut repartir")
    func redemarrage() async throws {
        let receiver = try await makeReceiver()
        defer { receiver.stop() }
        let harness = try SenderHarness(receiver: receiver)
        defer { harness.feeder.stop() }

        try await harness.sender.start(volume: -20)
        await harness.sender.stop()
        await harness.sender.stop()
        try await harness.sender.start(volume: -20)

        #expect(await waitUntil { receiver.audioPackets(inSession: 1).count >= 5 })
        #expect(await harness.sender.state == .streaming)
        await harness.sender.stop()
    }

    /// Le cycle de référence du canal de timing retenait son socket : il répondait encore après
    /// l'arrêt, et chaque reconnexion en laissait un de plus derrière elle.
    @Test("Le répondeur d'horloge ne survit pas à l'arrêt")
    func horlogeLibereeALArret() async throws {
        let receiver = try await makeReceiver()
        defer { receiver.stop() }
        let harness = try SenderHarness(receiver: receiver)
        defer { harness.feeder.stop() }

        try await harness.sender.start(volume: -20)
        let port = receiver.timingPort(inSession: 0)
        #expect(try await receiver.probeTiming(port: port, timeout: 1))

        await harness.sender.stop()

        #expect(try await receiver.probeTiming(port: port, timeout: 0.3) == false)
        #expect(await portIsFree(port), "le socket d'horloge n'a pas été rendu au système")
    }

    /// Un socket retenu par un cycle de références garde son port : c'est le seul moyen d'observer
    /// la fuite depuis l'extérieur, faire taire le répondeur ne fermant pas le descripteur.
    private func portIsFree(_ port: UInt16) async -> Bool {
        await waitUntil(timeout: .seconds(2)) {
            (try? UDPChannel(label: "test-port-libre", preferredPort: port)) != nil
        }
    }

    /// Un signal de perte peut arriver en retard, par une tâche en vol. Il ne doit jamais
    /// condamner la session qui a remplacé la sienne.
    @Test("Un signal de perte d'une session précédente est ignoré")
    func signalEnRetard() async throws {
        let receiver = try await makeReceiver()
        defer { receiver.stop() }
        let harness = try SenderHarness(receiver: receiver)
        defer { harness.feeder.stop() }

        await harness.sender.setKeepAlivePolicy(.init(interval: .milliseconds(100)))
        try await harness.sender.start(volume: -20)
        receiver.dropControlConnection(inSession: 0)
        #expect(await waitUntil { receiver.audioPackets(inSession: 1).count >= 5 })

        // La première session portait le numéro 1, la courante le numéro 2.
        await harness.sender.noteSessionLost(generation: 1, reason: "signal en retard")
        try await Task.sleep(for: .milliseconds(300))
        #expect(await harness.sender.state == .streaming)
        #expect(receiver.sessionCount == 2)

        // Le même signal, à jour, déclenche bien la reconnexion : le test ne passe pas à vide.
        await harness.sender.noteSessionLost(generation: 2, reason: "signal à jour")
        #expect(await waitUntil { receiver.sessionCount >= 3 })
        await harness.sender.stop()
    }

    @Test("Annuler une négociation en cours rend la main aussitôt")
    func annulationPendantNegociation() async throws {
        let receiver = try await makeReceiver()
        defer { receiver.stop() }
        receiver.script = { request, _ in request.method == "SETUP" ? .silent : .normal }
        let harness = try SenderHarness(receiver: receiver)
        defer { harness.feeder.stop() }

        let sender = harness.sender
        let task = Task { try await sender.start(volume: -20) }
        #expect(await waitUntil { receiver.count(method: "SETUP") >= 1 })

        let start = ContinuousClock.now
        task.cancel()
        let result = await task.result
        #expect(ContinuousClock.now - start < .seconds(2))
        #expect(throws: CancellationError.self) { try result.get() }
        #expect(await sender.state == .idle)
    }

    @Test("stop() pendant une négociation l'interrompt, et laisse le sender à l'arrêt")
    func stopPendantNegociation() async throws {
        let receiver = try await makeReceiver()
        defer { receiver.stop() }
        receiver.script = { request, _ in request.method == "SETUP" ? .silent : .normal }
        let harness = try SenderHarness(receiver: receiver)
        defer { harness.feeder.stop() }

        let sender = harness.sender
        let task = Task { try await sender.start(volume: -20) }
        #expect(await waitUntil { receiver.count(method: "SETUP") >= 1 })

        let start = ContinuousClock.now
        await sender.stop()
        let result = await task.result
        #expect(ContinuousClock.now - start < .seconds(2))
        #expect(throws: CancellationError.self) { try result.get() }
        #expect(await sender.state == .idle)
    }

    // MARK: - Relecture de l'adresse

    /// Un sender branché sur `receiver`, qui relit son adresse à chaque échec de reconnexion.
    private func senderWithLookup(
        receiver: FakeAirPlay2Receiver,
        lookup: @escaping @Sendable () async -> AirPlay2Device?
    ) throws -> (sender: AirPlay2Sender, feeder: SineFeeder) {
        let ring = AudioRingBuffer(capacityFrames: 48_000, channelCount: 2)
        let feeder = SineFeeder(ring: ring)
        let sender = AirPlay2Sender(
            device: receiver.device(), ring: ring, captureFormat: try SenderHarness.captureFormat(),
            rediscover: lookup, rediscoveryInterval: 1
        )
        feeder.start()
        return (sender, feeder)
    }

    /// Un récepteur redémarré qui revient ailleurs : sans relecture, le sender l'appelle à l'ancienne
    /// adresse jusqu'à l'arrêt de la diffusion.
    @Test("Après un échec de reconnexion, l'adresse est relue et suivie")
    func adresseRelue() async throws {
        let first = try await makeReceiver()
        defer { first.stop() }
        let second = try await makeReceiver()
        defer { second.stop() }
        let moved = second.device()
        let (sender, feeder) = try senderWithLookup(receiver: first) { moved }
        defer { feeder.stop() }

        try await sender.start(volume: -20)
        #expect(await waitUntil { first.audioPackets(inSession: 0).count >= 5 })

        first.stop()

        #expect(await waitUntil(timeout: .seconds(15)) { second.audioPackets(inSession: 0).count >= 5 })
        #expect(await sender.state == .streaming)
        await sender.stop()
    }

    /// Bonjour peut rendre à un second HomePod le nom libéré par le premier.
    @Test("Un service de même nom, mais d'un autre appareil, n'est pas suivi")
    func autreAppareilNonSuivi() async throws {
        let first = try await makeReceiver()
        defer { first.stop() }
        let other = try await makeReceiver()
        defer { other.stop() }
        let impostor = AirPlay2Device(
            serviceName: "Récepteur simulé", host: "127.0.0.1", port: other.port,
            txt: ["features": "0x405f4200,0x1c300", "deviceid": "11:22:33:44:55:66"]
        )
        let lookups = LockedCounter()
        let (sender, feeder) = try senderWithLookup(receiver: first) {
            lookups.increment()
            return impostor
        }
        defer { feeder.stop() }

        try await sender.start(volume: -20)
        #expect(await waitUntil { first.audioPackets(inSession: 0).count >= 5 })

        first.stop()

        #expect(await waitUntil(timeout: .seconds(15)) { lookups.value >= 2 })
        #expect(other.sessionCount == 0)
        #expect(await sender.state == .reconnecting)
        await sender.stop()
    }

    // MARK: - Messages d'erreur

    private func startFailure(
        script: @escaping @Sendable (FakeAirPlay2Receiver.Request, Int) -> FakeAirPlay2Receiver.Action
    ) async throws -> AirPlay2SenderError {
        let receiver = try await makeReceiver()
        defer { receiver.stop() }
        receiver.script = script
        let harness = try SenderHarness(receiver: receiver)
        defer { harness.feeder.stop() }
        do {
            try await harness.sender.start(volume: -20)
            await harness.sender.stop()
            throw CancellationError()
        } catch let error as AirPlay2SenderError {
            #expect(await harness.sender.state == .failed)
            #expect(await harness.sender.statistics.lastFailure == error.description)
            return error
        }
    }

    @Test("470 : appairage requis, avec la marche à suivre")
    func erreur470() async throws {
        let error = try await startFailure { request, _ in
            request.uri == "/pair-setup" ? .status(470, "Connection Authorization Required") : .normal
        }
        #expect(error == .pairingRequired(receiver: "Récepteur simulé", status: 470))
        #expect(error.isPermanent)
        #expect(error.description.contains("atvremote"))
        #expect(error.description.contains("--credentials2"))
    }

    @Test("401, et 403 au pairing : même marche à suivre")
    func erreur401() async throws {
        let unauthorized = try await startFailure { request, _ in
            request.method == "SETUP" ? .status(401, "Unauthorized") : .normal
        }
        #expect(unauthorized == .pairingRequired(receiver: "Récepteur simulé", status: 401))

        let forbidden = try await startFailure { request, _ in
            request.uri == "/pair-setup" ? .status(403, "Forbidden") : .normal
        }
        #expect(forbidden == .pairingRequired(receiver: "Récepteur simulé", status: 403))
        #expect(forbidden.isPermanent)
        #expect(forbidden.description.contains("atvremote"))
    }

    /// Le symptôme relevé sur les HomePod : un `403` au volume, présenté comme un appairage à faire
    /// avec atvremote, et la sortie abandonnée pour de bon. L'appairage avait pourtant abouti.
    @Test("403 sur le volume ou le RECORD : accès refusé à cette requête, pas un appairage")
    func erreur403EnSession() async throws {
        for step in ["SET_PARAMETER", "RECORD", "SETUP"] {
            let error = try await startFailure { request, _ in
                request.method == step ? .status(403, "Forbidden") : .normal
            }
            #expect(
                error == .requestForbidden(receiver: "Récepteur simulé", step: step, reason: "Forbidden"))
            #expect(!error.isPermanent, "\(step)")
            #expect(!isPermanentOutputFailure(error), "\(step)")
            #expect(error.minimumRetryDelay >= .seconds(10))
            #expect(error.description.contains(step))
            #expect(error.description.contains("403"))
            #expect(error.description.contains("refusé l'accès"))
            #expect(!error.description.contains("atvremote"))
            #expect(!error.description.contains("--credentials2"))
        }
    }

    /// Avec des credentials, un refus au `pair-verify` reste un refus de credentials, et un `403` en
    /// session reste un accès refusé : l'appairage, lui, a abouti.
    @Test("Avec des credentials, le 403 se classe de même")
    func erreur403AvecCredentials() {
        func failure(_ error: Error) -> AirPlay2SenderError {
            AirPlay2SenderError(classifying: error, receiver: "R", address: "a", hasCredentials: true)
        }
        let verify = failure(AirPlay2PairingSession.Failure.authorizationRequired(status: 403, step: "verify-M1"))
        #expect(verify == .credentialsRejected(receiver: "R", detail: "réponse 403"))
        #expect(verify.isPermanent)
        let session = failure(RTSPError.unexpectedStatus(method: "RECORD", code: 403, reason: ""))
        #expect(session == .requestForbidden(receiver: "R", step: "RECORD", reason: ""))
        #expect(!session.isPermanent)
    }

    @Test("453 : occupé, et un délai d'attente d'au moins dix secondes")
    func erreur453() async throws {
        let error = try await startFailure { request, _ in
            request.method == "SETUP" ? .status(453, "Not Enough Bandwidth") : .normal
        }
        #expect(error == .receiverBusy(receiver: "Récepteur simulé"))
        #expect(error.description.contains("occupé"))
        #expect(error.minimumRetryDelay >= .seconds(10))
    }

    @Test("400 et 500 sont nommés avec l'étape qui a échoué")
    func erreurs400Et500() async throws {
        let rejected = try await startFailure { request, _ in
            request.method == "RECORD" ? .status(400, "Bad Request") : .normal
        }
        #expect(
            rejected
                == .requestRejected(
                    receiver: "Récepteur simulé", step: "RECORD", status: 400, reason: "Bad Request"))
        #expect(rejected.description.contains("RECORD"))

        let failed = try await startFailure { request, _ in
            request.method == "SETUP" ? .status(500, "Internal Server Error") : .normal
        }
        #expect(failed == .receiverFailed(receiver: "Récepteur simulé", step: "SETUP", status: 500))
        #expect(failed.description.contains("erreur interne"))
    }

    /// Un port fermé rend la main tout de suite, avec le bon diagnostic : auparavant, dix
    /// secondes d'attente pour finir sur « délai d'établissement dépassé ».
    @Test("Une connexion refusée échoue vite et le dit")
    func connexionRefusee() async throws {
        // Un port qu'on vient de libérer : rien n'y écoute plus.
        let closed = try await makeReceiver()
        let port = closed.port
        closed.stop()
        try await Task.sleep(for: .milliseconds(100))

        let sender = AirPlay2Sender(
            device: AirPlay2Device(
                serviceName: "Récepteur simulé", host: "127.0.0.1", port: port, txt: [:]),
            ring: AudioRingBuffer(capacityFrames: 1_024, channelCount: 2),
            captureFormat: try SenderHarness.captureFormat()
        )

        let start = ContinuousClock.now
        await #expect(
            throws: AirPlay2SenderError.connectionRefused(
                receiver: "Récepteur simulé", address: "127.0.0.1:\(port)")
        ) {
            try await sender.start(volume: -20)
        }
        #expect(ContinuousClock.now - start < .seconds(3))
    }

    /// Un TXT illisible ne vaut pas un refus : le récepteur tranche lui-même.
    @Test("Un TXT vide n'empêche pas de tenter le transitoire")
    func txtVide() async throws {
        let receiver = try await makeReceiver()
        defer { receiver.stop() }
        let ring = AudioRingBuffer(capacityFrames: 48_000, channelCount: 2)
        let feeder = SineFeeder(ring: ring)
        feeder.start()
        defer { feeder.stop() }
        let sender = AirPlay2Sender(
            device: AirPlay2Device(
                serviceName: "Sans TXT", host: "127.0.0.1", port: receiver.port, txt: [:]),
            ring: ring,
            captureFormat: try SenderHarness.captureFormat()
        )

        try await sender.start(volume: -20)
        #expect(await sender.state == .streaming)
        await sender.stop()
    }

    @Test("Un récepteur qui annonce autre chose que le transitoire n'est pas sollicité")
    func transitoireNonAnnonce() async throws {
        let receiver = try await makeReceiver()
        defer { receiver.stop() }
        let sender = AirPlay2Sender(
            device: AirPlay2Device(
                serviceName: "Apple TV", host: "127.0.0.1", port: receiver.port,
                txt: ["features": "0x445F8A00,0x800"]),
            ring: AudioRingBuffer(capacityFrames: 1_024, channelCount: 2),
            captureFormat: try SenderHarness.captureFormat()
        )

        await #expect(throws: AirPlay2SenderError.pairingRequired(receiver: "Apple TV", status: nil)) {
            try await sender.start(volume: -20)
        }
        #expect(receiver.requests().isEmpty)
    }

    /// Le moteur abandonne sur un échec permanent et réessaie sur les autres : ce partage doit
    /// rester celui de `isPermanentOutputFailure`, faute de quoi un Apple TV serait relancé sans
    /// fin, ou une enceinte occupée abandonnée à la première réponse.
    @Test("Le partage entre échecs permanents et passagers est celui du moteur")
    func permanence() {
        func failure(_ error: Error, credentials: Bool = false) -> AirPlay2SenderError {
            AirPlay2SenderError(
                classifying: error, receiver: "R", address: "a", hasCredentials: credentials)
        }
        func status(_ code: Int) -> RTSPError {
            .unexpectedStatus(method: "SETUP", code: code, reason: "")
        }
        func rejected(_ reason: PairingTLV8.PairingError) -> AirPlay2PairingSession.Failure {
            .receiverRejected(reason, step: "M1")
        }

        for code in [401, 470] {
            #expect(failure(status(code)).isPermanent)
            #expect(failure(status(code), credentials: true).isPermanent)
        }
        for code in [401, 403, 470] {
            let pairing = AirPlay2PairingSession.Failure.authorizationRequired(status: code, step: "M1")
            #expect(failure(pairing).isPermanent, "\(code)")
            #expect(failure(pairing, credentials: true).isPermanent, "\(code)")
        }
        // Un 403 sur une requête de session : l'appairage a abouti, ce n'est pas lui qui est refusé.
        #expect(!failure(status(403)).isPermanent)
        #expect(!failure(status(403), credentials: true).isPermanent)
        #expect(failure(AirPlay2PairingSession.Failure.transientPairingUnsupported(features: 0)).isPermanent)
        #expect(failure(AirPlay2PairingSession.Failure.receiverIdentityMismatch).isPermanent)
        #expect(failure(AirPlay2PairingSession.Failure.receiverSignatureInvalid).isPermanent)
        for reason in [PairingTLV8.PairingError.authentication, .maxPeers, .unavailable] {
            #expect(failure(rejected(reason)).isPermanent, "\(reason)")
        }

        for code in [400, 404, 453, 500, 503] {
            #expect(!failure(status(code)).isPermanent, "\(code)")
        }
        for reason in [PairingTLV8.PairingError.unknown, .backoff, .maxTries, .busy] {
            #expect(!failure(rejected(reason)).isPermanent, "\(reason)")
        }
        #expect(!failure(AirPlay2PairingSession.Failure.malformedResponse(step: "M2")).isPermanent)
        #expect(!failure(AirPlay2PairingSession.Failure.unexpectedState(step: "M2")).isPermanent)
        #expect(!failure(RTSPError.timedOut(method: "SETUP")).isPermanent)
        #expect(!failure(RTSPError.connectionFailed("x")).isPermanent)
    }

    // MARK: - Erreurs d'émission

    /// Un accroc d'émission est une perte ordinaire : le paquet reste réclamable, et quelques
    /// erreurs ne valent pas une reconnexion. Provoqué par un port de données nul, sur lequel
    /// `sendto` échoue à chaque paquet.
    @Test("Un paquet raté reste réclamable, et l'accroc ne coupe pas la session")
    func erreurDEmission() async throws {
        var options = FakeAirPlay2Receiver.Options()
        options.announcedDataPort = 0
        let receiver = try await makeReceiver(options: options)
        defer { receiver.stop() }
        let harness = try SenderHarness(receiver: receiver)
        defer { harness.feeder.stop() }

        try await harness.sender.start(volume: -20)
        #expect(await waitUntil { await harness.sender.statistics.errors >= 50 })

        // Bien au-delà de l'ancien seuil de 20 erreurs : toujours la même session.
        #expect(receiver.sessionCount == 1)
        #expect(await harness.sender.state == .streaming)

        // Le premier paquet n'est jamais parti, et son numéro est celui annoncé au `RECORD`.
        let record = try #require(receiver.requests().first { $0.method == "RECORD" })
        let rtpInfo = try #require(record.headers["rtp-info"])
        let sequence = try #require(
            rtpInfo.split(separator: ";").first?.split(separator: "=").last.flatMap { UInt16($0) })
        receiver.requestRetransmission(first: sequence, count: 1, inSession: 0)
        #expect(await waitUntil { receiver.resendPackets(inSession: 0).count == 1 })
        let resent = try #require(receiver.resendPackets(inSession: 0).first)
        _ = try FakeAirPlay2Receiver.decryptAudio(
            Data(resent.dropFirst(4)), key: receiver.streamKey(inSession: 0))

        // Les compteurs ont avancé malgré les échecs : le suivant porte le numéro d'après, et
        // l'horodatage de 352 trames de plus, sans quoi le flux se décalerait de 8 ms par paquet.
        receiver.requestRetransmission(first: sequence &+ 1, count: 1, inSession: 0)
        #expect(await waitUntil { receiver.resendPackets(inSession: 0).count == 2 })
        let packets = receiver.resendPackets(inSession: 0).map { [UInt8]($0.dropFirst(4)) }
        func timestamp(_ packet: [UInt8]) -> UInt32 {
            packet[4...7].reduce(0) { $0 << 8 | UInt32($1) }
        }
        #expect(timestamp(packets[1]) == timestamp(packets[0]) &+ 352)
        // Et aucun nonce n'a été réutilisé, ce qui casserait l'AEAD.
        #expect(packets[0].suffix(8) != packets[1].suffix(8))

        // Au-delà de ~2 s d'échecs ininterrompus, la session est réputée perdue.
        #expect(await waitUntil { receiver.sessionCount >= 2 })
        await harness.sender.stop()
    }

    // MARK: - Latence annoncée

    /// « Les HomePod n'annoncent rien » n'était pas établi : la réponse du `RECORD` était jetée.
    @Test("L'Audio-Latency du RECORD est relevée, sans entrer dans le calage")
    func latenceAnnonceeRelevee() async throws {
        let receiver = try await makeReceiver(options: .init(announcedAudioLatency: 11_025))
        defer { receiver.stop() }
        let harness = try SenderHarness(receiver: receiver)
        defer { harness.feeder.stop() }

        try await harness.sender.start(volume: -20)

        #expect(await harness.sender.statistics.reportedLatencyFrames == 11_025)
        #expect(await harness.sender.currentOutputStatistics().reportedLatencyFrames == 11_025)
        // Le calage reste celui d'avant : aucun changement sans écoute.
        #expect(harness.sender.synchronizer.declaredReceiverLatencyFrames == 0)
        await harness.sender.stop()
    }

    @Test("Un récepteur qui n'annonce aucune latence n'en a pas d'inventée")
    func latenceNonAnnoncee() async throws {
        let receiver = try await makeReceiver()
        defer { receiver.stop() }
        let harness = try SenderHarness(receiver: receiver)
        defer { harness.feeder.stop() }

        try await harness.sender.start(volume: -20)

        #expect(await harness.sender.statistics.reportedLatencyFrames == nil)
        #expect(await harness.sender.currentOutputStatistics().reportedLatencyFrames == nil)
        await harness.sender.stop()
    }

    // MARK: - Volume

    @Test("La plage envoyée reste celle du protocole")
    func plageDeVolume() {
        #expect(AirPlay2Session.wireVolume(-20) == -20)
        #expect(AirPlay2Session.wireVolume(0) == 0)
        #expect(AirPlay2Session.wireVolume(-30) == -30)
        #expect(AirPlay2Session.wireVolume(-144) == -144)
        // Sous -30 : coupé, comme chez pyatv, plutôt que relevé à -30.
        #expect(AirPlay2Session.wireVolume(-35) == -144)
        #expect(AirPlay2Session.wireVolume(6) == 0)
        #expect(AirPlay2Session.wireVolume(.infinity) == 0)
        #expect(AirPlay2Session.wireVolume(-.infinity) == -144)
        #expect(AirPlay2Session.wireVolume(.nan) == -144)
        // Pas de notation scientifique sur le fil.
        #expect("\(AirPlay2Session.wireVolume(-0.00001))" == "0.0")
    }

    /// Le silence part tel quel, et le corps garde la forme attendue.
    @Test("Le silence part à -144")
    func silence() async throws {
        let receiver = try await makeReceiver()
        defer { receiver.stop() }
        let harness = try SenderHarness(receiver: receiver)
        defer { harness.feeder.stop() }

        try await harness.sender.start(volume: -144)
        try await harness.sender.setVolume(-35)
        await harness.sender.stop()

        #expect(receiver.volumes(inSession: 0) == ["volume: -144.0\r\n", "volume: -144.0\r\n"])
    }

    // MARK: - Canal d'événements

    /// Le récepteur pose ses requêtes chiffrées, coupées arbitrairement par TCP, et attend une
    /// réponse. pyatv répond `200` à chacune, on fait de même.
    @Test("Une requête du récepteur est déchiffrée et acquittée, même coupée en deux")
    func evenementAcquitte() async throws {
        let receiver = try await makeReceiver()
        defer { receiver.stop() }
        let harness = try SenderHarness(receiver: receiver)
        defer { harness.feeder.stop() }

        try await harness.sender.start(volume: -20)
        #expect(await waitUntil { receiver.eventChannelIsOpen(inSession: 0) })

        let sealed = try receiver.sealEvent(
            Data("POST /command RTSP/1.0\r\nCSeq: 7\r\nServer: AirTunes/700\r\nContent-Length: 0\r\n\r\n".utf8),
            inSession: 0)
        try #require(!sealed.isEmpty)
        receiver.sendRawEvent(sealed.prefix(9), inSession: 0)
        try await Task.sleep(for: .milliseconds(50))
        receiver.sendRawEvent(sealed.dropFirst(9), inSession: 0)

        #expect(await waitUntil { !receiver.eventPlaintext(inSession: 0).isEmpty })
        let reply = String(decoding: receiver.eventPlaintext(inSession: 0), as: UTF8.self)
        #expect(reply.hasPrefix("RTSP/1.0 200 OK\r\n"))
        #expect(reply.contains("CSeq: 7\r\n"))
        #expect(reply.contains("Server: AirTunes/700\r\n"))
        #expect(reply.contains("Audio-Latency: 0\r\n"))
        #expect(reply.contains("Content-Length: 0\r\n"))

        #expect(await waitUntil { await harness.sender.statistics.eventMessages == 1 })
        #expect(await harness.sender.state == .streaming)
        await harness.sender.stop()
    }

    /// Un contenu indéchiffrable arrête le décodage, pas la session : ce canal reste un
    /// observateur, et sa connexion garde son rôle de signal de vie.
    @Test("Un contenu indéchiffrable ne fait pas tomber la session")
    func evenementIndechiffrable() async throws {
        let receiver = try await makeReceiver()
        defer { receiver.stop() }
        let harness = try SenderHarness(receiver: receiver)
        defer { harness.feeder.stop() }

        try await harness.sender.start(volume: -20)
        #expect(await waitUntil { receiver.eventChannelIsOpen(inSession: 0) })

        // Un bloc de 8 octets annoncés, tous faux.
        receiver.sendRawEvent(Data([8, 0]) + Data(repeating: 0xAB, count: 24), inSession: 0)
        try await Task.sleep(for: .milliseconds(300))

        #expect(await harness.sender.state == .streaming)
        #expect(receiver.sessionCount == 1)
        #expect(await harness.sender.statistics.eventMessages == 0)

        // Et la perte reste détectée.
        receiver.dropEventChannel(inSession: 0)
        #expect(await waitUntil { receiver.sessionCount >= 2 })
        await harness.sender.stop()
    }

    /// Sans canal d'événements, on diffuse quand même : c'est un observateur.
    @Test("Un récepteur sans canal d'événements reste utilisable")
    func sansCanalEvenements() async throws {
        var options = FakeAirPlay2Receiver.Options()
        options.eventChannelEnabled = false
        let receiver = try await makeReceiver(options: options)
        defer { receiver.stop() }
        let harness = try SenderHarness(receiver: receiver)
        defer { harness.feeder.stop() }

        try await harness.sender.start(volume: -20)
        #expect(await waitUntil { receiver.audioPackets(inSession: 0).count >= 5 })
        #expect(await harness.sender.statistics.eventChannelConnected == false)
        await harness.sender.stop()
    }
}
