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
    static let period: TimeInterval = 12
    /// D'où part une bande et jusqu'où elle va, en rayons de sphère.
    static let birthRadius = 1.05
    static let reachRadius = 3.6
    /// La part de la course passée à apparaître. Une bande qui naîtrait d'un coup clignoterait.
    static let fadeInShare = 0.2
    /// La densité d'une bande à son plus fort, sur son contour : un voile, pas un trait. Les premières
    /// ondes, à 0,8, se lisaient comme des anneaux dessinés.
    static let peakOpacity = 0.22
    /// La largeur à mi-hauteur de chaque bande au bout de sa course, pour une sphère de
    /// `referenceSphereRadius` : très larges, elles se fondent l'une dans l'autre (`HaloWaveField`).
    static let endWidths: [Double] = [150, 120, 170, 105]
    static let referenceSphereRadius = 140.0
    /// À sa naissance, une bande fait cette part de sa largeur finale.
    static let birthWidthShare = 0.4
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
        Harmonic(lobes: 2, amplitude: 0.080, rate: 0.17, bandOffset: 1.9),
        Harmonic(lobes: 3, amplitude: 0.060, rate: -0.26, bandOffset: 2.7),
        Harmonic(lobes: 5, amplitude: 0.025, rate: 0.37, bandOffset: 0.8),
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
        /// Sa largeur à mi-hauteur, en points, pour une sphère de `referenceSphereRadius`.
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
        // Une montée en S : l'apparition n'a pas de coin, ni à son début ni à son sommet.
        let rise = min(progress / fadeInShare, 1)
        let fadeIn = rise * rise * (3 - 2 * rise)
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
}

/// Les ondes en lumière, calculées par pixel comme le fond (`GrainientField`) : une petite image, étirée
/// ensuite à la taille de la vue.
///
/// Baptiste a trouvé les premières « trop nettes et trop présentes » : des traits empilés, dont on voyait
/// les paliers. Ici chaque bande est une cloche de lumière sans bord, large, posée sur son contour qui
/// ondule ; l'image fait `pixelWidth` pixels de large et l'étirement la floute encore, comme le fond. Aucun
/// trait, aucun filtre de flou. Chaque pixel est un voile teinté (alpha prémultiplié), qui éclaire le fond
/// au lieu de le recouvrir : son grain reste visible à travers.
nonisolated enum HaloWaveField {
    /// La largeur de l'image calculée. Sa hauteur suit les proportions de la vue.
    static let pixelWidth = 160
    static let heightRange = 40...240
    /// Le nombre de directions où le contour d'une bande est calculé à chaque image.
    static let angleSteps = 512
    /// La portée de la cloche de chaque côté du contour, en largeurs à mi-hauteur de la bande.
    static let reachPerWidth = 1.1
    /// Le voile le plus dense qu'un pixel puisse porter, là où des bandes se superposent : les ondes se
    /// devinent, elles ne se lisent pas comme des anneaux dessinés.
    static let maxAlpha = 0.28

    /// Une teinte de lumière, composantes sRGB de 0 à 1.
    struct Tint: Equatable, Sendable {
        var red: Double
        var green: Double
        var blue: Double

        init(hex: UInt32) {
            red = Double((hex >> 16) & 0xFF) / 255
            green = Double((hex >> 8) & 0xFF) / 255
            blue = Double(hex & 0xFF) / 255
        }
    }

    /// Une teinte par bande, tirée de la rampe et de la nappe du fond (`GrainientField.ramp`, `.pool`),
    /// éclaircie : rose, violet, orange, bleu profond.
    static let tints: [Tint] = [
        Tint(hex: 0xF0559A), Tint(hex: 0x9A58E0), Tint(hex: 0xFF8566), Tint(hex: 0x4A72E8),
    ]

    /// La cloche d'une bande : 1 sur le contour, 0 à une portée et au-delà, sans bord ni cassure (la pente
    /// et la courbure s'annulent aux deux bouts). `offset` est l'écart au contour, en portées.
    static func profile(_ offset: Double) -> Double {
        let inside = 1 - offset * offset
        guard inside > 0 else { return 0 }
        return inside * inside * inside
    }

    /// La portée d'une bande, en rayons de sphère.
    static func reach(of band: HaloWaveGeometry.Band) -> Double {
        band.lineWidth / HaloWaveGeometry.referenceSphereRadius * reachPerWidth
    }

    /// La taille de l'image pour une vue de cette taille : la hauteur suit ses proportions, bornée.
    static func gridSize(for viewSize: CGSize) -> (width: Int, height: Int) {
        guard viewSize.width > 0, viewSize.height > 0 else { return (pixelWidth, 100) }
        let height = (Double(pixelWidth) * viewSize.height / viewSize.width).rounded()
        return (pixelWidth, Int(min(max(height, Double(heightRange.lowerBound)), Double(heightRange.upperBound))))
    }

    /// Le désordre posé avant d'arrondir un pixel à ses 8 bits, de −0,5 à 0,5 : fixe par pixel, il ne
    /// scintille pas, et empêche les arrondis de dessiner des courbes de niveau.
    static func dither(_ index: Int) -> Double {
        var hash = UInt64(truncatingIfNeeded: index) &* 0x9E37_79B9_7F4A_7C15
        hash ^= hash >> 29
        hash = hash &* 0xBF58_476D_1CE4_E5B9
        hash ^= hash >> 32
        return Double(hash >> 40) / Double(1 << 24) - 0.5
    }

    /// Ce qui ne dépend que de la vue : la distance à la sphère et la direction de chaque pixel. Calculé
    /// une fois par taille de fenêtre, pas à chaque image.
    struct Grid: Sendable {
        let width: Int
        let height: Int
        /// La distance de chaque pixel au centre de la sphère, en rayons de sphère.
        private let distances: [Float]
        /// La direction de chaque pixel, en rang dans la table du contour.
        private let directions: [UInt16]

        init(viewSize: CGSize, center: CGPoint, sphereRadius: Double) {
            let size = HaloWaveField.gridSize(for: viewSize)
            width = size.width
            height = size.height
            var distances = [Float](repeating: 0, count: width * height)
            var directions = [UInt16](repeating: 0, count: width * height)
            let radius = max(sphereRadius, 1)
            let steps = Double(HaloWaveField.angleSteps)
            var row = 0
            while row < height {
                // Le centre de chaque pixel : l'image étirée garde ses bords à leur place.
                let y = (Double(row) + 0.5) / Double(height) * viewSize.height - center.y
                var column = 0
                while column < width {
                    let x = (Double(column) + 0.5) / Double(width) * viewSize.width - center.x
                    let index = row * width + column
                    distances[index] = Float(hypot(x, y) / radius)
                    var turn = atan2(y, x) / (2 * Double.pi)
                    if turn < 0 { turn += 1 }
                    directions[index] = UInt16(Int(turn * steps) % HaloWaveField.angleSteps)
                    column += 1
                }
                row += 1
            }
            self.distances = distances
            self.directions = directions
        }

        /// Le voile de chaque pixel à cet instant, avant arrondi (rouge, vert, bleu) : la somme des teintes
        /// des bandes, chacune pesée par sa cloche et son opacité.
        func light(at time: TimeInterval) -> [Float] {
            var light = [Float](repeating: 0, count: width * height * 3)
            var contour = [Float](repeating: 0, count: HaloWaveField.angleSteps)
            for band in HaloWaveGeometry.bands(at: time) where band.opacity > 0.002 {
                var step = 0
                while step < HaloWaveField.angleSteps {
                    let angle = 2 * Double.pi * (Double(step) + 0.5) / Double(HaloWaveField.angleSteps)
                    contour[step] = Float(HaloWaveGeometry.radius(of: band, angle: angle, time: time))
                    step += 1
                }
                let reach = Float(HaloWaveField.reach(of: band))
                let tint = HaloWaveField.tints[band.index % HaloWaveField.tints.count]
                let red = Float(tint.red * band.opacity)
                let green = Float(tint.green * band.opacity)
                let blue = Float(tint.blue * band.opacity)
                var index = 0
                while index < distances.count {
                    let offset = (distances[index] - contour[Int(directions[index])]) / reach
                    let inside = 1 - offset * offset
                    if inside > 0 {
                        let weight = inside * inside * inside
                        light[index * 3] += weight * red
                        light[index * 3 + 1] += weight * green
                        light[index * 3 + 2] += weight * blue
                    }
                    index += 1
                }
            }
            return light
        }

        /// Les octets RGBA prémultipliés (sRGB, ligne du haut d'abord) des ondes à cet instant. La densité
        /// d'un pixel est la plus forte de ses trois composantes : le voile le plus léger qui porte cette
        /// lumière.
        func pixels(at time: TimeInterval) -> [UInt8] {
            let light = light(at: time)
            var bytes = [UInt8](repeating: 0, count: width * height * 4)
            let ceiling = Float(HaloWaveField.maxAlpha)
            var index = 0
            while index < width * height {
                let red = light[index * 3]
                let green = light[index * 3 + 1]
                let blue = light[index * 3 + 2]
                let density = max(red, max(green, blue))
                if density > 0 {
                    // Plafonné en gardant la teinte, puis arrondi avec son désordre.
                    let alpha = Double(min(density, ceiling))
                    let level = Float((alpha * 255 + 0.5 + HaloWaveField.dither(index)).rounded(.down))
                    if level >= 1 {
                        let scale = level / density
                        // Jamais plus que l'alpha : un pixel prémultiplié reste valide.
                        bytes[index * 4] = UInt8(min((red * scale).rounded(), level))
                        bytes[index * 4 + 1] = UInt8(min((green * scale).rounded(), level))
                        bytes[index * 4 + 2] = UInt8(min((blue * scale).rounded(), level))
                        bytes[index * 4 + 3] = UInt8(level)
                    }
                }
                index += 1
            }
            return bytes
        }

        /// Les ondes à cet instant, en petite image à étirer.
        func image(at time: TimeInterval) -> CGImage? {
            let bytes = pixels(at: time)
            guard
                let provider = CGDataProvider(data: Data(bytes) as CFData),
                let space = CGColorSpace(name: CGColorSpace.sRGB)
            else { return nil }
            return CGImage(
                width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
            )
        }
    }
}

/// La grille de la vue, gardée d'une image à l'autre : elle ne se recalcule que si la fenêtre ou la
/// sphère changent de taille.
final class HaloWaveGrids {
    private struct Key: Equatable {
        var viewSize: CGSize
        var center: CGPoint
        var sphereRadius: Double
    }

    private var key: Key?
    private var grid: HaloWaveField.Grid?

    func grid(viewSize: CGSize, center: CGPoint, sphereRadius: Double) -> HaloWaveField.Grid {
        let wanted = Key(viewSize: viewSize, center: center, sphereRadius: sphereRadius)
        if let grid, key == wanted { return grid }
        let fresh = HaloWaveField.Grid(viewSize: viewSize, center: center, sphereRadius: sphereRadius)
        key = wanted
        grid = fresh
        return fresh
    }
}

/// Les ondes qui partent du halo tant qu'un son part vraiment.
///
/// Une petite image recalculée vingt fois par seconde et étirée sur toute la vue (`HaloWaveField`) : c'est
/// l'étirement qui les floute, comme le fond, sans filtre de flou — il ne se rend pas hors écran, et
/// coûterait bien plus à chaque image. Vingt images par seconde suffisent à un mouvement aussi lent et
/// aussi flou ; l'ancien dessin en traçait trente.
struct HaloWaves: View {
    /// Le centre de la sphère, en points de cette vue.
    let center: CGPoint
    let sphereRadius: Double
    /// Un son part vers au moins une enceinte.
    let isAudible: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Fenêtre à l'arrière-plan : les ondes s'arrêtent, personne ne les regarde.
    @Environment(\.appearsActive) private var appearsActive
    @State private var grids = HaloWaveGrids()

    /// L'image posée quand le mouvement est réduit : les quatre bandes bien réparties.
    static let stillTime: TimeInterval = HaloWaveGeometry.period * 0.11
    /// L'intervalle entre deux images : vingt par seconde.
    static let frameInterval: TimeInterval = 1.0 / 20

    var body: some View {
        Group {
            if !isAudible {
                Color.clear
            } else {
                GeometryReader { proxy in
                    if reduceMotion {
                        frame(at: Self.stillTime, size: proxy.size)
                    } else {
                        TimelineView(.animation(minimumInterval: Self.frameInterval, paused: !appearsActive)) {
                            timeline in
                            frame(at: timeline.date.timeIntervalSinceReferenceDate, size: proxy.size)
                        }
                    }
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func frame(at time: TimeInterval, size: CGSize) -> some View {
        if size.width > 0, size.height > 0 {
            let grid = grids.grid(viewSize: size, center: center, sphereRadius: sphereRadius)
            if let image = grid.image(at: time) {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.high)
            }
        }
    }
}
