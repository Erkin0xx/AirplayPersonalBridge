//
//  ScrollChevrons.swift
//  AirplayPersonalBridge
//

import SwiftUI

/// Où en est une rangée qui défile : hors de la vue pour être testé.
///
/// Dans une petite fenêtre, les pastilles du halo et les tuiles de la console ne tiennent plus toutes.
/// Un pavé tactile les fait défiler ; une souris à molette, non. Un chevron apparaît donc du côté où il
/// reste quelque chose, et avance d'une page au clic : rien de ce qui a quitté la vue n'est hors d'atteinte.
nonisolated struct ScrollEdges: Equatable, Sendable {
    var offset: CGFloat = 0
    var viewport: CGFloat = 0
    var content: CGFloat = 0

    /// Sous ce reste, on est au bout : un chevron pour un point n'aurait pas de sens.
    static let tolerance: CGFloat = 1
    /// La part de la vue qu'un clic fait défiler : le dernier élément visible reste à l'écran, en repère.
    static let pageShare: CGFloat = 0.8

    /// Le plus loin qu'on puisse défiler.
    var maxOffset: CGFloat { max(content - viewport, 0) }
    var canScrollBack: Bool { offset > Self.tolerance }
    var canScrollForward: Bool { offset < maxOffset - Self.tolerance }

    /// Où mène un clic sur un chevron : une page plus loin, sans dépasser les bouts.
    func target(forward: Bool) -> CGFloat {
        let step = viewport * Self.pageShare
        return min(max(offset + (forward ? step : -step), 0), maxOffset)
    }
}

/// Pose sur un `ScrollView` horizontal un chevron de chaque côté où il reste du contenu, et, si on le
/// demande, un fondu de ces mêmes bords.
struct HorizontalScrollChevrons: ViewModifier {
    /// La largeur du fondu des bords ; zéro pour aucun.
    var fade: CGFloat = 0
    /// Du bord de la vue au chevron.
    var inset: CGFloat = 0

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var position = ScrollPosition()
    @State private var edges = ScrollEdges()

    func body(content: Content) -> some View {
        content
            .scrollPosition($position)
            .onScrollGeometryChange(for: ScrollEdges.self) { geometry in
                ScrollEdges(
                    offset: geometry.contentOffset.x, viewport: geometry.containerSize.width,
                    content: geometry.contentSize.width
                )
            } action: { _, new in
                edges = new
            }
            .mask {
                if fade > 0 {
                    HStack(spacing: 0) {
                        edge(isShown: edges.canScrollBack, from: .leading)
                        Rectangle()
                        edge(isShown: edges.canScrollForward, from: .trailing)
                    }
                } else {
                    // Sans fondu, rien n'est masqué : l'ombre du contenu déborde comme avant.
                    Rectangle().padding(-200)
                }
            }
            .overlay(alignment: .leading) {
                if edges.canScrollBack { chevron(forward: false).padding(.leading, inset) }
            }
            .overlay(alignment: .trailing) {
                if edges.canScrollForward { chevron(forward: true).padding(.trailing, inset) }
            }
    }

    private func edge(isShown: Bool, from side: UnitPoint) -> some View {
        LinearGradient(
            colors: [isShown ? .clear : .black, .black], startPoint: side,
            endPoint: side == .leading ? .trailing : .leading
        )
        .frame(width: fade)
    }

    private func chevron(forward: Bool) -> some View {
        Button {
            let target = edges.target(forward: forward)
            withAnimation(reduceMotion ? nil : .smooth(duration: 0.3)) {
                position.scrollTo(x: target)
            }
        } label: {
            Image(systemName: forward ? "chevron.right" : "chevron.left")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(Color.black.opacity(0.62), in: Circle())
                .overlay { Circle().strokeBorder(Color.white.opacity(0.22), lineWidth: 1) }
                .contentShape(Circle().inset(by: -4))
        }
        .buttonStyle(.plain)
        .help(forward ? "Voir la suite" : "Revenir au début")
        .accessibilityLabel(forward ? "Faire défiler vers la suite" : "Faire défiler vers le début")
    }
}
