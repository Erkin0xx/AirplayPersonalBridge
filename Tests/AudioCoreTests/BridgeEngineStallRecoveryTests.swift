import AVFoundation
import Foundation
import Testing

@testable import AudioCore

private let tone = BridgeEngine.Source.tone(frequency: 440, levelDBFS: -50)

@Suite("Moteur : capture bloquée")
struct BridgeEngineStallRecoveryTests {
    private func started(
        expectation: Bool?
    ) async throws -> (BridgeEngine, ManualCaptureSource, FakeSenderFactory, Date) {
        let source = ManualCaptureSource()
        source.expectation = expectation
        let factory = FakeSenderFactory()
        let engine = makeEngine(source: source, factory: factory)
        try await engine.start(source: tone, outputs: [request("a")])
        #expect(await eventually { await engine.phase(of: "a") == .streaming })
        source.push(frames: 480)
        let start = Date()
        await engine.tickHealth(now: start)
        return (engine, source, factory, start)
    }

    /// Aucune notification de route, et l'alerte promettait un nouvel essai que rien ne lançait.
    @Test("Bloquée pendant qu'une application joue : reconstruite, sans toucher aux sorties")
    func stalledWhilePlayingIsRebuilt() async throws {
        let (engine, source, factory, start) = try await started(expectation: true)

        await engine.tickHealth(now: start.addingTimeInterval(3))
        #expect(source.prepareCount == 1, "trop tôt pour y toucher")
        #expect(await engine.captureHealth.diagnosis == .stalled)
        #expect(await engine.captureHealth.nextStallRebuild != nil)

        await engine.tickHealth(now: start.addingTimeInterval(5))
        #expect(await eventually { await engine.captureHealth.rebuilds == 1 })
        #expect(source.prepareCount == 2)
        #expect(await factory.latest("a")?.stopCount == 0)
        #expect(factory.senders("a").count == 1)

        // Reconstruire ne suffit pas à dire que tout va bien : aucun bloc n'est encore revenu.
        await engine.tickHealth(now: start.addingTimeInterval(6))
        #expect(await engine.captureHealth.diagnosis == .stalled)
        #expect(await engine.captureHealth.stalledSince == start)
        await engine.stop()
    }

    @Test("Bloquée sans fin : les essais s'espacent, sans boucle")
    func repeatedStallBacksOff() async throws {
        let (engine, _, _, start) = try await started(expectation: true)
        var attempts: [Int] = []
        // Essais attendus à 5, 15, 35 et 75 s, le délai doublant de 5 s à chaque fois.
        for second in 1...120 {
            await engine.tickHealth(now: start.addingTimeInterval(Double(second)))
            #expect(await eventually { await !engine.isRebuildingCapture })
            let rebuilds = await engine.captureHealth.rebuilds
            if rebuilds > attempts.count { attempts.append(second) }
        }
        #expect(attempts == [5, 15, 35, 75])
        await engine.stop()
    }

    @Test("Les blocs reviennent : le suivi repart de zéro")
    func flowResetsRecovery() async throws {
        let (engine, source, _, start) = try await started(expectation: true)
        await engine.tickHealth(now: start.addingTimeInterval(5))
        #expect(await eventually { await engine.captureHealth.rebuilds == 1 })

        source.push(frames: 480)
        let later = start.addingTimeInterval(7)
        await engine.tickHealth(now: later)
        #expect(await engine.captureHealth.nextStallRebuild == nil)
        #expect(await engine.captureHealth.diagnosis == .healthy)

        // Nouvel arrêt : le premier essai revient au bout du délai initial, pas du délai doublé.
        await engine.tickHealth(now: later.addingTimeInterval(5))
        #expect(await eventually { await engine.captureHealth.rebuilds == 2 })
        await engine.stop()
    }

    /// Le tap ne livre rien quand rien ne joue, et mettre la musique en pause n'est pas une panne.
    @Test("Plus aucun bloc parce que rien ne joue : ni reconstruction, ni alerte de panne")
    func nothingPlayingIsNotAStall() async throws {
        let (engine, source, _, start) = try await started(expectation: false)
        for second in 1...30 {
            await engine.tickHealth(now: start.addingTimeInterval(Double(second)))
        }
        #expect(source.prepareCount == 1)
        #expect(await engine.captureHealth.diagnosis == .silentNothingPlaying)
        #expect(await engine.captureHealth.nextStallRebuild == nil)
        await engine.stop()
    }

    /// Plus rien ne joue, mais si la dernière reconstruction a échoué, ce n'est pas « rien à signaler ».
    @Test("Une reconstruction en échec reste dite, même si rien ne joue")
    func failedRebuildStaysVisible() async throws {
        let (engine, source, _, start) = try await started(expectation: false)
        source.preparesToFail = 1_000
        source.fireRouteChange()
        #expect(await eventually { await engine.captureHealth.lastRebuildError != nil })

        await engine.tickHealth(now: start.addingTimeInterval(5))
        #expect(await engine.captureHealth.diagnosis == .stalled)
        await engine.stop()
    }

    /// L'entrée physique ne sait pas dire si quelque chose joue. Rien n'est tenté, et donc rien n'est
    /// promis : c'est ce qui permet à l'alerte de ne pas mentir.
    @Test("Sans savoir si quelque chose joue : aucune reconstruction, et aucune d'annoncée")
    func unknownExpectationPromisesNothing() async throws {
        let (engine, source, _, start) = try await started(expectation: nil)
        for second in 1...30 {
            await engine.tickHealth(now: start.addingTimeInterval(Double(second)))
        }
        #expect(source.prepareCount == 1)
        #expect(await engine.captureHealth.diagnosis == .stalled)
        #expect(await engine.captureHealth.nextStallRebuild == nil)
        await engine.stop()
    }

    /// Chaque reconstruction repart de zéro sur le suivi des trous : celui qui attendait encore sa
    /// confirmation, s'il était oublié, s'ajouterait au retard à chaque tentative, jusqu'à manger les
    /// 2 s de marge, au pire au bout d'une dizaine.
    @Test("Les reconstructions d'une capture bloquée ne mangent pas la marge de restitution")
    func stallRebuildsKeepClockCurrent() async throws {
        let source = ManualCaptureSource()
        source.expectation = true
        let factory = FakeSenderFactory()
        var tuning = BridgeEngine.Tuning.fast
        tuning.stallThresholdSeconds = 0.02
        tuning.stallRebuildDelaySeconds = 0.1
        tuning.stallRebuildMaximumDelaySeconds = 0.1
        tuning.interruptionThresholdSeconds = 0.05
        let engine = makeEngine(source: source, factory: factory, tuning: tuning)
        try await engine.start(source: tone, outputs: [request("a")])
        #expect(await eventually { factory.latest("a") != nil })
        let clock = try #require(factory.latest("a")).context.clock
        source.push(frames: 480)
        await engine.tickHealth()

        for _ in 0..<20 {
            try await Task.sleep(for: .milliseconds(100))
            await engine.tickHealth()
        }
        #expect(await engine.captureHealth.rebuilds >= 5)

        let instant = try #require(clock.presentationUnixTime(forCaptureFrame: 480))
        let lag = Date().timeIntervalSince1970 + clock.playoutDelaySeconds - instant
        #expect(abs(lag) < 0.5, "l'horloge retarde de \(lag) s")
        await engine.stop()
    }
}
