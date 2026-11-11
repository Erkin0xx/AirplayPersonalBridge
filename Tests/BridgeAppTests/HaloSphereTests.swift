import CoreGraphics
import Foundation
import Testing

@testable import BridgeApp

@Suite("Centre du halo — verre noir, triangle, logo vivant")
struct HaloSphereTests {
    // MARK: - Logo

    @Test("Les cinq barres libres, au repos, sont exactement le glyphe de toujours")
    func restingBarsAreTheGlyph() {
        // Élément par élément, au milliardième : `marks(.idle)`, assemblé par `addPath`, et le même tracé
        // construit barre par barre diffèrent au dernier bit de quelques flottants, et `==` les dit différents.
        let rest = Self.elements(of: BridgeGlyph.marks(bars: .rest))
        #expect(rest.count == 50)
        #expect(Self.match(rest, Self.elements(of: BridgeGlyph.marks(.idle))))
        #expect(Self.match(rest, Self.elements(of: BridgeGlyph.marks(.streaming))))
        #expect(!Self.match(rest, Self.elements(of: BridgeGlyph.marks(.connecting))))
        #expect(BridgeGlyph.Bars.rest == BridgeGlyph.Bars(leftPylon: 14, left: 6, center: 2, right: 6, rightPylon: 14))
        // Une barre plus haute change le tracé, sans sortir du cadre : elle reste centrée sur la médiane.
        var raised = BridgeGlyph.Bars.rest
        raised.left = 11
        let box = BridgeGlyph.marks(bars: raised).boundingBoxOfPath
        #expect(!Self.match(Self.elements(of: BridgeGlyph.marks(bars: raised)), rest))
        #expect(abs(box.midY - BridgeGlyph.canvas.height / 2) < 1e-9)
        #expect(box.minY >= 0 && box.maxY <= BridgeGlyph.canvas.height)
    }

    /// Les éléments d'un tracé, dans l'ordre : son genre, puis ses points.
    private static func elements(of path: CGPath) -> [[CGFloat]] {
        var elements: [[CGFloat]] = []
        path.applyWithBlock { element in
            let count: Int
            switch element.pointee.type {
            case .moveToPoint, .addLineToPoint: count = 1
            case .addQuadCurveToPoint: count = 2
            case .addCurveToPoint: count = 3
            default: count = 0
            }
            var values = [CGFloat(element.pointee.type.rawValue)]
            var index = 0
            while index < count {
                values.append(element.pointee.points[index].x)
                values.append(element.pointee.points[index].y)
                index += 1
            }
            elements.append(values)
        }
        return elements
    }

    private static func match(_ one: [[CGFloat]], _ other: [[CGFloat]]) -> Bool {
        guard one.count == other.count else { return false }
        return zip(one, other).allSatisfy { first, second in
            first.count == second.count && zip(first, second).allSatisfy { abs($0 - $1) < 1e-9 }
        }
    }

    /// Les barres sur deux minutes, à la cadence du dessin.
    private static func samples() -> [BridgeGlyph.Bars] {
        var samples: [BridgeGlyph.Bars] = []
        var time = 0.0
        while time < 120 {
            samples.append(HaloLogoMotion.bars(at: time))
            time += HaloSphere.frameInterval
        }
        return samples
    }

    @Test("Le logo garde le profil du pont à tout instant : point, suspentes, pylônes, dans cet ordre")
    func logoKeepsTheBridgeProfile() {
        for bars in Self.samples() {
            #expect(bars.center < min(bars.left, bars.right))
            #expect(max(bars.left, bars.right) < min(bars.leftPylon, bars.rightPylon))
            for pylon in [bars.leftPylon, bars.rightPylon] {
                #expect(HaloLogoMotion.pylonRange.contains(Double(pylon)))
            }
            for side in [bars.left, bars.right] {
                #expect(HaloLogoMotion.sideRange.contains(Double(side)))
            }
            #expect(HaloLogoMotion.centerRange.contains(Double(bars.center)))
            // Rien ne sort du cadre du glyphe.
            #expect(max(bars.leftPylon, bars.rightPylon) <= BridgeGlyph.canvas.height)
        }
        // Les courses ne se recouvrent pas : l'ordre tient par construction, pas par chance.
        #expect(HaloLogoMotion.centerRange.upperBound < HaloLogoMotion.sideRange.lowerBound)
        #expect(HaloLogoMotion.sideRange.upperBound < HaloLogoMotion.pylonRange.lowerBound)
        // Et le repos du glyphe est dans chaque course : le logo figé n'est pas une autre forme.
        #expect(HaloLogoMotion.pylonRange.contains(14))
        #expect(HaloLogoMotion.sideRange.contains(6))
        #expect(HaloLogoMotion.centerRange.contains(2))
    }

    @Test("Le mouvement des barres se voit, même sur le plus petit disque")
    func logoMovementIsVisible() {
        let samples = Self.samples()
        func span(_ height: (BridgeGlyph.Bars) -> CGFloat) -> CGFloat {
            let heights = samples.map(height)
            return (heights.max() ?? 0) - (heights.min() ?? 0)
        }
        // Un point du cadre du glyphe, sur le plus petit disque.
        let unit = HaloMetrics.sphereRange.lowerBound * HaloSphere.glyphShare.width / BridgeGlyph.canvas.width
        // Les suspentes parcourent plus d'une fois et demie leur hauteur de repos : un égaliseur.
        #expect(span(\.left) * unit > 14)
        #expect(span(\.right) * unit > 14)
        #expect(span(\.left) > 5 && span(\.right) > 5)
        // Le point respire en hauteur, les pylônes varient légèrement.
        #expect(span(\.center) * unit > 5)
        #expect(span(\.leftPylon) * unit > 4 && span(\.rightPylon) * unit > 4)
        #expect(span(\.leftPylon) < span(\.left) / 2)
        // Déphasées : les deux suspentes ne montent pas ensemble.
        let apart = samples.map { abs($0.left - $0.right) }.max() ?? 0
        #expect(apart > 4)
    }

    @Test("Le logo ondule lentement, sans à-coup, sur des périodes sans commune mesure")
    func logoMovesSlowlyAndSmoothly() {
        let samples = Self.samples()
        var index = 1
        var largest: CGFloat = 0
        while index < samples.count {
            let before = samples[index - 1]
            let now = samples[index]
            largest = max(
                largest, abs(now.left - before.left), abs(now.right - before.right),
                abs(now.center - before.center), abs(now.leftPylon - before.leftPylon),
                abs(now.rightPylon - before.rightPylon)
            )
            index += 1
        }
        // Moins d'un demi-point du cadre par image : deux points d'écran sur le plus grand disque.
        #expect(largest < 0.5)

        let periods = HaloLogoMotion.voices.flatMap { [$0.period, $0.slowPeriod] }
        #expect(periods.allSatisfy { $0 >= 2.5 })
        // Aucune période n'est le multiple simple d'une autre : les barres ne se resynchronisent pas.
        for (index, period) in periods.enumerated() {
            for other in periods[(index + 1)...] {
                let ratio = max(period, other) / min(period, other)
                for divisor in 1...4 {
                    let scaled = ratio * Double(divisor)
                    #expect(abs(scaled - scaled.rounded()) > 0.02, "\(period) et \(other)")
                }
            }
        }
        for voice in HaloLogoMotion.voices {
            var time = 0.0
            while time < 60 {
                let swing = HaloLogoMotion.swing(voice, at: time)
                #expect(swing >= 0 && swing <= 1)
                time += 0.1
            }
        }
        #expect(HaloSphere.frameInterval >= 1.0 / 20)
    }

    // MARK: - Triangle

    @Test("Le triangle lecture est centré, arrondi, et tient dans le cadre du logo")
    func playMarkIsCentredAndRounded() {
        let diameter: CGFloat = 300
        let path = HaloPlayMark.path(diameter: diameter)
        let box = path.boundingBoxOfPath
        let radius = HaloPlayMark.cornerRadius * diameter
        // Au centième de point : les arcs sont rendus en courbes de Bézier.
        #expect(abs(box.midY) < 0.01)
        #expect(abs(box.minX - (-0.03 * diameter - radius)) < 0.01)
        #expect(abs(box.maxX - (0.0933 * diameter + radius)) < 0.01)
        #expect(abs(box.height - (0.16 * diameter + 2 * radius)) < 0.01)
        // Le centre de gravité des sommets tombe à un centième de diamètre du centre du disque.
        let centroid = HaloPlayMark.vertices.reduce(0) { $0 + $1.x } / 3
        #expect(abs(centroid) < 0.012)
        #expect(box.width < HaloSphere.glyphShare.width * diameter)
        #expect(box.height < HaloSphere.glyphShare.height * diameter)

        // Plein, d'un seul tenant : le centre et les trois sommets sont dedans.
        #expect(path.contains(.zero))
        for vertex in HaloPlayMark.vertices {
            #expect(path.contains(CGPoint(x: vertex.x * diameter, y: vertex.y * diameter)))
        }
        // La pointe est arrondie : elle déborde du sommet d'un rayon, pas davantage.
        let tip = HaloPlayMark.vertices[1].x * diameter
        #expect(path.contains(CGPoint(x: tip + radius * 0.9, y: 0)))
        #expect(!path.contains(CGPoint(x: tip + radius * 1.1, y: 0)))
        // Un coin vif irait jusqu'au coin du cadre : l'arrondi le rogne.
        #expect(!path.contains(CGPoint(x: box.minX + 0.2, y: box.minY + 0.2)))
        #expect(!path.contains(CGPoint(x: box.minX + 0.2, y: box.maxY - 0.2)))
        // Et il suit le disque : centré où on le demande.
        let moved = HaloPlayMark.path(diameter: diameter, center: CGPoint(x: 150, y: 150)).boundingBoxOfPath
        #expect(abs(moved.midY - 150) < 0.01 && abs(moved.minX - (box.minX + 150)) < 0.01)
    }

    // MARK: - Lueurs

    @Test("Les lueurs dérivent lentement et reviennent à leur place de dessin")
    func lightsDriftAndReturn() {
        for light in HaloGlass.lights {
            let rest = HaloGlass.pose(of: light, at: HaloGlass.stillTime)
            #expect(rest.center == light.center && rest.radii == light.radii)
            let later = HaloGlass.pose(of: light, at: light.period)
            #expect(abs(later.center.x - light.center.x) < 1e-9 && abs(later.center.y - light.center.y) < 1e-9)
            let far = HaloGlass.pose(of: light, at: light.period / 2)
            #expect(abs(far.center.x - (light.center.x + light.drift.dx)) < 1e-9)
            #expect(abs(far.radii.width - light.radii.width * (1 + light.swell)) < 1e-9)
            #expect(light.period >= 9)
            var time = 0.0
            while time < light.period {
                let travel = HaloGlass.travel(of: light, at: time)
                #expect(travel >= 0 && travel <= 1)
                // Lent : moins de deux centièmes de rayon par image.
                let now = HaloGlass.pose(of: light, at: time).center
                let next = HaloGlass.pose(of: light, at: time + HaloSphere.frameInterval).center
                #expect(hypot(next.x - now.x, next.y - now.y) < 0.02)
                time += 0.25
            }
        }
    }

    @Test("Une lueur est une cloche : pleine au cœur, nulle au bord, sans arête ni remontée")
    func lightsHaveNoEdge() {
        #expect(HaloGlass.falloff(0) == 1)
        #expect(HaloGlass.falloff(1) == 0 && HaloGlass.falloff(1.4) == 0)
        var previous = 1.0
        var steepest = 0.0
        var share = 0.01
        while share <= 1.0001 {
            let value = HaloGlass.falloff(share)
            #expect(value <= previous)
            steepest = max(steepest, previous - value)
            previous = value
            share += 0.01
        }
        // Aucun pas d'un centième ne fait tomber la lueur de plus de deux centièmes : pas de bord net.
        #expect(steepest < 0.02)
        // Elle arrive à zéro à plat : le dernier centième ne pèse presque rien.
        #expect(HaloGlass.falloff(0.99) < 0.001)
    }

    @Test("L'opacité entre deux arrêts suit le dégradé")
    func stopsInterpolate() {
        let stops = [HaloGlass.Stop(location: 0, alpha: 0.6), HaloGlass.Stop(location: 0.5, alpha: 0.2),
                     HaloGlass.Stop(location: 1, alpha: 0)]
        #expect(HaloGlass.alpha(in: stops, at: -1) == 0.6)
        #expect(abs(HaloGlass.alpha(in: stops, at: 0.25) - 0.4) < 1e-12)
        #expect(abs(HaloGlass.alpha(in: stops, at: 0.75) - 0.1) < 1e-12)
        #expect(HaloGlass.alpha(in: stops, at: 2) == 0)
        #expect(HaloGlass.alpha(in: [], at: 0.5) == 0)
        // Les dégradés du verre ne remontent jamais en s'éloignant de leur centre.
        for list in [HaloGlass.wellStops, HaloGlass.veilStops(isLive: true), HaloGlass.veilStops(isLive: false),
                     HaloGlass.lipStops] {
            for (before, after) in zip(list, list.dropFirst()) {
                #expect(after.location > before.location && after.alpha <= before.alpha)
            }
        }
    }

    // MARK: - Lisibilité

    /// La luminance la plus forte derrière le logo, sur tous les instants de la dérive des lueurs.
    private static func brightestBehindGlyph(isAudible: Bool = true) -> Double {
        let half = HaloGlass.glyphHalfSize
        var brightest = 0.0
        var time = 0.0
        // Les trois lueurs ont des périodes de 9, 11 et 14 s : dix minutes en croisent toutes les poses.
        while time < 600 {
            var row = -4
            while row <= 4 {
                var column = -4
                while column <= 4 {
                    let x = Double(half.width) * Double(column) / 4
                    let y = Double(half.height) * Double(row) / 4
                    let color = HaloGlass.backdrop(x: x, y: y, time: time, isAudible: isAudible)
                    brightest = max(brightest, color.luminance)
                    column += 1
                }
                row += 1
            }
            time += 0.5
        }
        return brightest
    }

    @Test("Le logo blanc garde un contraste d'au moins 4,5 pour 1 à tout instant de la diffusion")
    func glyphStaysLegible() {
        let brightest = Self.brightestBehindGlyph()
        // Blanc sur un fond de luminance L : (1 + 0,05) / (L + 0,05).
        let contrast = 1.05 / (brightest + 0.05)
        #expect(contrast >= 4.5, "contraste \(contrast), luminance \(brightest)")
        // Voilé (son coupé), le verre est plus sombre encore.
        let veiled = Self.brightestBehindGlyph(isAudible: false)
        #expect(veiled < brightest)
        #expect(HaloGlass.glyphHalfSize == CGSize(width: HaloSphere.glyphShare.width, height: HaloSphere.glyphShare.height))
    }

    @Test("La lueur rose reste dans le bas du disque, le centre reste sombre")
    func roseStaysBelowTheGlyph() {
        var time = 0.0
        while time < 60 {
            // Dans le bas : la lueur est là, rose (plus de rouge que de bleu, presque pas de vert).
            let low = HaloGlass.backdrop(x: -0.1, y: 0.72, time: time)
            #expect(low.luminance > 0.07)
            #expect(low.red > low.blue && low.blue > low.green)
            // Sous le logo : presque noir, à tout instant.
            #expect(HaloGlass.backdrop(x: 0, y: 0, time: time).luminance < 0.02)
            // En haut à droite : violet, plus de bleu que de vert, moins clair que le bas.
            let high = HaloGlass.backdrop(x: 0.5, y: -0.6, time: time)
            #expect(high.blue > high.green && high.luminance < low.luminance)
            time += 0.5
        }
        // Son coupé : la même lueur, voilée.
        let live = HaloGlass.backdrop(x: -0.1, y: 0.72, time: HaloGlass.stillTime)
        let veiled = HaloGlass.backdrop(x: -0.1, y: 0.72, time: 3, isAudible: false)
        #expect(veiled.luminance < live.luminance * 0.6)
        #expect(veiled == HaloGlass.backdrop(x: -0.1, y: 0.72, time: 40, isAudible: false))
    }

    @Test("Le creux sous le logo le couvre en entier et s'arrête avant le bord du disque")
    func wellCoversTheGlyph() {
        let half = HaloGlass.glyphHalfSize
        let corner = (Double(half.width) * Double(half.width) + Double(half.height) * Double(half.height)).squareRoot()
        #expect(HaloGlass.alpha(in: HaloGlass.wellStops, at: corner / HaloGlass.wellRadius) > 0.3)
        #expect(HaloGlass.alpha(in: HaloGlass.wellStops, at: 0) > 0.6)
        #expect(HaloGlass.alpha(in: HaloGlass.wellStops, at: 0.9 / HaloGlass.wellRadius) == 0)
        // Le voile du haut meurt avant le logo.
        let veil = HaloGlass.veilStops(isLive: true)
        #expect(HaloGlass.alpha(in: veil, at: (1 - Double(half.height)) / Double(HaloGlass.veilRadii.height)) < 0.03)
    }

    @Test("Le verre au repos est noir et sans couleur")
    func restingGlassIsBlack() {
        for y in [-1.0, 0, 1] {
            let ground = HaloGlass.ground(y: y)
            #expect(ground.luminance < 0.005)
            #expect(abs(ground.red - ground.green) < 1e-9 && ground.blue - ground.red < 0.02)
        }
        #expect(HaloGlass.ground(y: -1) == HaloGlass.RGB(hex: HaloGlass.groundTop))
        #expect(HaloGlass.ground(y: 1).luminance < HaloGlass.ground(y: -1).luminance)
    }
}
