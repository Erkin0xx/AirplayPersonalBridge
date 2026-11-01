//
//  MenuBarGlyph.swift
//  AirplayPersonalBridge
//

import AppKit
import SwiftUI

/// Le glyphe en image `template` : c'est le seul moyen de lui faire suivre la teinte que macOS donne
/// à la barre de menus, sur un fond clair comme sur un fond foncé.
///
/// Dessiné à la demande plutôt que tiré d'un catalogue d'actifs : il reste vectoriel à toute échelle,
/// et la cible `swift build`, qui ne voit pas `Assets.xcassets`, peut le rendre dans ses tests.
enum MenuBarGlyphImage {
    private static let images = Dictionary(
        uniqueKeysWithValues: BridgeGlyph.Variant.allCases.map { ($0, make($0)) }
    )

    static func image(for variant: BridgeGlyph.Variant) -> NSImage {
        images[variant] ?? make(variant)
    }

    /// Non isolée : AppKit peut rappeler le dessin hors du fil principal, et une fermeture héritant de
    /// l'isolation par défaut planterait alors à la vérification de l'acteur.
    private nonisolated static func make(_ variant: BridgeGlyph.Variant) -> NSImage {
        let image = NSImage(size: BridgeGlyph.canvas, flipped: true) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.addPath(BridgeGlyph.path(variant))
            context.fillPath(using: .evenOdd)
            return true
        }
        image.isTemplate = true
        return image
    }
}

/// Un chemin du glyphe, ramené au cadre qu'on lui donne.
struct BridgeGlyphShape: Shape {
    private let glyph: Path

    init(path: CGPath) {
        glyph = Path(path)
    }

    func path(in rect: CGRect) -> Path {
        let canvas = BridgeGlyph.canvas
        let scale = min(rect.width / canvas.width, rect.height / canvas.height)
        return glyph.applying(
            CGAffineTransform(
                translationX: rect.midX - canvas.width * scale / 2,
                y: rect.midY - canvas.height * scale / 2
            )
            .scaledBy(x: scale, y: scale)
        )
    }
}

/// La pastille d'état de l'en-tête : le glyphe de la barre de menus, dans la même rondeur que celle
/// des enceintes juste en dessous.
///
/// La diffusion s'y sent sans s'imposer : la pastille prend l'accent et les suspentes respirent. Ce
/// n'est **pas** un vumètre, le pipeline ne mesure aucun niveau. C'est pourquoi l'animation s'arrête
/// dès que la capture signale un silence : elle ne doit pas prétendre qu'un son passe.
struct PanelStatusChip: View {
    let status: MenuBarStatus
    /// Rien ne signale de silence : on peut laisser le glyphe respirer.
    let isAudible: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Le contenu d'un `MenuBarExtra` peut survivre à la fermeture du panneau : sans cette garde,
    /// l'animation continuerait de tourner pour personne.
    @Environment(\.appearsActive) private var appearsActive

    var body: some View {
        ZStack {
            Circle().fill(background)
            // Le point d'exclamation, seule marque du lot, se prend à plus grande échelle pour peser
            // autant que les cinq barres.
            marks
                .frame(width: status == .trouble ? 24 : 18, height: status == .trouble ? 22 : 16)
                .foregroundStyle(foreground)
        }
        .frame(width: PanelMetrics.pastille, height: PanelMetrics.pastille)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var marks: some View {
        switch status {
        case .streaming where isAudible && !reduceMotion:
            TimelineView(.animation(minimumInterval: 1 / 20, paused: !appearsActive)) { timeline in
                glyph(.streaming, levels: Self.levels(at: timeline.date.timeIntervalSinceReferenceDate))
            }
        case .connecting where !reduceMotion:
            TimelineView(.animation(minimumInterval: 1 / 15, paused: !appearsActive)) { timeline in
                glyph(.connecting).opacity(
                    0.55 + 0.45 * abs(sin(timeline.date.timeIntervalSinceReferenceDate * 2.4))
                )
            }
        default:
            glyph(status.glyph)
        }
    }

    private func glyph(
        _ variant: BridgeGlyph.Variant, levels: BridgeGlyph.Levels = .rest
    ) -> some View {
        BridgeGlyphShape(path: BridgeGlyph.marks(variant, levels: levels))
            .fill(style: FillStyle(eoFill: true))
    }

    /// Deux sinusoïdes de périodes sans commune mesure : le mouvement ne se répète pas à l'œil, et
    /// reste assez lent pour passer pour une respiration plutôt que pour un niveau.
    private static func levels(at time: TimeInterval) -> BridgeGlyph.Levels {
        BridgeGlyph.Levels(
            sides: 0.72 + 0.28 * sin(time * 2.1),
            center: 0.5 + 0.5 * sin(time * 3.3 + 1)
        )
    }

    private var background: Color {
        switch status {
        case .idle, .connecting: PanelPalette.quietFill
        case .streaming: .accentColor
        case .trouble: .red
        }
    }

    private var foreground: Color {
        switch status {
        case .idle: .secondary
        case .connecting: .primary
        case .streaming, .trouble: .white
        }
    }
}
