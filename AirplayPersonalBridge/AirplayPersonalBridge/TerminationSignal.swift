import AppKit

/// Convertit SIGTERM en « Quitter ».
///
/// Par défaut, SIGTERM tue une app AppKit sur place : `willTerminateNotification` n'est jamais
/// émise, les sessions AirPlay ne reçoivent pas leur `TEARDOWN`, et un récepteur matériel peut
/// rester bloqué sur la session. `scripts/install-app.sh` s'en sert pour arrêter l'instance en
/// cours avant de la remplacer : le « quit » par AppleEvent ouvrirait une fenêtre d'autorisation
/// Automation, un signal n'en ouvre aucune.
enum TerminationSignal {
    // Conservée pour la durée du process : une source libérée cesse d'émettre.
    @MainActor private static var source: (any DispatchSourceSignal)?

    @MainActor static func install() {
        // Sans cela l'action par défaut du signal tue le process avant la source Dispatch.
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler {
            MainActor.assumeIsolated { NSApplication.shared.terminate(nil) }
        }
        source.resume()
        self.source = source
    }
}
