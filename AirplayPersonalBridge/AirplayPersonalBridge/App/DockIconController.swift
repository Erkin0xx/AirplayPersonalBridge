//
//  DockIconController.swift
//  AirplayPersonalBridge
//

import AppKit

/// Ce que l'application demande au système pour se montrer ou s'effacer. Injecté pour tester les
/// enchaînements sans toucher à l'application réelle.
protocol ApplicationPresenting {
    func setDockIconVisible(_ visible: Bool)
    func activate()
}

struct LiveApplicationPresenter: ApplicationPresenting {
    func setDockIconVisible(_ visible: Bool) {
        NSApplication.shared.setActivationPolicy(visible ? .regular : .accessory)
    }

    func activate() {
        NSApplication.shared.activate()
    }
}

/// L'icône du Dock n'existe que tant qu'une fenêtre est ouverte.
///
/// L'app vit dans la barre de menus : une icône permanente dans le Dock n'y apporterait rien. Mais
/// une fenêtre sans icône du Dock ne se retrouve pas dans ⌘⇥ et n'a pas de menu : le temps qu'elle
/// est ouverte, l'app redevient une application ordinaire. Cela vaut pour la fenêtre principale comme
/// pour celle des réglages, qui s'ouvre aussi depuis la barre de menus, sans l'autre.
final class DockIconController {
    /// Les fenêtres de l'app qui justifient l'icône.
    enum Window: Hashable {
        case main
        case settings
    }

    private let presenter: any ApplicationPresenting
    private var openWindows: Set<Window> = []
    var isWindowOpen: Bool { !openWindows.isEmpty }

    init(presenter: any ApplicationPresenting = LiveApplicationPresenter()) {
        self.presenter = presenter
    }

    /// Avant d'ouvrir la fenêtre : une app `.accessory` ne peut pas passer au premier plan, et la
    /// fenêtre s'ouvrirait derrière celle de l'application en cours.
    func prepareToShowWindow() {
        presenter.setDockIconVisible(true)
        presenter.activate()
    }

    func windowDidOpen(_ window: Window = .main) {
        guard openWindows.insert(window).inserted else { return }
        presenter.setDockIconVisible(true)
        presenter.activate()
    }

    /// Différé d'un tour : changer de politique pendant que la fenêtre se ferme perturbe AppKit, et
    /// une fenêtre rouverte dans la foulée n'a pas à faire clignoter l'icône.
    func windowWillClose(_ window: Window = .main) {
        openWindows.remove(window)
        Task { [weak self] in
            await Task.yield()
            guard let self, !self.isWindowOpen else { return }
            self.presenter.setDockIconVisible(false)
        }
    }
}
