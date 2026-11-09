import Foundation
import Testing

@testable import BridgeApp

/// Le relanceur de coreaudiod, sans coreaudiod : aucun test ne doit relancer le vrai, qui couperait le
/// son de toute la machine. `AppLifecycle` l'exige de chaque test qui la construit.
final class StubCoreAudioRestarter: CoreAudioRestarting {
    enum Behaviour {
        case answer(CoreAudioRestartOutcome)
        /// Ne répond qu'à `release` : une commande figée.
        case hang
    }

    var behaviour: Behaviour
    /// Appelé à l'entrée de `restart` : ce que la fermeture a déjà fait à cet instant.
    var onRestart: () -> Void = {}
    private(set) var timeouts: [Duration] = []
    private var parked: [CheckedContinuation<Void, Never>] = []

    init(_ behaviour: Behaviour = .answer(.restarted)) {
        self.behaviour = behaviour
    }

    var restartCount: Int { timeouts.count }

    func restart(timeout: Duration) async -> CoreAudioRestartOutcome {
        timeouts.append(timeout)
        onRestart()
        switch behaviour {
        case .answer(let outcome):
            return outcome
        case .hang:
            await withCheckedContinuation { parked.append($0) }
            return .restarted
        }
    }

    /// Libère une relance figée, pour que le test finisse proprement.
    func release() {
        for continuation in parked { continuation.resume() }
        parked = []
    }
}

/// `QuitSequence` seule, les étapes remplacées par des notes : l'ordre, et ce qui ne doit jamais
/// retenir la réponse à AppKit.
@Suite("Fermeture — ordre de la séquence")
struct QuitSequenceTests {
    private final class Journal {
        var events: [String] = []
        var stopLimits: [Duration] = []
        var repliedAt: ContinuousClock.Instant?
    }

    /// Délais courts : un test n'a pas à dormir 5 s.
    private static let budget = QuitSequence.Budget(
        outputs: .milliseconds(400), coreAudioRestart: .milliseconds(120)
    )

    private func sequence(
        _ journal: Journal, coreAudio: StubCoreAudioRestarter
    ) -> QuitSequence {
        coreAudio.onRestart = { journal.events.append("relance") }
        return QuitSequence(
            stopOutputs: { limit in
                journal.stopLimits.append(limit)
                // Un vrai arrêt suspend : la suite doit l'attendre, pas seulement le lancer.
                try? await Task.sleep(for: .milliseconds(20))
                journal.events.append("arrêt")
            },
            restoreSystemOutput: { journal.events.append("son du Mac") },
            coreAudio: coreAudio,
            budget: Self.budget
        )
    }

    @Test("TEARDOWN et capture, puis le son du Mac, puis la relance de coreaudiod, puis la réponse")
    func order() async {
        let journal = Journal()
        let coreAudio = StubCoreAudioRestarter()
        await sequence(journal, coreAudio: coreAudio).run { journal.events.append("réponse") }
        #expect(journal.events == ["arrêt", "son du Mac", "relance", "réponse"])
        #expect(journal.stopLimits == [Self.budget.outputs])
        #expect(coreAudio.timeouts == [Self.budget.coreAudioRestart])
    }

    @Test(
        "Une relance en échec n'empêche ni la réponse ni l'ordre",
        arguments: [
            CoreAudioRestartOutcome.exited(status: 1), .killed(signal: 15), .timedOut,
            .launchFailed("introuvable"),
        ]
    )
    func failedRestartStillReplies(_ outcome: CoreAudioRestartOutcome) async {
        let journal = Journal()
        let coreAudio = StubCoreAudioRestarter(.answer(outcome))
        await sequence(journal, coreAudio: coreAudio).run { journal.events.append("réponse") }
        #expect(journal.events == ["arrêt", "son du Mac", "relance", "réponse"])
    }

    /// La séquence borne elle-même la relance, sans se fier au relanceur : celui-ci ne répond jamais.
    @Test("Une relance qui ne répond jamais ne retient la réponse que le temps de sa part")
    func silentRestartIsBounded() async {
        let journal = Journal()
        let coreAudio = StubCoreAudioRestarter(.hang)
        let start = ContinuousClock.now
        let running = Task {
            await sequence(journal, coreAudio: coreAudio).run { journal.repliedAt = .now }
        }
        #expect(await eventually(timeout: .seconds(3)) { journal.repliedAt != nil })
        let elapsed = journal.repliedAt.map { start.duration(to: $0) }
        let limit = Self.budget.coreAudioRestart
        #expect(elapsed.map { $0 >= limit } == true, "\(String(describing: elapsed))")
        #expect(
            elapsed.map { $0 < limit + .milliseconds(500) } == true,
            "\(String(describing: elapsed))"
        )
        coreAudio.release()
        await running.value
    }

    /// La demande de Baptiste : 1 s au plus pour la relance, **dans** la borne de 5 s.
    @Test("Budget réel : 4 s pour les sorties, 1 s pour la relance, secours à 6 s")
    func standardBudget() {
        #expect(AppLifecycle.shutdownTimeout == .seconds(5))
        #expect(AppLifecycle.quitBudget.coreAudioRestart == .seconds(1))
        #expect(AppLifecycle.quitBudget.outputs == .seconds(4))
        #expect(AppLifecycle.quitBudget.total == AppLifecycle.shutdownTimeout)
        #expect(AppLifecycle.replyFallbackDelay == .seconds(6))
    }
}

/// `LiveCoreAudioRestarter` avec des commandes inoffensives : le processus fils, son gestionnaire de
/// fin et l'échéance, **jamais coreaudiod**.
@Suite("Fermeture — relance par un processus fils")
struct LiveCoreAudioRestarterTests {
    private func restarter(_ path: String, _ arguments: String...) -> LiveCoreAudioRestarter {
        LiveCoreAudioRestarter(
            command: .init(executable: URL(fileURLWithPath: path), arguments: arguments)
        )
    }

    /// Vérifiée sans être lancée.
    @Test("La commande de l'app : sudo sans mot de passe, puis killall coreaudiod")
    func appCommand() {
        let command = LiveCoreAudioRestarter.Command.killCoreAudio
        #expect(command.executable.path == "/usr/bin/sudo")
        #expect(command.arguments == ["-n", "/usr/bin/killall", "coreaudiod"])
    }

    @Test("Code de sortie nul : relancé")
    func success() async {
        #expect(await restarter("/usr/bin/true").restart(timeout: .seconds(10)) == .restarted)
    }

    /// Ce que rend `sudo -n` sans la règle sudoers.
    @Test("Code de sortie non nul : échec, avec le code")
    func failure() async {
        #expect(
            await restarter("/usr/bin/false").restart(timeout: .seconds(10)) == .exited(status: 1)
        )
    }

    @Test("Tuée par un signal : échec, avec le signal")
    func killed() async {
        let outcome = await restarter("/bin/sh", "-c", "kill -TERM $$").restart(timeout: .seconds(10))
        #expect(outcome == .killed(signal: SIGTERM))
    }

    @Test("Commande introuvable : échec au lancement, sans attendre l'échéance")
    func launchFailure() async {
        let start = ContinuousClock.now
        let outcome = await restarter("/nonexistent/killall").restart(timeout: .seconds(10))
        guard case .launchFailed = outcome else {
            Issue.record("attendu un échec au lancement, obtenu \(outcome)")
            return
        }
        #expect(start.duration(to: .now) < .seconds(2))
    }

    /// Jamais `waitUntilExit` : l'échéance rend la main, le fils finit seul.
    @Test("Commande figée : la main revient à l'échéance")
    func timeout() async {
        let start = ContinuousClock.now
        let outcome = await restarter("/bin/sleep", "2").restart(timeout: .milliseconds(100))
        #expect(outcome == .timedOut)
        #expect(start.duration(to: .now) < .seconds(1))
    }

    /// Un tube que personne ne lit se remplit à 64 Kio, et le fils s'y bloque : jusqu'à l'échéance.
    @Test("Une sortie abondante ne bloque pas le fils")
    func largeOutputDoesNotBlock() async {
        let outcome = await restarter(
            "/bin/dd", "if=/dev/zero", "bs=1048576", "count=4"
        ).restart(timeout: .seconds(10))
        #expect(outcome == .restarted)
    }
}
