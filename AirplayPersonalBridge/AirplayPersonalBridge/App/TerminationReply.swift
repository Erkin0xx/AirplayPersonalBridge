//
//  TerminationReply.swift
//  AirplayPersonalBridge
//

import AudioCore
import Foundation
import OSLog

private let terminationLog = Logger(subsystem: AudioLog.subsystem, category: "termination")

/// La réponse à AppKit après `.terminateLater` : une seule fois, et à coup sûr.
///
/// L'arrêt borné répond depuis le MainActor, donc depuis la file principale. Quand `terminate` est
/// appelé depuis un bloc de cette file (`DispatchQueue.main.async`, une tâche `@MainActor`, le
/// gestionnaire d'une source Dispatch), la boucle imbriquée où AppKit attend sa réponse ne la draine
/// plus : la borne de 5 s ne tombe jamais, et l'app reste figée. `TerminationSignal` évite ce cas
/// pour SIGTERM ; ce filet couvre tout autre appelant. Un minuteur de boucle se déclenche encore dans
/// cette boucle imbriquée : passé le délai, il répond à la place, sans `TEARDOWN` mais sans `kill -9`.
///
/// Public pour `Tests/TerminationProbe`, qui l'exerce dans un vrai process AppKit.
public final class TerminationReply {
    private var reply: (() -> Void)?
    private var fallback: Timer?

    public init(fallbackAfter delay: Duration, reply: @escaping () -> Void) {
        self.reply = reply
        let (seconds, attoseconds) = delay.components
        // Capture forte : si l'arrêt ne tourne jamais, seul le minuteur garde la réponse en vie.
        let timer = Timer(
            timeInterval: Double(seconds) + Double(attoseconds) / 1e18, repeats: false
        ) { _ in
            MainActor.assumeIsolated { self.answer(byFallback: true) }
        }
        // Les modes communs, dont celui de la boucle où AppKit attend la réponse.
        RunLoop.main.add(timer, forMode: .common)
        fallback = timer
    }

    /// Répond à AppKit, si ce n'est déjà fait.
    public func send() {
        answer(byFallback: false)
    }

    private func answer(byFallback: Bool) {
        guard let reply else { return }
        self.reply = nil
        fallback?.invalidate()
        fallback = nil
        if byFallback {
            terminationLog.fault(
                "Réponse de secours à AppKit : l'arrêt n'a pas pu tourner sur le MainActor"
            )
        }
        reply()
    }
}
