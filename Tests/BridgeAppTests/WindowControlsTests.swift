import AppKit
import Foundation
import SwiftUI
import Testing

@testable import BridgeApp

/// Une fenêtre qui note ce qu'on lui demande, sans rien faire.
private final class SpyWindow: WindowControlling {
    enum Request: Equatable { case close, minimize, fullScreenToggle, zoom }

    var isInFullScreen = false
    private(set) var requests: [Request] = []

    func requestClose() { requests.append(.close) }
    func requestMinimize() { requests.append(.minimize) }
    func requestFullScreenToggle() { requests.append(.fullScreenToggle) }
    func requestZoom() { requests.append(.zoom) }
}

@Suite("Commandes de fenêtre — ce que fait chaque bouton")
struct WindowControlActionTests {
    @Test("Fermer ferme, réduire réduit, avec ou sans ⌥", arguments: [false, true])
    func closeAndMinimize(optionHeld: Bool) {
        let window = SpyWindow()
        WindowControl.close.perform(on: window, optionHeld: optionHeld)
        #expect(window.requests == [.close])
        WindowControl.minimize.perform(on: window, optionHeld: optionHeld)
        #expect(window.requests == [.close, .minimize])
    }

    @Test("Agrandir bascule le plein écran")
    func enlargeTogglesFullScreen() {
        let window = SpyWindow()
        WindowControl.enlarge.perform(on: window, optionHeld: false)
        #expect(window.requests == [.fullScreenToggle])
    }

    @Test("Agrandir avec ⌥ agrandit sans plein écran")
    func enlargeWithOptionZooms() {
        let window = SpyWindow()
        WindowControl.enlarge.perform(on: window, optionHeld: true)
        #expect(window.requests == [.zoom])
    }

    /// Comme le bouton vert : en plein écran, il en sort, ⌥ ou non. Un zoom y laisserait la fenêtre
    /// en plein écran, sans sortie visible.
    @Test("En plein écran, agrandir en sort, avec ou sans ⌥", arguments: [false, true])
    func enlargeLeavesFullScreen(optionHeld: Bool) {
        let window = SpyWindow()
        window.isInFullScreen = true
        WindowControl.enlarge.perform(on: window, optionHeld: optionHeld)
        #expect(window.requests == [.fullScreenToggle])
    }

    @Test("Les boutons sont dans l'ordre de macOS, chacun avec son libellé")
    func labels() {
        #expect(WindowControl.allCases == [.close, .minimize, .enlarge])
        #expect(WindowControl.close.accessibilityLabel(isFullScreen: false) == "Fermer la fenêtre")
        #expect(WindowControl.minimize.accessibilityLabel(isFullScreen: false) == "Réduire la fenêtre")
        #expect(WindowControl.enlarge.accessibilityLabel(isFullScreen: false) == "Agrandir la fenêtre")
        #expect(WindowControl.enlarge.accessibilityLabel(isFullScreen: true) == "Quitter le plein écran")
        #expect(
            WindowControl.enlarge.symbol(isFullScreen: true) != WindowControl.enlarge.symbol(isFullScreen: false)
        )
        // Un nom de SF Symbol inconnu n'affiche rien, sans erreur.
        for control in WindowControl.allCases {
            for isFullScreen in [false, true] {
                let name = control.symbol(isFullScreen: isFullScreen)
                #expect(NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil, "\(name)")
            }
        }
    }
}

@Suite("Commandes de fenêtre — géométrie")
struct WindowControlsMetricsTests {
    @Test("Chaque bouton offre au moins 24 points, dans une capsule plus petite que les autres commandes")
    func sizes() {
        #expect(WindowControlsMetrics.buttonSize.width >= 24)
        #expect(WindowControlsMetrics.buttonSize.height >= 24)
        #expect(WindowControlsMetrics.height < WindowChromeMetrics.controlHeight)
    }

    @Test("La capsule est centrée en hauteur sur la pastille de source")
    func verticalAlignment() {
        let pillCenter = WindowChromeMetrics.topPadding + WindowChromeMetrics.controlHeight / 2
        #expect(WindowControlsMetrics.top + WindowControlsMetrics.height / 2 == pillCenter)
    }

    /// Les outils du plan commencent à `trafficLightsWidth` : ni chevauchement, ni trou.
    @Test("La place réservée à gauche est celle de la capsule, marge et écart compris")
    func reservedWidth() {
        let capsuleEnd = WindowChromeMetrics.sideMargin + WindowControlsMetrics.width
        #expect(WindowChromeMetrics.trafficLightsWidth == capsuleEnd + WindowControlsMetrics.trailingGap)
        #expect(WindowControlsMetrics.trailingGap >= 6)
        #expect(WindowControlsMetrics.trailingGap <= 12)
    }
}

private final class Flag {
    var isSet = false
}

@Suite("Commandes de fenêtre — boutons système")
struct SystemWindowButtonsTests {
    private static let mask: NSWindow.StyleMask = [
        .titled, .closable, .miniaturizable, .resizable, .fullSizeContentView,
    ]

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 400, height: 300), styleMask: Self.mask,
            backing: .buffered, defer: true
        )
        window.isReleasedWhenClosed = false
        return window
    }

    /// Écrits ici, et non repris de `SystemWindowButtons.replaced` : un bouton oublié là-bas doit se voir.
    private static let systemButtons: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]

    private func hiddenFlags(_ window: NSWindow) -> [Bool?] {
        Self.systemButtons.map { window.standardWindowButton($0)?.isHidden }
    }

    private func makeLifecycle() -> AppLifecycle {
        AppLifecycle(
            state: BridgeHarness().state,
            loginItem: LoginItemController(service: PreviewLoginItemService()),
            dock: DockIconController(presenter: StubPresenter()),
            coreAudio: StubCoreAudioRestarter()
        )
    }

    @Test("La fenêtre principale perd ses trois boutons système dès son rattachement")
    func mainWindowHidesThem() {
        let window = makeWindow()
        #expect(hiddenFlags(window) == [false, false, false])
        makeLifecycle().mainWindowDidAttach(window)
        #expect(hiddenFlags(window) == [true, true, true])
    }

    @Test("La fenêtre des réglages garde les siens")
    func settingsWindowKeepsThem() {
        let window = makeWindow()
        makeLifecycle().settingsWindowDidAttach(window)
        #expect(hiddenFlags(window) == [false, false, false])
    }

    /// AppKit peut les réafficher en recomposant la barre de titre : le masquage est reposé à chacun de
    /// ces moments, et au retour de la fenêtre au premier plan.
    @Test("Le masquage est reposé quand la barre de titre se recompose")
    func hidesAgain() {
        let window = makeWindow()
        let lifecycle = makeLifecycle()
        lifecycle.mainWindowDidAttach(window)
        for name in AppLifecycle.titlebarRebuildNotifications + [NSWindow.didBecomeKeyNotification] {
            for type in Self.systemButtons {
                window.standardWindowButton(type)?.isHidden = false
            }
            NotificationCenter.default.post(name: name, object: window)
            #expect(hiddenFlags(window) == [true, true, true], "\(name.rawValue)")
        }
        withExtendedLifetime(lifecycle) {}
    }

    @Test("Le plein écran fait partie des moments où le masquage est reposé")
    func fullScreenIsCovered() {
        #expect(AppLifecycle.titlebarRebuildNotifications.contains(NSWindow.didEnterFullScreenNotification))
        #expect(AppLifecycle.titlebarRebuildNotifications.contains(NSWindow.didExitFullScreenNotification))
    }

    /// `performClose` simule le bouton rouge : il doit fermer la fenêtre même quand ce bouton est masqué,
    /// sinon le bouton de l'app ne ferait que sonner.
    @Test("Fermer aboutit sur une vraie fenêtre aux boutons masqués")
    func closeWorksWithHiddenButton() {
        let window = makeWindow()
        SystemWindowButtons.hide(in: window)
        let closed = Flag()
        let observer = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: nil
        ) { _ in MainActor.assumeIsolated { closed.isSet = true } }
        defer { NotificationCenter.default.removeObserver(observer) }
        WindowControl.close.perform(on: window, optionHeld: false)
        #expect(closed.isSet)
    }

    @Test("Ce qui bouge continue tant que la fenêtre se voit, même sans le premier plan")
    func motionFollowsVisibilityNotFocus() {
        #expect(WindowVisibility.isOnScreen([.visible]))
        // Réduite, recouverte, sur un autre bureau : `occlusionState` perd `.visible`.
        #expect(!WindowVisibility.isOnScreen([]))
        // Hors de la fenêtre principale (aperçu, rendu d'essai), rien ne se fige.
        #expect(EnvironmentValues().windowIsOnScreen)
    }
}
