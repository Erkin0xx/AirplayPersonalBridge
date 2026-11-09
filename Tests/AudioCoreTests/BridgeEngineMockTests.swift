import Darwin
import Foundation
import Testing

@testable import AudioCore

// Le moteur et les vrais senders, de bout en bout, contre les deux mocks.
//
//   ./run-mocks.sh start && AUDIOCORE_MOCK_TESTS=1 swift test --filter BridgeEngineMockTests
//
// Écarté par défaut : il lui faut des mocks lancés, et shairport-sync quitte après chaque session.
// Les récepteurs sont désignés par adresse, sans découverte : celle-ci ouvrirait une connexion
// vers chaque service annoncé, vrai matériel compris, et le mock AirPlay 2 cesse vite d'y figurer
// (`CLAUDE.md`, jalon 3). Ce qui est vérifié ici n'est pas la découverte, mais ce qui suit.

private func localAddress() -> String? {
    var interfaces: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&interfaces) == 0 else { return nil }
    defer { freeifaddrs(interfaces) }
    var cursor = interfaces
    while let current = cursor {
        defer { cursor = current.pointee.ifa_next }
        let interface = current.pointee
        guard String(cString: interface.ifa_name) == "en0",
            let address = interface.ifa_addr, address.pointee.sa_family == sa_family_t(AF_INET)
        else { continue }
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        guard getnameinfo(
            address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0,
            NI_NUMERICHOST
        ) == 0 else { continue }
        return String(cString: host)
    }
    return nil
}

/// Fabrique les vrais senders, en gardant une référence pour observer leur ancrage.
private final class DirectMockFactory: OutputSenderFactory, @unchecked Sendable {
    private let lock = NSLock()
    private var created: [String: any OutputSender] = [:]
    private let host: String

    init(host: String) { self.host = host }

    func sender(_ id: String) -> (any OutputSender)? {
        lock.lock()
        defer { lock.unlock() }
        return created[id]
    }

    private func remember(_ sender: any OutputSender, as id: String) {
        lock.lock()
        created[id] = sender
        lock.unlock()
    }

    func makeSender(
        for request: BridgeEngine.OutputRequest, context: OutputSenderContext
    ) async throws -> any OutputSender {
        let sender: any OutputSender
        switch request.proto {
        case .raop:
            let port: UInt16 = request.deviceName == "closed" ? 1 : 5_000
            let device = RAOPDevice(
                serviceName: "000000000000@\(request.deviceName)", host: host, port: port,
                txt: ["et": "0,1", "cn": "0,1", "sr": "44100", "ss": "16", "ch": "2"]
            )
            sender = RAOPSender(
                device: device, ring: context.ring, captureFormat: context.captureFormat,
                clock: context.clock
            )
        case .airplay2:
            let txt = BonjourTXTQuery.lookup(fullName: "\(request.deviceName)._airplay._tcp.local.")
            let device = AirPlay2Device(
                serviceName: request.deviceName, host: host, port: 7_000, txt: txt
            )
            sender = AirPlay2Sender(
                device: device, ring: context.ring, captureFormat: context.captureFormat,
                clock: context.clock
            )
        }
        remember(sender, as: request.id)
        return sender
    }
}

@Suite(
    "Moteur contre les mocks",
    .serialized,
    .enabled(if: ProcessInfo.processInfo.environment["AUDIOCORE_MOCK_TESTS"] == "1")
)
struct BridgeEngineMockTests {
    private let raop = BridgeEngine.OutputRequest(
        id: "raop", proto: .raop, deviceName: "Geneva-Mock", volumeDB: -30
    )
    private let airplay2 = BridgeEngine.OutputRequest(
        id: "airplay2", proto: .airplay2, deviceName: "ApTV-HomePod-Mock", volumeDB: -30
    )

    private func makeLiveEngine(_ factory: DirectMockFactory) -> BridgeEngine {
        var dependencies = BridgeEngine.Dependencies.live
        dependencies.senderFactory = factory
        return BridgeEngine(dependencies: dependencies)
    }

    /// L'instant annoncé pour la trame courante vaut « maintenant » : c'est ce qu'annonce un
    /// sender ordinaire, et c'est ce qui rend l'alignement indépendant de la durée de négociation.
    /// Sans la graduation commune, une sortie ajoutée à chaud annoncerait une date passée de toute
    /// la durée de la session.
    private func expectAnchorIsCurrent(_ sender: any OutputSender, label: String) {
        let synchronizer = sender.synchronizer
        guard let anchor = synchronizer.syncAnchorUnixTime(
            latencyFrames: UInt32(SharedPlaybackClock.defaultPlayoutDelaySeconds * 44_100)) else {
            Issue.record("\(label) : ancrage indisponible")
            return
        }
        let lag = Date().timeIntervalSince1970 - anchor
        #expect(abs(lag) < 0.25, "\(label) : l'ancrage retarde de \(lag) s sur le direct")
    }

    @Test("Ajout et retrait à chaud sur les vrais senders, sans perturber l'autre sortie")
    func hotPlugAgainstMocks() async throws {
        let factory = DirectMockFactory(host: try #require(localAddress()))
        let engine = makeLiveEngine(factory)

        try await engine.start(
            source: .tone(frequency: 440, levelDBFS: -50), outputs: [airplay2]
        )
        #expect(await eventually(timeout: .seconds(20)) {
            await engine.phase(of: "airplay2") == .streaming
        })

        // Une session déjà bien entamée : la sortie ajoutée n'en a rien vu.
        try await Task.sleep(for: .seconds(4))
        let packetsBeforeAdd = try #require(await engine.snapshot(of: "airplay2")).packetsSent
        #expect(packetsBeforeAdd > 300)

        try await engine.addOutput(raop)
        #expect(await eventually(timeout: .seconds(20)) {
            await engine.phase(of: "raop") == .streaming
        })
        try await Task.sleep(for: .seconds(3))

        let afterAdd = try #require(await engine.snapshot(of: "airplay2"))
        let added = try #require(await engine.snapshot(of: "raop"))
        #expect(afterAdd.packetsSent > packetsBeforeAdd + 200)
        #expect(afterAdd.errors == 0)
        #expect(afterAdd.statistics.reconnections == 0)
        #expect(added.packetsSent > 200)
        #expect(added.statistics.anchoredSyncPackets == added.statistics.syncPacketsSent)
        #expect(added.sync?.receiverLatencySeconds ?? 0 > 0)

        expectAnchorIsCurrent(try #require(factory.sender("airplay2")), label: "AirPlay 2")
        expectAnchorIsCurrent(try #require(factory.sender("raop")), label: "RAOP")

        // Réglages poussés en pleine diffusion.
        await engine.setVolume(-25, for: "raop")
        await engine.setManualDelay(0.05, for: "raop")
        try await Task.sleep(for: .milliseconds(200))
        #expect(try #require(factory.sender("raop")).synchronizer.manualOffsetSeconds == 0.05)
        #expect(await engine.phase(of: "raop") == .streaming)

        // Retrait : TEARDOWN, sans toucher à l'autre sortie.
        let clock = ContinuousClock()
        let removal = await clock.measure { await engine.removeOutput(id: "raop") }
        #expect(removal < .seconds(4))
        #expect(await engine.outputOrder == ["airplay2"])

        let beforeRemainder = try #require(await engine.snapshot(of: "airplay2")).packetsSent
        try await Task.sleep(for: .seconds(2))
        let remainder = try #require(await engine.snapshot(of: "airplay2"))
        #expect(remainder.packetsSent > beforeRemainder + 150)
        #expect(remainder.errors == 0)
        #expect(remainder.statistics.reconnections == 0)
        #expect(await engine.captureHealth.diagnosis == .healthy)

        let stopping = await clock.measure { await engine.stop() }
        #expect(stopping < .seconds(5))
        #expect(await !engine.isRunning)
    }

    @Test("Un récepteur injoignable est réessayé, et son retrait n'attend pas")
    func unreachableReceiverIsRetried() async throws {
        let factory = DirectMockFactory(host: try #require(localAddress()))
        let engine = makeLiveEngine(factory)
        let closed = BridgeEngine.OutputRequest(
            id: "closed", proto: .raop, deviceName: "closed", volumeDB: -30
        )
        try await engine.start(source: .tone(frequency: 440, levelDBFS: -50), outputs: [closed])
        #expect(await eventually(timeout: .seconds(15)) {
            if case .waitingForReceiver = await engine.phase(of: "closed") { return true }
            return false
        })
        let clock = ContinuousClock()
        let stopping = await clock.measure { await engine.stop() }
        #expect(stopping < .seconds(5))
    }
}
