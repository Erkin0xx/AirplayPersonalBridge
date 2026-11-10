//
//  AppLifecycle.swift
//  AirplayPersonalBridge
//

import AppKit
import AudioCore
import Foundation

/// Identifiant de la fenêtre unique de l'app, partagé entre la scène et le panneau qui la rouvre.
enum MainWindow {
    static let id = "main"
}

/// La coquille de l'app : ce qui doit vivre avec ou sans fenêtre.
///
/// C'est ici que tout se joue depuis que l'app vit dans la barre de menus : le moteur doit tourner
/// fenêtre fermée, la découverte démarrer sans qu'aucune vue n'apparaisse, et quitter doit laisser
/// à chaque récepteur le temps de recevoir son `TEARDOWN`.
///
/// Hors de `AirplayPersonalBridgeApp.swift` pour que `swift build` la compile et que `swift test`
/// la couvre : le point d'entrée `@main` n'appartient qu'à la cible Xcode.
final class AppLifecycle: NSObject, NSApplicationDelegate {
    /// Borne de l'arrêt à la fermeture de l'app, relance de coreaudiod comprise. Un récepteur muet ne
    /// doit pas retenir la session de l'utilisateur ; au-delà, ce récepteur finira par expirer de
    /// lui-même.
    static let shutdownTimeout: Duration = .seconds(5)
    /// La part de la borne laissée à la relance de coreaudiod, dernière action avant de fermer.
    static let coreAudioRestartTimeout: Duration = .seconds(1)
    /// Au-delà, AppKit a sa réponse même si l'arrêt n'a pas pu tourner (`TerminationReply`). Après la
    /// borne : tant que le MainActor tourne, c'est elle qui répond.
    static let replyFallbackDelay: Duration = shutdownTimeout + .seconds(1)
    /// L'arrêt des sorties a ce que la relance laisse de la borne : 4 s.
    static let quitBudget = QuitSequence.Budget(
        outputs: shutdownTimeout - coreAudioRestartTimeout,
        coreAudioRestart: coreAudioRestartTimeout
    )

    let state: BridgeState
    let loginItem: LoginItemController
    let dock: DockIconController
    private let coreAudio: any CoreAudioRestarting
    private let quitBudget: QuitSequence.Budget

    private var isTerminating = false
    private var wasLaunchedAtLogin = false
    private weak var mainWindow: NSWindow?
    private var windowObservers: [any NSObjectProtocol] = []
    private weak var settingsWindow: NSWindow?
    private var settingsWindowObservers: [any NSObjectProtocol] = []
    private var powerObservers: [any NSObjectProtocol] = []

    /// Celle qu'emploie `@NSApplicationDelegateAdaptor`, seule à relancer le vrai coreaudiod.
    override convenience init() {
        self.init(
            state: BridgeState(environment: .live),
            loginItem: LoginItemController(),
            dock: DockIconController(),
            coreAudio: LiveCoreAudioRestarter(command: .killCoreAudio)
        )
    }

    /// - Parameter coreAudio: sans valeur par défaut, pour qu'aucun test ne relance coreaudiod par
    ///   mégarde : chacun passe une doublure.
    init(
        state: BridgeState, loginItem: LoginItemController, dock: DockIconController,
        coreAudio: any CoreAudioRestarting, quitBudget: QuitSequence.Budget = AppLifecycle.quitBudget
    ) {
        self.state = state
        self.loginItem = loginItem
        self.dock = dock
        self.coreAudio = coreAudio
        self.quitBudget = quitBudget
        super.init()
    }

    // MARK: - Lancement

    func applicationDidFinishLaunching(_ notification: Notification) {
        noteLaunch(
            asLoginItem: Self.isLoginItemLaunch(NSAppleEventManager.shared().currentAppleEvent)
        )
        observePower()
        // Ici et non dans une vue : à l'ouverture de session, aucune n'apparaît.
        state.startBackgroundWork()
    }

    func noteLaunch(asLoginItem: Bool) {
        wasLaunchedAtLogin = asLoginItem
        closeWindowIfLaunchedAtLogin()
    }

    /// L'événement d'ouverture dit si macOS a lancé l'app comme élément d'ouverture de session.
    /// Seul ce cas reste discret : lancée à la main, une app qui ne montre rien paraît en panne.
    static func isLoginItemLaunch(_ event: NSAppleEventDescriptor?) -> Bool {
        guard let event, event.eventID == kAEOpenApplication else { return false }
        return event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue
            == keyAELaunchedAsLogInItem
    }

    // MARK: - Fenêtre

    /// La scène `Window` ne survit pas à la fermeture de sa dernière fenêtre sans ce refus : le
    /// moteur vit dans ce processus, qui doit rester en vie pour continuer à diffuser.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Appelée par la vue de la fenêtre dès qu'elle est rattachée à son `NSWindow`.
    func mainWindowDidAttach(_ window: NSWindow) {
        guard mainWindow !== window else {
            dock.windowDidOpen()
            bringToFront(window)
            return
        }
        mainWindow = window
        for observer in windowObservers { NotificationCenter.default.removeObserver(observer) }
        windowObservers = [
            NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.dock.windowWillClose() }
            },
            // Une fenêtre rouverte peut réutiliser le même `NSWindow`, sans repasser par la vue.
            NotificationCenter.default.addObserver(
                forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.dock.windowDidOpen() }
            },
        ]
        // Avant toute chose : passer au premier plan pour se refermer aussitôt ferait clignoter
        // l'icône du Dock et voler la main à l'ouverture de session.
        guard !closeWindowIfLaunchedAtLogin() else { return }
        dock.windowDidOpen()
        if window.isVisible { bringToFront(window) }
    }

    /// `activate` est coopératif depuis macOS 14 : une app qui sort de l'état `.accessory` peut se
    /// voir refuser le premier plan, et sa fenêtre s'ouvrir derrière celle de l'application en
    /// cours. L'utilisateur vient de la demander, elle doit passer devant.
    private func bringToFront(_ window: NSWindow) {
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    /// `Window` ouvre sa fenêtre au lancement. À l'ouverture de session, c'est la seule exception
    /// à la refermer aussitôt. Ni `applicationDidFinishLaunching` ni le rattachement de la vue ne
    /// passent avant l'autre à coup sûr : chacun essaie, et le second aboutit.
    @discardableResult
    private func closeWindowIfLaunchedAtLogin() -> Bool {
        guard wasLaunchedAtLogin, let mainWindow else { return false }
        wasLaunchedAtLogin = false
        mainWindow.close()
        return true
    }

    /// Rouvre la fenêtre depuis le panneau, au premier plan.
    ///
    /// La fenêtre déjà ouverte est amenée devant. Une fenêtre fermée n'est pas touchée : SwiftUI en
    /// a peut-être recréé une autre, et réafficher l'ancienne la montrerait vide.
    func showMainWindow(using open: () -> Void) {
        // Une demande explicite l'emporte sur la discrétion de l'ouverture de session.
        wasLaunchedAtLogin = false
        dock.prepareToShowWindow()
        open()
        guard let mainWindow else { return }
        if mainWindow.isMiniaturized { mainWindow.deminiaturize(nil) }
        if mainWindow.isVisible { bringToFront(mainWindow) }
    }

    // MARK: - Fenêtre des réglages

    /// Ouvre la fenêtre des réglages depuis le panneau de la barre de menus, au premier plan.
    ///
    /// Sans fenêtre principale, l'app est `.accessory` : elle ne peut pas passer devant, et la fenêtre
    /// des réglages s'ouvrirait derrière celle de l'application en cours. D'où l'icône du Dock et
    /// l'activation **avant** l'ouverture, comme pour la fenêtre principale.
    func showSettingsWindow(using open: () -> Void) {
        dock.prepareToShowWindow()
        open()
        if let settingsWindow, settingsWindow.isVisible { bringToFront(settingsWindow) }
    }

    /// Appelée par la vue des réglages dès qu'elle est rattachée à son `NSWindow`, d'où qu'elle ait été
    /// ouverte (⌘,, bouton des options, panneau).
    func settingsWindowDidAttach(_ window: NSWindow) {
        if settingsWindow !== window {
            settingsWindow = window
            for observer in settingsWindowObservers { NotificationCenter.default.removeObserver(observer) }
            settingsWindowObservers = [
                NotificationCenter.default.addObserver(
                    forName: NSWindow.willCloseNotification, object: window, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.dock.windowWillClose(.settings) }
                },
                // Rouverte, la fenêtre peut réutiliser le même `NSWindow`, sans repasser par la vue.
                NotificationCenter.default.addObserver(
                    forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.dock.windowDidOpen(.settings) }
                },
            ]
        }
        dock.windowDidOpen(.settings)
        if window.isVisible { bringToFront(window) }
    }

    // MARK: - Panneau

    func panelDidOpen() {
        state.panelDidOpen()
        loginItem.refresh()
    }

    // MARK: - Veille

    private func observePower() {
        let center = NSWorkspace.shared.notificationCenter
        powerObservers = [
            center.addObserver(
                forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.state.systemWillSleep() }
            },
            center.addObserver(
                forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.state.systemDidWake() }
            },
        ]
    }

    // MARK: - Quitter

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        handleTerminationRequest { sender.reply(toApplicationShouldTerminate: true) }
    }

    /// Toute fermeture passe par `QuitSequence`, diffusion en cours ou non : quitter sur-le-champ
    /// laisserait un récepteur bloqué sur une session sans `TEARDOWN`, et la relance de coreaudiod,
    /// dernière action de l'app, vaut à chaque fois. AppKit attend donc toujours une réponse bornée.
    ///
    /// Vaut aussi pour SIGTERM : `TerminationSignal` le convertit en `terminate`, qui passe ici. La
    /// borne ne tient que si le MainActor tourne pendant l'attente d'AppKit : `TerminationReply` répond
    /// de lui-même sinon.
    func handleTerminationRequest(reply: @escaping () -> Void) -> NSApplication.TerminateReply {
        guard !isTerminating else { return .terminateLater }
        isTerminating = true
        let answer = TerminationReply(fallbackAfter: Self.replyFallbackDelay, reply: reply)
        let sequence = QuitSequence(
            stopOutputs: { [state] limit in await state.shutdown(timeout: limit) },
            restoreSystemOutput: { [state] in state.restoreSystemOutput() },
            coreAudio: coreAudio,
            budget: quitBudget
        )
        Task {
            await sequence.run { answer.send() }
        }
        return .terminateLater
    }

    /// Filet de sécurité : les réglages et le plan sont déjà écrits à chaque modification, mais une
    /// sauvegarde à la fermeture évite de dépendre d'un appel qu'on aurait oublié d'ajouter.
    func applicationWillTerminate(_ notification: Notification) {
        state.flushSettings()
        state.persistRoomLayout()
    }
}
