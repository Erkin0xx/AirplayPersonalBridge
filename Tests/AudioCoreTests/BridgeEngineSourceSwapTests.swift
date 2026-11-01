import AVFoundation
import Foundation
import Testing

@testable import AudioCore

private let tone = BridgeEngine.Source.tone(frequency: 440, levelDBFS: -50)

@Suite("Moteur : changement de source")
struct BridgeEngineSourceSwapTests {
    /// Une suite de sources, données dans l'ordre à chaque demande du moteur.
    private final class SourceQueue: @unchecked Sendable {
        private let lock = NSLock()
        private var remaining: [ManualCaptureSource]

        init(_ sources: [ManualCaptureSource]) { remaining = sources }

        func next() -> ManualCaptureSource {
            lock.withLock { remaining.count > 1 ? remaining.removeFirst() : remaining[0] }
        }
    }

    private func makeEngine(
        _ sources: [ManualCaptureSource], factory: FakeSenderFactory
    ) -> BridgeEngine {
        let queue = SourceQueue(sources)
        return BridgeEngine(
            dependencies: BridgeEngine.Dependencies(
                makeSource: { _, _ in queue.next() },
                senderFactory: factory,
                permissions: FakePermissions(),
                tuning: .fast
            )
        )
    }

    /// Un navigateur qui joue depuis un nouveau processus : seul le tap change, les sessions des
    /// sorties continuent, et il n'y a jamais deux captures à la fois.
    @Test("Une nouvelle source prend le relais sans toucher aux sorties")
    func swapKeepsOutputs() async throws {
        let ledger = CaptureLedger()
        let first = ManualCaptureSource(ledger: ledger)
        let second = ManualCaptureSource(ledger: ledger)
        let factory = FakeSenderFactory()
        let engine = makeEngine([first, second], factory: factory)
        try await engine.start(source: tone, outputs: [request("a")])
        #expect(await eventually { await engine.phase(of: "a") == .streaming })
        let sender = try #require(factory.latest("a"))
        first.push(frames: 1_000)

        #expect(await engine.replaceCapture(with: .inputDevice))

        #expect(first.stopCount == 1)
        #expect(second.startCount == 1)
        #expect(ledger.maximumActive == 1)
        #expect(await sender.stopCount == 0)
        #expect(factory.senders("a").count == 1)
        #expect(!first.hasRouteHandler)
        #expect(second.hasRouteHandler)

        // Le flux continue sur le même tampon, et le relevé suivant regarde la bonne source.
        #expect(second.push(frames: 100))
        #expect(!first.push(frames: 100))
        #expect(sender.context.ring.totalFramesWritten == 1_100)
        #expect(await engine.phase(of: "a") == .streaming)

        await engine.stop()
        #expect(ledger.activeCount == 0)
    }

    @Test("Une nouvelle source qui ne démarre pas laisse l'ancienne en place")
    func failedSwapKeepsCapture() async throws {
        let ledger = CaptureLedger()
        let first = ManualCaptureSource(ledger: ledger)
        let second = ManualCaptureSource(ledger: ledger)
        second.preparesToFail = 1_000
        let factory = FakeSenderFactory()
        let engine = makeEngine([first, second], factory: factory)
        try await engine.start(source: tone, outputs: [request("a")])
        #expect(await eventually { await engine.phase(of: "a") == .streaming })
        let sender = try #require(factory.latest("a"))

        #expect(await !engine.replaceCapture(with: .inputDevice))

        #expect(await eventually { first.startCount == 2 })
        #expect(first.hasRouteHandler)
        #expect(ledger.activeCount == 1)
        #expect(first.push(frames: 100))
        #expect(await sender.stopCount == 0)
        await engine.stop()
        #expect(ledger.activeCount == 0)
    }

    /// L'autorisation est demandée au démarrage : une source qui en exigerait une autre ne peut pas
    /// se glisser à la place de la première, et l'appelant passera par une relance complète.
    @Test("Une source qui exige une autre autorisation ne prend pas le relais")
    func swapRefusesOtherPermission() async throws {
        let first = ManualCaptureSource()
        let second = ManualCaptureSource(permission: .microphone)
        let engine = makeEngine([first, second], factory: FakeSenderFactory())
        try await engine.start(source: tone, outputs: [request("a")])

        #expect(await !engine.replaceCapture(with: .inputDevice))
        #expect(first.stopCount == 0)
        #expect(first.push(frames: 10))
        await engine.stop()
    }

    /// La file des transitions de l'interface attend cet appel : il ne doit pas rester bloqué sur une
    /// capture qui refuse de repartir, sans quoi le bouton d'arrêt ne répondrait plus.
    @Test("Une source qui ne démarre pas, ni l'ancienne : la main revient, et l'arrêt passe")
    func failedSwapDoesNotHoldStop() async throws {
        let ledger = CaptureLedger()
        let first = ManualCaptureSource(ledger: ledger)
        let second = ManualCaptureSource(ledger: ledger)
        second.preparesToFail = 1_000
        let engine = makeEngine([first, second], factory: FakeSenderFactory())
        try await engine.start(source: tone, outputs: [request("a")])

        first.preparesToFail = 1_000
        #expect(await !engine.replaceCapture(with: .inputDevice))
        #expect(await eventually { await engine.captureHealth.lastRebuildError != nil })

        await engine.stop()
        #expect(await !engine.isRunning)
        #expect(ledger.activeCount == 0)
    }

    @Test("Sans diffusion, rien à remplacer")
    func swapOutsideSession() async {
        let engine = makeEngine([ManualCaptureSource()], factory: FakeSenderFactory())
        #expect(await !engine.replaceCapture(with: .inputDevice))
    }

    /// Deux IO sur un même tampon, ce serait deux producteurs pour un ring buffer qui n'en admet
    /// qu'un. Et l'attendre retiendrait la file des transitions de l'interface, donc un arrêt demandé,
    /// tant que la capture refuse de repartir.
    @Test("Un changement de source pendant une reconstruction est refusé sans attendre")
    func swapRefusedDuringRebuild() async throws {
        let ledger = CaptureLedger()
        let first = ManualCaptureSource(ledger: ledger)
        let second = ManualCaptureSource(ledger: ledger)
        var tuning = BridgeEngine.Tuning.fast
        tuning.rebuildRetryInitialDelay = .milliseconds(50)
        tuning.rebuildRetryMaximumDelay = .milliseconds(50)
        let queue = SourceQueue([first, second])
        let engine = BridgeEngine(
            dependencies: BridgeEngine.Dependencies(
                makeSource: { _, _ in queue.next() },
                senderFactory: FakeSenderFactory(),
                permissions: FakePermissions(),
                tuning: tuning
            )
        )
        try await engine.start(source: tone, outputs: [request("a")])

        first.preparesToFail = 1_000
        first.fireRouteChange()
        #expect(await eventually { await engine.captureHealth.lastRebuildError != nil })

        #expect(await !engine.replaceCapture(with: .inputDevice))
        #expect(second.startCount == 0)

        // La reconstruction aboutie, il passe.
        first.preparesToFail = 0
        #expect(await eventually { await engine.captureHealth.rebuilds == 1 })
        #expect(await eventually { await !engine.isRebuildingCapture })
        #expect(await engine.replaceCapture(with: .inputDevice))
        #expect(ledger.maximumActive == 1)
        #expect(ledger.activeCount == 1)
        #expect(second.push(frames: 10))
        await engine.stop()
        #expect(ledger.activeCount == 0)
    }
}
