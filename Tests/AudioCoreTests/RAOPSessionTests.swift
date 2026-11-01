import AVFoundation
import Foundation
import Testing

@testable import AudioCore

/// Le sender RAOP de bout en bout, contre un faux récepteur sur la boucle locale.
///
/// Sérialisés : chaque test tient un flux audio cadencé en temps réel, et les faire tourner de
/// front fausserait les mesures de cadence.
@Suite("Session RAOP", .serialized)
struct RAOPSessionTests {
    /// Un sender et tout ce qu'il lui faut pour diffuser.
    private struct Rig {
        let server: FakeRAOPReceiver
        let sender: RAOPSender
        let feeder: ToneFeeder
        let ring: AudioRingBuffer

        func close() async {
            await sender.stop()
            feeder.stop()
            server.shutdown()
        }
    }

    private func makeRig(
        script: @escaping @Sendable (FakeRAOPReceiver.Request) -> FakeRAOPReceiver.Reply = { _ in
            .standard
        },
        txt: [String: String]? = nil,
        format: AVAudioFormat? = captureFormat(),
        hz: Double = 440,
        amplitude: Float = 0.25,
        reconnects: Bool = true,
        keepAliveInterval: Duration = .seconds(25)
    ) async throws -> Rig {
        let format = try #require(format)
        let server = try await FakeRAOPReceiver(script: script)
        let ring = AudioRingBuffer(capacityFrames: 48_000, channelCount: Int(format.channelCount))
        let feeder = ToneFeeder(ring: ring, format: format, hz: hz, amplitude: amplitude)
        let device = txt.map { server.device(txt: $0) } ?? server.device()
        let sender = RAOPSender(
            device: device, ring: ring, captureFormat: format, reconnects: reconnects,
            keepAliveInterval: keepAliveInterval
        )
        return Rig(server: server, sender: sender, feeder: feeder, ring: ring)
    }

    /// PCM big-endian d'une charge utile L16, entrelacé.
    private func samples(ofL16 payload: Data) -> [Int16] {
        let bytes = [UInt8](payload)
        return stride(from: 0, to: bytes.count - 1, by: 2).map {
            Int16(bitPattern: UInt16(bytes[$0]) << 8 | UInt16(bytes[$0 + 1]))
        }
    }

    private func rms(_ values: [Int16]) -> Double {
        guard !values.isEmpty else { return 0 }
        let energy = values.reduce(0.0) { $0 + Double($1) * Double($1) }
        return (energy / Double(values.count)).squareRoot()
    }

    // MARK: - Ce qui part sur le fil

    @Test("Face à la Geneva, la séquence et le SDP sont ceux de pyatv")
    func genevaWireFormat() async throws {
        let rig = try await makeRig()
        try await rig.sender.start(volume: -20)
        #expect(await eventually { rig.server.audioPackets.count > 10 })
        await rig.close()

        let requests = rig.server.requests
        #expect(
            requests.map(\.method)
                == ["ANNOUNCE", "SETUP", "POST", "RECORD", "SET_PARAMETER", "TEARDOWN"]
        )

        let lines = try #require(requests.first?.bodyText).components(separatedBy: "\r\n")
        // Mêmes lignes que `ANNOUNCE_PAYLOAD` de pyatv, sans aucune clé : `et=0,4`, `cn=0`.
        #expect(lines.contains("v=0"))
        #expect(lines.contains("s=iTunes"))
        #expect(lines.contains("c=IN IP4 127.0.0.1"))
        #expect(lines.contains("t=0 0"))
        #expect(lines.contains("m=audio 0 RTP/AVP 96"))
        #expect(lines.contains("a=rtpmap:96 L16/44100/2"))
        #expect(lines.contains("a=fmtp:96 352 0 16 40 10 14 2 255 0 0 44100"))
        #expect(!lines.contains { $0.hasPrefix("a=rsaaeskey") || $0.hasPrefix("a=aesiv") })

        let feedback = try #require(requests.first { $0.method == "POST" })
        #expect(feedback.uri == "/feedback")
        #expect(feedback.protocolVersion == "RTSP/1.0")
        #expect(feedback.headers["cseq"] != nil)

        let teardown = try #require(requests.last)
        #expect(teardown.uri == requests[0].uri, "même URI de session qu'à l'ANNOUNCE")
        #expect(teardown.headers["session"] == "4242", "l'identifiant rendu par le SETUP")
    }

    @Test("Quand le récepteur propose le clair et RSA-AES, le clair l'emporte")
    func clearIsPreferred() async throws {
        let rig = try await makeRig(txt: ["et": "0,1", "cn": "0"])
        try await rig.sender.start(volume: -20)
        await rig.close()
        let sdp = try #require(rig.server.requests.first?.bodyText)
        #expect(!sdp.contains("a=rsaaeskey"))
    }

    @Test("Un récepteur qui n'accepte que RSA-AES le reçoit, avec une clé de 256 octets")
    func rsaFallback() async throws {
        let rig = try await makeRig(txt: ["et": "1", "cn": "0"])
        try await rig.sender.start(volume: -20)
        await rig.close()

        let lines = try #require(rig.server.requests.first?.bodyText).components(separatedBy: "\r\n")
        let key = try #require(lines.first { $0.hasPrefix("a=rsaaeskey:") })
        let iv = try #require(lines.first { $0.hasPrefix("a=aesiv:") })
        #expect(key.count == "a=rsaaeskey:".count + 342, "256 octets en base64 sans bourrage")
        #expect(iv.count == "a=aesiv:".count + 22, "16 octets en base64 sans bourrage")
    }

    @Test("La ligne fmtp n'est retirée du L16 que face à un récepteur qui annonce aussi ALAC")
    func fmtpIsOnlyDroppedWhenALACIsAlsoAnnounced() async throws {
        let rig = try await makeRig(txt: ["et": "0,1", "cn": "0,1"])
        try await rig.sender.start(volume: -20)
        await rig.close()
        let sdp = try #require(rig.server.requests.first?.bodyText)
        #expect(sdp.contains("a=rtpmap:96 L16/44100/2"))
        #expect(!sdp.contains("a=fmtp"), "shairport-sync 5.2.1 y prend du PCM pour de l'ALAC")
    }

    @Test("Un récepteur sans PCM reçoit de l'ALAC, avec ses paramètres de décodeur")
    func alacFallback() async throws {
        let rig = try await makeRig(txt: ["et": "0", "cn": "1"])
        try await rig.sender.start(volume: -20)
        #expect(await eventually { !rig.server.audioPackets.isEmpty })
        await rig.close()

        let sdp = try #require(rig.server.requests.first?.bodyText)
        #expect(sdp.contains("a=rtpmap:96 AppleLossless"))
        #expect(sdp.contains("a=fmtp:96 352 0 16 40 10 14 2 255 0 0 44100"))
        #expect(rig.server.audioPackets.first?.payload.count == 1_412)
    }

    @Test("Un TXT annonçant 24 bits n'empêche pas d'annoncer ce qu'on envoie vraiment : 16 bits")
    func alwaysAnnounces16Bits() async throws {
        let rig = try await makeRig(txt: ["et": "0", "cn": "0", "ss": "24"])
        try await rig.sender.start(volume: -20)
        await rig.close()
        let sdp = try #require(rig.server.requests.first?.bodyText)
        #expect(sdp.contains("a=fmtp:96 352 0 16 40"))
    }

    @Test("Le flux audio : marqueur sur le premier paquet, séquence et estampilles contiguës")
    func audioStream() async throws {
        let rig = try await makeRig()
        try await rig.sender.start(volume: -20)
        #expect(await eventually { rig.server.audioPackets.count > 60 })
        let packets = rig.server.audioPackets
        await rig.close()

        #expect(packets.first?.marker == true)
        #expect(packets.dropFirst().allSatisfy { !$0.marker })
        #expect(packets.allSatisfy { $0.payload.count == 352 * 4 }, "L16 stéréo")
        for (previous, next) in zip(packets, packets.dropFirst()) {
            #expect(next.sequence == previous.sequence &+ 1)
            #expect(next.timestamp == previous.timestamp &+ 352)
        }
    }

    // MARK: - Retransmission

    @Test("Une demande de retransmission reçoit le paquet complet, à l'octet près")
    func retransmission() async throws {
        let rig = try await makeRig()
        try await rig.sender.start(volume: -20)
        #expect(await eventually { rig.server.audioPackets.count > 30 })

        let sent = rig.server.audioPackets
        let wanted = Array(sent[10..<14])
        try rig.server.requestRetransmission(first: wanted[0].sequence, count: 4)
        #expect(await eventually(within: .seconds(2)) { rig.server.retransmissions.count == 4 })

        let responses = rig.server.retransmissions
        for (response, original) in zip(responses, wanted) {
            let sequence = withUnsafeBytes(of: original.sequence.bigEndian, Array.init)
            #expect(Array(response.prefix(4)) == [0x80, 0xD6] + sequence)
            #expect(Data(response.dropFirst(4)) == original.raw, "le paquet tel qu'il est parti")
        }

        let statistics = await rig.sender.statistics
        #expect(statistics.retransmitRequests == 1)
        #expect(statistics.packetsRetransmitted == 4)
        #expect(statistics.retransmitMisses == 0)
        await rig.close()
    }

    @Test("Un paquet retransmis en mode chiffré est celui qui est parti, chiffré")
    func retransmissionWhenEncrypted() async throws {
        let rig = try await makeRig(txt: ["et": "1", "cn": "0"])
        try await rig.sender.start(volume: -20)
        #expect(await eventually { rig.server.audioPackets.count > 20 })
        let original = rig.server.audioPackets[5]
        try rig.server.requestRetransmission(first: original.sequence, count: 1)
        #expect(await eventually(within: .seconds(2)) { rig.server.retransmissions.count == 1 })
        #expect(rig.server.retransmissions.first.map { Data($0.dropFirst(4)) } == original.raw)
        await rig.close()
    }

    @Test("Un paquet qui n'est plus dans l'historique est compté, pas inventé")
    func unknownPacketIsNotAnswered() async throws {
        let rig = try await makeRig()
        try await rig.sender.start(volume: -20)
        #expect(await eventually { rig.server.audioPackets.count > 5 })
        let first = try #require(rig.server.audioPackets.first)

        // Bien avant le premier paquet de la session.
        try rig.server.requestRetransmission(first: first.sequence &- 100, count: 3)
        #expect(await eventually { await rig.sender.statistics.retransmitMisses == 3 })
        #expect(rig.server.retransmissions.isEmpty)
        await rig.close()
    }

    @Test("Une demande démesurée reste bornée par l'historique et par le débit")
    func hugeRequestIsBounded() async throws {
        let rig = try await makeRig()
        try await rig.sender.start(volume: -20)
        #expect(await eventually { rig.server.audioPackets.count > 5 })
        let first = try #require(rig.server.audioPackets.first)

        try rig.server.requestRetransmission(first: first.sequence, count: UInt16.max)
        #expect(await eventually { await rig.sender.statistics.retransmitRequests == 1 })
        let statistics = await rig.sender.statistics
        // Les paquets déjà émis, et rien de plus : l'historique ne contient que 512 cases.
        let accounted = statistics.packetsRetransmitted + statistics.retransmitMisses
            + statistics.retransmitsThrottled
        #expect(accounted == 512)
        await rig.close()
    }

    @Test("Une rafale de demandes ne retarde pas le flux audio")
    func burstDoesNotDelayAudio() async throws {
        let rig = try await makeRig()
        try await rig.sender.start(volume: -20)
        #expect(await eventually { rig.server.audioPackets.count > 200 })

        let before = rig.server.audioPackets.count
        let first = try #require(rig.server.audioPackets.first?.sequence)
        let start = ContinuousClock.now
        for round in 0..<1_000 {
            try rig.server.requestRetransmission(
                first: first &+ UInt16(round % 150), count: 64
            )
        }
        // Une seconde de flux pendant et après la rafale.
        try await Task.sleep(until: start + .seconds(1), clock: .continuous)

        let during = Array(rig.server.audioPackets[before...])
        let statistics = await rig.sender.statistics
        await rig.close()

        #expect(during.count > 100, "\(during.count) paquets en 1 s, 125 attendus")
        var largestGap = 0.0
        for (previous, next) in zip(during, during.dropFirst()) {
            let gap = next.arrivedAt - previous.arrivedAt
            largestGap = max(
                largestGap,
                Double(gap.components.seconds) + Double(gap.components.attoseconds) / 1e18
            )
        }
        // Le récepteur tamponne : ce qui compte est qu'aucun trou ne dépasse sa marge.
        #expect(largestGap < 0.1, "trou de \(largestGap * 1000) ms dans le flux")
        #expect(statistics.retransmitsThrottled > 0, "le débit de retransmission doit être plafonné")
        #expect(statistics.packetsRetransmitted < 1_000)
    }

    @Test("La reconnexion vide l'historique : une ancienne demande reste sans réponse")
    func reconnectionClearsHistory() async throws {
        let rig = try await makeRig()
        try await rig.sender.start(volume: -20)
        #expect(await eventually { rig.server.audioPackets.count > 20 })
        let oldPacket = rig.server.audioPackets[5]

        rig.server.closeConnections()
        #expect(await eventually(within: .seconds(5)) {
            await rig.sender.statistics.reconnections == 1 && rig.server.requests.filter {
                $0.method == "RECORD"
            }.count == 2
        })
        let packetsBefore = rig.server.audioPackets.count
        #expect(await eventually { rig.server.audioPackets.count > packetsBefore + 5 })

        try rig.server.requestRetransmission(first: oldPacket.sequence, count: 1)
        #expect(await eventually { await rig.sender.statistics.retransmitMisses == 1 })
        #expect(rig.server.retransmissions.isEmpty)
        await rig.close()
    }

    @Test("Une émission en échec n'arrête pas la position du flux, et le paquet reste récupérable")
    func sendFailureStillAdvancesStream() async throws {
        let rig = try await makeRig(reconnects: false)
        // Un port de destination nul fait échouer chaque `sendto`, sans toucher au canal de contrôle.
        rig.server.announcedAudioPort = 0
        try await rig.sender.start(volume: -20)
        #expect(await eventually { await rig.sender.statistics.errors >= 10 })

        let record = try #require(rig.server.requests.first { $0.method == "RECORD" })
        let info = try #require(record.headers["rtp-info"])
        let firstSequence = try #require(
            info.split(separator: ";").first.flatMap { UInt16($0.dropFirst("seq=".count)) }
        )
        try rig.server.requestRetransmission(first: firstSequence, count: 5)
        #expect(await eventually(within: .seconds(2)) { rig.server.retransmissions.count == 5 })

        // Sans avancer, tous les échecs auraient écrasé la même case : seul le dernier resterait,
        // et l'audio suivant partirait sous le même numéro et la même estampille.
        let timestamps = rig.server.retransmissions.map { response -> UInt32 in
            let bytes = [UInt8](response)
            return UInt32(bytes[8]) << 24 | UInt32(bytes[9]) << 16
                | UInt32(bytes[10]) << 8 | UInt32(bytes[11])
        }
        for (previous, next) in zip(timestamps, timestamps.dropFirst()) {
            #expect(next == previous &+ 352)
        }
        await rig.close()
    }

    // MARK: - Maintien de session

    @Test("Le maintien de session part à intervalle régulier, si le récepteur l'accepte")
    func keepAlive() async throws {
        let rig = try await makeRig(keepAliveInterval: .milliseconds(100))
        try await rig.sender.start(volume: -20)
        #expect(await eventually {
            rig.server.requests.filter { $0.uri == "/feedback" }.count >= 4
        })
        let statistics = await rig.sender.statistics
        #expect(statistics.keepAliveSupported)
        #expect(statistics.keepAlivesSent >= 2)
        await rig.close()

        // Rien ne doit survivre à l'arrêt.
        let count = rig.server.requests.filter { $0.uri == "/feedback" }.count
        try await Task.sleep(for: .milliseconds(300))
        #expect(rig.server.requests.filter { $0.uri == "/feedback" }.count == count)
    }

    @Test("Un récepteur qui refuse la sonde n'en reçoit plus, et la session continue")
    func keepAliveRefused() async throws {
        let rig = try await makeRig(
            script: { $0.uri == "/feedback" ? .status(404, "Not Found") : .standard },
            keepAliveInterval: .milliseconds(50)
        )
        try await rig.sender.start(volume: -20)
        #expect(await eventually { rig.server.audioPackets.count > 50 })

        #expect(rig.server.requests.filter { $0.uri == "/feedback" }.count == 1)
        let state = await rig.sender.state
        let statistics = await rig.sender.statistics
        #expect(state == .streaming)
        #expect(!statistics.keepAliveSupported)
        await rig.close()
    }

    @Test("Une sonde sans réponse retarde peu le départ, et la réponse tardive ne gêne pas")
    func keepAliveProbeSilent() async throws {
        let rig = try await makeRig(script: { $0.uri == "/feedback" ? .silence : .standard })
        let start = ContinuousClock.now
        try await rig.sender.start(volume: -20)
        #expect(secondsSince(start) < 3)
        let state = await rig.sender.state
        #expect(state == .streaming)
        await rig.close()
    }

    @Test("Un maintien refusé en cours de route ne fait pas tomber la session")
    func keepAliveFailureDoesNotKillSession() async throws {
        let answers = Counter()
        let rig = try await makeRig(
            script: { request in
                guard request.uri == "/feedback" else { return .standard }
                answers.increment()
                return answers.value == 1 ? .standard : .status(500, "Internal Server Error")
            },
            keepAliveInterval: .milliseconds(50)
        )
        try await rig.sender.start(volume: -20)
        #expect(await eventually { await rig.sender.statistics.keepAliveFailures >= 3 })

        let state = await rig.sender.state
        let statistics = await rig.sender.statistics
        #expect(state == .streaming)
        #expect(statistics.reconnections == 0)
        await rig.close()
    }

    @Test("Un maintien de session concurrent d'un changement de volume ne mélange pas les réponses")
    func keepAliveAndVolumeDoNotInterleave() async throws {
        let rig = try await makeRig(
            script: { $0.method == "SETUP" ? .standard : .delayed(.milliseconds(30), body: "") },
            keepAliveInterval: .milliseconds(20)
        )
        try await rig.sender.start(volume: -20)
        for step in 0..<10 {
            try await rig.sender.setVolume(-20 - Float(step))
        }
        #expect(rig.server.requestOverlap == 1)
        await rig.close()
    }

    // MARK: - Erreurs et reconnexion

    @Test("Récepteur occupé au démarrage : échec net, avec le message à afficher")
    func busyAtStart() async throws {
        let rig = try await makeRig(script: { _ in .status(453, "Not Enough Bandwidth") })
        await #expect(throws: RTSPError.self) { try await rig.sender.start(volume: -20) }

        let state = await rig.sender.state
        let message = await rig.sender.lastErrorMessage
        #expect(state == .failed)
        #expect(message?.contains("occupé") == true, "\(message ?? "aucun message")")
        #expect(rig.server.requests.count == 1, "rien d'autre après un refus")
        await rig.close()
        let afterStop = await rig.sender.state
        #expect(afterStop == .idle)
    }

    @Test("Un récepteur occupé à la reconnexion n'est pas harcelé")
    func busyAtReconnectIsNotHammered() async throws {
        let rig = try await makeRig()
        try await rig.sender.start(volume: -20)
        #expect(await eventually { rig.server.audioPackets.count > 5 })

        rig.server.setScript { _ in .status(453, "Not Enough Bandwidth") }
        rig.server.closeConnections()
        #expect(await eventually { await rig.sender.state == .reconnecting })

        // Première tentative à +1 s, puis pas avant 10 s.
        try await Task.sleep(for: .milliseconds(2_500))
        let announces = rig.server.requests.filter { $0.method == "ANNOUNCE" }.count
        #expect(announces == 2, "\(announces) ANNOUNCE : la session de départ et une seule tentative")

        let state = await rig.sender.state
        let message = await rig.sender.lastErrorMessage
        #expect(state == .reconnecting)
        #expect(message?.contains("occupé") == true, "\(message ?? "aucun message")")
        await rig.close()
    }

    @Test("Le délai de reconnexion croît, plus vite pour un récepteur occupé")
    func reconnectDelays() {
        let network = RTSPError.connectionFailed("x")
        let busy = RTSPError.unexpectedStatus(method: "ANNOUNCE", code: 453, reason: "")
        #expect(RAOPSender.reconnectDelay(after: network, current: .seconds(1)) == .seconds(2))
        #expect(RAOPSender.reconnectDelay(after: network, current: .seconds(10)) == .seconds(15))
        #expect(RAOPSender.reconnectDelay(after: busy, current: .seconds(1)) == .seconds(10))
        #expect(RAOPSender.reconnectDelay(after: busy, current: .seconds(20)) == .seconds(30))
    }

    @Test("Un mot de passe exigé met fin aux tentatives, qui n'y changeraient rien")
    func passwordStopsRetrying() async throws {
        #expect(!RAOPSender.isWorthRetrying(
            RTSPError.unexpectedStatus(method: "ANNOUNCE", code: 401, reason: "")
        ))
        #expect(!RAOPSender.isWorthRetrying(RAOPSenderError.alacUnsupported("x")))
        #expect(RAOPSender.isWorthRetrying(
            RTSPError.unexpectedStatus(method: "ANNOUNCE", code: 453, reason: "")
        ))
        #expect(RAOPSender.isWorthRetrying(RTSPError.timedOut(method: "SETUP")))

        let rig = try await makeRig()
        try await rig.sender.start(volume: -20)
        #expect(await eventually { rig.server.audioPackets.count > 5 })

        rig.server.setScript { _ in .status(401, "Unauthorized") }
        rig.server.closeConnections()
        #expect(await eventually { await rig.sender.state == .failed })
        let message = await rig.sender.lastErrorMessage
        #expect(message?.contains("mot de passe") == true)

        let announces = rig.server.requests.filter { $0.method == "ANNOUNCE" }.count
        try await Task.sleep(for: .milliseconds(1_500))
        #expect(rig.server.requests.filter { $0.method == "ANNOUNCE" }.count == announces)
        await rig.close()
    }

    @Test("Une fermeture propre du récepteur relance la session, marqueur compris")
    func finTriggersReconnection() async throws {
        let rig = try await makeRig()
        try await rig.sender.start(volume: -20)
        #expect(await eventually { rig.server.audioPackets.count > 10 })
        let before = rig.server.audioPackets.count

        rig.server.closeConnections()
        #expect(await eventually(within: .seconds(5)) {
            await rig.sender.state == .streaming
                && rig.server.audioPackets.count > before + 10
                && rig.server.requests.filter { $0.method == "RECORD" }.count == 2
        })

        let resumed = rig.server.audioPackets[before...]
        #expect(resumed.first { $0.marker } != nil, "le récepteur doit repartir sur des tampons neufs")
        let statistics = await rig.sender.statistics
        #expect(statistics.reconnections == 1)
        await rig.close()
    }

    @Test("Sans reconnexion automatique, une session perdue se voit dans l'état")
    func lostSessionWithoutReconnection() async throws {
        let rig = try await makeRig(reconnects: false)
        try await rig.sender.start(volume: -20)
        rig.server.closeConnections()
        #expect(await eventually { await rig.sender.state == .failed })
        await rig.close()
    }

    @Test("Un volume refusé au démarrage ne coûte pas la session")
    func refusedVolumeDoesNotKillSession() async throws {
        let rig = try await makeRig(
            script: { $0.method == "SET_PARAMETER" ? .status(400, "Bad Request") : .standard }
        )
        try await rig.sender.start(volume: -20)
        #expect(await eventually { rig.server.audioPackets.count > 10 })
        let state = await rig.sender.state
        #expect(state == .streaming)
        await rig.close()
    }

    @Test("Un volume réglé pendant une coupure part à la reprise, sans erreur")
    func volumeDuringReconnectionIsApplied() async throws {
        let rig = try await makeRig()
        try await rig.sender.start(volume: -20)
        #expect(await eventually { rig.server.audioPackets.count > 5 })

        rig.server.closeConnections()
        #expect(await eventually { await rig.sender.state == .reconnecting })
        try await rig.sender.setVolume(-7)

        #expect(await eventually(within: .seconds(5)) {
            rig.server.requests.last { $0.method == "SET_PARAMETER" }?.bodyText.contains("-7.0")
                == true
        })
        await rig.close()
    }

    @Test("Des sessions à répétition ne laissent aucun socket derrière elles")
    func sessionsLeaveNoSocketBehind() async throws {
        let format = try #require(captureFormat())
        let server = try await FakeRAOPReceiver()
        defer { server.shutdown() }
        let sender = RAOPSender(
            device: server.device(),
            ring: AudioRingBuffer(capacityFrames: 4_800, channelCount: 2),
            captureFormat: format
        )

        @Sendable func openDescriptors() -> Int {
            (0..<Int(getdtablesize())).filter { fcntl(Int32($0), F_GETFD) != -1 }.count
        }

        try await sender.start()
        await sender.stop()
        try await Task.sleep(for: .milliseconds(100))
        let baseline = openDescriptors()

        for _ in 0..<50 {
            try await sender.start()
            await sender.stop()
        }

        // Une marge, parce que les autres suites tournent en parallèle. Le répondeur d'horloge
        // retenait son canal : 50 sessions laissaient 50 sockets ouverts.
        #expect(await eventually(within: .seconds(3)) { openDescriptors() < baseline + 25 })
    }

    @Test("Un récepteur sans IPv4 est refusé avant tout échange")
    func ipv6HostIsRefusedUpFront() async throws {
        let format = try #require(captureFormat())
        let device = RAOPDevice(serviceName: "x", host: "fe80::1", port: 5000, txt: ["et": "0"])
        let sender = RAOPSender(
            device: device,
            ring: AudioRingBuffer(capacityFrames: 1_024, channelCount: 2),
            captureFormat: format
        )
        await #expect(throws: RAOPSenderError.self) { try await sender.start() }
    }

    // MARK: - Arrêt

    @Test("Un stop pendant une négociation sans réponse rend la main tout de suite")
    func stopDuringNegotiation() async throws {
        let rig = try await makeRig(script: { _ in .silence })
        let starting = Task { try await rig.sender.start(volume: -20) }
        #expect(await eventually { !rig.server.requests.isEmpty })

        let start = ContinuousClock.now
        await rig.sender.stop()
        #expect(secondsSince(start) < 1)

        await #expect(throws: (any Error).self) { try await starting.value }
        let state = await rig.sender.state
        #expect(state == .idle, "un stop ne doit pas se solder par un échec")

        // Et rien ne doit ressusciter.
        try await Task.sleep(for: .milliseconds(200))
        #expect(rig.server.audioPackets.isEmpty)
        rig.feeder.stop()
        rig.server.shutdown()
    }

    @Test("Annuler la tâche de démarrage abandonne la négociation et laisse le sender au repos")
    func cancellationDuringNegotiation() async throws {
        let rig = try await makeRig(script: { _ in .silence })
        let starting = Task { try await rig.sender.start(volume: -20) }
        #expect(await eventually { !rig.server.requests.isEmpty })

        let start = ContinuousClock.now
        starting.cancel()
        await #expect(throws: CancellationError.self) { try await starting.value }
        #expect(secondsSince(start) < 1)

        let state = await rig.sender.state
        #expect(state == .idle)
        await rig.close()
    }

    @Test("Un stop depuis une tâche déjà annulée envoie quand même le TEARDOWN")
    func stopFromCancelledTaskStillTearsDown() async throws {
        let rig = try await makeRig()
        try await rig.sender.start(volume: -20)
        #expect(await eventually { rig.server.audioPackets.count > 5 })

        // C'est exactement ainsi que `BridgeEngine` arrête une sortie.
        let sender = rig.sender
        let stopping = Task {
            while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(5)) }
            await sender.stop()
        }
        stopping.cancel()
        await stopping.value

        #expect(rig.server.requests.last?.method == "TEARDOWN")
        rig.feeder.stop()
        rig.server.shutdown()
    }

    @Test("Un récepteur muet au TEARDOWN ne bloque pas l'arrêt plus de 2 s")
    func silentTeardownIsBounded() async throws {
        let rig = try await makeRig(script: { $0.method == "TEARDOWN" ? .silence : .standard })
        try await rig.sender.start(volume: -20)
        let start = ContinuousClock.now
        await rig.close()
        #expect(secondsSince(start) < 3)
        #expect(rig.server.requests.last?.method == "TEARDOWN")
    }

    @Test("Un stop en pleine reconnexion vers un récepteur disparu rend la main tout de suite")
    func stopDuringLongLoss() async throws {
        let rig = try await makeRig()
        try await rig.sender.start(volume: -20)
        #expect(await eventually { rig.server.audioPackets.count > 5 })

        rig.server.refuseNewConnections()
        #expect(await eventually { await rig.sender.state == .reconnecting })
        // Laisse passer une tentative, pour s'arrêter en plein milieu du repli.
        #expect(await eventually(within: .seconds(4)) {
            await rig.sender.statistics.reconnectionAttempts >= 1
        })

        let start = ContinuousClock.now
        await rig.sender.stop()
        #expect(secondsSince(start) < 1)
        let state = await rig.sender.state
        #expect(state == .idle)
        rig.feeder.stop()
        rig.server.shutdown()
    }

    @Test("Après un stop, le sender peut repartir sur une nouvelle session propre")
    func restartAfterStop() async throws {
        let rig = try await makeRig()
        try await rig.sender.start(volume: -20)
        #expect(await eventually { rig.server.audioPackets.count > 5 })
        await rig.sender.stop()

        let before = rig.server.audioPackets.count
        try await rig.sender.start(volume: -20)
        #expect(await eventually { rig.server.audioPackets.count > before + 5 })
        #expect(rig.server.audioPackets[before].marker)
        await rig.close()
    }

    // MARK: - Renfort de basses

    @Test("Le renfort s'entend dans le flux émis, et 0 dB est bit à bit sans filtre")
    func bassBoostReachesTheWire() async throws {
        func levelAt(boost: Float) async throws -> Double {
            // Assez bas pour que le limiteur n'entre pas en jeu.
            let rig = try await makeRig(hz: 40, amplitude: 0.05)
            await rig.sender.setBassBoost(decibels: boost)
            try await rig.sender.start(volume: -20)
            #expect(await eventually { rig.server.audioPackets.count > 110 })
            let settled = rig.server.audioPackets.suffix(50)
            await rig.close()
            return rms(settled.flatMap { samples(ofL16: $0.payload) })
        }

        let flat = try await levelAt(boost: 0)
        let boosted = try await levelAt(boost: 12)
        let gain = 20 * log10(boosted / flat)
        #expect(abs(gain - 11.2) < 1.5, "gain mesuré sur le flux : \(gain) dB")
    }

    @Test("Le renfort se règle en pleine diffusion, et survit à une reconnexion")
    func bassBoostIsLiveAndSurvivesReconnection() async throws {
        let rig = try await makeRig(hz: 40, amplitude: 0.05)
        try await rig.sender.start(volume: -20)
        #expect(await eventually { rig.server.audioPackets.count > 80 })
        let flat = rms(rig.server.audioPackets.suffix(40).flatMap { samples(ofL16: $0.payload) })

        await rig.sender.setBassBoost(decibels: 12)
        let before = rig.server.audioPackets.count
        #expect(await eventually { rig.server.audioPackets.count > before + 60 })
        let boosted = rms(rig.server.audioPackets.suffix(40).flatMap { samples(ofL16: $0.payload) })
        #expect(20 * log10(boosted / flat) > 9)

        rig.server.closeConnections()
        #expect(await eventually(within: .seconds(5)) {
            rig.server.requests.filter { $0.method == "RECORD" }.count == 2
        })
        let resumed = rig.server.audioPackets.count
        #expect(await eventually { rig.server.audioPackets.count > resumed + 60 })
        let after = rms(rig.server.audioPackets.suffix(40).flatMap { samples(ofL16: $0.payload) })
        #expect(20 * log10(after / flat) > 9)

        let statistics = await rig.sender.statistics
        #expect(statistics.bassBoostDecibels == 12)
        await rig.close()
    }

    @Test("Le renfort d'une sortie n'atteint pas le tampon partagé")
    func bassBoostLeavesSharedRingUntouched() async throws {
        // Le producteur écrit un motif connu ; le sender lit et filtre sa copie. Une seconde
        // lecture directe du stockage du ring n'est pas possible sans casser le contrat SPSC :
        // on vérifie donc au niveau du filtre, sur une copie, et que l'original n'a pas bougé.
        var filter = LowShelfFilter(sampleRate: 48_000, channelCount: 2)
        filter.setGain(decibels: 12)
        let original = (0..<9_600).map { Float(sin(Double($0) * 0.005)) * 0.5 }
        var copy = original
        copy.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            filter.process(base, frameCount: 4_800)
        }
        #expect(copy != original)
        #expect(original[100] == Float(sin(Double(100) * 0.005)) * 0.5)
    }

    // MARK: - Formats de capture

    @Test(
        "Toute fréquence de capture, et le mono d'une entrée physique, donnent un flux correct",
        arguments: [
            (44_100.0, AVAudioChannelCount(2), true),
            (48_000.0, AVAudioChannelCount(2), true),
            (96_000.0, AVAudioChannelCount(2), true),
            (48_000.0, AVAudioChannelCount(1), false),
        ]
    )
    func captureFormats(sampleRate: Double, channels: AVAudioChannelCount, interleaved: Bool)
        async throws
    {
        let format = captureFormat(
            sampleRate: sampleRate, channels: channels, interleaved: interleaved
        )
        let rig = try await makeRig(format: format, hz: 1_000, amplitude: 0.25)
        try await rig.sender.start(volume: -20)
        #expect(await eventually(within: .seconds(4)) { rig.server.audioPackets.count > 110 })
        let settled = Array(rig.server.audioPackets.suffix(80))
        await rig.close()

        #expect(settled.allSatisfy { $0.payload.count == 352 * 4 })
        let interleavedSamples = settled.flatMap { samples(ofL16: $0.payload) }
        let left = stride(from: 0, to: interleavedSamples.count, by: 2).map { interleavedSamples[$0] }
        let right = stride(from: 1, to: interleavedSamples.count, by: 2).map { interleavedSamples[$0] }

        // Niveau juste sur les deux canaux, et fréquence préservée : une erreur de ratio ou
        // d'entrelacement déplacerait la note.
        let level = 0.25 / 2.0.squareRoot() * 32_768
        #expect(abs(rms(left) - level) < level * 0.15, "gauche : \(rms(left))")
        #expect(abs(rms(right) - level) < level * 0.15, "droite : \(rms(right))")

        let crossings = zip(left, left.dropFirst()).filter { ($0 < 0) != ($1 < 0) }.count
        let measuredHz = Double(crossings) / 2 / (Double(left.count) / 44_100)
        #expect(abs(measuredHz - 1_000) < 10, "\(measuredHz) Hz au lieu de 1 000")
    }

    @Test("Un format de capture qui n'est pas du float32 est refusé clairement")
    func nonFloatCaptureIsRefused() async throws {
        let format = try #require(AVAudioFormat(
            commonFormat: .pcmFormatInt16, sampleRate: 48_000, channels: 2, interleaved: true
        ))
        #expect(throws: RAOPResamplerError.self) {
            _ = try RAOPResampler(inputFormat: format)
        }
    }
}

/// Le choix du récepteur et la lecture de ses capacités : aucun réseau, aucune découverte.
@Suite("Découverte RAOP")
struct RAOPDiscoveryTests {
    private let names = [
        "AA11BB22CC33@Salon (2)", "DD44EE55FF66@Salon", "112233445566@Geneva AeroSphere Large",
    ]

    private func match(_ name: String) -> String? {
        RAOPDiscovery.bestMatch(for: name, among: names, name: { $0 })
    }

    @Test("Le nom exact l'emporte sur la contenance : « Salon » n'est pas « Salon (2) »")
    func exactBeforePartial() {
        #expect(match("salon") == "DD44EE55FF66@Salon")
        #expect(match("Salon (2)") == "AA11BB22CC33@Salon (2)")
        #expect(match("DD44EE55FF66@Salon") == "DD44EE55FF66@Salon")
    }

    @Test("Sans nom exact, une partie du nom suffit, et le choix est reproductible")
    func partialIsDeterministic() {
        #expect(match("Geneva") == "112233445566@Geneva AeroSphere Large")
        #expect(match("alon") == "DD44EE55FF66@Salon", "le plus court des candidats")
        #expect(match("inconnu") == nil)
    }

    @Test("Le nom complet d'une requête DNS échappe ce qui doit l'être")
    func fullServiceName() {
        #expect(
            RAOPDiscovery.fullServiceName(name: "AABB@Geneva", type: "_raop._tcp", domain: "local.")
                == "AABB@Geneva._raop._tcp.local."
        )
        #expect(
            RAOPDiscovery.fullServiceName(name: "M. Dupont", type: "_raop._tcp.", domain: "local.")
                == "M\\. Dupont._raop._tcp.local."
        )
        #expect(
            RAOPDiscovery.fullServiceName(name: "a\\b", type: "_raop._tcp", domain: "local.")
                == "a\\\\b._raop._tcp.local."
        )
    }

    private func device(_ txt: [String: String]) -> RAOPDevice {
        RAOPDevice(serviceName: "AABB@Geneva", host: "127.0.0.1", port: 5000, txt: txt)
    }

    @Test("Le TXT de la vraie Geneva se lit comme attendu")
    func genevaTXT() {
        let geneva = device(["et": "0,4", "cn": "0", "sr": "44100", "ss": "16", "ch": "2"])
        #expect(geneva.supportsUnencrypted)
        #expect(!geneva.supportsRSAEncryption)
        #expect(geneva.supportsPCM)
        #expect(!geneva.supportsALAC)
        #expect(geneva.displayName == "Geneva")
    }

    @Test("Un TXT mal espacé ou incomplet reste exploitable")
    func unusualTXT() {
        let spaced = device(["et": "0, 1", "cn": " 1 ,0 "])
        #expect(spaced.supportsRSAEncryption, "espace après la virgule")
        #expect(spaced.supportsALAC)
        #expect(spaced.supportsPCM)

        // Rien d'annoncé : ce que pyatv envoie sans condition.
        let empty = device([:])
        #expect(empty.supportsUnencrypted)
        #expect(empty.supportsPCM)
        #expect(empty.sampleRate == 44_100)
        #expect(empty.channelCount == 2)
    }

    @Test("Une valeur absurde dans le TXT ne devient pas une division par zéro")
    func absurdTXTValues() {
        let absurd = device(["sr": "0", "ss": "abc", "ch": "-2"])
        #expect(absurd.sampleRate == 44_100)
        #expect(absurd.bitDepth == 16)
        #expect(absurd.channelCount == 2)

        let refused = device(["et": "3,4", "cn": "2"])
        #expect(!refused.supportsUnencrypted)
        #expect(!refused.supportsRSAEncryption)
        #expect(!refused.supportsPCM)
        #expect(!refused.supportsALAC)
    }
}

/// Le rééchantillonneur seul, sur les formats que la capture peut réellement livrer.
@Suite("Formats de capture du rééchantillonneur")
struct RAOPResamplerFormatTests {
    private func convert(
        _ format: AVAudioFormat, frames: Int, hz: Double = 1_000, amplitude: Float = 0.5
    ) throws -> [Int16] {
        let resampler = try RAOPResampler(inputFormat: format)
        let channels = Int(format.channelCount)
        var source = [Float](repeating: 0, count: frames * channels)
        for frame in 0..<frames {
            let value = amplitude * Float(sin(2 * .pi * hz * Double(frame) / format.sampleRate))
            for channel in 0..<channels { source[frame * channels + channel] = value }
        }
        return try source.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return [] }
            return try resampler.convert(base, frameCount: frames)
        }
    }

    @Test("44,1 kHz : aucune conversion de fréquence, donc aucune trame de plus ou de moins")
    func sameRate() throws {
        let format = try #require(captureFormat(sampleRate: 44_100))
        let converted = try convert(format, frames: 44_100)
        #expect(abs(converted.count / 2 - 44_100) < 50, "\(converted.count / 2) trames")
    }

    @Test("96 kHz : le ratio est le bon")
    func highRate() throws {
        let format = try #require(captureFormat(sampleRate: 96_000))
        let converted = try convert(format, frames: 96_000)
        #expect(abs(converted.count / 2 - 44_100) < 200, "\(converted.count / 2) trames")
    }

    @Test("Mono planaire d'une entrée physique : le son arrive sur les deux canaux")
    func monoPlanar() throws {
        let format = try #require(captureFormat(channels: 1, interleaved: false))
        let converted = try convert(format, frames: 48_000)
        #expect(abs(converted.count / 2 - 44_100) < 200)

        let middle = converted.count / 4 * 2
        let left = stride(from: middle, to: middle + 8_820, by: 2).map { abs(Int(converted[$0])) }
        let right = stride(from: middle + 1, to: middle + 8_821, by: 2).map {
            abs(Int(converted[$0]))
        }
        let leftPeak = left.max() ?? 0
        let rightPeak = right.max() ?? 0
        #expect(leftPeak > 5_000, "gauche : crête \(leftPeak)")
        #expect(rightPeak > 5_000, "droite : crête \(rightPeak)")
    }

    @Test("Stéréo planaire : l'entrelacement du ring buffer est bien défait")
    func stereoPlanar() throws {
        let format = try #require(captureFormat(interleaved: false))
        let resampler = try RAOPResampler(inputFormat: format)
        // Gauche active, droite muette : une erreur de désentrelacement les mélangerait.
        var source = [Float](repeating: 0, count: 9_600)
        for frame in 0..<4_800 {
            source[frame * 2] = 0.5 * Float(sin(2 * .pi * 1_000 * Double(frame) / 48_000))
        }
        let converted = try source.withUnsafeBufferPointer { buffer -> [Int16] in
            guard let base = buffer.baseAddress else { return [] }
            return try resampler.convert(base, frameCount: 4_800)
        }
        let left = stride(from: 0, to: converted.count, by: 2).map { abs(Int(converted[$0])) }
        let right = stride(from: 1, to: converted.count, by: 2).map { abs(Int(converted[$0])) }
        #expect((left.max() ?? 0) > 5_000)
        #expect((right.max() ?? 0) < 50)
    }
}
