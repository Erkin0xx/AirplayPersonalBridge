import AVFoundation
import Foundation
import Network

@testable import AudioCore

/// Faux récepteur RAOP, sur la boucle locale : un serveur RTSP scriptable et les trois canaux
/// UDP d'une session. C'est ce qui permet d'éprouver le sender sans le moindre matériel : les
/// tests ne touchent jamais à la découverte Bonjour, qui contacterait les vrais appareils du
/// réseau, et construisent directement un `RAOPDevice` pointant sur `127.0.0.1`.
final class FakeRAOPReceiver: @unchecked Sendable {
    struct Request: Sendable {
        let method: String
        let uri: String
        let protocolVersion: String
        /// Noms en minuscules.
        let headers: [String: String]
        let body: Data
        let arrivedAt: ContinuousClock.Instant

        var bodyText: String { String(decoding: body, as: UTF8.self) }
    }

    /// Ce que le faux récepteur fait d'une requête.
    enum Reply: Sendable {
        /// Réponse normale du protocole, ports du `SETUP` compris.
        case standard
        /// Refus, ou tout autre code.
        case status(Int, String)
        /// Ne répond jamais, en gardant la connexion ouverte.
        case silence
        /// Ferme la connexion sans répondre.
        case close
        /// Envoie ces octets tels quels, morceau par morceau.
        case chunks([Data], spacing: Duration)
        /// Répond normalement après ce délai, avec éventuellement un corps reconnaissable.
        case delayed(Duration, body: String)
    }

    struct AudioPacket: Sendable {
        let sequence: UInt16
        let timestamp: UInt32
        let marker: Bool
        let raw: Data
        let arrivedAt: ContinuousClock.Instant

        var payload: Data { raw.dropFirst(12) }
    }

    private let lock = NSLock()
    private let queue = DispatchQueue(label: "fr.baptiste.airplaymultioutput.tests.fake-raop")
    private let listener: NWListener
    private var connections: [NWConnection] = []
    private var buffers: [ObjectIdentifier: Data] = [:]
    private var script: @Sendable (Request) -> Reply
    private var storedRequests: [Request] = []
    private var storedAudio: [AudioPacket] = []
    private var storedRetransmissions: [Data] = []
    private var storedSyncs: [Data] = []
    private var unansweredRequests = 0
    private var maximumOverlap = 0
    private var accepting = true

    let audio: UDPChannel
    let control: UDPChannel
    let timing: UDPChannel
    /// Port annoncé au `SETUP`. Le `0` ne s'emploie que pour provoquer des erreurs d'émission.
    var announcedAudioPort: UInt16?
    private var boundPort: UInt16 = 0

    /// Port d'écoute RTSP.
    var port: UInt16 { boundPort }

    init(
        script: @escaping @Sendable (Request) -> Reply = { _ in .standard }
    ) async throws {
        self.script = script
        audio = try UDPChannel(label: "fake-audio")
        control = try UDPChannel(label: "fake-control")
        timing = try UDPChannel(label: "fake-timing")

        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters)
        self.listener = listener

        let ready = PortBox()
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready: ready.resolve(listener.port?.rawValue)
            case .failed, .cancelled: ready.resolve(nil)
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: queue)
        let actualPort = await ready.value()
        boundPort = actualPort ?? 0

        audio.onReceive = { [weak self] data, _ in self?.storeAudio(data) }
        control.onReceive = { [weak self] data, _ in self?.storeControl(data) }
        audio.startReceiving()
        control.startReceiving()
    }

    deinit {
        listener.cancel()
    }

    /// Récepteur tel que le verrait la découverte : TXT de la vraie Geneva par défaut.
    func device(
        txt: [String: String] = ["et": "0,4", "cn": "0", "sr": "44100", "ss": "16", "ch": "2"]
    ) -> RAOPDevice {
        RAOPDevice(
            serviceName: "65D15B6D3AC1@Faux-Recepteur", host: "127.0.0.1", port: boundPort, txt: txt
        )
    }

    var requests: [Request] {
        lock.lock()
        defer { lock.unlock() }
        return storedRequests
    }

    var audioPackets: [AudioPacket] {
        lock.lock()
        defer { lock.unlock() }
        return storedAudio
    }

    var retransmissions: [Data] {
        lock.lock()
        defer { lock.unlock() }
        return storedRetransmissions
    }

    var syncPackets: [Data] {
        lock.lock()
        defer { lock.unlock() }
        return storedSyncs
    }

    /// Plus grand nombre de requêtes en attente de réponse au même instant.
    var requestOverlap: Int {
        lock.lock()
        defer { lock.unlock() }
        return maximumOverlap
    }

    func setScript(_ script: @escaping @Sendable (Request) -> Reply) {
        lock.lock()
        self.script = script
        lock.unlock()
    }

    /// Port de contrôle que le sender a annoncé dans son `SETUP`.
    var senderControlPort: UInt16? {
        lock.lock()
        defer { lock.unlock() }
        let setup = storedRequests.last { $0.method == "SETUP" }
        guard let transport = setup?.headers["transport"] else { return nil }
        for part in transport.split(separator: ";") where part.hasPrefix("control_port=") {
            return UInt16(part.dropFirst("control_port=".count))
        }
        return nil
    }

    /// Réclame des paquets, comme le ferait un récepteur qui constate un trou : `80 D5`.
    func requestRetransmission(first: UInt16, count: UInt16) throws {
        guard let port = senderControlPort else { return }
        try control.setDestination(host: "127.0.0.1", port: port)
        var datagram = Data([0x80, 0xD5, 0x00, 0x01])
        datagram.append(contentsOf: withUnsafeBytes(of: first.bigEndian, Array.init))
        datagram.append(contentsOf: withUnsafeBytes(of: count.bigEndian, Array.init))
        try control.send(datagram)
    }

    /// Ferme proprement toutes les connexions (FIN), comme un récepteur qui met fin à la session.
    func closeConnections() {
        queue.sync {
            lock.lock()
            let open = connections
            connections.removeAll()
            lock.unlock()
            for connection in open { connection.cancel() }
        }
    }

    /// Referme les connexions et refuse les suivantes en les fermant aussitôt.
    func refuseNewConnections() {
        lock.lock()
        accepting = false
        lock.unlock()
        closeConnections()
    }

    func allowNewConnections() {
        lock.lock()
        accepting = true
        lock.unlock()
    }

    func shutdown() {
        closeConnections()
        listener.cancel()
        audio.stop()
        control.stop()
        timing.stop()
    }

    // MARK: - Interne

    private func accept(_ connection: NWConnection) {
        lock.lock()
        let isAccepting = accepting
        if isAccepting { connections.append(connection) }
        lock.unlock()
        guard isAccepting else {
            connection.start(queue: queue)
            connection.cancel()
            return
        }
        connection.start(queue: queue)
        receive(on: connection)
    }

    private func receive(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) {
            [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.absorb(data, from: connection)
            }
            if error == nil, !isComplete {
                self.receive(on: connection)
            } else {
                // Le client est parti : ne pas garder son socket, que les tests comptent.
                self.lock.lock()
                self.connections.removeAll { $0 === connection }
                self.lock.unlock()
                connection.cancel()
            }
        }
    }

    private func absorb(_ data: Data, from connection: NWConnection) {
        let key = ObjectIdentifier(connection)
        lock.lock()
        var buffer = buffers[key, default: Data()]
        buffer.append(data)
        var parsed: [Request] = []
        while let (request, consumed) = Self.parse(buffer) {
            parsed.append(request)
            buffer = Data(buffer.dropFirst(consumed))
        }
        buffers[key] = buffer
        lock.unlock()

        for request in parsed {
            lock.lock()
            storedRequests.append(request)
            unansweredRequests += 1
            maximumOverlap = max(maximumOverlap, unansweredRequests)
            let reply = script(request)
            lock.unlock()
            answer(request, with: reply, on: connection)
        }
    }

    private func answer(_ request: Request, with reply: Reply, on connection: NWConnection) {
        let cseq = request.headers["cseq"].map { "CSeq: \($0)\r\n" } ?? ""
        switch reply {
        case .standard:
            markAnswered()
            connection.send(
                content: standardResponse(to: request), completion: .contentProcessed { _ in })
        case let .status(code, reason):
            markAnswered()
            connection.send(
                content: Data("RTSP/1.0 \(code) \(reason)\r\n\(cseq)\r\n".utf8),
                completion: .contentProcessed { _ in }
            )
        case .silence:
            break
        case .close:
            markAnswered()
            connection.cancel()
        case let .chunks(chunks, spacing):
            markAnswered()
            let seconds = Self.seconds(spacing)
            for (index, chunk) in chunks.enumerated() {
                queue.asyncAfter(deadline: .now() + seconds * Double(index)) {
                    connection.send(content: chunk, completion: .contentProcessed { _ in })
                }
            }
        case let .delayed(delay, body):
            queue.asyncAfter(deadline: .now() + Self.seconds(delay)) { [weak self] in
                self?.markAnswered()
                let response =
                    "RTSP/1.0 200 OK\r\n\(cseq)Content-Length: \(body.utf8.count)\r\n\r\n\(body)"
                connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in })
            }
        }
    }

    private func markAnswered() {
        lock.lock()
        unansweredRequests = max(0, unansweredRequests - 1)
        lock.unlock()
    }

    private func standardResponse(to request: Request) -> Data {
        var headers = ""
        if let cseq = request.headers["cseq"] { headers += "CSeq: \(cseq)\r\n" }
        switch request.method {
        case "SETUP":
            let audioPort = announcedAudioPort ?? audio.localPort
            headers += "Transport: RTP/AVP/UDP;unicast;mode=record;server_port=\(audioPort);"
                + "control_port=\(control.localPort);timing_port=\(timing.localPort)\r\n"
            headers += "Session: 4242\r\n"
        case "RECORD":
            headers += "Audio-Latency: 4096\r\n"
        default:
            break
        }
        return Data("RTSP/1.0 200 OK\r\n\(headers)\r\n".utf8)
    }

    private func storeAudio(_ data: Data) {
        guard data.count >= 12 else { return }
        let bytes = [UInt8](data.prefix(12))
        let packet = AudioPacket(
            sequence: UInt16(bytes[2]) << 8 | UInt16(bytes[3]),
            timestamp: UInt32(bytes[4]) << 24 | UInt32(bytes[5]) << 16
                | UInt32(bytes[6]) << 8 | UInt32(bytes[7]),
            marker: bytes[1] & 0x80 != 0,
            raw: data,
            arrivedAt: .now
        )
        lock.lock()
        storedAudio.append(packet)
        lock.unlock()
    }

    private func storeControl(_ data: Data) {
        guard data.count >= 2 else { return }
        lock.lock()
        switch data[data.startIndex + 1] {
        case 0xD6: storedRetransmissions.append(data)
        case 0xD4: storedSyncs.append(data)
        default: break
        }
        lock.unlock()
    }

    private static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    private static func parse(_ data: Data) -> (Request, Int)? {
        guard let end = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: data[data.startIndex..<end.lowerBound], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        let first = lines.removeFirst().split(separator: " ").map(String.init)
        guard first.count == 3 else { return nil }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...]
                .trimmingCharacters(in: .whitespaces)
        }
        let length = headers["content-length"].flatMap(Int.init) ?? 0
        let bodyStart = end.upperBound
        guard data.distance(from: bodyStart, to: data.endIndex) >= length else { return nil }
        let bodyEnd = data.index(bodyStart, offsetBy: length)
        let request = Request(
            method: first[0], uri: first[1], protocolVersion: first[2], headers: headers,
            body: Data(data[bodyStart..<bodyEnd]), arrivedAt: .now
        )
        return (request, data.distance(from: data.startIndex, to: bodyEnd))
    }
}

private final class PortBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<UInt16?, Never>?
    private var resolved: UInt16??

    func resolve(_ port: UInt16?) {
        lock.lock()
        guard resolved == nil else {
            lock.unlock()
            return
        }
        resolved = .some(port)
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: port)
    }

    func value() async -> UInt16? {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let resolved {
                lock.unlock()
                continuation.resume(returning: resolved)
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }
    }
}

/// Alimente un ring buffer en sinusoïde à la cadence réelle, comme le ferait la capture.
final class ToneFeeder: @unchecked Sendable {
    private let task: Task<Void, Never>

    /// - Parameter amplitude: en pleine échelle. −50 dBFS ≈ 0,00316 pour tout ce qui part vers le
    ///   mock, qui joue sur les haut-parleurs du Mac.
    init(ring: AudioRingBuffer, format: AVAudioFormat, hz: Double, amplitude: Float) {
        let channels = Int(format.channelCount)
        let sampleRate = format.sampleRate
        task = Task.detached(priority: .userInitiated) {
            var phase = 0.0
            let increment = 2 * Double.pi * hz / sampleRate
            var scratch = [Float](repeating: 0, count: 8_192 * channels)
            var last = ContinuousClock.now
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(5))
                let now = ContinuousClock.now
                let elapsed = now - last
                last = now
                let seconds = Double(elapsed.components.seconds)
                    + Double(elapsed.components.attoseconds) / 1e18
                let frames = min(Int(seconds * sampleRate), 8_192)
                for frame in 0..<frames {
                    let value = amplitude * Float(sin(phase))
                    phase += increment
                    for channel in 0..<channels { scratch[frame * channels + channel] = value }
                }
                scratch.withUnsafeBufferPointer { buffer in
                    guard let base = buffer.baseAddress else { return }
                    ring.write(from: base, frameCount: frames)
                }
            }
        }
    }

    deinit { task.cancel() }

    func stop() { task.cancel() }
}

/// Attend qu'une condition devienne vraie. Rend faux à l'échéance, pour un échec lisible.
func eventually(
    within limit: Duration = .seconds(5),
    _ condition: @Sendable () async -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now + limit
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
}

func secondsSince(_ start: ContinuousClock.Instant) -> Double {
    let elapsed = ContinuousClock.now - start
    return Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
}

func captureFormat(
    sampleRate: Double = 48_000, channels: AVAudioChannelCount = 2, interleaved: Bool = true
) -> AVAudioFormat? {
    AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: channels,
        interleaved: interleaved
    )
}
