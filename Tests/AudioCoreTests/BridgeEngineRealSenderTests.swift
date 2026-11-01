import Foundation
import Network
import Testing

@testable import AudioCore

/// Récepteur RAOP minimal, dans le processus du test : il répond 200 à tout, et le test décide
/// quand il coupe la connexion. Les mocks n'offrent pas ce contrôle et sont partagés.
private final class LoopbackRAOPReceiver: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "fr.baptiste.airplaymultioutput.tests.loopback-raop")
    private var connections: [NWConnection] = []
    private var answerDelay: TimeInterval = 0

    init() throws {
        listener = try NWListener(using: .tcp, on: .any)
    }

    /// Démarre l'écoute et rend le port attribué.
    func start() async throws -> UInt16 {
        let once = OnceThrowingResumer<UInt16>()
        return try await withCheckedThrowingContinuation { continuation in
            once.attach(continuation)
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            listener.stateUpdateHandler = { [listener] state in
                switch state {
                case .ready: once.resume(returning: listener.port?.rawValue ?? 0)
                case let .failed(error): once.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        queue.sync {
            for connection in connections { connection.cancel() }
            connections = []
        }
        listener.cancel()
    }

    /// Coupe brutalement les sessions en cours, et retarde les réponses des suivantes.
    ///
    /// `forceCancel` et non `cancel` : une fermeture propre (FIN) passe inaperçue de `RTSPClient`,
    /// qui ne garde aucune lecture en attente entre deux requêtes et reste donc `.ready`. Seule
    /// une rupture franche, comme la mort du récepteur, lui parvient.
    func dropSessions(thenAnswerAfter delay: TimeInterval) {
        queue.sync {
            answerDelay = delay
            for connection in connections { connection.forceCancel() }
            connections = []
        }
    }

    private func accept(_ connection: NWConnection) {
        connections.append(connection)
        connection.start(queue: queue)
        receive(on: connection, pending: Data())
    }

    private func receive(on connection: NWConnection, pending: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) {
            [weak self] data, _, isComplete, error in
            guard let self, error == nil, !isComplete else { return }
            var buffer = pending
            buffer.append(data ?? Data())
            while let (request, consumed) = Self.nextRequest(in: buffer) {
                buffer.removeFirst(consumed)
                self.answer(request, on: connection)
            }
            self.receive(on: connection, pending: buffer)
        }
    }

    private static func nextRequest(in buffer: Data) -> (String, Int)? {
        guard let separator = buffer.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: buffer[buffer.startIndex..<separator.lowerBound], as: UTF8.self)
        let bodyLength = header("Content-Length", in: head).flatMap(Int.init) ?? 0
        let consumed = separator.upperBound - buffer.startIndex + bodyLength
        guard buffer.count >= consumed else { return nil }
        return (head, consumed)
    }

    private static func header(_ name: String, in head: String) -> String? {
        for line in head.components(separatedBy: "\r\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2, parts[0].lowercased() == name.lowercased() {
                return parts[1].trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    private func answer(_ head: String, on connection: NWConnection) {
        var response = "RTSP/1.0 200 OK\r\nCSeq: \(Self.header("CSeq", in: head) ?? "0")\r\n"
        if head.hasPrefix("SETUP") {
            // Des ports où rien n'écoute : l'audio part en UDP, sans retour, comme vers un
            // récepteur réel qui ne signalerait rien.
            response +=
                "Transport: RTP/AVP/UDP;unicast;mode=record;"
                + "server_port=59001;control_port=59002;timing_port=59003\r\nSession: 1\r\n"
        }
        response += "\r\n"
        let delay = head.hasPrefix("ANNOUNCE") ? answerDelay : 0
        queue.asyncAfter(deadline: .now() + delay) {
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in })
        }
    }
}

/// Le vrai `RAOPSender`, désigné par adresse.
private final class LoopbackSenderFactory: OutputSenderFactory, @unchecked Sendable {
    private let lock = NSLock()
    private var last: RAOPSender?
    private let port: UInt16

    init(port: UInt16) { self.port = port }

    var sender: RAOPSender? {
        lock.lock()
        defer { lock.unlock() }
        return last
    }

    private func remember(_ sender: RAOPSender) {
        lock.lock()
        last = sender
        lock.unlock()
    }

    func makeSender(
        for request: BridgeEngine.OutputRequest, context: OutputSenderContext
    ) async throws -> any OutputSender {
        let device = RAOPDevice(
            serviceName: "000000000000@Boucle", host: "127.0.0.1", port: port,
            txt: ["et": "0", "cn": "0", "sr": "44100", "ss": "16", "ch": "2"]
        )
        let sender = RAOPSender(
            device: device, ring: context.ring, captureFormat: context.captureFormat,
            clock: context.clock
        )
        remember(sender)
        return sender
    }
}

@Suite("Moteur et vrai sender, sur une boucle locale")
struct BridgeEngineRealSenderTests {
    /// La reconnexion n'est pas celle d'une doublure : le sender réel perd sa connexion RTSP, son
    /// tampon déborde pendant qu'il renégocie, et il repart.
    ///
    /// C'est là que le compteur d'avant se trompait pour de bon : chaque reconnexion décalait la
    /// sortie du volume débordé, et les 90 reconnexions de la validation d'une heure avaient ainsi
    /// accumulé 2,4 s d'écart, inaudibles sur un mock.
    @Test("Une reconnexion se lit dans la phase, et l'ancrage repart sur le direct")
    func reconnectionKeepsAnchorCurrent() async throws {
        let receiver = try LoopbackRAOPReceiver()
        let port = try await receiver.start()
        defer { receiver.stop() }
        let factory = LoopbackSenderFactory(port: port)

        var dependencies = BridgeEngine.Dependencies.live
        dependencies.senderFactory = factory
        dependencies.tuning.monitorInterval = .milliseconds(20)
        let engine = BridgeEngine(dependencies: dependencies)
        let output = BridgeEngine.OutputRequest(
            id: "boucle", proto: .raop, deviceName: "Boucle", volumeDB: -30
        )

        try await engine.start(source: .tone(frequency: 440, levelDBFS: -50), outputs: [output])
        #expect(await eventually { await engine.phase(of: "boucle") == .streaming })
        #expect(await eventually { await engine.snapshot(of: "boucle")?.packetsSent ?? 0 > 50 })

        // Coupure : le sender attend 1 s avant de renégocier, puis le récepteur met 2 s à répondre.
        // Le tampon d'une seconde a largement le temps de déborder.
        receiver.dropSessions(thenAnswerAfter: 2)
        #expect(await eventually { await engine.phase(of: "boucle") == .reconnecting })
        #expect(await eventually(timeout: .seconds(15)) {
            await engine.phase(of: "boucle") == .streaming
        })

        #expect(await eventually {
            guard let snapshot = await engine.snapshot(of: "boucle") else { return false }
            return snapshot.statistics.reconnections == 1 && snapshot.packetsSent > 100
        })
        let snapshot = try #require(await engine.snapshot(of: "boucle"))
        #expect(snapshot.droppedWhileStreaming > 24_000)

        let sender = try #require(factory.sender)
        let anchor = try #require(sender.synchronizer.syncAnchorUnixTime(latencyFrames: 88_200))
        let lag = Date().timeIntervalSince1970 - anchor
        #expect(abs(lag) < 0.25, "l'ancrage retarde de \(lag) s sur le direct")

        let clock = ContinuousClock()
        let stopping = await clock.measure { await engine.stop() }
        #expect(stopping < .seconds(5))
        #expect(await sender.currentOutputState() == .idle)
    }
}
