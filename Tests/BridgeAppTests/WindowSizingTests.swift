import CoreGraphics
import Testing

@testable import BridgeApp

/// Les paliers de taille de la fenêtre : à cette largeur et cette hauteur, quelle disposition. Des
/// fonctions pures ; ce qu'elles donnent à l'écran se juge sur les rendus de `SmallWindowExport`.
@Suite("Fenêtre — paliers de taille")
struct WindowSizingTests {
    private let roomy = WindowSizing.roomy
    private let minimum = WindowSizing.minimum
    private let defaultSize = CGSize(width: 1200, height: 760)
    /// La marge haute que `ContentView` donne aux vues sans plan.
    private let immersiveTop: CGFloat = 48

    @Test("La taille minimale est celle d'une télécommande, bien sous l'ancienne")
    func minimumIsSmall() {
        #expect(minimum.width <= 480 && minimum.height <= 420)
        #expect(minimum.width < roomy.width && minimum.height < roomy.height)
    }

    // MARK: - Haut de fenêtre

    @Test("La pastille de source reste centrée tant qu'elle ne touche pas ses voisins")
    func pillStaysCentred() {
        let x = WindowChromeLayout.pillMinX(windowWidth: 1200, pillWidth: 180, leading: 98, trailing: 50)
        #expect(x == 510)
        // Symétrique et serré, mais encore libre : toujours au centre.
        #expect(WindowChromeLayout.pillMinX(windowWidth: 440, pillWidth: 180, leading: 98, trailing: 98) == 130)
    }

    @Test("Poussée par un voisin, la pastille garde l'écart, des deux côtés")
    func pillIsPushedAside() {
        let gap = WindowChromeLayout.gap
        // Le sélecteur de lieu d'écoute, large à droite : la pastille part vers la gauche.
        let left = WindowChromeLayout.pillMinX(windowWidth: 600, pillWidth: 180, leading: 98, trailing: 230)
        #expect(left + 180 == 600 - 230 - gap)
        #expect(left >= 98 + gap)
        // Les outils du plan, larges à gauche : elle part vers la droite.
        let right = WindowChromeLayout.pillMinX(windowWidth: 600, pillWidth: 180, leading: 300, trailing: 50)
        #expect(right == 300 + gap)
        // Elle ne tient pas du tout : elle part de son voisin de gauche, sans passer dessous.
        #expect(WindowChromeLayout.pillMinX(windowWidth: 400, pillWidth: 300, leading: 100, trailing: 100) == 100 + gap)
    }

    @Test("La place de la pastille se mesure entre ses voisins, et décide du repli en icône")
    func pillSlot() {
        let gap = WindowChromeLayout.gap
        #expect(WindowChromeLayout.pillSlot(windowWidth: 440, leading: 98, trailing: 50) == 440 - 148 - 2 * gap)
        #expect(WindowChromeLayout.pillSlot(windowWidth: 100, leading: 98, trailing: 50) == 0)
        #expect(!WindowChromeLayout.pillIsIconOnly(slot: WindowChromeLayout.iconOnlyBelow))
        #expect(WindowChromeLayout.pillIsIconOnly(slot: WindowChromeLayout.iconOnlyBelow - 1))
        // La fenêtre la plus étroite, sans outils autour : le nom garde sa place.
        let bare = WindowChromeLayout.pillSlot(windowWidth: minimum.width, leading: 98, trailing: 50)
        #expect(!WindowChromeLayout.pillIsIconOnly(slot: bare))
        // La vue Plan repliée à cette largeur (outils de tracé à gauche, « Plus » à droite) : une icône.
        let plan = WindowChromeLayout.pillSlot(windowWidth: minimum.width, leading: 215, trailing: 134)
        #expect(WindowChromeLayout.pillIsIconOnly(slot: plan))
    }

    @Test("Le sélecteur de lieu d'écoute reçoit ce qui reste une fois la pastille servie")
    func listeningPlacesBudget() {
        // À la taille par défaut, des segments tiennent largement ; à la plus petite, il ne reste qu'une icône.
        #expect(WindowChromeLayout.listeningPlacesBudget(windowWidth: 1200) > 400)
        let smallest = WindowChromeLayout.listeningPlacesBudget(windowWidth: minimum.width)
        #expect(smallest >= WindowChromeMetrics.controlHeight)
        #expect(smallest < 100)
        #expect(WindowChromeLayout.listeningPlacesBudget(windowWidth: 0) == 0)
        var previous: CGFloat = 0
        for width in stride(from: 440, through: 1400, by: 40) {
            let budget = WindowChromeLayout.listeningPlacesBudget(windowWidth: CGFloat(width))
            #expect(budget >= previous)
            previous = budget
        }
    }

    // MARK: - Plan

    @Test("Le panneau des enceintes se replie quand le plan n'a plus sa place à côté")
    func planSidebarDocking() {
        let wide = PlanWindowLayout.make(windowWidth: roomy.width)
        #expect(wide.docksSidebar && wide.showsFullTools && wide.showsHint)
        #expect(wide.sidebarWidth == BridgeSidebar.panelWidth)
        #expect(wide.inspectorWidth == RoomPlanView.inspectorWidth)
        #expect(wide.overlayTop == WindowChromeMetrics.contentTop)
        #expect(wide.sidebarBottom == WindowChromeMetrics.sideMargin)

        #expect(PlanWindowLayout.make(windowWidth: PlanWindowLayout.dockingWidth).docksSidebar)
        let narrow = PlanWindowLayout.make(windowWidth: PlanWindowLayout.dockingWidth - 1)
        #expect(!narrow.docksSidebar && !narrow.showsFullTools && !narrow.showsHint)
        // La barre réduite reste au-dessus de ce qui s'ouvre en surimpression.
        #expect(narrow.overlayTop > WindowChromeMetrics.contentTop + PlanWindowLayout.compactBarHeight)
        // Et le panneau ouvert s'arrête au-dessus des boutons du zoom.
        #expect(narrow.sidebarBottom > WindowChromeMetrics.sideMargin + PlanWindowLayout.zoomRowHeight)
    }

    @Test("Docké, le panneau laisse au moins 400 points au plan ; en surimpression, rien ne dépasse")
    func planWidths() {
        let docked = PlanWindowLayout.dockingWidth - BridgeSidebar.panelWidth - 2 * WindowChromeMetrics.sideMargin
        #expect(docked >= 400)
        let smallest = PlanWindowLayout.make(windowWidth: minimum.width)
        #expect(smallest.sidebarWidth <= minimum.width - 2 * WindowChromeMetrics.sideMargin)
        #expect(smallest.inspectorWidth <= minimum.width - 2 * WindowChromeMetrics.sideMargin)
        let tiny = PlanWindowLayout.make(windowWidth: 200)
        #expect(tiny.sidebarWidth == 200 - 2 * WindowChromeMetrics.sideMargin)
        #expect(PlanWindowLayout.make(windowWidth: 0).sidebarWidth == 0)
    }

    // MARK: - Halo

    @Test("À partir de l'ancienne taille minimale, la vue Halo ne change pas")
    func haloUnchangedWhenRoomy() {
        for size in [roomy, defaultSize, CGSize(width: 1600, height: 1000)] {
            let layout = HaloLayout.make(size: size)
            #expect(layout.chips == .wrapped)
            #expect(layout.titleSize == 28)
            #expect(layout.showsSubtitle && layout.floatsNotices)
            #expect(layout.chipsTop == 18 && layout.sidePadding == 24 && layout.bottomPadding == 20)
        }
    }

    @Test("Les pastilles passent sur une rangée, puis se réduisent")
    func haloChipTiers() {
        // Assez large pour deux pastilles entières, mais basse : une rangée qui défile.
        #expect(HaloLayout.make(size: CGSize(width: 760, height: 560)).chips == .row)
        #expect(HaloLayout.make(size: CGSize(width: 900, height: 420)).chips == .row)
        // Large et haute : les deux rangées d'origine, même sous l'ancienne largeur minimale.
        #expect(HaloLayout.make(size: CGSize(width: 760, height: 700)).chips == .wrapped)
        // Deux pastilles entières ne tiennent plus : réduites, quelle que soit la hauteur.
        #expect(HaloLayout.make(size: CGSize(width: 600, height: 480)).chips == .compactRow)
        #expect(HaloLayout.make(size: CGSize(width: 460, height: 760)).chips == .compactRow)
        #expect(HaloLayout.make(size: minimum).chips == .compactRow)
        let edge = HaloLayout.compactChipsWidth
        #expect(HaloLayout.make(size: CGSize(width: edge, height: 500)).chips == .row)
        #expect(HaloLayout.make(size: CGSize(width: edge - 1, height: 500)).chips == .compactRow)
        // Dans la fenêtre la plus étroite, deux pastilles réduites tiennent à côté des commandes rondes.
        let room = minimum.width - 2 * HaloLayout.make(size: minimum).sidePadding
            - HaloChipMetrics.controlsWidth - HaloChipMetrics.spacing
        #expect(HaloChipsArrangement.rowWidth(chipCount: 2, chipWidth: HaloChipMetrics.compactWidth) <= room)
    }

    @Test("Le titre rapetisse, l'aide s'en va, et les alertes quittent leur coin")
    func haloHeadlineTiers() {
        let medium = HaloLayout.make(size: CGSize(width: 760, height: 560))
        #expect(medium.titleSize == 22 && medium.showsSubtitle && !medium.floatsNotices)
        let small = HaloLayout.make(size: CGSize(width: 600, height: 480))
        #expect(small.titleSize == 19 && !small.showsSubtitle && !small.floatsNotices)
        // Étroite mais haute : c'est la largeur qui retient le titre.
        let tall = HaloLayout.make(size: CGSize(width: 460, height: 760))
        #expect(tall.titleSize == 22 && tall.showsSubtitle && !tall.floatsNotices)
        // Une alerte flottante de 316 points recouvrirait l'anneau dès que la largeur manque.
        #expect(!HaloLayout.make(size: CGSize(width: roomy.width - 1, height: 760)).floatsNotices)
        #expect(!HaloLayout.make(size: CGSize(width: 1200, height: roomy.height - 1)).floatsNotices)
    }

    @Test("À la taille minimale, le halo le plus petit tient avec son titre, une alerte et ses pastilles")
    func haloFitsMinimum() {
        let layout = HaloLayout.make(size: minimum)
        // Le titre et la ligne d'alerte, à leur hauteur de ligne (≈ 1,25 fois le corps), et leur écart.
        let headline = layout.titleSize * 1.25 + 4 + 13 * 1.25
        let fixed = immersiveTop + layout.bottomPadding + layout.chipsTop + HaloChipMetrics.compactHeight + headline
        #expect(fixed + HaloMetrics.minimumZoneHeight <= minimum.height)
        // Et la sphère qui y loge reste au-dessus de son plancher : le pont s'y lit.
        let zone = CGSize(width: minimum.width - 2 * layout.sidePadding, height: minimum.height - fixed)
        #expect(HaloMetrics.sphereDiameter(fitting: zone) > HaloMetrics.sphereRange.lowerBound)
    }

    @Test("La rangée unique de pastilles se mesure sans les commandes rondes")
    func haloRowWidth() {
        #expect(HaloChipsArrangement.rowWidth(chipCount: 0, chipWidth: 100) == 0)
        #expect(HaloChipsArrangement.rowWidth(chipCount: -2, chipWidth: 100) == 0)
        #expect(HaloChipsArrangement.rowWidth(chipCount: 1, chipWidth: 100) == 100)
        #expect(HaloChipsArrangement.rowWidth(chipCount: 3, chipWidth: 100) == 300 + 2 * HaloChipMetrics.spacing)
    }

    // MARK: - Console

    @Test("À partir de l'ancienne taille minimale, la console ne change pas")
    func consoleUnchangedWhenRoomy() {
        for size in [roomy, defaultSize] {
            let view = CGSize(width: size.width, height: size.height - immersiveTop)
            let layout = ConsoleLayout.make(size: view, speakerCount: 4)
            #expect(!layout.isCompact && !layout.compactTiles)
            #expect(layout.margin == ConsoleMetrics.margin)
            #expect(layout.maxTileHeight == min(max(view.height * 0.66, 250), 480))
        }
    }

    @Test("Une fenêtre basse resserre ce qui entoure les tuiles, puis simplifie les tuiles")
    func consoleHeightTiers() {
        // 560 de haut : la console resserrée, mais des tuiles entières.
        let medium = ConsoleLayout.make(size: CGSize(width: 760, height: 560 - immersiveTop), speakerCount: 4)
        #expect(medium.isCompact && !medium.compactTiles)
        #expect(medium.maxTileHeight == 560 - immersiveTop - ConsoleLayout.compactChromeHeight)
        // 480 : encore entières, de justesse.
        #expect(!ConsoleLayout.make(size: CGSize(width: 600, height: 480 - immersiveTop), speakerCount: 4).compactTiles)
        // 420 et la taille minimale : simplifiées.
        #expect(ConsoleLayout.make(size: CGSize(width: 900, height: 420 - immersiveTop), speakerCount: 4).compactTiles)
        let smallest = ConsoleLayout.make(
            size: CGSize(width: minimum.width, height: minimum.height - immersiveTop), speakerCount: 4
        )
        #expect(smallest.isCompact && smallest.compactTiles)
        // Tout tient dans la hauteur : ce qui entoure les tuiles, et la tuile la plus basse.
        #expect(
            ConsoleLayout.compactChromeHeight + ConsoleLayout.smallestTileHeight <= minimum.height - immersiveTop
        )
        #expect(smallest.maxTileHeight >= ConsoleLayout.smallestTileHeight)
        // Étroite mais haute : rien de resserré en hauteur.
        let tall = ConsoleLayout.make(size: CGSize(width: 460, height: 760 - immersiveTop), speakerCount: 4)
        #expect(!tall.isCompact && !tall.compactTiles)
    }

    @Test("Une fenêtre étroite resserre les marges, et les tuiles défilent")
    func consoleWidthTiers() {
        let narrow = ConsoleLayout.make(size: CGSize(width: minimum.width, height: 352), speakerCount: 4)
        #expect(narrow.margin == ConsoleLayout.narrowMargin)
        #expect(narrow.scrolls)
        #expect(narrow.columnWidth == minimum.width - 2 * ConsoleLayout.narrowMargin)
        #expect(ConsoleLayout.make(size: CGSize(width: 759, height: 600), speakerCount: 1).margin == ConsoleLayout.narrowMargin)
        #expect(ConsoleLayout.make(size: CGSize(width: 760, height: 600), speakerCount: 1).margin == ConsoleMetrics.margin)
    }

    // MARK: - Barre de lecture

    @Test("À sa largeur d'origine, la barre de lecture ne change pas")
    func transportUnchangedWhenWide() {
        let layout = TransportLayout.make(width: ConsoleLayout.minimumColumnWidth, isCompact: false)
        #expect(layout.textWidth == TransportLayout.fullTextWidth)
        #expect(layout.showsDecibels && !layout.showsLevelInText)
        #expect(layout.height == TransportBar.height)
        #expect(layout.chipDiameter == 48 && layout.commandDiameter == 52 && layout.spacing == 14)
    }

    @Test("Le curseur cède d'abord, puis le texte se tronque, puis les dB s'en vont")
    func transportShrinkOrder() {
        var sawFullTextWithDecibels = false, sawShortTextWithDecibels = false, sawNoDecibels = false
        var previousText = CGFloat.infinity
        var hidDecibelsAt: CGFloat?
        for width in stride(from: CGFloat(720), through: 380, by: -4) {
            let layout = TransportLayout.make(width: width, isCompact: true)
            #expect(layout.textWidth >= TransportLayout.minimumTextWidth)
            #expect(layout.textWidth <= TransportLayout.fullTextWidth)
            if layout.showsDecibels {
                // Tant que les dB sont là, le texte ne fait que rétrécir, sans cesser de se lire.
                #expect(layout.textWidth <= previousText)
                #expect(layout.textWidth >= TransportLayout.readableTextWidth)
                #expect(hidDecibelsAt == nil)
                previousText = layout.textWidth
                if layout.textWidth == TransportLayout.fullTextWidth { sawFullTextWithDecibels = true }
                if layout.textWidth < TransportLayout.fullTextWidth { sawShortTextWithDecibels = true }
            } else {
                if hidDecibelsAt == nil {
                    hidDecibelsAt = width
                    // Les dB partis rendent leur place au texte.
                    #expect(layout.textWidth > previousText)
                }
                sawNoDecibels = true
                // Le niveau se lit alors sous le titre : il ne disparaît jamais.
                #expect(layout.showsLevelInText)
            }
        }
        #expect(sawFullTextWithDecibels && sawShortTextWithDecibels && sawNoDecibels)
    }

    @Test("Dans la fenêtre la plus étroite, la barre garde son curseur, son silence et sa commande")
    func transportFitsMinimum() {
        let width = minimum.width - 2 * ConsoleLayout.narrowMargin
        let layout = TransportLayout.make(width: width, isCompact: true)
        #expect(!layout.showsDecibels && layout.showsLevelInText)
        let used = layout.leadingPadding + layout.trailingPadding + layout.chipDiameter + layout.chipSpacing
            + layout.textWidth + layout.sliderMinWidth + TransportLayout.muteWidth + layout.commandDiameter
            + 3 * layout.spacing
        #expect(used <= width)
        // « Diffusion vers 3 enceintes » y tient à peu près en entier.
        #expect(layout.textWidth >= 140)
    }

    @Test("Sans volume général, la barre donne toute la place au texte")
    func transportWithoutMaster() {
        let wide = TransportLayout.make(width: 720, isCompact: false, showsMaster: false)
        #expect(wide.textWidth == TransportLayout.fullTextWidth)
        #expect(!wide.showsDecibels && !wide.showsLevelInText)
        let narrow = TransportLayout.make(width: 300, isCompact: true, showsMaster: false)
        #expect(narrow.textWidth >= TransportLayout.minimumTextWidth)
        #expect(narrow.textWidth < TransportLayout.fullTextWidth)
    }

    // MARK: - Rangée qui défile

    @Test("Un chevron apparaît du côté où il reste du contenu, et seulement là")
    func scrollEdges() {
        let fits = ScrollEdges(offset: 0, viewport: 400, content: 400)
        #expect(!fits.canScrollBack && !fits.canScrollForward)
        let start = ScrollEdges(offset: 0, viewport: 300, content: 700)
        #expect(!start.canScrollBack && start.canScrollForward)
        let middle = ScrollEdges(offset: 200, viewport: 300, content: 700)
        #expect(middle.canScrollBack && middle.canScrollForward)
        let end = ScrollEdges(offset: 400, viewport: 300, content: 700)
        #expect(end.canScrollBack && !end.canScrollForward)
        // Un reste d'un point n'est pas une suite.
        #expect(!ScrollEdges(offset: 399.5, viewport: 300, content: 700).canScrollForward)
        #expect(!ScrollEdges(offset: 0.5, viewport: 300, content: 700).canScrollBack)
        // Rien de mesuré encore : aucun chevron.
        #expect(!ScrollEdges().canScrollBack && !ScrollEdges().canScrollForward)
    }

    @Test("Un clic sur un chevron avance d'une page, sans dépasser les bouts")
    func scrollTargets() {
        let start = ScrollEdges(offset: 0, viewport: 300, content: 1000)
        #expect(start.target(forward: true) == 300 * ScrollEdges.pageShare)
        #expect(start.target(forward: false) == 0)
        let nearEnd = ScrollEdges(offset: 650, viewport: 300, content: 1000)
        #expect(nearEnd.target(forward: true) == 700)
        #expect(nearEnd.target(forward: false) == 650 - 300 * ScrollEdges.pageShare)
        #expect(ScrollEdges(offset: 0, viewport: 400, content: 300).target(forward: true) == 0)
    }
}
