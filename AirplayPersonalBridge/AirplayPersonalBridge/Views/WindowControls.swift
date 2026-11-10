//
//  WindowControls.swift
//  AirplayPersonalBridge
//

import AppKit
import SwiftUI

/// Ce qu'une commande de fenêtre peut demander à sa fenêtre. Un protocole pour que la règle « quel bouton
/// fait quoi, avec ou sans ⌥ » se teste sans fenêtre réelle.
protocol WindowControlling: AnyObject {
    var isInFullScreen: Bool { get }
    /// Comme le bouton rouge : la fenêtre se ferme, son délégué consulté, et l'app reste dans la barre de menus.
    func requestClose()
    func requestMinimize()
    func requestFullScreenToggle()
    /// Agrandir à la taille utile de l'écran, sans plein écran, ou revenir à la taille d'avant.
    func requestZoom()
}

extension NSWindow: WindowControlling {
    var isInFullScreen: Bool { styleMask.contains(.fullScreen) }
    func requestClose() { performClose(nil) }
    // `miniaturize`, et non `performMiniaturize` : ce dernier simule un clic sur le bouton système, masqué.
    func requestMinimize() { miniaturize(nil) }
    func requestFullScreenToggle() { toggleFullScreen(nil) }
    func requestZoom() { zoom(nil) }
}

/// Les trois commandes de la fenêtre, dans l'ordre des boutons de macOS.
enum WindowControl: CaseIterable, Identifiable {
    case close, minimize, enlarge

    var id: Self { self }

    /// Ce que fait le bouton, comme son équivalent système. « Agrandir » bascule le plein écran ; avec ⌥,
    /// il agrandit sans plein écran. En plein écran, il en sort toujours : ⌥ n'y change rien, comme le
    /// bouton vert.
    func perform(on window: any WindowControlling, optionHeld: Bool) {
        switch self {
        case .close:
            window.requestClose()
        case .minimize:
            window.requestMinimize()
        case .enlarge:
            if optionHeld, !window.isInFullScreen {
                window.requestZoom()
            } else {
                window.requestFullScreenToggle()
            }
        }
    }

    func symbol(isFullScreen: Bool) -> String {
        switch self {
        case .close: "xmark"
        case .minimize: "minus"
        case .enlarge:
            isFullScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right"
        }
    }

    func accessibilityLabel(isFullScreen: Bool) -> String {
        switch self {
        case .close: "Fermer la fenêtre"
        case .minimize: "Réduire la fenêtre"
        case .enlarge: isFullScreen ? "Quitter le plein écran" : "Agrandir la fenêtre"
        }
    }

    func help(isFullScreen: Bool) -> String {
        switch self {
        case .close: "Fermer la fenêtre (⌘W). L'app reste dans la barre de menus."
        case .minimize: "Réduire la fenêtre dans le Dock (⌘M)"
        case .enlarge:
            isFullScreen
                ? "Quitter le plein écran"
                : "Plein écran. Avec ⌥ : agrandir la fenêtre sans plein écran."
        }
    }
}

/// La géométrie de la capsule des commandes de fenêtre : plus petite que les commandes de droite, et
/// centrée sur leur ligne.
enum WindowControlsMetrics {
    /// La surface cliquable de chaque bouton.
    static let buttonSize = CGSize(width: 26, height: 26)
    static let innerPadding: CGFloat = 3
    static let height: CGFloat = buttonSize.height + 2 * innerPadding
    static let width: CGFloat = CGFloat(WindowControl.allCases.count) * buttonSize.width + 2 * innerPadding
    /// Du haut de la fenêtre à la capsule : centrée en hauteur sur la pastille de source.
    static let top: CGFloat =
        WindowChromeMetrics.topPadding + (WindowChromeMetrics.controlHeight - height) / 2
    /// De la capsule à ce qui la suit sur la même ligne (les outils du plan).
    static let trailingGap: CGFloat = 8
}

/// Les boutons système de la fenêtre principale, masqués : `WindowControls` les remplace.
enum SystemWindowButtons {
    static let replaced: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]

    /// Masque les boutons rouge, orange et vert. À reposer : AppKit reconstruit la barre de titre, et ses
    /// boutons avec elle, à certains changements de la fenêtre (`AppLifecycle.mainWindowDidAttach`).
    static func hide(in window: NSWindow) {
        for type in replaced {
            window.standardWindowButton(type)?.isHidden = true
        }
    }
}

/// Fermer, réduire, agrandir : une capsule de verre en haut à gauche, à la place des boutons système.
///
/// Sans couleur : des icônes blanches sur le verre des autres commandes, qui s'éclaircissent au survol.
/// Elle reste visible en plein écran, où macOS cache les siens tant que la souris ne monte pas : c'est la
/// seule sortie visible du plein écran.
struct WindowControls: View {
    /// La fenêtre visée, pour les tests et les rendus ; sans elle, celle qui porte la vue.
    var target: (any WindowControlling)?
    @State private var host = WindowReference()
    @State private var isHovered = false
    @State private var hoveredControl: WindowControl?
    @State private var isFullScreen = false

    var body: some View {
        HStack(spacing: 0) {
            ForEach(WindowControl.allCases) { control in
                button(control)
            }
        }
        .padding(WindowControlsMetrics.innerPadding)
        .floatingGlass(in: Capsule(), interactive: true)
        .contentShape(Capsule())
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.15), value: isHovered)
        .animation(.easeOut(duration: 0.12), value: hoveredControl)
        .background(
            WindowAttachmentObserver { window in
                host.window = window
                isFullScreen = window.isInFullScreen
            }
        )
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) {
            noteFullScreen($0, entered: true)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) {
            noteFullScreen($0, entered: false)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Commandes de la fenêtre")
    }

    private func button(_ control: WindowControl) -> some View {
        Button {
            guard let window = target ?? host.window else { return }
            control.perform(on: window, optionHeld: NSEvent.modifierFlags.contains(.option))
        } label: {
            Image(systemName: control.symbol(isFullScreen: isFullScreen))
                .font(.system(size: 10.5, weight: .bold))
                .foregroundStyle(.white.opacity(isHovered ? 1 : 0.72))
                .frame(width: WindowControlsMetrics.buttonSize.width, height: WindowControlsMetrics.buttonSize.height)
                .background(.white.opacity(hoveredControl == control ? 0.16 : 0), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hoveredControl = $0 ? control : (hoveredControl == control ? nil : hoveredControl) }
        .help(control.help(isFullScreen: isFullScreen))
        .accessibilityLabel(control.accessibilityLabel(isFullScreen: isFullScreen))
    }

    private func noteFullScreen(_ notification: Notification, entered: Bool) {
        guard let window = notification.object as? NSWindow, window === host.window else { return }
        isFullScreen = entered
    }
}

/// La fenêtre qui porte la vue, sans la retenir.
private final class WindowReference {
    weak var window: NSWindow?
}
