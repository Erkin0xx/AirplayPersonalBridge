//
//  QuitSequence.swift
//  AirplayPersonalBridge
//

import AudioCore
import Foundation
import OSLog

private let terminationLog = Logger(subsystem: AudioLog.subsystem, category: "termination")

/// La fermeture de l'app, de la demande d'AppKit à sa réponse, toujours dans cet ordre :
/// 1. `TEARDOWN` des sessions, puis 2. arrêt de la capture, tap et agrégat détruits : `stopOutputs`,
///    c'est-à-dire `BridgeState.shutdown`, dont le moteur (`BridgeEngine.stop`) tient cet ordre ;
/// 3. sortie par défaut, volume et silence du Mac rendus (`restoreSystemOutput`) ;
/// 4. relance de coreaudiod, dernière action de l'app (`coreAudio`) ;
/// 5. réponse à AppKit, qui ferme (`reply`).
///
/// Vaut à chaque fermeture, par le menu ou par SIGTERM, diffusion en cours ou non. Chaque étape a sa
/// part de la borne (`Budget`), et aucune ne peut retenir la suivante : une relance qui échoue ou ne
/// répond pas laisse une ligne au journal, et l'app quitte quand même. Les étapes sont injectées : les
/// tests en vérifient l'ordre sans moteur, et sans jamais relancer le vrai coreaudiod.
struct QuitSequence {
    /// Les deux parts de la borne de fermeture. La relance a la sienne, prise sur la borne et non
    /// ajoutée : l'arrêt des sorties ne peut pas la lui manger, ni la fermeture la dépasser.
    struct Budget: Equatable {
        var outputs: Duration
        var coreAudioRestart: Duration

        var total: Duration { outputs + coreAudioRestart }
    }

    var stopOutputs: (Duration) async -> Void
    var restoreSystemOutput: () -> Void
    var coreAudio: any CoreAudioRestarting
    var budget: Budget

    func run(reply: () -> Void) async {
        await stopOutputs(budget.outputs)
        restoreSystemOutput()
        let outcome = await restartCoreAudio()
        if outcome == .restarted {
            terminationLog.notice("coreaudiod relancé à la fermeture")
        } else {
            terminationLog.error(
                "coreaudiod non relancé à la fermeture, l'app quitte quand même : \(outcome.summary, privacy: .public)"
            )
        }
        reply()
    }

    /// Bornée ici aussi, sans se fier au relanceur : la réponse à AppKit n'attend jamais plus que la
    /// part de la relance. Ni groupe de tâches ni `async let`, qui attendraient le relanceur à la
    /// sortie (`BridgeState.wait`).
    private func restartCoreAudio() async -> CoreAudioRestartOutcome {
        let limit = budget.coreAudioRestart
        return await withCheckedContinuation { continuation in
            let once = OnceContinuation(continuation)
            Task {
                once.resume(returning: await coreAudio.restart(timeout: limit))
            }
            Task {
                try? await Task.sleep(for: limit)
                once.resume(returning: .timedOut)
            }
        }
    }
}
