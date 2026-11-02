import Foundation
import Testing

@testable import AudioCore

private let tone = BridgeEngine.Source.tone(frequency: 440, levelDBFS: -50)

private func levelRequest(
    _ id: String, proto: BridgeEngine.OutputProtocol, level: OutputLevel
) -> BridgeEngine.OutputRequest {
    BridgeEngine.OutputRequest(
        id: id, proto: proto, deviceName: id, volumeDB: -12, outputLevel: level
    )
}

/// Le niveau propre d'une sortie (gain numérique et silence), tel que le moteur le fait suivre : calqué
/// sur le volume et le renfort de basses, rattrapage de la négociation compris.
@Suite("Moteur : gain et silence d'une sortie")
struct BridgeEngineOutputLevelTests {
    @Test(
        "Le niveau part avant la connexion, puis suit les changements, sur les deux protocoles",
        arguments: [BridgeEngine.OutputProtocol.raop, .airplay2]
    )
    func levelReachesSender(proto: BridgeEngine.OutputProtocol) async throws {
        let factory = FakeSenderFactory()
        let engine = makeEngine(source: ManualCaptureSource(), factory: factory)
        let start = OutputLevel(gainDB: -6)
        try await engine.start(
            source: tone, outputs: [levelRequest("a", proto: proto, level: start)]
        )
        #expect(await eventually { await engine.phase(of: "a") == .streaming })
        let sender = try #require(factory.latest("a"))
        #expect(await sender.startedLevel == start)

        let muted = OutputLevel(gainDB: -6, isMuted: true)
        await engine.setOutputLevel(muted, for: "a")
        #expect(await sender.pushedLevels.last == muted)
        await engine.setOutputLevel(muted, for: "inconnue")

        // Ni volume, ni délai, ni renfort, ni relance : le niveau seul.
        #expect(await sender.pushedVolumes.isEmpty)
        #expect(await sender.stopCount == 0)
        #expect(factory.senders("a").count == 1)
        #expect(await engine.phase(of: "a") == .streaming)
        await engine.stop()
    }

    @Test("Sans consigne, la sortie part à l'unité : l'étage est contourné")
    func defaultIsUnity() async throws {
        let factory = FakeSenderFactory()
        let engine = makeEngine(source: ManualCaptureSource(), factory: factory)
        try await engine.start(source: tone, outputs: [request("a")])
        #expect(await eventually { await engine.phase(of: "a") == .streaming })
        let sender = try #require(factory.latest("a"))
        #expect(await sender.startedLevel == .unity)
        await engine.stop()
    }

    @Test("Le niveau réglé pendant la négociation est appliqué à la connexion, et survit au sender")
    func levelDuringNegotiationIsApplied() async throws {
        let factory = FakeSenderFactory()
        factory.script("a", [.hang])
        let engine = makeEngine(source: ManualCaptureSource(), factory: factory)
        try await engine.start(
            source: tone, outputs: [levelRequest("a", proto: .airplay2, level: .unity)]
        )
        #expect(await eventually {
            guard let sender = factory.latest("a") else { return false }
            return await sender.isNegotiating
        })

        let muted = OutputLevel(gainDB: -3, isMuted: true)
        await engine.setOutputLevel(muted, for: "a")
        let first = try #require(factory.latest("a"))
        #expect(await first.pushedLevels == [.unity])
        await first.releaseStart()
        #expect(await eventually { await first.pushedLevels.last == muted })

        // Un sender abandonné est remplacé : le suivant repart de la dernière consigne.
        await first.setState(.failed)
        #expect(await eventually { factory.senders("a").count == 2 })
        let second = try #require(factory.latest("a"))
        #expect(await eventually { await second.startedLevel == muted })
        await engine.stop()
    }

    @Test("Une sortie ajoutée à chaud part de son niveau")
    func hotAddStartsFromLevel() async throws {
        let factory = FakeSenderFactory()
        let engine = makeEngine(source: ManualCaptureSource(), factory: factory)
        try await engine.start(source: tone, outputs: [request("a")])
        let level = OutputLevel(gainDB: -4.5)
        try await engine.addOutput(levelRequest("b", proto: .airplay2, level: level))
        #expect(await eventually { await engine.phase(of: "b") == .streaming })
        let sender = try #require(factory.latest("b"))
        #expect(await sender.startedLevel == level)
        let other = try #require(factory.latest("a"))
        #expect(await other.pushedLevels == [.unity])
        await engine.stop()
    }
}
