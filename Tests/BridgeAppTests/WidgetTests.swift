import AppKit
import Foundation
import Testing

@testable import BridgeApp

/// La fenêtre du widget, en doublure : aucun test n'en montre une vraie.
final class FakeWidgetWindow: WidgetWindowing {
    private(set) var isShown = false
    var onMove: ((CGPoint) -> Void)?
    private(set) var shownAt: [CGPoint?] = []
    private(set) var hideCount = 0
    private(set) var floating: [Bool] = []

    func show(at saved: CGPoint?) {
        isShown = true
        shownAt.append(saved)
    }

    func hide() {
        isShown = false
        hideCount += 1
    }

    func setFloating(_ floats: Bool) { floating.append(floats) }

    /// L'utilisateur déplace la fenêtre.
    func drag(to origin: CGPoint) { onMove?(origin) }
}

@Suite("Widget — réglages")
struct WidgetSettingsTests {
    private func decode(_ json: String) throws -> BridgeSettings {
        try JSONDecoder().decode(BridgeSettings.self, from: Data(json.utf8))
    }

    @Test("Aller-retour dans le fichier des réglages")
    func roundTrip() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "bridge-widget-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileSettingsStore(url: directory.appending(path: "settings.json"))

        var settings = BridgeSettings()
        settings.widget = WidgetSettings(
            isShown: true, style: .band, floatsOnTop: false,
            position: WidgetSettings.Position(x: 1200.5, y: -340)
        )
        #expect(store.save(settings))
        let loaded = store.load()
        #expect(loaded.widget == settings.widget)
        #expect(loaded == settings)
    }

    @Test("Un fichier d'avant le widget ne l'affiche pas, et le pose sur le bureau le jour où on l'ouvre")
    func missingKey() throws {
        let settings = try decode(#"{"masterVolumeDB": -31}"#)
        #expect(settings.widget == WidgetSettings())
        #expect(!settings.widget.isShown)
        #expect(settings.widget.style == .halo)
        #expect(!settings.widget.floatsOnTop)
        #expect(settings.widget.position == nil)
        #expect(settings.masterVolumeDB == -31)
    }

    @Test("Un style inconnu donne le style par défaut, sans coûter les autres champs")
    func unknownStyle() throws {
        let settings = try decode(
            #"{"widget": {"isShown": true, "style": "cadran", "staysAboveWindows": true, "position": {"x": 10, "y": 20}}}"#
        )
        #expect(settings.widget.style == .default)
        #expect(settings.widget.isShown)
        #expect(settings.widget.floatsOnTop)
        #expect(settings.widget.position == WidgetSettings.Position(x: 10, y: 20))
    }

    @Test("L'ancien réglage « flottant » de la première version est ignoré : le widget se pose sur le bureau")
    func legacyFloatingFlagIsIgnored() throws {
        // Ce que la première version écrivait, avec son défaut flottant.
        let settings = try decode(
            #"{"widget": {"floatsOnTop": true, "isShown": true, "position": {"x": 31, "y": 194}, "style": "halo"}}"#
        )
        #expect(!settings.widget.floatsOnTop)
        #expect(settings.widget.isShown)
        #expect(settings.widget.position == WidgetSettings.Position(x: 31, y: 194))
    }

    @Test("Une position illisible ou hors de tout écran est oubliée, le reste est gardé")
    func badPosition() throws {
        for position in [#""en haut""#, #"{"x": 10}"#, #"{"x": 1e12, "y": 0}"#, #"{"x": 0, "y": -200000}"#] {
            let settings = try decode(#"{"widget": {"isShown": true, "style": "bandeau", "position": \#(position)}}"#)
            #expect(settings.widget.position == nil, "position \(position)")
            #expect(settings.widget.isShown)
            #expect(settings.widget.style == .band)
        }
    }

    @Test("Un widget illisible en entier ne coûte pas les autres réglages")
    func unreadableWidget() throws {
        let settings = try decode(#"{"masterVolumeDB": -18, "widget": 3, "windowLayout": "console"}"#)
        #expect(settings.widget == WidgetSettings())
        #expect(settings.masterVolumeDB == -18)
        #expect(settings.windowLayout == .console)
    }

    @Test("Les noms des styles dans le fichier ne changent pas")
    func rawValues() {
        #expect(WidgetStyle.halo.rawValue == "halo")
        #expect(WidgetStyle.band.rawValue == "bandeau")
        #expect(WidgetStyle.halo.other == .band)
        #expect(WidgetStyle.band.other == .halo)
    }

    @Test("L'état écrit les réglages du widget, et les relit au lancement")
    func stateRoundTrip() {
        let harness = BridgeHarness()
        harness.state.widget = WidgetSettings(
            isShown: true, style: .band, floatsOnTop: false, position: WidgetSettings.Position(x: 40, y: 60)
        )
        harness.state.flushSettings()
        #expect(harness.store.stored.widget == harness.state.widget)

        let relaunched = BridgeHarness(settings: harness.store.stored)
        #expect(relaunched.state.widget == harness.state.widget)
    }

    @Test("Sans changement, rien n'est réécrit")
    func noSpuriousSave() {
        let harness = BridgeHarness()
        harness.state.flushSettings()
        let before = harness.store.saveCount
        harness.state.widget = WidgetSettings()
        harness.state.flushSettings()
        #expect(harness.store.saveCount == before)
    }
}

@Suite("Widget — disposition et libellés")
struct WidgetLayoutTests {
    @Test("Trois enceintes remplissent la zone, à la place que leur donnent les maquettes", arguments: WidgetStyle.allCases)
    func threeFit(style: WidgetStyle) {
        let layout = WidgetSpeakerLayout.make(count: 3, style: style)
        #expect(!layout.scrolls)
        #expect(layout.contentWidth == layout.zoneWidth)
        #expect(layout.firstColumnX == layout.zoneX)
        // La dernière colonne s'arrête à la marge droite du widget.
        #expect(layout.zoneX + layout.zoneWidth == WidgetMetrics.size.width - 14)
    }

    @Test("Moins de trois enceintes se centrent dans la même zone", arguments: WidgetStyle.allCases)
    func fewerAreCentered(style: WidgetStyle) {
        for count in 1...2 {
            let layout = WidgetSpeakerLayout.make(count: count, style: style)
            #expect(!layout.scrolls)
            let left = layout.firstColumnX - layout.zoneX
            let right = layout.zoneX + layout.zoneWidth - (layout.firstColumnX + layout.contentWidth)
            #expect(left > 0)
            #expect(abs(left - right) < 0.001)
        }
    }

    @Test("Au-delà de trois, la rangée défile depuis le début de la zone", arguments: WidgetStyle.allCases)
    func moreScroll(style: WidgetStyle) {
        for count in 4...6 {
            let layout = WidgetSpeakerLayout.make(count: count, style: style)
            #expect(layout.scrolls)
            #expect(layout.contentWidth > layout.zoneWidth)
            #expect(layout.firstColumnX == layout.zoneX)
        }
    }

    @Test("Aucune enceinte : rien à poser, rien à faire défiler")
    func none() {
        let layout = WidgetSpeakerLayout.make(count: 0, style: .halo)
        #expect(layout.contentWidth == 0)
        #expect(!layout.scrolls)
        #expect(WidgetSpeakerLayout.make(count: -2, style: .band).count == 0)
    }

    @Test("La fenêtre de défilement tient dans le widget, et ne mord ni l'anneau ni la colonne de gauche")
    func viewportStaysInside() {
        let halo = WidgetSpeakerLayout.make(count: 5, style: .halo)
        #expect(halo.viewportX + halo.viewportWidth <= WidgetMetrics.size.width)
        let ringEdge = WidgetMetrics.haloCenter.x + WidgetMetrics.haloRingRadius + HaloRingMetrics.widget.knobDiameter / 2
        #expect(halo.viewportX >= ringEdge)

        let band = WidgetSpeakerLayout.make(count: 5, style: .band)
        #expect(band.viewportX + band.viewportWidth <= WidgetMetrics.size.width)
        #expect(band.viewportX >= WidgetMetrics.bandColumn.maxX)
    }

    @Test("Ce qui se saisit fait au moins 22 points")
    func targets() {
        let minimum = WidgetMetrics.minimumTarget
        #expect(WidgetMetrics.haloFader.width >= minimum)
        #expect(WidgetMetrics.bandPill.width >= minimum)
        #expect(WidgetMetrics.bandSliderHeight >= minimum)
        #expect(HaloRingMetrics.widget.grabHalfWidth * 2 >= minimum)
        #expect(WidgetMetrics.bandButtonDiameter >= minimum)
    }

    @Test("L'anneau du widget tient dans le widget et laisse le disque à la diffusion")
    func ringFits() {
        let metrics = HaloRingMetrics.widget
        let radius = WidgetMetrics.haloRingRadius
        // Le bord du disque est hors de la bande de l'anneau.
        #expect(WidgetMetrics.haloDiscDiameter / 2 < radius - metrics.grabHalfWidth)
        // La prise ne sort ni du carré de l'anneau, ni du widget.
        #expect(metrics.knobDiameter / 2 <= metrics.overhang)
        #expect(metrics.lineWidth / 2 + metrics.haloReach <= metrics.overhang)
        let reach = radius + metrics.knobDiameter / 2
        #expect(WidgetMetrics.haloCenter.x - reach >= 0)
        #expect(WidgetMetrics.haloCenter.y - reach >= 0)
        #expect(WidgetMetrics.haloCenter.y + reach <= WidgetMetrics.size.height)
    }

    @Test("Les mesures par défaut des commandes partagées sont celles de la fenêtre")
    func sharedDefaults() {
        let fader = DarkshellFaderMetrics.console
        #expect(fader.grip == DarkshellFaderGeometry.grip)
        #expect(fader.mark == DarkshellFaderGeometry.mark)
        #expect(fader.lineThickness == DarkshellFaderGeometry.lineThickness)
        #expect(fader.markInset == DarkshellFaderGeometry.markInset)
        #expect(fader.floor == nil)
        #expect(fader.shadowRadius == 11)
        #expect(fader.shadowY == 10)

        let ring = HaloRingMetrics.window
        #expect(ring.lineWidth == HaloVolumeRing.lineWidth)
        #expect(ring.knobDiameter == HaloVolumeRing.knobDiameter)
        #expect(ring.grabHalfWidth == HaloVolumeRing.grabHalfWidth)
        #expect(ring.side(forRadius: 120) == HaloVolumeRing.side(forRadius: 120))
    }

    @Test("La prise d'un curseur fin reste dans sa coque")
    func compactGrip() {
        let metrics = DarkshellFaderMetrics.compact(width: 22, floor: 8)
        #expect(metrics.grip.width < 22 - 2 * Darkshell.lipWidth)
        #expect(2 * (metrics.mark.width + metrics.markInset + Darkshell.lipWidth) < 22)
        let height: CGFloat = 86
        for level in stride(from: CGFloat(0), through: height, by: 1) {
            let center = DarkshellFaderGeometry.gripCenterY(
                levelY: level, trackHeight: height, gripHeight: metrics.grip.height,
                lineThickness: metrics.lineThickness
            )
            #expect(center - metrics.grip.height / 2 >= Darkshell.lipWidth)
            #expect(center + metrics.grip.height / 2 <= height - Darkshell.lipWidth)
        }
    }

    // MARK: Libellés

    @Test("Sous le nom : le réglage, ou ce qui empêche l'enceinte de jouer")
    func captions() {
        func caption(
            offline: Bool = false, heldBack: Bool = false, enabled: Bool = true, muted: Bool = false,
            trim: Double = 1
        ) -> WidgetCopy.Caption {
            WidgetCopy.caption(
                isOffline: offline, isHeldBack: heldBack, isEnabled: enabled, isMuted: muted, trimDB: trim
            )
        }
        #expect(caption() == WidgetCopy.Caption(text: "+1,0 dB", tone: .value))
        #expect(caption(trim: -2.5).text == "−2,5 dB")
        #expect(caption(trim: 0).text == "0,0 dB")
        #expect(caption(muted: true) == WidgetCopy.Caption(text: "Coupée", tone: .quiet))
        #expect(caption(enabled: false) == WidgetCopy.Caption(text: "Décochée", tone: .quiet))
        #expect(caption(heldBack: true).text == "Bloquée")
        // Hors ligne passe avant tout : c'est ce qui l'empêche de jouer, cochée ou non.
        #expect(caption(offline: true) == WidgetCopy.Caption(text: "Hors ligne", tone: .warning))
        #expect(caption(offline: true, enabled: false, muted: true).text == "Hors ligne")
        // Décochée passe avant coupée : la cocher est le premier geste.
        #expect(caption(enabled: false, muted: true).text == "Décochée")
    }

    @Test("Le volume général en mots")
    func masterValue() {
        #expect(WidgetCopy.masterValue(isMuted: false, decibels: -24) == "−24 dB")
        #expect(WidgetCopy.masterValue(isMuted: true, decibels: -24) == "Coupé")
    }

    @Test("Sans enceinte à montrer, le widget dit pourquoi")
    func emptyMessages() {
        #expect(WidgetCopy.emptyMessage(isSearching: false, allHidden: false) == "Aucune enceinte trouvée")
        #expect(WidgetCopy.emptyMessage(isSearching: true, allHidden: false) == "Recherche des enceintes…")
        #expect(WidgetCopy.emptyMessage(isSearching: true, allHidden: true) == "Toutes les enceintes sont masquées")
    }

    @Test("La ligne « Widget » dit ce que fera le clic")
    func toggleTitle() {
        #expect(WidgetCopy.toggleTitle(isShown: false) == "Afficher le widget")
        #expect(WidgetCopy.toggleTitle(isShown: true) == "Masquer le widget")
    }

    @Test("L'icône de la ligne « Widget » existe")
    func symbolExists() {
        #expect(NSImage(systemSymbolName: WidgetSymbol.name, accessibilityDescription: nil) != nil)
    }
}

@Suite("Widget — menu du fond")
struct WidgetMenuTests {
    @Test("Le menu coche le style en cours et « Toujours au-dessus »")
    func entries() {
        var settings = WidgetSettings(isShown: true, style: .band, floatsOnTop: false)
        var entries = WidgetMenu.entries(for: settings)
        #expect(entries.compactMap(\.action) == [
            .setStyle(.halo), .setStyle(.band), .toggleFloating, .openMainWindow, .close,
        ])
        #expect(entries.filter(\.isChecked).map(\.title) == ["Style Bandeau"])

        settings.style = .halo
        settings.floatsOnTop = true
        entries = WidgetMenu.entries(for: settings)
        #expect(entries.filter(\.isChecked).map(\.title) == ["Style Halo", "Toujours au-dessus"])
    }

    @Test("Chaque ligne change ce qu'elle dit, et rien d'autre")
    func apply() {
        let start = WidgetSettings(
            isShown: true, style: .halo, floatsOnTop: true, position: WidgetSettings.Position(x: 5, y: 6)
        )
        var settings = start
        WidgetMenu.apply(.setStyle(.band), to: &settings)
        #expect(settings == WidgetSettings(isShown: true, style: .band, floatsOnTop: true, position: start.position))

        settings = start
        WidgetMenu.apply(.toggleFloating, to: &settings)
        #expect(settings == WidgetSettings(isShown: true, style: .halo, floatsOnTop: false, position: start.position))

        settings = start
        WidgetMenu.apply(.openMainWindow, to: &settings)
        #expect(settings == start)

        settings = start
        WidgetMenu.apply(.close, to: &settings)
        // Fermé, il garde son style et sa place pour la prochaine fois.
        #expect(settings == WidgetSettings(isShown: false, style: .halo, floatsOnTop: true, position: start.position))
    }

    @Test("Le fond dessine ce menu, et une ligne cliquée fait son action")
    func backdropMenu() throws {
        let view = WidgetBackdrop.BackdropView()
        view.entries = WidgetMenu.entries(for: WidgetSettings(isShown: true, style: .band, floatsOnTop: true))
        var performed: [WidgetMenuAction] = []
        view.perform = { performed.append($0) }

        let menu = view.makeMenu()
        #expect(menu.items.count == view.entries.count)
        #expect(menu.items.filter(\.isSeparatorItem).count == 2)
        #expect(menu.items.filter { $0.state == .on }.map(\.title) == ["Style Bandeau", "Toujours au-dessus"])

        let close = try #require(menu.items.first { $0.title == "Fermer le widget" })
        view.fire(close)
        let halo = try #require(menu.items.first { $0.title == "Style Halo" })
        view.fire(halo)
        #expect(performed == [.close, .setStyle(.halo)])
        // Un séparateur n'a rien à faire.
        let separator = try #require(menu.items.first { $0.isSeparatorItem })
        view.fire(separator)
        #expect(performed.count == 2)
    }

    @Test("Le premier clic sur le fond compte : le widget n'est jamais la fenêtre active")
    func backdropAcceptsFirstMouse() {
        #expect(WidgetBackdrop.BackdropView().acceptsFirstMouse(for: nil))
    }
}

@Suite("Widget — place à l'écran")
struct WidgetPlacementTests {
    private let screen = CGRect(x: 0, y: 0, width: 1512, height: 944)
    private let size = WidgetMetrics.size

    @Test("Jamais déplacé, il s'ouvre dans le coin haut droit de l'écran principal")
    func defaultCorner() {
        let origin = WidgetPlacement.origin(saved: nil, size: size, screens: [screen], main: screen)
        #expect(origin.x == 1512 - 345 - WidgetPlacement.screenMargin)
        #expect(origin.y == 944 - 165 - WidgetPlacement.screenMargin)
    }

    @Test("La place mémorisée est rendue telle quelle, même à cheval sur le bord")
    func savedPlace() {
        let saved = CGPoint(x: 300, y: 420)
        #expect(WidgetPlacement.origin(saved: saved, size: size, screens: [screen], main: screen) == saved)
        // Aux trois quarts hors de l'écran, il se rattrape encore.
        let edge = CGPoint(x: 1512 - 90, y: 100)
        #expect(WidgetPlacement.origin(saved: edge, size: size, screens: [screen], main: screen) == edge)
    }

    @Test("Sur un second écran, la place est gardée tant que cet écran est là")
    func secondScreen() {
        let second = CGRect(x: 1512, y: 0, width: 1920, height: 1080)
        let saved = CGPoint(x: 2400, y: 500)
        #expect(WidgetPlacement.origin(saved: saved, size: size, screens: [screen, second], main: screen) == saved)
        // L'écran débranché : il revient dans le coin de l'écran principal.
        let home = WidgetPlacement.origin(saved: saved, size: size, screens: [screen], main: screen)
        #expect(home == WidgetPlacement.origin(saved: nil, size: size, screens: [screen], main: screen))
    }

    @Test("Trop peu visible pour être saisi, il revient dans le coin")
    func unreachable() {
        let corner = WidgetPlacement.origin(saved: nil, size: size, screens: [screen], main: screen)
        let sliver = CGPoint(x: 1512 - 20, y: 100)
        #expect(WidgetPlacement.origin(saved: sliver, size: size, screens: [screen], main: screen) == corner)
        let below = CGPoint(x: 100, y: -150)
        #expect(WidgetPlacement.origin(saved: below, size: size, screens: [screen], main: screen) == corner)
    }

    @Test("Sans écran, la place mémorisée est laissée telle quelle")
    func noScreen() {
        let saved = CGPoint(x: 12, y: 34)
        #expect(WidgetPlacement.origin(saved: saved, size: size, screens: [], main: nil) == saved)
        #expect(WidgetPlacement.origin(saved: nil, size: size, screens: [], main: nil) == .zero)
    }
}

@Suite("Widget — fenêtre")
struct WidgetControllerTests {
    private func make(_ settings: WidgetSettings = WidgetSettings()) -> (BridgeHarness, FakeWidgetWindow, WidgetController) {
        var stored = BridgeSettings()
        stored.widget = settings
        let harness = BridgeHarness(settings: stored)
        let window = FakeWidgetWindow()
        return (harness, window, WidgetController(state: harness.state, window: window))
    }

    @Test("Au lancement, il ne s'ouvre que s'il était affiché")
    func launchHidden() {
        let (_, window, controller) = make()
        controller.start()
        #expect(!window.isShown)
        #expect(window.shownAt.isEmpty)
        #expect(window.hideCount == 0)
    }

    @Test("Affiché au dernier arrêt, il se rouvre à sa place et à son niveau")
    func launchShown() {
        let (_, window, controller) = make(
            WidgetSettings(isShown: true, floatsOnTop: false, position: WidgetSettings.Position(x: 220, y: 310))
        )
        controller.start()
        #expect(window.isShown)
        #expect(window.shownAt == [CGPoint(x: 220, y: 310)])
        #expect(window.floating.last == false)
    }

    @Test("Les réglages commandent la fenêtre : l'afficher, la masquer, la faire flotter")
    func followsSettings() async {
        let (harness, window, controller) = make()
        controller.start()

        harness.state.widget.isShown = true
        #expect(await eventually { window.isShown })
        #expect(window.shownAt.count == 1)
        #expect(window.shownAt.first == .some(nil))

        harness.state.widget.floatsOnTop = false
        #expect(await eventually { window.floating.last == false })

        harness.state.widget.isShown = false
        #expect(await eventually { !window.isShown })
        #expect(window.hideCount == 1)
    }

    @Test("Changer de style ou de place ne remontre pas une fenêtre déjà là")
    func noRedundantShow() async {
        let (harness, window, controller) = make(WidgetSettings(isShown: true))
        controller.start()
        harness.state.widget.style = .band
        harness.state.widget.position = WidgetSettings.Position(x: 1, y: 2)
        harness.state.widget.floatsOnTop = false
        #expect(await eventually { window.floating.last == false })
        #expect(window.shownAt.count == 1)
        #expect(window.hideCount == 0)
    }

    @Test("La place où on le laisse est mémorisée, et écrite dans les réglages")
    func remembersPosition() {
        let (harness, window, controller) = make(WidgetSettings(isShown: true))
        controller.start()
        window.drag(to: CGPoint(x: 512, y: 384))
        #expect(harness.state.widget.position == WidgetSettings.Position(x: 512, y: 384))
        harness.state.flushSettings()
        #expect(harness.store.stored.widget.position == WidgetSettings.Position(x: 512, y: 384))
        #expect(harness.store.stored.widget.isShown)
    }

    @Test("Un déplacement d'une fenêtre fermée n'est pas mémorisé")
    func ignoresMoveWhenClosed() {
        let (harness, window, controller) = make()
        controller.start()
        window.drag(to: CGPoint(x: 9, y: 9))
        #expect(harness.state.widget.position == nil)
    }

    // MARK: Panneau réel

    @Test("Le panneau n'a ni barre de titre ni boutons, et ne prend pas le premier plan")
    func panelChrome() {
        let panel = LiveWidgetWindow.makePanel(content: NSView(), floats: true)
        #expect(!panel.styleMask.contains(.titled))
        #expect(!panel.styleMask.contains(.closable))
        #expect(!panel.styleMask.contains(.resizable))
        #expect(panel.styleMask.contains(.nonactivatingPanel))
        #expect(panel.standardWindowButton(.closeButton) == nil)
        #expect(!panel.canBecomeMain)
        // Le clavier reste possible, mais seulement si une commande le demande.
        #expect(panel.canBecomeKey)
        #expect(panel.becomesKeyOnlyIfNeeded)
        // Créé, pas montré.
        #expect(!panel.isVisible)
    }

    @Test("Le panneau fait exactement la taille du widget, et ne se redimensionne pas")
    func panelSize() {
        let panel = LiveWidgetWindow.makePanel(content: NSView(), floats: true)
        #expect(panel.frame.size == CGSize(width: 345, height: 165))
        #expect(panel.contentMinSize == WidgetMetrics.size)
        #expect(panel.contentMaxSize == WidgetMetrics.size)
        #expect(panel.contentView?.frame.size == WidgetMetrics.size)
    }

    @Test("Le panneau flotte au-dessus des fenêtres, sur tous les bureaux, app au premier plan ou non")
    func panelFloats() {
        let floating = LiveWidgetWindow.makePanel(content: NSView(), floats: true)
        #expect(floating.level == .floating)
        #expect(floating.collectionBehavior.contains(.canJoinAllSpaces))
        #expect(floating.collectionBehavior.contains(.fullScreenAuxiliary))
        #expect(!floating.hidesOnDeactivate)

        // Posé sur le bureau : sous toutes les fenêtres, au-dessus des icônes, immobile sous Mission Control.
        let desk = LiveWidgetWindow.makePanel(content: NSView(), floats: false)
        #expect(desk.level.rawValue < NSWindow.Level.normal.rawValue)
        #expect(desk.level.rawValue > Int(CGWindowLevelForKey(.desktopIconWindow)))
        // Le niveau des widgets de macOS, relevé sur ceux du Centre de notifications.
        #expect(desk.level.rawValue == Int(CGWindowLevelForKey(.desktopIconWindow)) + 2)
        #expect(desk.collectionBehavior.contains(.canJoinAllSpaces))
        #expect(desk.collectionBehavior.contains(.stationary))
        #expect(!desk.collectionBehavior.contains(.fullScreenAuxiliary))
        #expect(LiveWidgetWindow.level(floats: true) == .floating)
        // Par défaut, sur le bureau.
        #expect(!WidgetSettings(isShown: true).floatsOnTop)
    }

    @Test("Le panneau est transparent autour du rectangle arrondi, avec une ombre, et se déplace par son fond seul")
    func panelSurface() {
        let panel = LiveWidgetWindow.makePanel(content: NSView(), floats: true)
        #expect(!panel.isOpaque)
        #expect(panel.backgroundColor == .clear)
        #expect(panel.hasShadow)
        // Le déplacement passe par `WidgetBackdrop` : un curseur qu'on glisse n'emporte pas la fenêtre.
        #expect(!panel.isMovableByWindowBackground)
        #expect(panel.isMovable)
        #expect(!panel.isReleasedWhenClosed)
    }

    @Test("Une fenêtre réelle jamais affichée dit qu'elle ne l'est pas")
    func liveWindowStartsHidden() {
        let window = LiveWidgetWindow(state: BridgeHarness().state)
        #expect(!window.isShown)
        // Masquer ou régler le niveau sans panneau ne crée rien.
        window.hide()
        window.setFloating(false)
        #expect(!window.isShown)
    }
}

@Suite("Widget — coquille de l'app")
struct WidgetLifecycleTests {
    private func make(
        _ settings: WidgetSettings, presenter: StubPresenter = StubPresenter()
    ) -> (AppLifecycle, FakeWidgetWindow, BridgeHarness) {
        var stored = BridgeSettings()
        stored.widget = settings
        let harness = BridgeHarness(settings: stored)
        let window = FakeWidgetWindow()
        let lifecycle = AppLifecycle(
            state: harness.state,
            loginItem: LoginItemController(service: PreviewLoginItemService()),
            dock: DockIconController(presenter: presenter),
            coreAudio: StubCoreAudioRestarter(),
            widgetWindow: window
        )
        return (lifecycle, window, harness)
    }

    @Test("Le widget s'ouvre sans faire apparaître l'icône du Dock ni prendre le premier plan")
    func noDockIcon() async {
        let presenter = StubPresenter()
        let (lifecycle, window, harness) = make(WidgetSettings(isShown: true), presenter: presenter)
        lifecycle.widget?.start()
        #expect(window.isShown)

        harness.state.widget.isShown = false
        #expect(await eventually { !window.isShown })
        harness.state.widget.isShown = true
        #expect(await eventually { window.isShown })

        #expect(presenter.dockIconVisible.isEmpty)
        #expect(presenter.activateCount == 0)
        #expect(!lifecycle.dock.isWindowOpen)
    }

    @Test("Sans fenêtre de widget, la coquille n'en commande aucune")
    func noWidgetByDefault() {
        let lifecycle = AppLifecycle(
            state: BridgeHarness().state,
            loginItem: LoginItemController(service: PreviewLoginItemService()),
            dock: DockIconController(presenter: StubPresenter()),
            coreAudio: StubCoreAudioRestarter()
        )
        #expect(lifecycle.widget == nil)
    }

    @Test("« Ouvrir la fenêtre… » du widget passe par l'action d'une scène, icône du Dock comprise")
    func opensMainWindow() {
        let presenter = StubPresenter()
        let (lifecycle, _, _) = make(WidgetSettings(isShown: true), presenter: presenter)

        // Aucune scène n'a encore donné son action : rien ne s'ouvre, rien ne plante.
        lifecycle.showMainWindowFromWidget()
        #expect(presenter.dockIconVisible.isEmpty)

        var opened = 0
        lifecycle.sceneActions = SceneActions(openMainWindow: { opened += 1 })
        lifecycle.showMainWindowFromWidget()
        #expect(opened == 1)
        #expect(presenter.dockIconVisible == [true])
        #expect(presenter.activateCount == 1)
    }

    @Test("Fermer le widget ne fait pas quitter l'app")
    func closingDoesNotQuit() {
        let (lifecycle, _, _) = make(WidgetSettings(isShown: false))
        #expect(!lifecycle.applicationShouldTerminateAfterLastWindowClosed(NSApplication.shared))
    }
}

/// Ce qui se saisit dans le widget, relevé sur la vraie vue dans un panneau jamais affiché : un point du
/// fond tombe sur `WidgetBackdrop` (il déplace la fenêtre et porte le menu), un point d'une commande, non.
@Suite("Widget — fond et commandes")
struct WidgetHitTests {
    private func host(style: WidgetStyle) async -> (panel: NSPanel, view: NSView) {
        let state = BridgeState.preview(.streaming)
        state.widget.style = style
        if let appleTV = state.outputs.first(where: { $0.displayName == "Apple TV Salon" }) {
            state.setHidden(true, for: appleTV)
        }
        // Sans le fond animé : ses images-clés occuperaient un cœur pendant le reste de la suite.
        let hosting = WidgetHostingView(rootView: WidgetFace(state: state).environment(\.colorScheme, .dark))
        hosting.sizingOptions = []
        let panel = LiveWidgetWindow.makePanel(content: hosting, floats: true)
        // Le temps que la vue se compose ; la fenêtre n'est jamais montrée.
        try? await Task.sleep(for: .milliseconds(300))
        hosting.layoutSubtreeIfNeeded()
        return (panel, hosting)
    }

    /// `x`, `y` dans le repère du widget, depuis le coin haut gauche.
    private func isBackdrop(_ view: NSView, x: CGFloat, y: CGFloat) -> Bool {
        view.hitTest(CGPoint(x: x, y: WidgetMetrics.size.height - y)) is WidgetBackdrop.BackdropView
    }

    @Test("Style Halo : le fond se saisit entre les commandes, pas sur elles")
    func halo() async {
        let (panel, view) = await host(style: .halo)
        defer { panel.close() }
        #expect(!panel.isVisible)

        // Le fond : au-dessus des curseurs, entre deux curseurs, sous l'anneau.
        #expect(isBackdrop(view, x: 240, y: 6))
        #expect(isBackdrop(view, x: 219.5, y: 76))
        #expect(isBackdrop(view, x: 160, y: 150))

        // Les commandes : le disque, la bande de l'anneau, un curseur, un nom.
        let center = WidgetMetrics.haloCenter
        #expect(!isBackdrop(view, x: center.x, y: center.y))
        #expect(!isBackdrop(view, x: center.x, y: center.y - WidgetMetrics.haloRingRadius))
        #expect(!isBackdrop(view, x: 190.5, y: 76))
        #expect(!isBackdrop(view, x: 190.5, y: 136))
    }

    @Test("Style Bandeau : le fond se saisit entre les commandes, pas sur elles")
    func band() async {
        let (panel, view) = await host(style: .band)
        defer { panel.close() }

        // Le fond : entre la colonne de gauche et les pastilles, entre deux pastilles, à côté du bouton.
        #expect(isBackdrop(view, x: 144, y: 80))
        #expect(isBackdrop(view, x: 209, y: 80))
        #expect(isBackdrop(view, x: 24, y: 40))

        // Les commandes : le bouton rond, le curseur du volume général, une pastille, son icône.
        let column = WidgetMetrics.bandColumn
        #expect(!isBackdrop(view, x: column.midX, y: column.minY + 4 + WidgetMetrics.bandButtonDiameter / 2))
        #expect(!isBackdrop(view, x: column.midX, y: column.maxY - WidgetMetrics.bandSliderHeight / 2))
        #expect(!isBackdrop(view, x: 177.5, y: 90))
        #expect(!isBackdrop(view, x: 177.5, y: 30))
    }
}
