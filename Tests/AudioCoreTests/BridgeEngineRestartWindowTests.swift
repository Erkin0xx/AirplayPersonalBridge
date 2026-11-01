import AVFoundation
import Foundation
import Testing

@testable import AudioCore

private let tone = BridgeEngine.Source.tone(frequency: 440, levelDBFS: -50)

/// Une relance pour une nouvelle fréquence dure jusqu'à `stopTimeout` : tout ce que l'interface fait
/// pendant ce temps doit tenir une fois les sorties relancées.
@Suite("Moteur : gestes pendant une relance", .serialized)
struct BridgeEngineRestartWindowTests {
    private func makeHarness() -> (ManualCaptureSource, FakeSenderFactory, BridgeEngine) {
        let source = ManualCaptureSource(
            format: stereoFormat(sampleRate: 48_000),
            laterFormats: [stereoFormat(sampleRate: 96_000)]
        )
        let factory = FakeSenderFactory()
        // Un récepteur qui retient son TEARDOWN : c'est ce qui tient la fenêtre ouverte.
        factory.makeStopHang("a")
        var tuning = BridgeEngine.Tuning.fast
        tuning.stopTimeout = .milliseconds(600)
        return (source, factory, makeEngine(source: source, factory: factory, tuning: tuning))
    }

    private func finish(_ engine: BridgeEngine, _ factory: FakeSenderFactory) async {
        for sender in factory.senders("a") { await sender.releaseStop() }
        await engine.stop()
        for sender in factory.senders("a") { await sender.releaseStop() }
    }

    @Test("Une sortie décochée pendant la relance reste retirée, et se recoche sans erreur")
    func removedStaysRemoved() async throws {
        let (source, factory, engine) = makeHarness()
        try await engine.start(source: tone, outputs: [request("a"), request("b")])
        #expect(await eventually { await engine.phase(of: "a") == .streaming })
        #expect(await eventually { await engine.phase(of: "b") == .streaming })

        source.fireRouteChange()
        #expect(await eventually { await factory.senders("a")[0].stopCount >= 1 })

        await engine.removeOutput(id: "b")
        #expect(await engine.phase(of: "b") == nil)

        #expect(await eventually { await engine.captureHealth.rebuilds == 1 })
        try await Task.sleep(for: .milliseconds(100))
        #expect(await engine.outputs.map(\.id) == ["a"])
        #expect(factory.senders("b").count == 1)

        // Recocher : c'est ce qui finissait en `duplicateOutput`, la sortie à l'écran en panne.
        try await engine.addOutput(request("b"))
        await finish(engine, factory)
    }

    @Test("Un volume poussé pendant la relance n'est pas perdu")
    func volumeIsKept() async throws {
        let (source, factory, engine) = makeHarness()
        try await engine.start(source: tone, outputs: [request("a", volume: -20)])
        #expect(await eventually { await engine.phase(of: "a") == .streaming })

        source.fireRouteChange()
        #expect(await eventually { await factory.senders("a")[0].stopCount >= 1 })
        await engine.setVolume(-5, for: "a")

        #expect(await eventually { await engine.captureHealth.rebuilds == 1 })
        #expect(await eventually { factory.senders("a").count == 2 })
        #expect(await eventually { await factory.senders("a")[1].startedVolume != nil })
        let started = await factory.senders("a")[1].startedVolume
        let pushed = await factory.senders("a")[1].pushedVolumes
        #expect(started == -5 || pushed.last == -5)
        await finish(engine, factory)
    }

    /// Lancée sur l'ancien tampon puis oubliée, cette sortie gardait une session ouverte que ni le
    /// retrait ni l'arrêt ne pouvaient plus atteindre.
    @Test("Une sortie cochée pendant la relance part sur le nouveau format, et s'arrête avec le reste")
    func addedDuringRestartIsNotOrphaned() async throws {
        let (source, factory, engine) = makeHarness()
        try await engine.start(source: tone, outputs: [request("a")])
        #expect(await eventually { await engine.phase(of: "a") == .streaming })

        source.fireRouteChange()
        #expect(await eventually { await factory.senders("a")[0].stopCount >= 1 })
        try await engine.addOutput(request("c"))
        #expect(await engine.phase(of: "c") == .connecting)

        #expect(await eventually { await engine.captureHealth.rebuilds == 1 })
        #expect(await eventually { await engine.phase(of: "c") == .streaming })
        #expect(factory.senders("c").count == 1)
        let added = try #require(factory.latest("c"))
        #expect(added.context.captureFormat.sampleRate == 96_000)

        await engine.removeOutput(id: "c")
        #expect(await added.stopCount >= 1)
        #expect(await engine.phase(of: "c") == nil)
        await finish(engine, factory)
    }

    /// La relance échoue sur la nouvelle fréquence et la suivante retombe sur l'ancienne : la capture
    /// repartait, sans plus personne pour relancer les sorties déjà arrêtées.
    @Test("Une relance ratée puis un retour à l'ancienne fréquence ne laissent pas les sorties au repos")
    func failedRestartThenOldRate() async throws {
        let source = ManualCaptureSource(
            format: stereoFormat(sampleRate: 48_000),
            laterFormats: [stereoFormat(sampleRate: 96_000), stereoFormat(sampleRate: 48_000)]
        )
        let factory = FakeSenderFactory()
        let engine = makeEngine(source: source, factory: factory)
        try await engine.start(source: tone, outputs: [request("a", volume: -20)])
        #expect(await eventually { await engine.phase(of: "a") == .streaming })
        await engine.setVolume(-5, for: "a")

        source.startsToFail = 1
        source.fireRouteChange()

        #expect(await eventually { await engine.captureHealth.rebuilds == 1 })
        #expect(await eventually { await engine.phase(of: "a") == .streaming })
        #expect(factory.senders("a").count == 2)
        let replacement = try #require(factory.latest("a"))
        #expect(replacement.context.captureFormat.sampleRate == 48_000)
        #expect(await replacement.startedVolume == -5)
        await engine.stop()
    }
}
