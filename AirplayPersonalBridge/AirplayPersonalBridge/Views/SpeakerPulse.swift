//
//  SpeakerPulse.swift
//  AirplayPersonalBridge
//

import SwiftUI

/// L'onde qui part des enceintes en train de jouer, sur le plan.
///
/// Le plan dit où sont les enceintes ; l'onde dit lesquelles jouent, là où l'œil les cherche, sans une
/// ligne de texte. Trois anneaux qui s'éloignent et s'éteignent, lents : une respiration, pas un vumètre —
/// ils ne mesurent rien, et ne doivent pas le laisser croire. Dessinée à part du plan, dans son propre
/// `Canvas` : quelques cercles par image, quand redessiner tout le plan trente fois par seconde coûterait
/// un cœur.
struct SpeakerPulse: View {
    struct Source: Equatable {
        /// Le centre de l'enceinte, en points de la vue.
        var center: CGPoint
        /// D'où part l'onde : le bord de l'enceinte.
        var radius: Double
    }

    struct Ring: Equatable {
        /// De 0, au bord de l'enceinte, à 1, au bout de sa course.
        var progress: Double
        var opacity: Double
    }

    let sources: [Source]
    /// Jusqu'où l'onde s'éloigne du bord de l'enceinte, en points.
    let reach: Double

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Fenêtre à l'arrière-plan : l'onde s'arrête, personne ne la regarde.
    @Environment(\.appearsActive) private var appearsActive

    static let period: TimeInterval = 2.8
    static let ringCount = 3

    var body: some View {
        if sources.isEmpty {
            EmptyView()
        } else if reduceMotion {
            // Sans mouvement, l'onde reste dite : des anneaux posés.
            Canvas { context, _ in draw(Self.rings(at: Self.period * 0.12), in: &context) }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        } else {
            TimelineView(.animation(minimumInterval: 1 / 30, paused: !appearsActive)) { timeline in
                Canvas { context, _ in
                    draw(Self.rings(at: timeline.date.timeIntervalSinceReferenceDate), in: &context)
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    /// Les anneaux à cet instant : régulièrement espacés, chacun s'éteignant en s'éloignant. À la fin de
    /// sa course un anneau est transparent, et renaît au bord : la boucle n'a pas de couture.
    static func rings(at time: TimeInterval) -> [Ring] {
        (0..<ringCount).map { index in
            let phase = time / period + Double(index) / Double(ringCount)
            let progress = phase - phase.rounded(.down)
            // Naît vite, s'éteint lentement : un anneau qui apparaîtrait d'un coup clignoterait.
            let fadeIn = min(progress / 0.12, 1)
            let fadeOut = (1 - progress) * (1 - progress)
            return Ring(progress: progress, opacity: 0.6 * fadeIn * fadeOut)
        }
    }

    private func draw(_ rings: [Ring], in context: inout GraphicsContext) {
        for source in sources {
            for ring in rings {
                let radius = source.radius + ring.progress * reach
                let rect = CGRect(
                    x: source.center.x - radius, y: source.center.y - radius,
                    width: radius * 2, height: radius * 2
                )
                context.stroke(
                    Path(ellipseIn: rect),
                    with: .color(PlanPalette.speakerAccent.opacity(ring.opacity)),
                    lineWidth: 1.75 - ring.progress
                )
            }
        }
    }
}
