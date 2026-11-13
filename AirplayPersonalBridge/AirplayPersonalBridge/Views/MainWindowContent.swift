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
            // Ce qui bouge continue tant que la fenêtre se voit, premier plan ou non.
            .tracksWindowVisibility()
            .background(WindowAttachmentObserver { lifecycle.mainWindowDidAttach($0) })
            .capturesSceneActions(for: lifecycle)
    }
}

extension View {
    /// Donne à l'app les actions que seule une vue de scène obtient (`SceneActions`). À poser sur une vue
    /// de chaque scène qui peut apparaître la première.
    func capturesSceneActions(for lifecycle: AppLifecycle) -> some View {
        modifier(SceneActionsCapture(lifecycle: lifecycle))
    }
}

private struct SceneActionsCapture: ViewModifier {
    let lifecycle: AppLifecycle
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content.onAppear {
            lifecycle.sceneActions = SceneActions(openMainWindow: { openWindow(id: MainWindow.id) })
        }
    }
}

/// Le contenu de la fenêtre des réglages (scène `Settings`), relié de même à son `NSWindow` : ouverte
/// depuis la barre de menus, elle doit passer devant et donner à l'app son icône du Dock.
struct SettingsWindowContent: View {
    let lifecycle: AppLifecycle

    var body: some View {
        SettingsView(state: lifecycle.state)
            .background(WindowAttachmentObserver { lifecycle.settingsWindowDidAttach($0) })
    }
}

/// Prévient dès que la vue est rattachée à un `NSWindow` : aussi pour `WindowControls`, qui agit sur sa
/// fenêtre.
struct WindowAttachmentObserver: NSViewRepresentable {
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
