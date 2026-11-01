import AudioCore
import Foundation
import Testing

@testable import BridgeApp

/// Ce que décide le suivi des processus, sans moteur.
@Suite("Source — processus à suivre")
struct CaptureSourceFollowTargetTests {
    private func music(_ pids: [pid_t]) -> CaptureSource {
        .application(pids: pids, name: "Music", bundleID: "com.apple.Music")
    }

    private func target(
        preferred: String? = nil, current: CaptureSource, available: [CaptureSource],
        dead: Set<pid_t> = []
    ) -> CaptureSource? {
        CaptureSource.followTarget(
            preferredID: preferred ?? music([]).id, current: current,
            available: available + [.systemWide, .inputDevice],
            isProcessAlive: { !dead.contains($0) }
        )
    }

    @Test("Un nouveau processus rejoint la capture")
    func newProcessJoins() {
        #expect(target(current: music([1]), available: [music([1, 2])]) == music([1, 2]))
    }

    @Test("Un processus parti ne suit pas")
    func deadProcessIsDropped() {
        #expect(target(current: music([1]), available: [music([2])], dead: [1]) == music([2]))
    }

    /// Le tap continue de le suivre, sans rien coûter. Le relancer couperait le son pour rien.
    @Test("Un processus qui s'arrête ne change rien")
    func stoppedProcessChangesNothing() {
        #expect(target(current: music([1, 2]), available: [music([1])]) == nil)
        #expect(target(current: music([1]), available: [music([1])]) == nil)
    }

    /// La pause d'une application ne doit pas relancer la capture sur tout le son du Mac.
    @Test("Une application en pause ne fait rien bouger")
    func pausedApplicationStays() {
        #expect(target(current: music([1]), available: []) == nil)
    }

    @Test("Une application choisie revient quand elle rejoue")
    func preferredComesBack() {
        #expect(target(current: .systemWide, available: [music([7])]) == music([7]))
        #expect(target(current: .systemWide, available: []) == nil)
    }

    @Test("Rien à suivre sur le mode global")
    func nothingToFollowOnGlobal() {
        #expect(
            target(
                preferred: CaptureSource.systemWide.id, current: .systemWide, available: [music([7])]
            ) == nil)
    }

    /// Deux processus qui jouent à tour de rôle, sans jamais se chevaucher, faisaient alterner la
    /// capture à chaque fois : tous deux vivants, ils restent acquis.
    @Test("Deux processus qui se relaient ne font changer la capture qu'une fois")
    func alternatingProcessesSettle() {
        let first = target(current: music([1]), available: [music([2])])
        #expect(first == music([1, 2]))
        #expect(target(current: music([1, 2]), available: [music([1])]) == nil)
        #expect(target(current: music([1, 2]), available: [music([2])]) == nil)
    }

    @Test("Le rythme des changements ralentit quand ils s'enchaînent, et revient au calme")
    func pacerBacksOff() {
        var pacer = SourceFollowPacer(minimum: .seconds(5), maximum: .seconds(20))
        let start = ContinuousClock.now
        #expect(pacer.allows(at: start))

        pacer.noteChange(at: start)
        #expect(!pacer.allows(at: start + .seconds(4)))
        #expect(pacer.allows(at: start + .seconds(5)))

        pacer.noteChange(at: start + .seconds(5))
        #expect(!pacer.allows(at: start + .seconds(14)))
        #expect(pacer.allows(at: start + .seconds(15)))

        pacer.noteChange(at: start + .seconds(15))
        pacer.noteChange(at: start + .seconds(35))
        #expect(!pacer.allows(at: start + .seconds(54)), "plafonné à 20 s")
        #expect(pacer.allows(at: start + .seconds(55)))

        // Après un moment calme, on revient au minimum.
        pacer.noteChange(at: start + .seconds(1_000))
        #expect(pacer.allows(at: start + .seconds(1_005)))
    }
}

/// La capture suit une application pendant la diffusion, sans toucher aux sorties.
@Suite("État — suivi des processus", .serialized)
struct BridgeStateSourceFollowTests {
    private let music = CaptureSource.application(
        pids: [42], name: "Music", bundleID: "com.apple.Music"
    )

    private func capturedPIDs(_ harness: BridgeHarness) -> [pid_t]? {
        guard case let .processTap(mode)? = harness.captures.last?.source,
            case let .processes(pids) = mode
        else { return nil }
        return pids
    }

    private func streamingMusic() async -> BridgeHarness {
        let harness = BridgeHarness()
        harness.sources = [.systemWide, music, .inputDevice]
        harness.state.refreshSources()
        harness.state.selectSource(id: music.id)
        await harness.discover(raop: [Devices.genevaRAOP])
        await harness.startStreaming(expecting: [Devices.genevaID])
        return harness
    }

    /// Le tap restait sur l'ancien PID, les enceintes muettes, et l'alerte promettait que le son
    /// partirait dès qu'une lecture commencerait.
    @Test("Des PID renouvelés en pleine diffusion relancent la capture, pas les sorties")
    func renewedPIDsAreFollowed() async throws {
        let harness = await streamingMusic()
        let sender = try #require(harness.factory.latest(Devices.genevaID))

        harness.deadPIDs = [42]
        let renewed = CaptureSource.application(
            pids: [77], name: "Music", bundleID: "com.apple.Music"
        )
        harness.sources = [.systemWide, renewed, .inputDevice]

        #expect(await eventually { harness.captures.count == 2 })
        #expect(capturedPIDs(harness) == [77])
        #expect(await eventually { harness.state.selectedSource == renewed })

        // Les sessions n'ont rien vu.
        #expect(await sender.stopCount == 0)
        #expect(harness.factory.senders(Devices.genevaID).count == 1)
        #expect(harness.state.isStreaming)
        #expect(!harness.state.isRestarting)
        await harness.stopStreaming()
    }

    @Test("Un processus de plus, l'ancien toujours là : les deux sont captés")
    func addedProcessIsFollowed() async throws {
        let harness = await streamingMusic()
        harness.sources = [
            .systemWide,
            .application(pids: [42, 77], name: "Music", bundleID: "com.apple.Music"),
            .inputDevice,
        ]
        #expect(await eventually { harness.captures.count == 2 })
        #expect(capturedPIDs(harness) == [42, 77])
        await harness.stopStreaming()
    }

    /// Music en pause au démarrage, ou au réveil : la diffusion part sur le mode global et y restait
    /// quand Music reprenait.
    @Test("L'application choisie, en pause au démarrage, redevient la source quand elle rejoue")
    func preferredSourceReturnsWhileLive() async throws {
        let harness = BridgeHarness()
        harness.sources = [.systemWide, music, .inputDevice]
        harness.state.refreshSources()
        harness.state.selectSource(id: music.id)
        await harness.discover(raop: [Devices.genevaRAOP])

        harness.sources = [.systemWide, .inputDevice]
        await harness.startStreaming(expecting: [Devices.genevaID])
        #expect(harness.state.selectedSource == .systemWide)
        let sender = try #require(harness.factory.latest(Devices.genevaID))

        harness.sources = [.systemWide, music, .inputDevice]

        #expect(await eventually { harness.state.selectedSource == music })
        #expect(harness.captures.count == 2)
        #expect(capturedPIDs(harness) == [42])
        #expect(await sender.stopCount == 0)

        // La pause suivante ne la fait pas repartir sur le global.
        harness.sources = [.systemWide, .inputDevice]
        #expect(await staysFalse { harness.captures.count > 2 })
        #expect(harness.state.selectedSource == music)
        await harness.stopStreaming()
    }

    /// Une application qui crée sans arrêt de nouveaux processus : au pire un changement toutes les
    /// quelques secondes, chacun coûtant un petit trou de son.
    @Test("Un processus qui clignote ne fait pas tourner la capture en boucle")
    func flickeringProcessIsPaced() async throws {
        var timing = BridgeEnvironment.Timing.fast
        timing.sourceFollowMinimumSpacing = .seconds(60)
        let harness = BridgeHarness(timing: timing)
        harness.sources = [.systemWide, music, .inputDevice]
        harness.state.refreshSources()
        harness.state.selectSource(id: music.id)
        await harness.discover(raop: [Devices.genevaRAOP])
        await harness.startStreaming(expecting: [Devices.genevaID])

        var pid: pid_t = 100
        let deadline = ContinuousClock.now + .milliseconds(300)
        while ContinuousClock.now < deadline {
            pid += 1
            harness.sources = [
                .systemWide,
                .application(pids: [pid], name: "Music", bundleID: "com.apple.Music"),
                .inputDevice,
            ]
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(harness.captures.count == 2)
        await harness.stopStreaming()
    }

    @Test("Un choix de l'utilisateur prime sur le suivi en cours")
    func userChoiceWins() async throws {
        let harness = await streamingMusic()
        harness.sources = [
            .systemWide,
            .application(pids: [42, 77], name: "Music", bundleID: "com.apple.Music"),
            .inputDevice,
        ]
        harness.state.selectSource(id: CaptureSource.systemWide.id)

        #expect(await eventually { !harness.state.isRestarting && harness.state.isStreaming })
        #expect(await eventually { harness.state.selectedSource == .systemWide })
        #expect(await staysFalse { harness.state.selectedSource != .systemWide })
        await harness.stopStreaming()
    }
}
