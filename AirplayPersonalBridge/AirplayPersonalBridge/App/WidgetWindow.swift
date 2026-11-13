//
//  WidgetWindow.swift
//  AirplayPersonalBridge
//

import AppKit
import AudioCore
import OSLog
import SwiftUI

private let widgetLog = Logger(subsystem: AudioLog.subsystem, category: "widget")

/// La fenêtre du widget, vue par ce qui la commande. Injectée : aucun test ne doit en montrer une.
protocol WidgetWindowing: AnyObject {
    var isShown: Bool { get }
    /// Appelée quand l'utilisateur a déplacé la fenêtre, avec son nouveau coin bas gauche.
    var onMove: ((CGPoint) -> Void)? { get set }
    /// Montre la fenêtre là où elle était, ou dans le coin de l'écran si cette place n'existe plus. Sans
    /// passer l'app au premier plan.
    func show(at saved: CGPoint?)
    func hide()
    func setFloating(_ floats: Bool)
}

/// Fait suivre à la fenêtre du widget ce que disent les réglages (`BridgeState.widget`), et mémorise sa
/// place.
///
/// Les vues n'ouvrent ni ne ferment rien : elles écrivent `state.widget`, d'où qu'elles soient (panneau de
/// la barre de menus, bouton des options, Réglages, menu du widget), et la fenêtre suit. Le widget ne
/// touche ni à l'icône du Dock ni à la politique d'activation : il vit à côté des fenêtres de l'app.
final class WidgetController {
    private let state: BridgeState
    private let window: any WidgetWindowing
    private var isObserving = false

    init(state: BridgeState, window: any WidgetWindowing) {
        self.state = state
        self.window = window
        window.onMove = { [weak self] origin in self?.remember(origin) }
    }

    /// Au lancement : rouvre le widget s'il était affiché, puis suit les réglages.
    func start() {
        sync()
        guard !isObserving else { return }
        isObserving = true
        observe()
    }

    /// Met la fenêtre dans l'état que disent les réglages. Sans effet si elle y est déjà : un changement de
    /// place ou de style ne la remontre pas.
    func sync() {
        let settings = state.widget
        window.setFloating(settings.floatsOnTop)
        if settings.isShown {
            guard !window.isShown else { return }
            window.show(at: settings.position.map { CGPoint(x: $0.x, y: $0.y) })
        } else if window.isShown {
            window.hide()
        }
    }

    private func remember(_ origin: CGPoint) {
        // Une fenêtre qui se ferme n'a plus rien à mémoriser.
        guard state.widget.isShown else { return }
        state.widget.position = WidgetSettings.Position(x: origin.x, y: origin.y)
    }

    /// `withObservationTracking` ne prévient qu'une fois, et avant le changement : on relit au tour suivant,
    /// puis on se réabonne.
    private func observe() {
        withObservationTracking {
            _ = state.widget
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.sync()
                self.observe()
            }
        }
    }
}

// MARK: - Fenêtre réelle

/// Le panneau du widget. Sans barre de titre, un `NSWindow` refuse de devenir la fenêtre du clavier : on le
/// lui rend, pour les flèches sur un curseur et pour VoiceOver.
final class WidgetPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// La vue hébergée du widget : son premier clic compte, la fenêtre n'étant jamais active.
final class WidgetHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// La vraie fenêtre du widget : un `NSPanel` sans chrome, créé à la première ouverture.
///
/// Un `NSPanel` plutôt qu'une scène SwiftUI `Window` : seul un panneau non activant laisse régler un
/// curseur sans prendre le premier plan à l'application en cours, et il se configure et se teste hors de
/// toute scène (le point d'entrée `@main` n'est compilé que par Xcode).
final class LiveWidgetWindow: WidgetWindowing {
    private let state: BridgeState
    /// Posée par `AppLifecycle` : la vue du widget demande la fenêtre principale par là.
    var openMainWindow: () -> Void = {}
    var onMove: ((CGPoint) -> Void)?

    private var panel: WidgetPanel?
    private var observers: [any NSObjectProtocol] = []
    /// Le temps d'une mise en place par l'app : ce déplacement-là n'est pas celui de l'utilisateur.
    private var isPlacing = false
    private var floats = true

    init(state: BridgeState) {
        self.state = state
    }

    var isShown: Bool { panel?.isVisible ?? false }

    func show(at saved: CGPoint?) {
        let panel = panel ?? makePanel()
        self.panel = panel
        place(panel, at: saved)
        // `orderFrontRegardless` : l'app est souvent `.accessory`, sans fenêtre ni premier plan, et ne
        // doit pas les prendre pour montrer son widget.
        panel.orderFrontRegardless()
        panel.invalidateShadow()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    func setFloating(_ floats: Bool) {
        self.floats = floats
        panel?.level = Self.level(floats: floats)
    }

    static func level(floats: Bool) -> NSWindow.Level {
        floats ? .floating : .normal
    }

    private func place(_ panel: NSPanel, at saved: CGPoint?) {
        isPlacing = true
        defer { isPlacing = false }
        panel.setFrameOrigin(
            WidgetPlacement.origin(
                saved: saved, size: WidgetMetrics.size, screens: NSScreen.screens.map(\.visibleFrame),
                main: NSScreen.main?.visibleFrame
            )
        )
    }

    private func makePanel() -> WidgetPanel {
        let content = WidgetHostingView(
            rootView: WidgetView(
                state: state, actions: WidgetActions(openMainWindow: { [weak self] in self?.openMainWindow() })
            )
        )
        // La vue a une taille fixe : elle n'a pas à redimensionner sa fenêtre.
        content.sizingOptions = []
        let panel = Self.makePanel(content: content, floats: floats)
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: NSWindow.didMoveNotification, object: panel, queue: .main) {
                [weak self, weak panel] _ in
                MainActor.assumeIsolated {
                    guard let self, let panel, !self.isPlacing, panel.isVisible else { return }
                    self.onMove?(panel.frame.origin)
                }
            },
            // Un écran débranché ou une résolution changée : le widget ne doit pas rester hors d'atteinte.
            center.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
            ) { [weak self, weak panel] _ in
                MainActor.assumeIsolated {
                    guard let self, let panel, panel.isVisible else { return }
                    self.place(panel, at: panel.frame.origin)
                }
            },
        ]
        widgetLog.info("Fenêtre du widget créée")
        return panel
    }

    /// Le panneau configuré, sans l'afficher : hors de l'instance pour être testé.
    static func makePanel(content: NSView, floats: Bool) -> WidgetPanel {
        let panel = WidgetPanel(
            contentRect: CGRect(origin: .zero, size: WidgetMetrics.size),
            // Sans barre de titre ni boutons ; non activant : y régler un curseur ne prend pas le premier
            // plan à l'application en cours.
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true
        )
        panel.title = "Widget AirPlay Personal Bridge"
        panel.isReleasedWhenClosed = false
        // Le rectangle arrondi est dessiné par la vue : la fenêtre est transparente autour, et son ombre
        // suit le dessin.
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        // Le fond se saisit par `WidgetBackdrop`, pas par la fenêtre : un curseur qu'on glisse ne doit pas
        // l'emporter.
        panel.isMovableByWindowBackground = false
        panel.isMovable = true
        panel.level = level(floats: floats)
        // Sur tous les bureaux, et par-dessus une app en plein écran.
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        // L'app perd le premier plan en permanence : le widget reste.
        panel.hidesOnDeactivate = false
        // Il ne prend le clavier que si une commande le demande : un clic sur un curseur ne retire pas la
        // frappe à l'application en cours.
        panel.becomesKeyOnlyIfNeeded = true
        panel.isExcludedFromWindowsMenu = true
        panel.animationBehavior = .utilityWindow
        content.frame = CGRect(origin: .zero, size: WidgetMetrics.size)
        panel.contentView = content
        panel.setContentSize(WidgetMetrics.size)
        panel.contentMinSize = WidgetMetrics.size
        panel.contentMaxSize = WidgetMetrics.size
        return panel
    }
}
