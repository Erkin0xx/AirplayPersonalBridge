import Foundation
import Testing

@testable import BridgeApp

/// Repère le dossier des produits de compilation : la sonde y est compilée à côté du bundle de test.
private final class ProductsLocator: NSObject {}

/// SIGTERM dans un vrai process AppKit, `Tests/TerminationProbe`.
///
/// L'interblocage corrigé ne se voit que dans la boucle d'événements d'AppKit, que le process de
/// `swift test` ne fait pas tourner ; et un `terminate` qui aboutit y mettrait fin à toute la suite.
/// La sonde n'a ni moteur ni réseau : son délégué répond plus tard, depuis le MainActor, comme
/// `AppLifecycle` pendant une diffusion.
@Suite("Coquille — SIGTERM")
struct TerminationSignalTests {
    private struct Outcome {
        let steps: [String]
        let status: Int32
        let reason: Process.TerminationReason
    }

    private func runProbe(mode: String) async throws -> Outcome {
        let products = Bundle(for: ProductsLocator.self).bundleURL.deletingLastPathComponent()
        let probe = products.appendingPathComponent("TerminationProbe")
        try #require(
            FileManager.default.isExecutableFile(atPath: probe.path),
            "sonde introuvable : \(probe.path)"
        )
        let process = Process()
        process.executableURL = probe
        process.arguments = [mode]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let pid = process.processIdentifier

        // La sonde a son propre garde-fou ; celui-ci ne sert que si elle n'en venait pas à bout.
        let guardian = DispatchWorkItem { kill(pid, SIGKILL) }
        DispatchQueue.global().asyncAfter(deadline: .now() + 40, execute: guardian)
        defer { guardian.cancel() }

        // La fin de fichier dit que la sonde est sortie. Jamais `waitUntilExit()` (CLAUDE.md, Tests).
        let output = await withCheckedContinuation { (continuation: CheckedContinuation<String, Never>) in
            DispatchQueue.global().async {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                continuation.resume(returning: String(decoding: data, as: UTF8.self))
            }
        }
        #expect(await eventually { !process.isRunning }, "la sonde ne sort pas : \(output)")
        return Outcome(
            steps: output.split(separator: "\n").map(String.init),
            status: process.terminationStatus,
            reason: process.terminationReason
        )
    }

    /// Le défaut constaté sur l'app réelle : appelé depuis le gestionnaire de la source, `terminate`
    /// attendait sa réponse dans une boucle qui ne drainait plus la file principale. L'arrêt ne
    /// s'achevait jamais : la sonde finissait par `BLOQUE`, et depuis `TerminationReply`, par une
    /// réponse de secours sans `ARRET-TERMINE`, c'est-à-dire sans `TEARDOWN`.
    @Test("SIGTERM pendant un arrêt différé : l'arrêt s'achève, AppKit a sa réponse, l'app quitte")
    func sigtermLetsShutdownFinish() async throws {
        let outcome = try await runProbe(mode: "sigterm")
        #expect(outcome.steps == ["PRET", "DEMANDE", "ARRET-TERMINE", "REPONSE", "FIN"])
        #expect(outcome.reason == .exit)
        #expect(outcome.status == 0)
    }

    /// Un second `terminate` pendant l'attente fait quitter AppKit sur-le-champ, sans les `TEARDOWN`.
    @Test("Un second SIGTERM pendant l'arrêt ne l'écourte pas")
    func repeatedSigtermIsIgnored() async throws {
        let outcome = try await runProbe(mode: "sigterm-repete")
        #expect(
            outcome.steps == ["PRET", "DEMANDE", "SECOND-SIGTERM", "ARRET-TERMINE", "REPONSE", "FIN"]
        )
        #expect(outcome.reason == .exit)
        #expect(outcome.status == 0)
    }

    /// Le même interblocage, pour tout autre appelant de `terminate` depuis la file principale : une
    /// tâche `@MainActor` en est un. L'arrêt ne peut pas tourner, le filet de secours répond.
    @Test("Appelé depuis la file principale, `terminate` a quand même sa réponse")
    func fallbackAnswersWhenMainActorIsStuck() async throws {
        let outcome = try await runProbe(mode: "file-principale")
        #expect(outcome.steps == ["PRET", "DEMANDE", "REPONSE", "FIN"])
        #expect(outcome.reason == .exit)
        #expect(outcome.status == 0)
    }
}

/// `TerminationReply` dans le process de test, dont la boucle principale ne tourne que si on la fait
/// tourner : d'où `pumpMainRunLoop`.
@Suite("Coquille — réponse à AppKit")
struct TerminationReplyTests {
    /// Fait tourner la boucle principale, où vit le minuteur de secours, jusqu'à la condition.
    private func pumpMainRunLoop(for duration: Duration, until condition: () -> Bool = { false }) {
        let deadline = ContinuousClock.now + duration
        while !condition(), ContinuousClock.now < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
    }

    @Test("Sans réponse de l'arrêt, le filet de secours répond, une seule fois")
    func fallbackAnswersOnce() {
        var replies = 0
        let answer = TerminationReply(fallbackAfter: .milliseconds(20)) { replies += 1 }
        pumpMainRunLoop(for: .seconds(5)) { replies > 0 }
        #expect(replies == 1)
        answer.send()
        #expect(replies == 1)
    }

    /// Sans cela, AppKit recevrait une seconde réponse, après celle de l'arrêt.
    @Test("Une fois l'arrêt achevé, le filet de secours ne répond plus")
    func sendDisarmsFallback() {
        var replies = 0
        let answer = TerminationReply(fallbackAfter: .milliseconds(20)) { replies += 1 }
        answer.send()
        answer.send()
        #expect(replies == 1)
        pumpMainRunLoop(for: .milliseconds(150))
        #expect(replies == 1)
    }
}
