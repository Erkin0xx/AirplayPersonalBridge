//
//  HaloWaves.swift
//  AirplayPersonalBridge
//

import SwiftUI

/// La géométrie des ondes du halo, hors de la vue pour être testée.
///
/// Baptiste les a demandées « larges, organiques, pas juste un rond » : quatre bandes fermées qui
/// quittent la sphère, s'élargissent et s'éteignent, chacune avec un contour qui ondule lentement. Le
/// contour est un cercle déformé par trois harmoniques entières (2, 3 et 5 lobes) dont les phases
/// tournent à des vitesses sans commune mesure : la forme ne se répète jamais à l'œil, et reste fermée
/// quoi qu'il arrive, un nombre entier de lobes revenant à son point de départ après un tour.
///
/// Elles ne mesurent rien : c'est une respiration, pas un vumètre. D'où la règle de la vue : aucune onde
/// quand aucun son ne part.
nonisolated enum HaloWaveGeometry {
    static let bandCount = 4
    /// Le temps que met une bande à quitter la sphère et à disparaître.
    static let period: TimeInterval = 8
    /// D'où part une bande et jusqu'où elle va, en rayons de sphère.
    static let birthRadius = 1.05
    static let reachRadius = 3.6
    /// La part de la course passée à apparaître. Une bande qui naîtrait d'un coup clignoterait.
    static let fadeInShare = 0.14
    static let peakOpacity = 0.8
    /// L'épaisseur de chaque bande au bout de sa course, pour une sphère de `referenceSphereRadius` :
    /// larges, comme Baptiste les a demandées. C'est la largeur à mi-hauteur du trait, dont les bords
    /// s'estompent bien au-delà (`HaloWaves`).
    static let endWidths: [Double] = [40, 30, 46, 20]
    static let referenceSphereRadius = 140.0
    /// À sa naissance, une bande fait cette part de son épaisseur finale.
    static let birthWidthShare = 0.45
    /// Près de la sphère la bande l'épouse encore ; elle prend sa liberté en s'éloignant.
    static let birthWobbleShare = 0.4

    /// Une harmonique du contour : son nombre de lobes, sa part du rayon, la vitesse de sa phase en
    /// radians par seconde (le signe donne le sens), et de combien elle se décale d'une bande à l'autre.
    struct Harmonic: Equatable, Sendable {
        var lobes: Double
        var amplitude: Double
        var rate: Double
        var bandOffset: Double
    }

    static let harmonics: [Harmonic] = [
        Harmonic(lobes: 2, amplitude: 0.065, rate: 0.21, bandOffset: 1.9),
        Harmonic(lobes: 3, amplitude: 0.050, rate: -0.33, bandOffset: 2.7),
        Harmonic(lobes: 5, amplitude: 0.025, rate: 0.47, bandOffset: 0.8),
    ]

    /// L'écart le plus grand entre le contour et son cercle, en part du rayon.
    static var maxWobble: Double {
        harmonics.reduce(0) { $0 + $1.amplitude }
    }

    struct Band: Equatable, Sendable {
        var index: Int
        /// De 0, à la naissance, à 1, à la disparition : linéaire dans le temps.
        var progress: Double
        /// La distance parcourue, de 0 à 1 : la bande part vite et ralentit.
        var travel: Double
        var opacity: Double
        /// Le rayon de son cercle moyen, en rayons de sphère.
        var radius: Double
        /// L'épaisseur du trait, en points, pour une sphère de `referenceSphereRadius`.
        var lineWidth: Double
    }

    /// Les bandes à cet instant, régulièrement échelonnées. Transparente à sa naissance comme à sa
    /// disparition, une bande renaît sans que rien ne saute : la boucle n'a pas de couture.
    static func bands(at time: TimeInterval) -> [Band] {
        var bands: [Band] = []
        var index = 0
        while index < bandCount {
            let phase = time / period + Double(index) / Double(bandCount)
            bands.append(band(index: index, progress: phase - phase.rounded(.down)))
            index += 1
        }
        return bands
    }

    static func band(index: Int, progress: Double) -> Band {
        let progress = min(max(progress, 0), 1)
        let travel = 1 - pow(1 - progress, 1.7)
        let fadeIn = min(progress / fadeInShare, 1)
        let fadeOut = pow(1 - progress, 1.5)
        let endWidth = endWidths[index % endWidths.count]
        return Band(
            index: index, progress: progress, travel: travel,
            opacity: peakOpacity * fadeIn * fadeOut,
            radius: birthRadius + (reachRadius - birthRadius) * travel,
            lineWidth: endWidth * (birthWidthShare + (1 - birthWidthShare) * travel)
        )
    }

    /// Le rayon du contour d'une bande dans cette direction, en rayons de sphère.
    static func radius(of band: Band, angle: Double, time: TimeInterval) -> Double {
        let freedom = birthWobbleShare + (1 - birthWobbleShare) * band.travel
        var wobble = 0.0
        for harmonic in harmonics {
            let phase = time * harmonic.rate + Double(band.index) * harmonic.bandOffset
            wobble += harmonic.amplitude * sin(harmonic.lobes * angle + phase)
        }
        return band.radius * (1 + freedom * wobble)
    }

    /// Le contour d'une bande, en points de la vue : `samples` points répartis sur un tour, sans
    /// répéter le premier. C'est le tracé qui le referme.
    static func outline(
        of band: Band, time: TimeInterval, center: CGPoint, sphereRadius: Double, samples: Int = 72
    ) -> [CGPoint] {
        var points: [CGPoint] = []
        points.reserveCapacity(samples)
        var sample = 0
        while sample < samples {
            let angle = 2 * Double.pi * Double(sample) / Double(samples)
            let radius = radius(of: band, angle: angle, time: time) * sphereRadius
            points.append(CGPoint(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle)))
            sample += 1
        }
        return points
    }

    /// Une courbe fermée et lisse par ces points : chaque point sert de contrôle entre les milieux de
    /// ses deux segments, ce qui raccorde les arcs sans angle.
    static func closedPath(through points: [CGPoint]) -> Path {
        var path = Path()
        guard points.count >= 3, let last = points.last, let first = points.first else { return path }
        path.move(to: midpoint(last, first))
        var index = 0
        while index < points.count {
            let point = points[index]
            let next = points[(index + 1) % points.count]
            path.addQuadCurve(to: midpoint(point, next), control: point)
            index += 1
        }
        path.closeSubpath()
        return path
    }

    private static func midpoint(_ a: CGPoint, _ b: CGPoint) -> CGPoint {
        CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
    }
}

/// Les ondes qui partent du halo tant qu'un son part vraiment.
///
/// Un seul `Canvas` pour les quatre bandes, à part de la sphère : quelques tracés par image. La douceur
/// vient de traits superposés, jamais d'un filtre de flou : il ne se rend pas hors écran, et coûterait
/// bien plus à chaque image.
struct HaloWaves: View {
    /// Le centre de la sphère, en points de cette vue.
    let center: CGPoint
    let sphereRadius: Double
    /// Un son part vers au moins une enceinte.
    let isAudible: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Fenêtre à l'arrière-plan : les ondes s'arrêtent, personne ne les regarde.
    @Environment(\.appearsActive) private var appearsActive

    /// L'image posée quand le mouvement est réduit : les quatre bandes bien réparties.
    static let stillTime: TimeInterval = HaloWaveGeometry.period * 0.11

    /// Le profil d'une bande : des traits de même opacité, du plus fin au plus large, qui s'empilent.
    /// Le cœur en reçoit six, le bord un seul : l'opacité descend en pente douce vers l'extérieur, sans
    /// trait net au milieu. Les parts sont celles de l'épaisseur de la bande, qui se lit à mi-pente.
    private static let layerWidths: [Double] = [0.35, 0.68, 1.01, 1.34, 1.67, 2.0]
    private static let layerOpacity = 0.145
    private static let tints: [Color] = [
        BridgeTheme.color(0xFF6EAA), BridgeTheme.color(0x9678FF), BridgeTheme.color(0xFFAA5A), .white,
    ]

    var body: some View {
        Group {
            if !isAudible {
                Color.clear
            } else if reduceMotion {
                Canvas { context, _ in draw(at: Self.stillTime, in: &context) }
            } else {
                TimelineView(.animation(minimumInterval: 1 / 30, paused: !appearsActive)) { timeline in
                    Canvas { context, _ in
                        draw(at: timeline.date.timeIntervalSinceReferenceDate, in: &context)
                    }
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func draw(at time: TimeInterval, in context: inout GraphicsContext) {
        // Les teintes s'additionnent comme de la lumière, là où deux bandes se croisent.
        context.blendMode = .screen
        let scale = sphereRadius / HaloWaveGeometry.referenceSphereRadius
        for band in HaloWaveGeometry.bands(at: time) where band.opacity > 0.002 {
            let path = HaloWaveGeometry.closedPath(
                through: HaloWaveGeometry.outline(
                    of: band, time: time, center: center, sphereRadius: sphereRadius
                )
            )
            let tint = Self.tints[band.index % Self.tints.count]
            let shading = GraphicsContext.Shading.color(tint.opacity(band.opacity * Self.layerOpacity))
            for share in Self.layerWidths {
                context.stroke(
                    path, with: shading,
                    style: StrokeStyle(lineWidth: band.lineWidth * scale * share, lineJoin: .round)
                )
            }
        }
    }
}
