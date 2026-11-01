import AppKit
import AudioCore
import Foundation
import Testing

@testable import BridgeApp

final class StubPresenter: ApplicationPresenting {
    private(set) var dockIconVisible: [Bool] = []
    private(set) var activateCount = 0

    func setDockIconVisible(_ visible: Bool) { dockIconVisible.append(visible) }
    func activate() { activateCount += 1 }
}

@Suite("Coquille — icône du Dock")
struct DockIconControllerTests {
    @Test("L'icône n'existe que tant que la fenêtre est ouverte")
    func followsWindow() async {
        let presenter = StubPresenter()
        let dock = DockIconController(presenter: presenter)

        dock.windowDidOpen()
        #expect(presenter.dockIconVisible == [true])
        #expect(presenter.activateCount == 1)

        dock.windowWillClose()
        #expect(await eventually { presenter.dockIconVisible == [true, false] })
    }

    @Test("Rouvrir à l'instant n'efface pas l'icône")
    func reopenWinsOverPendingHide() async {
        let presenter = StubPresenter()
        let dock = DockIconController(presenter: presenter)
        dock.windowDidOpen()

        dock.windowWillClose()
        dock.windowDidOpen()
        #expect(await staysFalse { presenter.dockIconVisible.last == false })
    }

    @Test("Avant d'ouvrir, l'app passe au premier plan : sinon la fenêtre s'ouvrirait derrière")
    func prepareActivates() {
        let presenter = StubPresenter()
        let dock = DockIconController(presenter: presenter)
        dock.prepareToShowWindow()
        #expect(presenter.dockIconVisible == [true])
        #expect(presenter.activateCount == 1)
    }

    @Test("Le rattachement répété de la vue ne rejoue rien")
    func openIsIdempotent() {
        let presenter = StubPresenter()
        let dock = DockIconController(presenter: presenter)
        dock.windowDidOpen()
        dock.windowDidOpen()
        #expect(presenter.dockIconVisible == [true])
    }
}

@Suite("Coquille — lancement")
struct AppLifecycleLaunchTests {
    private func openEvent(launchedAsLoginItem: Bool) -> NSAppleEventDescriptor {
        let event = NSAppleEventDescriptor(
            eventClass: kCoreEventClass, eventID: kAEOpenApplication,
            targetDescriptor: nil, returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )
        if launchedAsLoginItem {
            event.setParam(
                NSAppleEventDescriptor(enumCode: keyAELaunchedAsLogInItem), forKeyword: keyAEPropData
            )
        }
        return event
    }

    @Test("Un lancement à l'ouverture de session se reconnaît, et lui seul reste discret")
    func loginLaunch() {
        #expect(AppLifecycle.isLoginItemLaunch(openEvent(launchedAsLoginItem: true)))
        #expect(!AppLifecycle.isLoginItemLaunch(openEvent(launchedAsLoginItem: false)))
        #expect(!AppLifecycle.isLoginItemLaunch(nil))
    }

    /// `Window` quitte l'app à la fermeture de sa dernière fenêtre, et le moteur vit dans ce
    /// processus : fenêtre fermée, la diffusion s'arrêterait.
    @Test("L'app survit à la fermeture de sa fenêtre")
    func survivesWindowClose() {
        let lifecycle = AppLifecycle(
            state: BridgeHarness().state,
            loginItem: LoginItemController(service: PreviewLoginItemService()),
            dock: DockIconController(presenter: StubPresenter())
        )
        #expect(!lifecycle.applicationShouldTerminateAfterLastWindowClosed(NSApplication.shared))
    }

    /// Une fenêtre ouverte d'elle-même à l'ouverture de session ne doit pas voler la main : elle se
    /// referme sans passer par le premier plan, et sans faire apparaître l'icône du Dock.
    @Test("Lancée à l'ouverture de session, la fenêtre se referme sans passer au premier plan")
    func loginLaunchStaysDiscreet() async {
        let presenter = StubPresenter()
        let lifecycle = AppLifecycle(
            state: BridgeHarness().state,
            loginItem: LoginItemController(service: PreviewLoginItemService()),
            dock: DockIconController(presenter: presenter)
        )
        lifecycle.noteLaunch(asLoginItem: true)

        let window = NSWindow(
            contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true
        )
        window.isReleasedWhenClosed = false
        lifecycle.mainWindowDidAttach(window)
        #expect(presenter.dockIconVisible.allSatisfy { !$0 })
        #expect(presenter.activateCount == 0)
        #expect(!window.isVisible)

        // Demandée ensuite, elle s'ouvre normalement.
        var opened = false
        lifecycle.showMainWindow { opened = true }
        #expect(opened)
        #expect(presenter.dockIconVisible.last == true)
    }

    @Test("Lancée à la main, la fenêtre fait apparaître l'icône du Dock")
    func manualLaunchShowsDockIcon() {
        let presenter = StubPresenter()
        let lifecycle = AppLifecycle(
            state: BridgeHarness().state,
            loginItem: LoginItemController(service: PreviewLoginItemService()),
            dock: DockIconController(presenter: presenter)
        )
        lifecycle.noteLaunch(asLoginItem: false)

        let window = NSWindow(
            contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true
        )
        window.isReleasedWhenClosed = false
        lifecycle.mainWindowDidAttach(window)
        #expect(presenter.dockIconVisible == [true])
        #expect(presenter.activateCount == 1)
    }

    @Test("L'ouverture du panneau rafraîchit l'état de l'élément d'ouverture")
    func panelRefreshesLoginItem() {
        let service = StubLoginItemService()
        let loginItem = LoginItemController(service: service)
        let lifecycle = AppLifecycle(
            state: BridgeHarness().state, loginItem: loginItem,
            dock: DockIconController(presenter: StubPresenter())
        )
        #expect(loginItem.status == .disabled)
        service.status = .enabled
        lifecycle.panelDidOpen()
        #expect(loginItem.status == .enabled)
    }
}

final class StubLoginItemService: LoginItemService {
    struct Refusal: LocalizedError {
        var errorDescription: String? { "refusé pour le test" }
    }

    var status: LoginItemStatus = .disabled
    var registerResult: LoginItemStatus = .enabled
    var registerThrows = false
    private(set) var settingsOpened = 0

    func register() throws {
        status = registerResult
        if registerThrows { throw Refusal() }
    }

    func unregister() throws { status = .disabled }
    func openSystemSettings() { settingsOpened += 1 }
}

@Suite("Coquille — démarrage à l'ouverture de session")
struct LoginItemControllerTests {
    @Test("Activer puis désactiver")
    func toggle() {
        let controller = LoginItemController(service: StubLoginItemService())
        #expect(!controller.isOn)
        controller.setEnabled(true)
        #expect(controller.isOn)
        #expect(controller.status == .enabled)
        #expect(controller.message == nil)
        controller.setEnabled(false)
        #expect(!controller.isOn)
    }

    @Test("En attente d'approbation : coché, et le message dit où aller")
    func requiresApproval() {
        let service = StubLoginItemService()
        service.registerResult = .requiresApproval
        let controller = LoginItemController(service: service)
        controller.setEnabled(true)
        #expect(controller.isOn)
        #expect(controller.needsApproval)
        #expect(controller.message?.contains("Réglages Système") == true)

        controller.openSystemSettings()
        #expect(service.settingsOpened == 1)
    }

    @Test("Retenue pour approbation, une inscription lève aussi une erreur : ce n'en est pas une")
    func approvalIsNotAFailure() {
        let service = StubLoginItemService()
        service.registerResult = .requiresApproval
        service.registerThrows = true
        let controller = LoginItemController(service: service)
        controller.setEnabled(true)
        #expect(controller.failureMessage == nil)
        #expect(controller.needsApproval)
    }

    @Test("Un échec s'affiche, et le bouton reflète ce que le système dit")
    func failureIsShown() {
        let service = StubLoginItemService()
        service.registerResult = .disabled
        service.registerThrows = true
        let controller = LoginItemController(service: service)
        controller.setEnabled(true)
        #expect(!controller.isOn)
        #expect(controller.message?.contains("refusé pour le test") == true)

        // Un nouvel essai efface le message.
        service.registerResult = .enabled
        service.registerThrows = false
        controller.setEnabled(true)
        #expect(controller.message == nil)
    }
}

@Suite("Coquille — alertes de capture")
struct CaptureAlertTests {
    private func health(
        _ diagnosis: BridgeEngine.CaptureHealth.Diagnosis,
        permission: CapturePermission.Status? = .authorized
    ) -> BridgeEngine.CaptureHealth {
        var health = BridgeEngine.CaptureHealth()
        health.diagnosis = diagnosis
        health.permission = permission
        return health
    }

    private func alert(
        _ health: BridgeEngine.CaptureHealth, source: CaptureSource = .systemWide,
        runningFor: TimeInterval = 60
    ) -> CaptureAlert? {
        CaptureAlert.evaluate(health: health, source: source, runningFor: runningFor)
    }

    /// Toute la difficulté : deux silences, dont un seul appelle un geste.
    @Test("« Rien ne joue » et « autorisation manquante » ne se confondent pas")
    func twoSilences() throws {
        let nothing = try #require(alert(health(.silentNothingPlaying)))
        #expect(nothing.title == "Rien ne joue")
        #expect(nothing.severity == .info)
        #expect(nothing.settingsPane == nil)

        let missing = try #require(alert(health(.silentWhilePlaying)))
        #expect(missing.title == "Autorisation manquante")
        #expect(missing.severity == .critical)
        #expect(missing.settingsPane == .systemAudioCapture)
    }

    @Test("Une autorisation refusée prime sur tout diagnostic, avec le bon panneau")
    func deniedPermission() throws {
        let system = try #require(alert(health(.healthy, permission: .denied)))
        #expect(system.severity == .critical)
        #expect(system.settingsPane == .systemAudioCapture)

        let microphone = try #require(
            alert(health(.silentUnknown, permission: .denied), source: .inputDevice)
        )
        #expect(microphone.settingsPane == .microphone)
    }

    @Test("Une capture saine, ou à l'arrêt, ne dit rien")
    func nothingToSay() {
        #expect(alert(health(.healthy)) == nil)
        #expect(alert(health(.notRunning, permission: nil)) == nil)
        #expect(alert(health(.notRunning, permission: .denied)) == nil)
    }

    @Test("L'attente du premier bloc n'alerte qu'au bout de quelques secondes")
    func firstBlock() {
        #expect(alert(health(.waitingForFirstBlock), runningFor: 1) == nil)
        #expect(alert(health(.waitingForFirstBlock), runningFor: 6)?.severity == .info)
    }

    @Test("L'entrée silencieuse parle de l'entrée, sans accuser l'autorisation")
    func silentInput() throws {
        let input = try #require(alert(health(.silentUnknown), source: .inputDevice))
        #expect(input.title == "Aucun signal sur l'entrée")
        #expect(input.settingsPane == nil)

        let tap = try #require(alert(health(.silentUnknown)))
        #expect(tap.settingsPane == .systemAudioCapture)
    }

    @Test("Une capture interrompue dit pourquoi, quand on le sait")
    func stalled() throws {
        var interrupted = health(.stalled)
        #expect(alert(interrupted)?.detail?.contains("périphérique") == true)
        interrupted.lastRebuildError = "périphérique introuvable"
        #expect(alert(interrupted)?.detail == "périphérique introuvable")
    }

    @Test("Les panneaux des Réglages ont une adresse valide")
    func settingsURLs() {
        for pane in [SystemSettingsPane.systemAudioCapture, .microphone, .localNetwork] {
            #expect(pane.url?.scheme == "x-apple.systempreferences")
        }
    }
}

@Suite("Coquille — état en mots")
struct BridgeStatusSummaryTests {
    private func summary(
        phase: BridgeState.StreamingPhase = .running,
        restarting: Bool = false,
        selection: [(Bool, OutputConnectionState)],
        alert: CaptureAlert? = nil,
        failure: StartFailure? = nil
    ) -> BridgeStatusSummary {
        BridgeStatusSummary.make(
            phase: phase, isRestarting: restarting,
            selection: selection.map { (isEnabled: $0.0, connection: $0.1) },
            sourceLabel: "Son système global", alert: alert, startFailure: failure
        )
    }

    private let failed = OutputConnectionState.failed("non")
    private let waiting = OutputConnectionState.waiting(attempt: 1, message: "absent", nextAttemptAt: nil)

    @Test("Au repos")
    func idle() {
        let some = summary(phase: .idle, selection: [(true, .idle), (true, .idle), (false, .idle)])
        #expect(some.title == "Au repos")
        #expect(some.detail == "2 enceintes cochées")
        #expect(some.menuBar == .idle)

        #expect(summary(phase: .idle, selection: [(true, .idle)]).detail == "1 enceinte cochée")
        #expect(summary(phase: .idle, selection: []).detail == "Aucune enceinte cochée")
    }

    @Test("Toutes les enceintes jouent")
    func allStreaming() {
        let result = summary(selection: [(true, .streaming), (true, .streaming), (false, .idle)])
        #expect(result.title == "Diffusion vers 2 enceintes")
        #expect(result.detail == "Son système global")
        #expect(result.menuBar == .streaming)
    }

    /// Une enceinte éteinte n'est pas une panne : les autres jouent, l'icône n'a pas à alarmer.
    @Test("Une enceinte en attente n'allume pas l'alarme")
    func oneWaiting() {
        let result = summary(selection: [(true, .streaming), (true, waiting)])
        #expect(result.title == "Diffusion vers 1 enceinte")
        #expect(result.detail == "1 en attente")
        #expect(result.menuBar == .streaming)
    }

    @Test("Une enceinte en panne se voit dans la barre, même si les autres jouent")
    func oneFailed() {
        let result = summary(selection: [(true, .streaming), (true, failed), (true, waiting)])
        #expect(result.detail == "1 en panne, 1 en attente")
        #expect(result.menuBar == .trouble)
    }

    @Test("Personne ne répond")
    func allFailed() {
        #expect(summary(selection: [(true, failed)]).title == "En panne")
        #expect(summary(selection: [(true, failed)]).menuBar == .trouble)
        #expect(summary(selection: [(true, waiting)]).title == "Connexion…")
        #expect(summary(selection: [(true, waiting)]).menuBar == .connecting)
    }

    @Test("Une autorisation perdue se voit dans la barre : les enceintes ne reçoivent que du silence")
    func criticalAlert() {
        let alert = CaptureAlert(
            severity: .critical, title: "Autorisation manquante", detail: nil, settingsPane: nil
        )
        #expect(summary(selection: [(true, .streaming)], alert: alert).menuBar == .trouble)

        let info = CaptureAlert(severity: .info, title: "Rien ne joue", detail: nil, settingsPane: nil)
        #expect(summary(selection: [(true, .streaming)], alert: info).menuBar == .streaming)
    }

    @Test("Les transitions passent pour une connexion")
    func transitions() {
        #expect(summary(phase: .starting, selection: []).menuBar == .connecting)
        #expect(summary(phase: .stopping, selection: []).menuBar == .connecting)
        #expect(summary(restarting: true, selection: []).title == "Relance de la diffusion…")
    }

    @Test("Un échec de démarrage se voit, au repos")
    func startFailure() {
        let result = summary(
            phase: .idle, selection: [(true, .idle)],
            failure: StartFailure(message: "non", settingsPane: nil)
        )
        #expect(result.title == "Démarrage impossible")
        #expect(result.menuBar == .trouble)
    }

    @Test("Plus rien de coché pendant une diffusion : on le dit")
    func emptySelection() {
        let result = summary(selection: [(false, .idle)])
        #expect(result.title == "Plus aucune enceinte")
    }

    /// Une barre monochrome : si deux états partageaient une forme, seule la couleur les
    /// distinguerait, et elle n'y passe pas. On compare les pixels plutôt que les chemins : c'est
    /// ce que l'œil reçoit qui compte.
    @Test("Chaque état a son glyphe, et ces glyphes diffèrent vraiment une fois rendus")
    func glyphs() throws {
        let bitmaps = try MenuBarStatus.allCases.map { status -> [UInt8] in
            let image = MenuBarGlyphImage.image(for: status.glyph)
            #expect(image.isTemplate)
            #expect(image.size == BridgeGlyph.canvas)
            return try Self.alphaChannel(of: image)
        }
        for (index, bitmap) in bitmaps.enumerated() {
            #expect(bitmap.contains { $0 > 0 }, "glyphe vide : \(MenuBarStatus.allCases[index])")
            for other in bitmaps[(index + 1)...] { #expect(bitmap != other) }
        }
    }

    private static func alphaChannel(of image: NSImage) throws -> [UInt8] {
        let size = 40
        let rep = try #require(
            NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                bytesPerRow: 0, bitsPerPixel: 0
            )
        )
        let context = try #require(NSGraphicsContext(bitmapImageRep: rep))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        image.draw(in: CGRect(x: 0, y: 0, width: size, height: size))
        NSGraphicsContext.restoreGraphicsState()
        return (0..<size * size).compactMap { index in
            rep.colorAt(x: index % size, y: index / size).map { UInt8($0.alphaComponent * 255) }
        }
    }

    /// Un `Image(systemName:)` au nom inconnu n'affiche rien, sans la moindre erreur.
    @Test("Tous les symboles système du panneau existent sur ce système")
    func panelSymbolsExist() {
        for name in Self.panelSymbols + SpeakerSymbol.all {
            #expect(
                NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil,
                "symbole inconnu : \(name)"
            )
        }
    }

    private static let panelSymbols = [
        "play.fill", "stop.fill", "arrow.clockwise", "hifispeaker", "speaker.slash.fill",
        "speaker.wave.3.fill", "checkmark", "waveform", "chevron.right",
        "info.circle.fill", "exclamationmark.circle.fill", "exclamationmark.triangle.fill",
    ]

    @Test("Le symbole d'une enceinte suit le nom, puis ce que le protocole laisse supposer")
    func speakerSymbols() {
        func symbol(
            _ name: String, _ proto: OutputProtocol, _ unavailability: OutputUnavailability? = nil
        ) -> String {
            SpeakerSymbol.name(displayName: name, proto: proto, unavailability: unavailability)
        }
        #expect(symbol("Salon", .airplay2) == "homepod.fill")
        #expect(symbol("HomePod de Baptiste", .raop) == "homepod.fill")
        #expect(symbol("Geneva", .raop) == "hifispeaker.fill")
        #expect(symbol("Apple TV Salon", .raop, .pairingRequired) == "appletv.fill")
        #expect(symbol("Salle de bain", .airplay2, .pairingRequired) == "appletv.fill")
        #expect(symbol("Enceinte inconnue", .raop) == "hifispeaker.fill")
    }

    @Test("Le panneau montre d'abord ce qui peut jouer, sans toucher à l'ordre du reste")
    func speakerOrder() {
        func output(_ name: String, _ unavailability: OutputUnavailability? = nil) -> OutputState {
            OutputState(
                id: name, displayName: name, host: "h", port: 1, proto: .raop,
                unavailability: unavailability
            )
        }
        let apple = output("Apple TV", .pairingRequired)
        let streamingAnyway = output("Diffuse quand même", .pairingRequired)
        streamingAnyway.connection = .streaming
        let list = [apple, output("Geneva"), streamingAnyway, output("Salon")]

        #expect(
            PanelSpeakerOrder.sorted(list).map(\.displayName)
                == ["Geneva", "Diffuse quand même", "Salon", "Apple TV"]
        )
    }
}

@Suite("Coquille — source")
struct CaptureSourceResolveTests {
    private let music = CaptureSource.application(pids: [1], name: "Music", bundleID: "com.apple.Music")
    private let dia = CaptureSource.application(pids: [2], name: "Dia", bundleID: "company.thebrowser.dia")

    @Test("Hors diffusion : le choix de l'utilisateur s'il est là, le mode global sinon")
    func idle() {
        let available: [CaptureSource] = [.systemWide, music, .inputDevice]
        #expect(
            CaptureSource.resolve(
                preferredID: music.id, current: .systemWide, available: available, isLive: false
            ).selected == music
        )
        #expect(
            CaptureSource.resolve(
                preferredID: dia.id, current: dia, available: available, isLive: false
            ).selected == .systemWide
        )
    }

    @Test("En diffusion : la capture reste désignée, et reste dans la liste")
    func live() {
        let resolved = CaptureSource.resolve(
            preferredID: dia.id, current: dia, available: [.systemWide, .inputDevice], isLive: true
        )
        #expect(resolved.selected == dia)
        #expect(resolved.sources == [.systemWide, dia, .inputDevice])
    }
}
