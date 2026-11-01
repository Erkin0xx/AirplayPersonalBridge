import AVFoundation
import Foundation
import Testing

@testable import AudioCore

/// Sessions contre le vrai mock Geneva (`shairport-sync`, 127.0.0.1:5000).
///
/// **Jamais lancés par défaut** : `RUN_MOCK_TESTS=1 swift test --filter RAOPMockIntegration`,
/// après avoir démarré le mock (`shairport-sync` seul suffit, il quitte à chaque `TEARDOWN`).
/// Ils ne passent pas par la découverte Bonjour, qui contacterait les vrais appareils du réseau.
///
/// Le niveau est de −50 dBFS, car shairport-sync joue sur les haut-parleurs du Mac. Pour juger le
/// son lui-même, lancer le mock avec `shairport-sync -o stdout > sortie.pcm` : plus rien ne
/// sort des haut-parleurs, et `RAOP_MOCK_LEVEL` permet de monter le niveau.
///
/// La durée se règle par `RAOP_MOCK_SECONDS` (10 s par défaut). L'échec historique survenait à
/// 25 s environ (`Bus error: 10`) : une session de validation doit donc durer plus longtemps.
/// Le résultat se lit dans le journal du mock, que ces tests ne peuvent pas juger seuls :
/// `client announced rsaaeskey`, `FIXME: unhandled prediction type` ou la mort du processus.
@Suite(
    "Intégration contre le mock Geneva", .serialized,
    .enabled(if: ProcessInfo.processInfo.environment["RUN_MOCK_TESTS"] == "1")
)
struct RAOPMockIntegrationTests {
    private static let levelMinus50dBFS: Float = 0.00316

    private var level: Float {
        ProcessInfo.processInfo.environment["RAOP_MOCK_LEVEL"].flatMap(Float.init)
            ?? Self.levelMinus50dBFS
    }

    private var volume: Float {
        ProcessInfo.processInfo.environment["RAOP_MOCK_VOLUME"].flatMap(Float.init) ?? -30
    }

    private var sessionSeconds: Int {
        ProcessInfo.processInfo.environment["RAOP_MOCK_SECONDS"].flatMap(Int.init) ?? 10
    }

    /// Variante choisie par `RAOP_MOCK_VARIANT`, le mock devant être relancé entre deux sessions.
    private var txt: [String: String] {
        let base = ["sr": "44100", "ss": "16", "ch": "2"]
        switch ProcessInfo.processInfo.environment["RAOP_MOCK_VARIANT"] ?? "announced" {
        case "clear-pcm": return base.merging(["et": "0", "cn": "0"]) { $1 }
        case "clear-alac": return base.merging(["et": "0", "cn": "1"]) { $1 }
        case "rsa-pcm": return base.merging(["et": "1", "cn": "0"]) { $1 }
        case "rsa-pcm-both": return base.merging(["et": "1", "cn": "0,1"]) { $1 }
        case "rsa-alac": return base.merging(["et": "1", "cn": "1"]) { $1 }
        default: return base.merging(["et": "0,1", "cn": "0,1"]) { $1 }
        }
    }

    /// Passif pour tous les autres appareils : `find` ne contacte que celui qu'il retient.
    @Test("La découverte trouve le mock par son nom affiché, TXT compris, sans attendre le délai")
    func discovery() async throws {
        let start = ContinuousClock.now
        let device = try await RAOPDiscovery().find(named: "Geneva-Mock")
        #expect(secondsSince(start) < 4, "le parcours doit s'arrêter dès le nom exact trouvé")
        #expect(device.displayName == "Geneva-Mock")
        #expect(device.port == 5000)
        #expect(UDPChannel.isIPv4Literal(device.host), "\(device.host)")
        #expect(device.supportsUnencrypted)
        #expect(device.supportsRSAEncryption)
        #expect(device.supportsPCM)
        #expect(device.supportsALAC)
    }

    @Test("Une session complète tient, et le mock reste en vie jusqu'au TEARDOWN")
    func fullSession() async throws {
        let format = try #require(captureFormat())
        let ring = AudioRingBuffer(capacityFrames: 48_000, channelCount: 2)
        let feeder = ToneFeeder(ring: ring, format: format, hz: 440, amplitude: level)
        defer { feeder.stop() }

        let device = RAOPDevice(
            serviceName: "65D15B6D3AC1@Geneva-Mock", host: "127.0.0.1", port: 5000, txt: txt
        )
        let sender = RAOPSender(
            device: device, ring: ring, captureFormat: format, reconnects: false
        )
        if let loss = ProcessInfo.processInfo.environment["RAOP_MOCK_LOSS"].flatMap(Int.init) {
            await sender.simulateLoss(everyNthPacket: loss)
        }
        try await sender.start(volume: volume)

        let deadline = ContinuousClock.now + .seconds(sessionSeconds)
        while ContinuousClock.now < deadline {
            try await Task.sleep(for: .seconds(1))
            let state = await sender.state
            let problem = await sender.lastErrorMessage ?? "?"
            #expect(state == .streaming, "session tombée : \(problem)")
            if state != .streaming { break }
        }

        let statistics = await sender.statistics
        await sender.stop()
        #expect(statistics.packetsSent > sessionSeconds * 100)
        #expect(statistics.reconnections == 0)
        print(
            """
            MOCK: paquets \(statistics.packetsSent), erreurs \(statistics.errors), \
            maintien accepté \(statistics.keepAliveSupported) (\(statistics.keepAlivesSent) envoyés), \
            retransmissions \(statistics.packetsRetransmitted)/\(statistics.retransmitRequests), \
            horloge \(statistics.timingResponsesSent), latence \(statistics.reportedLatencyFrames)
            """
        )
    }
}
