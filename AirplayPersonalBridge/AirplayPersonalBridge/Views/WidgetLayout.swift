//
//  WidgetLayout.swift
//  AirplayPersonalBridge
//

import CoreGraphics
import Foundation

/// Les mesures du widget, en points, relevées sur les maquettes 23 et 24 : hors des vues pour être testées.
///
/// Le widget a la taille du widget d'horloge de Baptiste. Tout y est posé à des places fixes : il ne se
/// redimensionne pas.
enum WidgetMetrics {
    static let size = CGSize(width: 345, height: 165)
    static let cornerRadius: CGFloat = 28
    /// La cible saisissable la plus petite qu'on s'autorise.
    static let minimumTarget: CGFloat = 22

    // MARK: Style « Halo »

    /// Le centre du disque, et de l'anneau qui l'entoure.
    static let haloCenter = CGPoint(x: 82, y: 82.5)
    static let haloDiscDiameter: CGFloat = 96
    /// Le rayon de l'anneau du volume général, au milieu de son trait.
    static let haloRingRadius: CGFloat = 62
    /// « GÉNÉRAL » et sa valeur, au-dessus des curseurs.
    static let haloHeader = CGRect(x: 166, y: 13, width: 165, height: 14)
    static let haloFaderTop: CGFloat = 33
    static let haloFader = CGSize(width: 22, height: 86)
    static let haloFaderRadius: CGFloat = 7.5

    // MARK: Style « Bandeau »

    /// La colonne de gauche : le bouton rond, puis le volume général.
    static let bandColumn = CGRect(x: 18, y: 14, width: 120, height: 137)
    static let bandButtonDiameter: CGFloat = 62
    static let bandSliderHeight: CGFloat = 26
    static let bandPillTop: CGFloat = 14
    static let bandPill = CGSize(width: 55, height: 137)
    static let bandPillRadius: CGFloat = 16
    /// Le pied d'une pastille, où logent le nom et la valeur : le trait du niveau ne descend pas dessous.
    static let bandPillFloor: CGFloat = 36
}

/// La rangée des enceintes, à droite : hors de la vue pour être testée.
///
/// Trois enceintes tiennent, c'est l'installation de Baptiste. Moins, elles se centrent dans la même zone ;
/// plus, la rangée défile, et sa fenêtre de défilement déborde un peu de la zone de chaque côté pour que
/// les colonnes ne soient pas coupées au ras de la première et de la dernière.
struct WidgetSpeakerLayout: Equatable {
    /// La largeur d'une colonne : c'est aussi celle du nom, sous le curseur.
    var columnWidth: CGFloat
    var spacing: CGFloat
    /// Le bord gauche de la zone : celui de la première colonne quand trois enceintes sont là.
    var zoneX: CGFloat
    var count: Int

    /// Ce qui tient sans défiler.
    static let capacity = 3
    /// Ce dont la fenêtre de défilement déborde de la zone, de chaque côté.
    static let bleed: CGFloat = 12

    static func make(count: Int, style: WidgetStyle) -> WidgetSpeakerLayout {
        switch style {
        case .halo:
            WidgetSpeakerLayout(columnWidth: 49, spacing: 9, zoneX: 166, count: max(count, 0))
        case .band:
            WidgetSpeakerLayout(
                columnWidth: WidgetMetrics.bandPill.width, spacing: 8, zoneX: 150, count: max(count, 0)
            )
        }
    }

    private static func width(of count: Int, column: CGFloat, spacing: CGFloat) -> CGFloat {
        count > 0 ? CGFloat(count) * column + CGFloat(count - 1) * spacing : 0
    }

    /// La largeur de la zone : celle de trois colonnes.
    var zoneWidth: CGFloat { Self.width(of: Self.capacity, column: columnWidth, spacing: spacing) }
    /// La largeur de toutes les colonnes, bout à bout.
    var contentWidth: CGFloat { Self.width(of: count, column: columnWidth, spacing: spacing) }
    var scrolls: Bool { count > Self.capacity }

    /// La fenêtre de défilement, dans le repère du widget.
    var viewportX: CGFloat { zoneX - Self.bleed }
    var viewportWidth: CGFloat { zoneWidth + 2 * Self.bleed }

    /// Le bord gauche de la première colonne tant que rien n'a défilé, dans le repère du widget : centrée
    /// dans la zone s'il y a de la place, au début de la zone sinon.
    var firstColumnX: CGFloat {
        scrolls ? zoneX : zoneX + (zoneWidth - contentWidth) / 2
    }
}

/// Les mots du widget : courts, la place est comptée.
enum WidgetCopy {
    enum Tone: Equatable {
        /// Une valeur : le réglage de l'enceinte.
        case value
        /// Un état qui n'appelle rien : décochée, coupée.
        case quiet
        /// Hors ligne : en orange, comme sur la maquette.
        case warning
    }

    struct Caption: Equatable {
        var text: String
        var tone: Tone
    }

    /// La ligne sous le nom d'une enceinte : son réglage, ou pourquoi elle ne joue pas. Ce qui l'empêche de
    /// jouer passe avant ce qu'on y a réglé.
    static func caption(
        isOffline: Bool, isHeldBack: Bool, isEnabled: Bool, isMuted: Bool, trimDB: Double
    ) -> Caption {
        if isOffline { return Caption(text: "Hors ligne", tone: .warning) }
        if isHeldBack { return Caption(text: "Bloquée", tone: .quiet) }
        if !isEnabled { return Caption(text: "Décochée", tone: .quiet) }
        if isMuted { return Caption(text: "Coupée", tone: .quiet) }
        return Caption(text: PanelFormat.decibels(trimDB, fractionDigits: 1, signed: true), tone: .value)
    }

    /// La valeur du volume général, à côté de « GÉNÉRAL ».
    static func masterValue(isMuted: Bool, decibels: Double) -> String {
        isMuted ? "Coupé" : PanelFormat.decibels(decibels)
    }

    /// À la place des curseurs quand il n'y a aucune enceinte à montrer.
    static func emptyMessage(isSearching: Bool, allHidden: Bool) -> String {
        if allHidden { return "Toutes les enceintes sont masquées" }
        return isSearching ? "Recherche des enceintes…" : "Aucune enceinte trouvée"
    }

    /// La ligne « Widget » du panneau de la barre de menus et du bouton des options.
    static func toggleTitle(isShown: Bool) -> String {
        isShown ? "Masquer le widget" : "Afficher le widget"
    }
}

/// L'icône de la ligne « Widget », dans le bouton des options de la fenêtre.
enum WidgetSymbol {
    static let name = "widget.small"
}

// MARK: - Menu du fond

/// Ce que fait une ligne du menu qui s'ouvre au clic droit sur le fond du widget.
enum WidgetMenuAction: Equatable {
    case setStyle(WidgetStyle)
    case toggleFloating
    case openMainWindow
    case close
}

/// Une ligne de ce menu. Sans action : un séparateur.
struct WidgetMenuEntry: Equatable {
    var title = ""
    var isChecked = false
    var action: WidgetMenuAction?

    static let separator = WidgetMenuEntry()
}

/// Le menu du fond, décrit hors de toute vue pour être testé : AppKit n'a plus qu'à le dessiner.
enum WidgetMenu {
    static func entries(for settings: WidgetSettings) -> [WidgetMenuEntry] {
        WidgetStyle.allCases.map { style in
            WidgetMenuEntry(
                title: "Style \(style.title)", isChecked: settings.style == style, action: .setStyle(style)
            )
        } + [
            .separator,
            WidgetMenuEntry(title: "Toujours au-dessus", isChecked: settings.floatsOnTop, action: .toggleFloating),
            .separator,
            WidgetMenuEntry(title: "Ouvrir la fenêtre…", action: .openMainWindow),
            WidgetMenuEntry(title: "Fermer le widget", action: .close),
        ]
    }

    /// Ce qu'une ligne change aux réglages du widget. Ouvrir la fenêtre n'y change rien : c'est à l'app.
    static func apply(_ action: WidgetMenuAction, to settings: inout WidgetSettings) {
        switch action {
        case let .setStyle(style): settings.style = style
        case .toggleFloating: settings.floatsOnTop.toggle()
        case .close: settings.isShown = false
        case .openMainWindow: break
        }
    }
}

// MARK: - Place à l'écran

/// Où poser la fenêtre du widget : hors de la fenêtre pour être testé. Repère d'AppKit, origine en bas à
/// gauche.
enum WidgetPlacement {
    /// Du coin de l'écran au widget, quand il s'ouvre pour la première fois.
    static let screenMargin: CGFloat = 24
    /// Ce qu'il faut voir du widget pour pouvoir le rattraper : en deçà, sa place mémorisée est perdue
    /// (un écran débranché, une résolution changée) et il revient dans le coin.
    static let reachable = CGSize(width: 80, height: 40)

    /// La place mémorisée si on peut encore y saisir le widget, sinon le coin haut droit de l'écran
    /// principal.
    /// - Parameters:
    ///   - screens: les zones utiles des écrans (`visibleFrame`).
    ///   - main: celle de l'écran principal.
    static func origin(saved: CGPoint?, size: CGSize, screens: [CGRect], main: CGRect?) -> CGPoint {
        if let saved, isReachable(CGRect(origin: saved, size: size), on: screens) { return saved }
        guard let home = main ?? screens.first else { return saved ?? .zero }
        return CGPoint(
            x: home.maxX - size.width - screenMargin, y: home.maxY - size.height - screenMargin
        )
    }

    static func isReachable(_ frame: CGRect, on screens: [CGRect]) -> Bool {
        screens.contains { screen in
            let shown = screen.intersection(frame)
            return !shown.isNull && shown.width >= reachable.width && shown.height >= reachable.height
        }
    }
}
