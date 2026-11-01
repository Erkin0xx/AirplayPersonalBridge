import Foundation
import Synchronization

/// Dialogue entre le binaire et le wrapper `./audiocap`.
///
/// Lancé par `open` (indispensable pour que TCC attribue l'autorisation au bundle), le process
/// ne dépend plus du terminal : il démarre depuis `/`, `open -W` ne rend pas son code de sortie,
/// et un Ctrl-C n'atteint que `open`, laissant la capture et la diffusion tourner. Le wrapper
/// passe donc un dossier temporaire privé (`open --env AUDIOCAP_RUN_DIR=…`), où le binaire dépose
/// son pid et son code de sortie. stdout et stderr sont redirigés par `open --stdout/--stderr`.
///
/// Sans cette variable (binaire lancé directement, ce qui fait perdre l'autorisation TCC mais
/// reste utile à `--help` ou `--list`), rien n'est écrit nulle part.
enum CLIRuntime {
    private static let runDirectory = ProcessInfo.processInfo.environment["AUDIOCAP_RUN_DIR"]

    /// Prépare le process lancé par le wrapper. À appeler avant tout le reste.
    static func start() {
        // Un chemin relatif (« systeme.wav ») s'entend depuis le dossier de l'utilisateur.
        if let directory = ProcessInfo.processInfo.environment["AUDIOCAP_WORKING_DIR"] {
            FileManager.default.changeCurrentDirectoryPath(directory)
        }
        writeRunFile(named: "pid", contents: "\(getpid())")
        CLIInterruption.install()
    }

    /// Note le code de sortie. Un fichier absent signale donc un plantage au wrapper.
    fileprivate static func recordExit(code: Int32) {
        writeRunFile(named: "status", contents: "\(code)")
    }

    private static func writeRunFile(named name: String, contents: String) {
        guard let runDirectory else { return }
        try? contents.write(
            toFile: (runDirectory as NSString).appendingPathComponent(name),
            atomically: true, encoding: .utf8
        )
    }
}

/// Arrêt propre sur Ctrl-C ou `kill` : le premier signal écourte la durée demandée, ce qui fait
/// passer par le chemin normal (`TEARDOWN` aux récepteurs, finalisation du `.wav`, bilan). Sans
/// `TEARDOWN`, un récepteur matériel peut rester bloqué sur la session. Le second signal quitte
/// sans attendre, pour le cas où l'arrêt lui-même resterait coincé.
enum CLIInterruption {
    private static let flag = Atomic<Bool>(false)
    // Conservées pour la durée du process : une source libérée cesse d'émettre.
    nonisolated(unsafe) private static var sources: [any DispatchSourceSignal] = []

    static var requested: Bool { flag.load(ordering: .relaxed) }

    fileprivate static func install() {
        for number in [SIGINT, SIGTERM] {
            // Sans cela l'action par défaut du signal tue le process avant la source Dispatch.
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
            source.setEventHandler {
                if flag.compareExchange(
                    expected: false, desired: true, ordering: .relaxed
                ).exchanged {
                    note("\nInterruption : arrêt propre en cours (nouveau Ctrl-C pour quitter sans attendre)…")
                } else {
                    exit(130)
                }
            }
            source.resume()
            sources.append(source)
        }
    }
}

/// Attend sans dépasser l'échéance, mais rend la main dès qu'une interruption est demandée.
/// Une attente d'intervalle peut durer une minute sur une longue session.
func interruptibleSleep(seconds: Double) async throws {
    let deadline = Date().addingTimeInterval(seconds)
    while !CLIInterruption.requested {
        let remaining = deadline.timeIntervalSinceNow
        guard remaining > 0 else { return }
        try await Task.sleep(for: .seconds(min(remaining, 0.2)))
    }
}

/// Remplace `exit` dans tout le module : chaque sortie passe ainsi par le compte rendu au
/// wrapper, sans avoir à modifier chaque appel. Une session interrompue rend 130 (la convention
/// shell pour un Ctrl-C), quel que soit le résultat qu'aurait donné la fin normale.
func exit(_ code: Int32) -> Never {
    let finalCode = CLIInterruption.requested ? 130 : code
    CLIRuntime.recordExit(code: finalCode)
    Foundation.exit(finalCode)
}
