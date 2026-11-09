//
//  CoreAudioRestarter.swift
//  AirplayPersonalBridge
//

import Foundation

/// Ce qu'a donné la relance de coreaudiod.
nonisolated enum CoreAudioRestartOutcome: Equatable, Sendable {
    /// coreaudiod a été tué : launchd le relance de lui-même.
    case restarted
    /// La commande a rendu un code non nul. `sudo -n` rend 1 sans la règle sudoers, `killall` aussi
    /// quand coreaudiod ne tourne pas.
    case exited(status: Int32)
    /// La commande a été tuée par ce signal.
    case killed(signal: Int32)
    /// Pas de réponse dans le délai.
    case timedOut
    /// La commande n'a pas pu être lancée.
    case launchFailed(String)

    /// Pour le journal, sur une ligne.
    var summary: String {
        switch self {
        case .restarted: "relancé"
        case .exited(let status): "code de sortie \(status) (règle sudoers absente ?)"
        case .killed(let signal): "commande tuée par le signal \(signal)"
        case .timedOut: "pas de réponse dans le délai"
        case .launchFailed(let reason): "lancement impossible : \(reason)"
        }
    }
}

/// Relance coreaudiod, dernière action de l'app avant de fermer (`QuitSequence`).
///
/// Injecté (CDC section 13) : aucun test ne doit relancer le vrai coreaudiod, qui coupe le son de
/// toute la machine le temps de repartir.
protocol CoreAudioRestarting {
    /// Rend la main en `timeout` au plus, quoi que fasse la commande.
    func restart(timeout: Duration) async -> CoreAudioRestartOutcome
}

/// La relance réelle, par un processus fils.
///
/// `sudo -n` ne demande jamais de mot de passe : sans la règle NOPASSWD posée par
/// `scripts/install-driver.sh`, limitée à cette commande, il échoue aussitôt, et l'app quitte quand
/// même. **Jamais `waitUntilExit`** (il a figé un passage de tests 14 min) : le gestionnaire de fin du
/// processus et une échéance se disputent une reprise unique. Passé le délai, le fils est laissé à
/// lui-même : s'il finit par tuer coreaudiod, c'est encore ce qu'on voulait.
struct LiveCoreAudioRestarter: CoreAudioRestarting {
    struct Command: Equatable {
        var executable: URL
        var arguments: [String]

        /// launchd relance coreaudiod dès qu'il meurt.
        static let killCoreAudio = Command(
            executable: URL(fileURLWithPath: "/usr/bin/sudo"),
            arguments: ["-n", "/usr/bin/killall", "coreaudiod"]
        )
    }

    let command: Command

    /// Sans valeur par défaut : seule l'app nomme `.killCoreAudio`, un test passe une commande inoffensive.
    init(command: Command) {
        self.command = command
    }

    func restart(timeout: Duration) async -> CoreAudioRestartOutcome {
        let process = Process()
        process.executableURL = command.executable
        process.arguments = command.arguments
        // Rien n'est lu : un tube que personne ne vide peut bloquer le fils. Et pas de terminal où
        // demander un mot de passe.
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        return await withCheckedContinuation { continuation in
            let once = OnceContinuation(continuation)
            // Avant `run` : un fils très bref peut finir avant qu'on ait fini de le lancer.
            process.terminationHandler = { finished in
                once.resume(returning: Self.outcome(of: finished))
            }
            do {
                try process.run()
            } catch {
                once.resume(returning: .launchFailed(String(describing: error)))
                return
            }
            Task {
                try? await Task.sleep(for: timeout)
                once.resume(returning: .timedOut)
            }
        }
    }

    private nonisolated static func outcome(of process: Process) -> CoreAudioRestartOutcome {
        switch process.terminationReason {
        case .exit:
            process.terminationStatus == 0 ? .restarted : .exited(status: process.terminationStatus)
        case .uncaughtSignal:
            .killed(signal: process.terminationStatus)
        @unknown default:
            .exited(status: process.terminationStatus)
        }
    }
}
