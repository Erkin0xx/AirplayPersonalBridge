import AppKit
import BridgeApp

// Sonde lancée par `TerminationSignalTests` : un vrai process AppKit qui reçoit SIGTERM pendant un
// arrêt différé, comme l'app quand `scripts/install-app.sh` l'arrête en pleine diffusion. Sans
// moteur ni réseau : le délégué tient le rôle d'`AppLifecycle`, répond `.terminateLater` et ne
// répond qu'une fois achevé un arrêt qui repasse par le MainActor, comme l'arrêt des sorties.
//
// Chaque étape s'écrit sur une ligne de la sortie standard, le test en vérifie la suite :
//   PRET            l'app tourne, `TerminationSignal` est installé
//   DEMANDE         AppKit demande au délégué s'il peut quitter
//   SECOND-SIGTERM  (mode `sigterm-repete`) le second signal est arrivé
//   ARRET-TERMINE   l'arrêt a pu s'achever sur le MainActor, la réponse part
//   FIN             `applicationWillTerminate` : AppKit quitte, code 0
//   BLOQUE          rien de tout cela à temps : le garde-fou quitte, code 3

enum Mode: String {
    /// Un SIGTERM, comme `install-app.sh`.
    case sigterm
    /// Un second SIGTERM pendant l'arrêt, qui ne doit pas l'écourter.
    case sigtermRepete = "sigterm-repete"
}

/// Hors du MainActor : le garde-fou écrit depuis une autre file.
nonisolated func report(_ step: String) {
    FileHandle.standardOutput.write(Data("\(step)\n".utf8))
}

/// Le temps qu'un arrêt de sorties prendrait : il doit tomber pendant l'attente d'AppKit.
let shutdownDuration: Duration = .milliseconds(300)

final class ProbeDelegate: NSObject, NSApplicationDelegate {
    let mode: Mode
    private var signalCount = 0
    private var secondSignalSeen = false
    private var observer: (any DispatchSourceSignal)?

    init(mode: Mode) {
        self.mode = mode
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if mode == .sigtermRepete { observeSecondSignal() }
        report("PRET")
        kill(getpid(), SIGTERM)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        report("DEMANDE")
        if mode == .sigtermRepete { kill(getpid(), SIGTERM) }
        Task {
            if mode == .sigtermRepete { await waitForSecondSignal() }
            try? await Task.sleep(for: shutdownDuration)
            report("ARRET-TERMINE")
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        report("FIN")
    }

    /// Une seconde source sur le même signal : chacune reçoit chaque SIGTERM.
    private func observeSecondSignal() {
        let observer = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        observer.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.noteSignal() }
        }
        observer.resume()
        self.observer = observer
    }

    private func noteSignal() {
        // Deux signaux rapprochés peuvent n'en faire qu'un appel : `data` les compte.
        signalCount += Int(observer?.data ?? 1)
        guard signalCount >= 2, !secondSignalSeen else { return }
        secondSignalSeen = true
        report("SECOND-SIGTERM")
    }

    private func waitForSecondSignal() async {
        let deadline = ContinuousClock.now + .seconds(5)
        while !secondSignalSeen, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}

guard let mode = Mode(rawValue: CommandLine.arguments.dropFirst().first ?? Mode.sigterm.rawValue)
else {
    report("MODE-INCONNU")
    exit(64)
}

// Hors de la file principale, la seule qui puisse se bloquer : ce garde-fou tourne quoi qu'il arrive.
DispatchQueue.global().asyncAfter(deadline: .now() + 15) {
    report("BLOQUE")
    exit(3)
}

let app = NSApplication.shared
// Ni icône dans le Dock, ni barre de menus.
app.setActivationPolicy(.prohibited)
let delegate = ProbeDelegate(mode: mode)
app.delegate = delegate
TerminationSignal.install()
app.run()
