//
//  WindowSizing.swift
//  AirplayPersonalBridge
//

import SwiftUI

/// Les tailles de la fenêtre principale, et ce que chaque palier change : hors des vues pour être testé.
///
/// La fenêtre se réduit jusqu'à une petite télécommande posée dans un coin de l'écran (demande de Baptiste
/// du 2026-11-11). Rien ne disparaît sans retour : ce qui n'a plus sa place se replie en menu, en icône,
/// ou défile. À partir de `roomy`, l'ancienne taille minimale, rien ne change.
nonisolated enum WindowSizing {
    /// La plus petite fenêtre : les trois vues y restent utilisables.
    static let minimum = CGSize(width: 440, height: 400)
    /// La taille minimale d'avant : à partir d'elle, la fenêtre se dessine comme elle l'a toujours fait.
    static let roomy = CGSize(width: 960, height: 620)
}

/// Le haut de la fenêtre : la pastille de source entre ce qui flotte à sa gauche et à sa droite.
enum WindowChromeLayout {
    /// Entre la pastille et ses voisins.
    nonisolated static let gap: CGFloat = 8
    /// La place gardée à la pastille quand on décide de la forme de ses voisins : « Son système global » y
    /// tient en entier.
    static let pillReserve: CGFloat = 200
    /// En deçà, un nom tronqué ne dit plus rien : une icône et un chevron.
    nonisolated static let iconOnlyBelow: CGFloat = 120

    /// La largeur libre entre les voisins de la pastille. `leading` et `trailing` sont mesurés : ce que
    /// les commandes occupent depuis chaque bord de la fenêtre, marge comprise.
    nonisolated static func pillSlot(windowWidth: CGFloat, leading: CGFloat, trailing: CGFloat) -> CGFloat {
        max(windowWidth - leading - trailing - 2 * gap, 0)
    }

    nonisolated static func pillIsIconOnly(slot: CGFloat) -> Bool {
        slot < iconOnlyBelow
    }

    /// Le bord gauche de la pastille : centrée dans la fenêtre tant qu'elle ne touche personne, sinon
    /// poussée juste assez pour garder l'écart. Si elle ne tient pas du tout, elle part de son voisin de
    /// gauche.
    nonisolated static func pillMinX(windowWidth: CGFloat, pillWidth: CGFloat, leading: CGFloat, trailing: CGFloat) -> CGFloat {
        let centered = (windowWidth - pillWidth) / 2
        let lower = leading + gap
        let upper = windowWidth - trailing - gap - pillWidth
        guard upper >= lower else { return lower }
        return min(max(centered, lower), upper)
    }

    /// La largeur offerte au sélecteur de lieu d'écoute de la console : ce qui reste une fois servis les
    /// commandes de fenêtre, la pastille et le bouton des options. Il s'y montre en segments, en menu à
    /// son nom, ou en icône, selon ce qui y tient.
    static func listeningPlacesBudget(windowWidth: CGFloat) -> CGFloat {
        let options = WindowChromeMetrics.controlHeight + gap + WindowChromeMetrics.sideMargin
        return max(windowWidth - WindowChromeMetrics.trafficLightsWidth - pillReserve - 2 * gap - options, 0)
    }
}

/// La vue Plan selon la largeur de la fenêtre.
struct PlanWindowLayout: Equatable {
    /// Le panneau des enceintes tient à côté du plan. Sinon il se replie derrière une barre réduite (état,
    /// silence, Diffuser/Arrêter), et s'ouvre en surimpression.
    var docksSidebar: Bool
    /// Les outils du haut en entier. Sinon l'ajout, le lieu d'écoute et l'historique passent dans « Plus ».
    var showsFullTools: Bool
    /// L'aide et l'échelle du bas : elles cèdent leur place avant les boutons du zoom.
    var showsHint: Bool
    var sidebarWidth: CGFloat
    var inspectorWidth: CGFloat

    /// En deçà, le plan n'aurait plus 400 points à côté du panneau.
    static let dockingWidth: CGFloat = 780
    /// La barre réduite, sous les commandes flottantes.
    static let compactBarHeight: CGFloat = 44
    static let compactBarGap: CGFloat = 8

    static func make(windowWidth: CGFloat) -> PlanWindowLayout {
        let docks = windowWidth >= dockingWidth
        let room = max(windowWidth - 2 * WindowChromeMetrics.sideMargin, 0)
        return PlanWindowLayout(
            docksSidebar: docks, showsFullTools: docks, showsHint: docks,
            sidebarWidth: min(BridgeSidebar.panelWidth, room),
            inspectorWidth: min(RoomPlanView.inspectorWidth, room)
        )
    }

    /// Du panneau des enceintes au bas de la fenêtre. Ouvert en surimpression, il s'arrête au-dessus des
    /// boutons du zoom, qu'il recouvrirait à moitié.
    var sidebarBottom: CGFloat {
        docksSidebar ? WindowChromeMetrics.sideMargin : 2 * WindowChromeMetrics.sideMargin + Self.zoomRowHeight
    }

    /// La rangée du zoom, en bas du plan.
    static let zoomRowHeight: CGFloat = 28

    /// Du haut de la fenêtre à ce qui flotte sous les commandes : le panneau replié laisse sa barre
    /// au-dessus du panneau ouvert et de l'inspecteur.
    var overlayTop: CGFloat {
        docksSidebar
            ? WindowChromeMetrics.contentTop
            : WindowChromeMetrics.contentTop + Self.compactBarHeight + Self.compactBarGap
    }
}

/// Ce que les outils de la vue Plan occupent en haut de la fenêtre, de chaque côté de la pastille de
/// source : mesuré par la vue, remonté à `ContentView`.
nonisolated struct PlanToolWidths: Equatable, Sendable {
    var leading: CGFloat = 0
    var trailing: CGFloat = 0

    struct Key: PreferenceKey {
        static var defaultValue: PlanToolWidths { PlanToolWidths() }

        static func reduce(value: inout PlanToolWidths, nextValue: () -> PlanToolWidths) {
            let next = nextValue()
            value = PlanToolWidths(
                leading: max(value.leading, next.leading), trailing: max(value.trailing, next.trailing)
            )
        }
    }
}

/// Propose à son contenu au plus `maxWidth`, et prend sa taille : un `frame(maxWidth:)` s'étirerait
/// jusqu'à cette largeur, et fausserait la mesure de ce que le contenu occupe vraiment.
struct CappedWidthLayout: Layout {
    var maxWidth: CGFloat

    private func capped(_ proposal: ProposedViewSize) -> ProposedViewSize {
        ProposedViewSize(width: min(proposal.width ?? maxWidth, maxWidth), height: proposal.height)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        subviews.first?.sizeThatFits(capped(proposal)) ?? .zero
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(
            at: CGPoint(x: bounds.maxX, y: bounds.minY), anchor: .topTrailing, proposal: capped(proposal)
        )
    }
}

/// Pose la pastille de source sur toute la largeur de la fenêtre (`WindowChromeLayout.pillMinX`).
struct SourcePillLayout: Layout {
    var leading: CGFloat
    var trailing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let height = subviews.first?.sizeThatFits(.unspecified).height ?? 0
        return CGSize(width: proposal.width ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let pill = subviews.first else { return }
        let size = pill.sizeThatFits(.unspecified)
        let x = WindowChromeLayout.pillMinX(
            windowWidth: bounds.width, pillWidth: size.width, leading: leading, trailing: trailing
        )
        pill.place(at: CGPoint(x: bounds.minX + x, y: bounds.minY), anchor: .topLeading, proposal: .unspecified)
    }
}
