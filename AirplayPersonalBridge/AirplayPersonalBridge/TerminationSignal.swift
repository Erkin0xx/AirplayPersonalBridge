import AppKit

/// Convertit SIGTERM en « Quitter ».
///
/// Par défaut, SIGTERM tue une app AppKit sur place : `willTerminateNotification` n'est jamais
/// émise, les sessions AirPlay ne reçoivent pas leur `TEARDOWN`, et un récepteur matériel peut
/// rester bloqué sur la session. `scripts/install-app.sh` s'en sert pour arrêter l'instance en
/// cours avant de la remplacer : le « quit » par AppleEvent ouvrirait une fenêtre d'autorisation
/// Automation, un signal n'en ouvre aucune.
///
/// **`terminate` part d'un bloc de la boucle, jamais du gestionnaire de la source.** Ce gestionnaire
/// s'exécute dans un bloc de la file principale. `applicationShouldTerminate` répond toujours
/// `.terminateLater` (`QuitSequence`), et AppKit fait tourner une boucle imbriquée jusqu'à
/// `reply(toApplicationShouldTerminate:)`. Mais une boucle imbriquée dans un bloc de la file
/// principale ne draine plus cette file : CFRunLoop s'en abstient tant qu'il est en train de la
/// servir. Plus aucune tâche du MainActor ne tourne, ni l'arrêt des sorties, ni sa borne de 5 s, ni
/// la réponse à AppKit. L'app s'est figée ainsi pendant une diffusion, et il a fallu un `kill -9`,
/// donc pas de `TEARDOWN`. Un bloc confié à la boucle (`RunLoop.perform`) s'exécute hors de la file
/// principale : la boucle imbriquée la draine alors normalement. `Tests/TerminationProbe` reproduit
/// l'interblocage dans un vrai process.
///
/// Public pour cette sonde, seule à s'en servir hors de l'app.
public enum TerminationSignal {
    // Conservée pour la durée du process : une source libérée cesse d'émettre.
    @MainActor private static var source: (any DispatchSourceSignal)?
    @MainActor private static var isTerminating = false

    @MainActor public static func install() {
        // Sans cela l'action par défaut du signal tue le process avant la source Dispatch.
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler {
            // Les modes communs : un menu ouvert ne retarde pas l'arrêt. Un bloc confié à la boucle ne
            // la réveille pas de lui-même.
            RunLoop.main.perform(inModes: [.common]) {
                MainActor.assumeIsolated { requestTermination() }
            }
            CFRunLoopWakeUp(CFRunLoopGetMain())
        }
        source.resume()
        self.source = source
    }

    /// Un second `terminate` pendant l'attente d'AppKit le fait quitter sur-le-champ, sans attendre sa
    /// réponse (vérifié) : un SIGTERM répété écourterait l'arrêt des sorties. Il est donc ignoré.
    @MainActor private static func requestTermination() {
        guard !isTerminating else { return }
        isTerminating = true
        NSApplication.shared.terminate(nil)
        // Ne revient que si la fermeture a été annulée : un SIGTERM suivant doit pouvoir la redemander.
        isTerminating = false
    }
}
