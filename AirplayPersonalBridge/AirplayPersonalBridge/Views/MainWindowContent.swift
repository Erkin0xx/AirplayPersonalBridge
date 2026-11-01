//
//  MainWindowContent.swift
//  AirplayPersonalBridge
//

import AppKit
import SwiftUI

/// Le contenu de la fenêtre unique, relié au `NSWindow` qui le porte.
///
/// La scène `Window` ne dit rien de l'ouverture ni de la fermeture de sa fenêtre : c'est par le
/// `NSWindow` que l'app sait quand montrer son icône dans le Dock.
struct MainWindowContent: View {
    let lifecycle: AppLifecycle

    var body: some View {
        ContentView(state: lifecycle.state)
            .background(WindowAttachmentObserver { lifecycle.mainWindowDidAttach($0) })
    }
}

private struct WindowAttachmentObserver: NSViewRepresentable {
    let onAttach: (NSWindow) -> Void

    func makeNSView(context: Context) -> ObserverView {
        ObserverView(onAttach: onAttach)
    }

    func updateNSView(_ view: ObserverView, context: Context) {}

    final class ObserverView: NSView {
        private let onAttach: (NSWindow) -> Void

        init(onAttach: @escaping (NSWindow) -> Void) {
            self.onAttach = onAttach
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("Cette vue n'est créée que par SwiftUI")
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            // Au tour suivant : changer de politique d'activation, ou fermer la fenêtre, n'a pas sa
            // place en pleine mise à jour des vues.
            Task { [onAttach] in onAttach(window) }
        }
    }
}
