import Foundation
import Network
import Testing

/// Garde-fou : une écoute de test sur un port éphémère fait échouer d'autres tests, par séries et
/// sans rapport apparent, avec une `NWConnection` refusée sur `EADDRINUSE` (voir `LateTCPPort`).
@Suite("Écoutes de test")
struct TestListenerPortTests {
    private static let ephemeral: ClosedRange<UInt16> = 49_152...65_535

    @Test("Les faux récepteurs écoutent hors de la plage éphémère")
    func fakeReceiversAvoidEphemeralPorts() async throws {
        let raop = try await FakeRAOPReceiver()
        defer { raop.shutdown() }
        #expect(raop.port != 0)
        #expect(!Self.ephemeral.contains(raop.port), "\(raop.port)")

        let airplay2 = FakeAirPlay2Receiver()
        try await airplay2.start()
        defer { airplay2.stop() }
        #expect(airplay2.port != 0)
        #expect(!Self.ephemeral.contains(airplay2.port), "\(airplay2.port)")
    }

    /// `NWListener` échoue parfois sur `EADDRINUSE` : sans repli, un faux récepteur ne répondait
    /// jamais à son `SETUP`, et un test sans rapport échouait 10 s plus tard. Provoqué ici sur un
    /// port réellement pris.
    @Test("Une écoute refusée passe au port suivant, et elle fonctionne")
    func refusedListenerMovesToAnotherPort() async throws {
        let taken = try LateTCPPort()
        try taken.open()

        let opened = try await startLoopbackListener(
            on: DispatchQueue(label: "test.listener-fallback"), firstPort: taken.port
        ) { $0.cancel() }
        defer { opened.listener.cancel() }

        #expect(opened.port != taken.port)
        #expect(!Self.ephemeral.contains(opened.port), "\(opened.port)")
        #expect(opened.listener.state == .ready)
    }

    /// Deux tests parallèles ne doivent pas se disputer un port entre sa vérification et son
    /// ouverture, ce qui ferait échouer l'une des deux écoutes.
    @Test("Un même process ne se voit jamais proposer deux fois le même port")
    func portsAreNotHandedOutTwice() throws {
        let ports = try (0..<200).map { _ in try LateTCPPort().port }
        #expect(Set(ports).count == ports.count)
        #expect(!ports.contains { Self.ephemeral.contains($0) })
    }

    /// Les écoutes privées à leur fichier de test échappent au premier test : c'est leur code qu'on
    /// lit. Le motif est découpé pour que ce fichier ne se signale pas lui-même.
    @Test("Aucune écoute de test ne demande un port quelconque au système")
    func noListenerAsksForAnyPort() throws {
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let forbidden = ["port: " + ".any)", "on: " + ".any)"]
        var offenders: [String] = []
        let files = try FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil
        )
        for file in files where file.pathExtension == "swift" {
            let text = try String(contentsOf: file, encoding: .utf8)
            for pattern in forbidden where text.contains(pattern) {
                offenders.append("\(file.lastPathComponent) : \(pattern)")
            }
        }
        #expect(files.count > 20, "le parcours n'a pas trouvé les tests")
        #expect(offenders.isEmpty, "\(offenders)")
    }
}
