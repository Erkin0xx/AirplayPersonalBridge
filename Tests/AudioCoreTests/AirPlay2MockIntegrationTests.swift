import Foundation
import Testing

@testable import AudioCore

/// Session complète contre le mock `airplay2-receiver`, lancé à part (`./run-mocks.sh`).
///
/// Jamais exécuté par défaut : `RUN_MOCK_TESTS=1 swift test --filter AirPlay2MockIntegrationTests`.
///
/// **Aucune découverte ici, à dessein.** `AirPlay2Discovery` résout les services par une connexion
/// TCP, et le réseau local porte de vrais HomePod et un vrai Apple TV qu'aucun test ne doit
/// solliciter. Le mock est donc joint directement à son adresse, celle de `en0` sur laquelle il
/// écoute ; seul son TXT est lu, par une simple question DNS. `MOCK_AIRPLAY2_HOST`/`_PORT` pour
/// viser ailleurs.
@Suite(
    "AirPlay 2 — session contre le mock",
    .enabled(if: ProcessInfo.processInfo.environment["RUN_MOCK_TESTS"] == "1"),
    .serialized
)
struct AirPlay2MockIntegrationTests {

    /// Le mock n'écoute que sur l'adresse de l'interface qu'on lui a donnée, jamais sur la boucle
    /// locale. Elle change d'un réseau à l'autre, d'où cette question plutôt qu'une constante.
    private func localAddress(of interface: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/ipconfig")
        process.arguments = ["getifaddr", interface]
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        // La fin de fichier dit que le process a terminé. `waitUntilExit()` peut bloquer à jamais,
        // sur un fil qui ne fait rien d'autre tourner (voir `RunMocksScriptTests`).
        let data = output.fileHandleForReading.readDataToEndOfFile()
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func mockDevice() throws -> AirPlay2Device {
        let environment = ProcessInfo.processInfo.environment
        let txt = BonjourTXTQuery.lookup(fullName: "ApTV-HomePod-Mock._airplay._tcp.local.")
        return AirPlay2Device(
            serviceName: "ApTV-HomePod-Mock",
            host: try environment["MOCK_AIRPLAY2_HOST"] ?? localAddress(of: "en0"),
            port: environment["MOCK_AIRPLAY2_PORT"].flatMap(UInt16.init) ?? 7000,
            txt: txt
        )
    }

    /// Pair-setup SRP refait contre l'implémentation de référence du mock, canal chiffré,
    /// `SETUP`, `RECORD`, flux, `feedback`, `TEARDOWN`. Le puits audio du mock plante sur `av` 18
    /// (voir `CLAUDE.md`) : la validation porte sur le protocole et le réseau, pas sur l'écoute.
    @Test("Négociation, flux et maintien de session contre le mock")
    func sessionComplete() async throws {
        let ring = AudioRingBuffer(capacityFrames: 48_000, channelCount: 2)
        let feeder = SineFeeder(ring: ring)
        feeder.start()
        defer { feeder.stop() }

        let sender = AirPlay2Sender(
            device: try mockDevice(),
            ring: ring,
            captureFormat: try SenderHarness.captureFormat(),
            reconnects: false
        )

        try await sender.start(volume: -20)
        #expect(await sender.state == .streaming)

        // Assez long pour plusieurs `feedback`, qui passent par le canal chiffré du mock.
        #expect(await waitUntil(timeout: .seconds(10)) { await sender.statistics.feedbackSent >= 3 })
        let statistics = await sender.statistics
        #expect(statistics.packetsSent > 500)
        #expect(statistics.syncPacketsSent > 0)
        #expect(statistics.errors == 0)
        #expect(statistics.feedbackRefused == 0)
        #expect(statistics.eventChannelConnected)
        #expect(await sender.state == .streaming)

        try await sender.setVolume(-10)
        await sender.stop()
        #expect(await sender.state == .idle)
    }
}
