import Foundation
import Network
import Testing

@testable import AudioCore

@Suite("Canal d'événements — décodage")
struct AirPlay2EventDecoderTests {
    private let secret = Data(repeating: 0x42, count: 64)

    /// Le pair : vu du récepteur, il écrit avec la clé « Write » et lit avec la clé « Read ».
    /// Si le décodeur inversait ces clés, tout échouerait sur une étiquette invalide.
    private func receiverSide() throws -> (
        write: AirPlay2ControlChannel.Direction, read: AirPlay2ControlChannel.Direction
    ) {
        (
            try AirPlay2ControlChannel.Direction(
                key: HKDF512.derive(
                    secret: secret, salt: "Events-Salt", info: "Events-Write-Encryption-Key")),
            try AirPlay2ControlChannel.Direction(
                key: HKDF512.derive(
                    secret: secret, salt: "Events-Salt", info: "Events-Read-Encryption-Key"))
        )
    }

    @Test("Les clés sont inversées par rapport au canal de contrôle, comme chez pyatv")
    func clesInversees() throws {
        let decoder = try AirPlay2EventDecoder(sessionSecret: secret)
        let peer = try receiverSide()

        let message = Data("POST /x RTSP/1.0\r\nCSeq: 1\r\n\r\n".utf8)
        let (requests, reply) = decoder.absorb(try peer.write.seal(message))

        #expect(requests.count == 1)
        #expect(requests.first?.method == "POST")
        #expect(requests.first?.uri == "/x")
        let (clear, _) = try peer.read.open(reply)
        #expect(String(decoding: clear, as: UTF8.self).hasPrefix("RTSP/1.0 200 OK"))
    }

    @Test("Deux requêtes dans un même fragment reçoivent chacune leur réponse")
    func deuxRequetes() throws {
        let decoder = try AirPlay2EventDecoder(sessionSecret: secret)
        let peer = try receiverSide()

        var wire = try peer.write.seal(Data("POST /a RTSP/1.0\r\nCSeq: 1\r\n\r\n".utf8))
        wire.append(try peer.write.seal(Data("POST /b RTSP/1.0\r\nCSeq: 2\r\n\r\n".utf8)))
        let (requests, reply) = decoder.absorb(wire)

        #expect(requests.map(\.uri) == ["/a", "/b"])
        let (clear, _) = try peer.read.open(reply)
        let text = String(decoding: clear, as: UTF8.self)
        #expect(text.contains("CSeq: 1\r\n"))
        #expect(text.contains("CSeq: 2\r\n"))
    }

    @Test("Un corps est lu selon Content-Length, même arrivé en plusieurs fois")
    func corpsFragmente() throws {
        let decoder = try AirPlay2EventDecoder(sessionSecret: secret)
        let peer = try receiverSide()

        let message = Data("POST /c RTSP/1.0\r\nContent-Length: 5\r\n\r\nhello".utf8)
        let first = decoder.absorb(try peer.write.seal(message.prefix(10)))
        #expect(first.requests.isEmpty)
        let second = decoder.absorb(try peer.write.seal(message.dropFirst(10)))
        #expect(second.requests.first?.body == Data("hello".utf8))
    }

    @Test("Un message sans CSeq est acquitté sans en inventer un")
    func sansCSeq() throws {
        let reply = AirPlay2EventDecoder.acknowledgement(
            of: AirPlay2EventRequest(
                method: "POST", uri: "/x", protocolVersion: "HTTP/1.1", headers: [:], body: Data()))
        let text = String(decoding: reply, as: UTF8.self)
        #expect(text.hasPrefix("HTTP/1.1 200 OK\r\n"))
        #expect(!text.contains("CSeq"))
    }

    /// Après un échec, le flux TCP ne se resynchronise pas : tout le reste est ignoré, sans
    /// répondre n'importe quoi au récepteur.
    @Test("Après une étiquette invalide, le décodage s'arrête définitivement")
    func echecTerminal() throws {
        let decoder = try AirPlay2EventDecoder(sessionSecret: secret)
        let peer = try receiverSide()

        var sealed = try peer.write.seal(Data("POST /x RTSP/1.0\r\n\r\n".utf8))
        sealed[4] ^= 0xFF
        let failed = decoder.absorb(sealed)
        #expect(failed.requests.isEmpty)
        #expect(failed.reply.isEmpty)
        #expect(decoder.hasFailed)

        let after = decoder.absorb(try peer.write.seal(Data("POST /y RTSP/1.0\r\n\r\n".utf8)))
        #expect(after.requests.isEmpty)
    }

    @Test("Une ligne de requête illisible est un échec, pas une attente")
    func ligneIllisible() throws {
        let decoder = try AirPlay2EventDecoder(sessionSecret: secret)
        let peer = try receiverSide()

        _ = decoder.absorb(try peer.write.seal(Data("n'importe quoi\r\n\r\n".utf8)))
        #expect(decoder.hasFailed)
    }
}

@Suite("Canal d'événements — connexion")
struct AirPlay2EventChannelConnectionTests {

    /// pyatv réessaie contre le mock, qui ouvre ce canal un peu après avoir répondu au `SETUP`.
    /// `NWConnection` reste sinon en attente d'un changement de réseau qui ne viendra jamais.
    @Test("Un port qui s'ouvre avec retard est rejoint dans la limite de l'échéance")
    func portOuvertEnRetard() async throws {
        // Réserve un port libre, puis le libère : c'est lui qui s'ouvrira plus tard.
        let reservation = try UDPChannel(label: "test-reservation")
        let port = reservation.localPort
        let endpoint = NWEndpoint.Port(rawValue: port) ?? .any

        let channel = AirPlay2EventChannel(host: "127.0.0.1", port: port)
        let connecting = Task { await channel.connect(timeout: .seconds(4)) }
        defer { channel.close() }

        try await Task.sleep(for: .milliseconds(700))
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: endpoint)
        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { $0.start(queue: .global()) }
        listener.start(queue: .global())
        defer { listener.cancel() }

        #expect(await connecting.value)
    }

    @Test("Un port qui ne s'ouvre jamais rend false à l'échéance, sans lever")
    func portFerme() async throws {
        let reservation = try UDPChannel(label: "test-reservation")
        let channel = AirPlay2EventChannel(host: "127.0.0.1", port: reservation.localPort)
        defer { channel.close() }

        let start = ContinuousClock.now
        let connected = await channel.connect(timeout: .milliseconds(300))
        #expect(!connected)
        #expect(ContinuousClock.now - start < .seconds(2))
        #expect(!channel.isConnected)
    }

    /// Un arrêt volontaire n'est pas une perte de session.
    @Test("close() ne signale pas de rupture, et réveille une connexion en cours")
    func fermetureVolontaire() async throws {
        let channel = AirPlay2EventChannel(host: "192.0.2.1", port: 7000)
        let lost = LockedFlag()
        let connecting = Task {
            await channel.connect(timeout: .seconds(30)) { lost.set() }
        }
        try await Task.sleep(for: .milliseconds(100))

        let start = ContinuousClock.now
        channel.close()
        #expect(await connecting.value == false)
        #expect(ContinuousClock.now - start < .seconds(2))
        #expect(!lost.value)
    }
}
