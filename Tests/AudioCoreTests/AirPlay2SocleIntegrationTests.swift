import Foundation
import Testing

@testable import AudioCore

/// `RTSPClient` et `UDPChannel` servent aussi le sender AirPlay 2. Ce test vérifie, contre le vrai
/// mock `airplay2-receiver`, que tout ce qui passe par ce socle tient toujours : pair-setup en
/// HTTP/1.1 sans `CSeq`, bascule en chiffré, plists de `SETUP`, `RECORD`, `TEARDOWN`.
///
/// **Jamais lancé par défaut** : `RUN_AIRPLAY2_MOCK_TESTS=1 AIRPLAY2_MOCK_HOST=<ip en0> swift test
/// --filter AirPlay2SocleIntegration`. L'adresse est donnée explicitement, sans parcours Bonjour :
/// seul le TXT du mock est lu, par son nom complet.
///
/// Le puits audio du mock plante sur `av` 18 (voir `CLAUDE.md`) : il n'y a rien à écouter, la
/// validation porte sur le protocole.
@Suite(
    "Socle partagé, contre le mock AirPlay 2", .serialized,
    .enabled(if: ProcessInfo.processInfo.environment["RUN_AIRPLAY2_MOCK_TESTS"] == "1")
)
struct AirPlay2SocleIntegrationTests {
    @Test("Une session AirPlay 2 complète passe par le client RTSP et s'arrête proprement")
    func fullSession() async throws {
        let host = try #require(ProcessInfo.processInfo.environment["AIRPLAY2_MOCK_HOST"])
        let txt = await Task {
            BonjourTXTQuery.lookup(fullName: "ApTV-HomePod-Mock._airplay._tcp.local.")
        }.value
        try #require(!txt.isEmpty, "le mock n'est pas annoncé")

        let format = try #require(captureFormat())
        let ring = AudioRingBuffer(capacityFrames: 48_000, channelCount: 2)
        let feeder = ToneFeeder(ring: ring, format: format, hz: 440, amplitude: 0.00316)
        defer { feeder.stop() }

        let device = AirPlay2Device(
            serviceName: "ApTV-HomePod-Mock", host: host, port: 7000, txt: txt
        )
        let sender = AirPlay2Sender(
            device: device, ring: ring, captureFormat: format, reconnects: false
        )
        try await sender.start(volume: -30)
        let state = await sender.state
        #expect(state == .streaming)

        try await Task.sleep(for: .seconds(4))
        try await sender.setVolume(-25)
        let statistics = await sender.statistics
        #expect(statistics.packetsSent > 300)

        let start = ContinuousClock.now
        await sender.stop()
        #expect(secondsSince(start) < 3)
        let stopped = await sender.state
        #expect(stopped == .idle)
        print("AIRPLAY2: paquets \(statistics.packetsSent), erreurs \(statistics.errors)")
    }
}
