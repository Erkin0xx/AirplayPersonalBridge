//
//  BridgeTheme.swift
//  AirplayPersonalBridge
//

import AppKit
import SwiftUI

/// Le thème de l'app, commun à ses trois vues et au panneau : sombre, rose, sur un fond de nappes de
/// couleur. Il vient de la maquette « Halo » retenue par Baptiste le 2026-11-10, et de l'icône rose.
///
/// L'accent est une couleur de l'app, pas celle du système : `Color.accentColor` suivrait le choix fait
/// dans Réglages Système, et l'app perdrait sa teinte chez qui a choisi le graphite.
enum BridgeTheme {
    /// Le rose de l'icône, un ton plus profond : du texte blanc doit rester lisible dessus.
    static let accent = color(0xDF3880)
    /// Les quatre teintes des nappes du fond, et des ondes du halo.
    static let rose = color(0xFF4F93)
    static let violet = color(0x7C5CFF)
    static let blue = color(0x3D8BFF)
    static let orange = color(0xFF9A3C)
    /// Le noir du fond, à peine violet.
    static let ground = color(0x09080D)

    static func color(_ hex: UInt32) -> Color {
        Color(
            .sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}

/// Le fond des vues « Halo » et « Console » : quatre nappes de couleur qui dérivent lentement sur un noir
/// à peine violet, sous un grain fin.
///
/// **Tout le fond tient dans cette vue** : Baptiste doit fournir un dégradé de référence, et le remplacer
/// ne doit toucher qu'ici. Vivant, les nappes sont pleines et bougent ; au repos elles s'éteignent presque,
/// immobiles — la couleur et le mouvement veulent dire « ça joue ». Des dégradés radiaux et non du flou :
/// un filtre de flou ne se rend pas hors écran, et coûterait bien plus à chaque image.
struct AuroraBackground: View {
    /// Un son passe : le fond vit.
    var isLive: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Fenêtre à l'arrière-plan : le fond s'arrête, personne ne le regarde.
    @Environment(\.appearsActive) private var appearsActive

    var body: some View {
        ZStack {
            BridgeTheme.ground
            if isLive && !reduceMotion {
                TimelineView(.animation(minimumInterval: 1 / 20, paused: !appearsActive)) { timeline in
                    Canvas { context, size in
                        Self.draw(
                            in: &context, size: size, time: timeline.date.timeIntervalSinceReferenceDate,
                            strength: 1
                        )
                    }
                }
            } else {
                Canvas { context, size in
                    Self.draw(in: &context, size: size, time: 0, strength: isLive ? 1 : Self.restStrength)
                }
            }
            Image(decorative: Self.grain, scale: 2)
                .resizable(resizingMode: .tile)
                .blendMode(.overlay)
                .opacity(0.16)
                .allowsHitTesting(false)
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }

    // MARK: - Nappes

    struct Field {
        var color: Color
        /// Le centre au repos et le rayon, en fractions de la vue (le rayon, de son plus grand côté).
        var center: UnitPoint
        var radius: Double
        var opacity: Double
        /// La période de la dérive, en secondes, et son déphasage.
        var period: Double
        var phase: Double
    }

    static let fields: [Field] = [
        Field(color: BridgeTheme.rose, center: UnitPoint(x: 0.16, y: 0.14), radius: 0.46, opacity: 0.50, period: 52, phase: 0),
        Field(color: BridgeTheme.violet, center: UnitPoint(x: 0.82, y: 0.20), radius: 0.44, opacity: 0.46, period: 62, phase: 1.7),
        Field(color: BridgeTheme.blue, center: UnitPoint(x: 0.30, y: 0.90), radius: 0.42, opacity: 0.34, period: 58, phase: 3.1),
        Field(color: BridgeTheme.orange, center: UnitPoint(x: 0.84, y: 0.84), radius: 0.40, opacity: 0.38, period: 46, phase: 4.4),
    ]

    /// Au repos, les nappes ne gardent qu'une trace de leur couleur.
    static let restStrength = 0.3
    /// Jusqu'où une nappe s'écarte de sa place, en fraction de la vue.
    static let driftAmplitude = 0.07

    /// Le centre d'une nappe à cet instant : une ellipse lente autour de sa place, jamais plus loin que
    /// `driftAmplitude`.
    static func center(of field: Field, at time: TimeInterval, in size: CGSize) -> CGPoint {
        let angle = 2 * Double.pi * time / field.period + field.phase
        return CGPoint(
            x: (field.center.x + driftAmplitude * cos(angle)) * size.width,
            y: (field.center.y + driftAmplitude * sin(angle * 0.8)) * size.height
        )
    }

    private static func draw(in context: inout GraphicsContext, size: CGSize, time: TimeInterval, strength: Double) {
        let side = max(size.width, size.height)
        for field in fields {
            let center = center(of: field, at: time, in: size)
            let radius = field.radius * side
            context.fill(
                Path(CGRect(origin: .zero, size: size)),
                with: .radialGradient(
                    Gradient(colors: [field.color.opacity(field.opacity * strength), field.color.opacity(0)]),
                    center: center, startRadius: 0, endRadius: radius
                )
            )
        }
    }

    // MARK: - Grain

    /// Un carreau de bruit gris, tiré une fois, toujours le même : le grain ne scintille pas, et un rendu
    /// d'essai se répète au pixel près.
    static let grain: CGImage = makeGrain(side: 256)

    private static func makeGrain(side: Int) -> CGImage {
        var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
        var pixels = [UInt8](repeating: 0, count: side * side)
        var index = 0
        while index < pixels.count {
            // Un générateur congruentiel suffit : il faut du désordre, pas du hasard.
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            pixels[index] = UInt8(truncatingIfNeeded: seed >> 56)
            index += 1
        }
        let provider = CGDataProvider(data: Data(pixels) as CFData)
        let image = provider.flatMap {
            CGImage(
                width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: side,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                provider: $0, decode: nil, shouldInterpolate: false, intent: .defaultIntent
            )
        }
        guard let image else { fatalError("Le carreau de grain se construit toujours : dimensions constantes") }
        return image
    }
}
