//
//  WindowVisibility.swift
//  AirplayPersonalBridge
//

import AppKit
import SwiftUI

/// La fenêtre se voit-elle à l'écran, au moins en partie.
///
/// Ce qui bouge dans la fenêtre (fond, ondes, centre du halo, barres) continue quand une autre app est au
/// premier plan : Baptiste garde la fenêtre à côté de son travail et veut la voir vivre (2026-11-11).
/// `appearsActive` figeait tout dès qu'elle perdait le premier plan. Ce qui arrête le mouvement, c'est que
/// personne ne puisse le voir : fenêtre réduite dans le Dock, entièrement recouverte, sur un autre bureau,
/// app masquée — ce que dit `NSWindow.occlusionState`.
///
/// Vrai par défaut : un aperçu, un rendu d'essai ou une vue hors de la fenêtre principale s'animent.
private struct WindowIsOnScreenKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    var windowIsOnScreen: Bool {
        get { self[WindowIsOnScreenKey.self] }
        set { self[WindowIsOnScreenKey.self] = newValue }
    }
}

extension View {
    /// Suit la visibilité de la fenêtre qui porte cette vue, et la donne à tout ce qu'elle contient.
    func tracksWindowVisibility() -> some View {
        modifier(WindowVisibilityTracker())
    }
}

private struct WindowVisibilityTracker: ViewModifier {
    @State private var isOnScreen = true

    func body(content: Content) -> some View {
        content
            .environment(\.windowIsOnScreen, isOnScreen)
            .background(WindowOcclusionObserver { isOnScreen = $0 })
    }
}

/// Relève `occlusionState` de la fenêtre, à son rattachement puis à chaque changement.
private struct WindowOcclusionObserver: NSViewRepresentable {
    let onChange: (Bool) -> Void

    func makeNSView(context: Context) -> ObserverView {
        ObserverView(onChange: onChange)
    }

    func updateNSView(_ view: ObserverView, context: Context) {}

    final class ObserverView: NSView {
        private let onChange: (Bool) -> Void
        private var observer: (any NSObjectProtocol)?

        init(onChange: @escaping (Bool) -> Void) {
            self.onChange = onChange
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("Cette vue n'est créée que par SwiftUI")
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            guard let window else { return }
            observer = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.report() }
            }
            // Au tour suivant : pas de changement d'état en pleine mise à jour des vues.
            Task { [weak self] in self?.report() }
        }

        private func report() {
            guard let window else { return }
            onChange(WindowVisibility.isOnScreen(window.occlusionState))
        }
    }
}

/// La règle, hors de la vue pour être testée.
nonisolated enum WindowVisibility {
    static func isOnScreen(_ state: NSWindow.OcclusionState) -> Bool {
        state.contains(.visible)
    }
}
