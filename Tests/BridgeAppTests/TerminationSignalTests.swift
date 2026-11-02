import Foundation
import Testing

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
    /// s'achevait jamais, AppKit n'avait jamais sa réponse, et la sonde finissait par `BLOQUE`.
    @Test("SIGTERM pendant un arrêt différé : l'arrêt s'achève, AppKit a sa réponse, l'app quitte")
    func sigtermLetsShutdownFinish() async throws {
        let outcome = try await runProbe(mode: "sigterm")
        #expect(outcome.steps == ["PRET", "DEMANDE", "ARRET-TERMINE", "FIN"])
        #expect(outcome.reason == .exit)
        #expect(outcome.status == 0)
    }

    /// Un second `terminate` pendant l'attente fait quitter AppKit sur-le-champ, sans les `TEARDOWN`.
    @Test("Un second SIGTERM pendant l'arrêt ne l'écourte pas")
    func repeatedSigtermIsIgnored() async throws {
        let outcome = try await runProbe(mode: "sigterm-repete")
        #expect(outcome.steps == ["PRET", "DEMANDE", "SECOND-SIGTERM", "ARRET-TERMINE", "FIN"])
        #expect(outcome.reason == .exit)
        #expect(outcome.status == 0)
    }
}
