//
//  HaloSphere.swift
//  AirplayPersonalBridge
//

import SwiftUI

/// Le mouvement de la sphère, hors de la vue pour être testé : une respiration lente. Les reflets du
/// verre ont leur propre mouvement (`NovaGlassMotion`). Rien n'y mesure le son : c'est un témoin, pas un
/// vumètre.
nonisolated enum HaloSphereMotion {
    /// Une inspiration et une expiration.
    static let breathPeriod: TimeInterval = 7.2
    /// De combien la sphère grossit en inspirant, en part de son rayon.
    static let breathDepth = 0.045
    /// Un tour complet de `spin`.
    static let spinPeriod: TimeInterval = 16

    /// De 0, expirée, à 1, inspirée, sans à-coup aux deux bouts.
    static func breath(at time: TimeInterval) -> Double {
        0.5 - 0.5 * cos(2 * Double.pi * time / breathPeriod)
    }

    /// L'échelle de la sphère à cet instant : jamais plus petite que sa taille, jamais plus grande que
    /// `1 + breathDepth`. L'anneau du volume, juste autour, compte dessus.
    static func scale(at time: TimeInterval) -> Double {
        1 + breathDepth * breath(at: time)
    }

    /// Un angle qui fait un tour par `spinPeriod`, en radians, dans `0..<2π`.
    static func spin(at time: TimeInterval) -> Double {
        let turns = time / spinPeriod
        return 2 * Double.pi * (turns - turns.rounded(.down))
    }
}

/// La sphère du halo : une bille de verre presque noir (`NovaGlass`), grise et immobile au repos, dont les
/// reflets roses glissent quand un son part.
///
/// Trois allures. `resting` : le verre éteint, un seul liseré, rien ne bouge. `live` sans son audible (son
/// coupé, capture muette) : les reflets sont là, la session tient, mais ils sont voilés et figés — le
/// reflet qui bouge veut dire « ça joue », et ne doit pas le prétendre. `live` et audible : ils glissent,
/// la sphère respire, une lueur l'entoure.
///
/// Tout est dessiné dans un `Canvas`, en textures cuites une fois et en dégradés : un filtre de flou ne se
/// rend pas hors écran. Pas de grain sur la bille : c'est le verre lisse sur le fond granuleux qui la
/// détache.
struct HaloSphere: View {
    enum Look: Equatable {
        case resting
        case live
    }

    let look: Look
    /// Un son part vraiment : la sphère vit.
    let isAudible: Bool
    /// Ce que porte le centre : le pont, ou les trois points d'une transition.
    let glyph: BridgeGlyph.Variant
    let diameter: CGFloat
    /// Un instant imposé, pour un rendu d'essai : la bille s'y fige. `nil` dans l'app.
    var frozenTime: TimeInterval?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Fenêtre à l'arrière-plan : la sphère s'arrête, personne ne la regarde.
    @Environment(\.appearsActive) private var appearsActive

    /// L'instant posé quand rien ne bouge : expirée, la nappe rose à sa place de dessin.
    static let stillTime: TimeInterval = 0
    /// Les reflets glissent sur cinquante secondes : vingt images par seconde leur suffisent.
    static let frameInterval: TimeInterval = 1 / 20
    /// Le dessin déborde de la sphère : la lueur et l'ombre portée.
    static let canvasShare: CGFloat = 2.2

    private var isAnimated: Bool { look == .live && isAudible && !reduceMotion && frozenTime == nil }

    var body: some View {
        ZStack {
            Group {
                if isAnimated {
                    TimelineView(.animation(minimumInterval: Self.frameInterval, paused: !appearsActive)) { timeline in
                        orb(at: timeline.date.timeIntervalSinceReferenceDate)
                    }
                } else {
                    orb(at: frozenTime ?? Self.stillTime)
                }
            }
            .frame(width: diameter * Self.canvasShare, height: diameter * Self.canvasShare)
            marks
                .frame(width: diameter * 0.364, height: diameter * 0.328)
                .foregroundStyle(look == .live ? Color.white : BridgeTheme.color(0xD8D4E0))
                // Une ombre sombre le détache d'un reflet qui passerait derrière lui.
                .shadow(color: .black.opacity(0.55), radius: 6, y: 1)
        }
        .frame(width: diameter, height: diameter)
    }

    private func orb(at time: TimeInterval) -> some View {
        Canvas { context, size in
            Self.draw(
                in: &context, center: CGPoint(x: size.width / 2, y: size.height / 2),
                radius: diameter / 2, look: look, isAudible: isAudible, time: time
            )
        }
    }

    // MARK: - Glyphe

    @ViewBuilder
    private var marks: some View {
        switch glyph {
        case .connecting where !reduceMotion:
            TimelineView(.animation(minimumInterval: 1 / 15, paused: !appearsActive)) { timeline in
                shape(.connecting).opacity(
                    0.55 + 0.45 * abs(sin(timeline.date.timeIntervalSinceReferenceDate * 2.4))
                )
            }
        case .idle, .streaming:
            if isAnimated {
                TimelineView(.animation(minimumInterval: 1 / 20, paused: !appearsActive)) { timeline in
                    shape(.streaming, levels: Self.levels(at: timeline.date.timeIntervalSinceReferenceDate))
                }
            } else {
                shape(.idle)
            }
        default:
            shape(glyph)
        }
    }

    private func shape(_ variant: BridgeGlyph.Variant, levels: BridgeGlyph.Levels = .rest) -> some View {
        BridgeGlyphShape(path: BridgeGlyph.marks(variant, levels: levels))
            .fill(style: FillStyle(eoFill: true))
    }

    /// Les suspentes du pont, comme dans la pastille du panneau (`PanelStatusChip`) : deux sinusoïdes de
    /// périodes sans commune mesure, assez lentes pour passer pour une respiration.
    static func levels(at time: TimeInterval) -> BridgeGlyph.Levels {
        BridgeGlyph.Levels(sides: 0.72 + 0.28 * sin(time * 2.1), center: 0.5 + 0.5 * sin(time * 3.3 + 1))
    }

    // MARK: - Dessin

    private static let veilShade = BridgeTheme.color(0x15141A)
    /// La part des reflets qui reste quand la session tient sans son audible.
    static let veiledShare = 0.5

    /// Dessine la bille : sa lueur, son ombre, puis le verre. Hors de la vue, pour qu'un rendu d'essai
    /// choisisse l'instant.
    static func draw(
        in context: inout GraphicsContext, center: CGPoint, radius restRadius: CGFloat, look: Look,
        isAudible: Bool, time: TimeInterval
    ) {
        let isAlive = look == .live && isAudible
        let breath = isAlive ? HaloSphereMotion.breath(at: time) : 0
        let radius = restRadius * (isAlive ? HaloSphereMotion.scale(at: time) : 1)

        if isAlive {
            // La lueur, derrière : elle enfle et s'éclaire avec la respiration. Elle part du bord de la
            // bille (à la moitié de son rayon à elle) et meurt vite : une lueur, pas un disque.
            let glow = restRadius * 1.9 * (0.96 + 0.12 * breath)
            let strength = 0.65 + 0.35 * breath
            context.fill(
                Path(ellipseIn: square(center, glow)),
                with: .radialGradient(
                    Gradient(stops: [
                        .init(color: BridgeTheme.rose.opacity(0.82 * strength), location: 0),
                        .init(color: BridgeTheme.rose.opacity(0.82 * strength), location: 0.5),
                        .init(color: BridgeTheme.rose.opacity(0.6 * strength), location: 0.54),
                        .init(color: BridgeTheme.rose.opacity(0.4 * strength), location: 0.585),
                        .init(color: BridgeTheme.rose.opacity(0.25 * strength), location: 0.64),
                        .init(color: BridgeTheme.rose.opacity(0.14 * strength), location: 0.71),
                        .init(color: BridgeTheme.violet.opacity(0.06 * strength), location: 0.84),
                        .init(color: BridgeTheme.violet.opacity(0), location: 1),
                    ]),
                    center: center, startRadius: 0, endRadius: glow
                )
            )
        }

        // L'ombre portée : sous la sphère, pas autour. Elle ne doit pas éteindre la lueur.
        let shadowCenter = CGPoint(x: center.x, y: center.y + restRadius * 0.3)
        let shadowRadius = restRadius * 1.24
        context.fill(
            Path(ellipseIn: square(shadowCenter, shadowRadius)),
            with: .radialGradient(
                Gradient(stops: [
                    .init(color: .black.opacity(0.42), location: 0),
                    .init(color: .black.opacity(0.36), location: 0.55),
                    .init(color: .black.opacity(0.2), location: 0.74),
                    .init(color: .black.opacity(0.07), location: 0.9),
                    .init(color: .black.opacity(0), location: 1),
                ]),
                center: shadowCenter, startRadius: 0, endRadius: shadowRadius
            )
        )

        let disc = Path(ellipseIn: square(center, radius))
        let box = Path(square(center, radius + 1))
        context.drawLayer { layer in
            layer.clip(to: disc)
            switch look {
            case .resting:
                layer.draw(image(NovaGlassTextures.resting), in: square(center, radius))
            case .live:
                layer.fill(box, with: .color(BridgeTheme.color(0x020207)))
                // Les reflets s'additionnent. Sans son audible, ils restent où le dessin les pose, voilés.
                var lights = layer
                lights.blendMode = .plusLighter
                lights.opacity = isAudible ? 1 : veiledShare
                let extent = radius * NovaGlassTextures.layerExtent
                for glass in NovaGlass.Layer.allCases {
                    let pose = NovaGlassMotion.pose(of: glass, at: time)
                    var sheet = lights
                    sheet.translateBy(x: center.x, y: center.y)
                    sheet.scaleBy(x: radius, y: radius)
                    sheet.concatenate(NovaGlassMotion.transform(for: pose))
                    sheet.scaleBy(x: 1 / radius, y: 1 / radius)
                    sheet.draw(
                        image(NovaGlassTextures.layers[glass.rawValue]),
                        in: CGRect(x: -extent, y: -extent, width: extent * 2, height: extent * 2)
                    )
                }
                lights.draw(image(NovaGlassTextures.rim), in: square(center, radius))

                // Le creux sombre sous le logo : aucun reflet ne doit le noyer.
                var well = layer
                well.translateBy(x: center.x, y: center.y)
                well.scaleBy(x: radius * NovaGlass.wellRadii.width, y: radius * NovaGlass.wellRadii.height)
                well.fill(
                    Path(ellipseIn: CGRect(x: -1, y: -1, width: 2, height: 2)),
                    with: .radialGradient(wellGradient, center: .zero, startRadius: 0, endRadius: 1)
                )
                if !isAudible {
                    // La session tient, aucun son ne part : le verre se voile.
                    layer.fill(box, with: .color(veilShade.opacity(0.42)))
                }
            }
        }
    }

    /// Le creux sous le logo, échantillonné sur la fonction que les tests vérifient.
    private static let wellGradient = Gradient(
        stops: (0...10).map { step in
            let share = Double(step) / 10
            return .init(color: .black.opacity(NovaGlass.wellAlpha(atShare: share)), location: share)
        }
    )

    private static func image(_ texture: CGImage) -> Image {
        Image(decorative: texture, scale: 1).interpolation(.medium)
    }

    private static func square(_ center: CGPoint, _ radius: CGFloat) -> CGRect {
        CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
    }
}

/// Le halo est la commande Diffuser / Arrêter : il cède sous le doigt, et s'efface quand il ne répond pas.
struct HaloSphereButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(isEnabled ? 1 : 0.72)
            .contentShape(Circle())
            .contentShape(.focusEffect, Circle())
            .animation(PanelMotion.quick(reduceMotion: reduceMotion), value: configuration.isPressed)
    }
}
