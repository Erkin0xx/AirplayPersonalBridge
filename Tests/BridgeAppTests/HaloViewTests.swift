import CoreGraphics
import Foundation
import SwiftUI
import Testing

@testable import BridgeApp

/// Ce que la vue « Halo » calcule hors de ses vues : l'anneau du volume, les ondes, les mesures et les
/// mots.
@Suite("Vue Halo — anneau du volume, ondes et mots")
struct HaloViewTests {
    private let master = BridgeSettings.Limits.masterDB
    private let center = CGPoint(x: 200, y: 200)

    // MARK: - Anneau du volume

    @Test("L'anneau se lit dans le sens horaire depuis le haut")
    func turnIsClockwiseFromTheTop() {
        func turn(_ dx: Double, _ dy: Double) -> Double {
            HaloRingGeometry.turn(of: CGPoint(x: center.x + dx, y: center.y + dy), around: center)
        }
        // L'axe des y descend : « en haut » est à −y.
        #expect(abs(turn(0, -100) - 0) < 1e-9)
        #expect(abs(turn(100, 0) - 0.25) < 1e-9)
        #expect(abs(turn(0, 100) - 0.5) < 1e-9)
        #expect(abs(turn(-100, 0) - 0.75) < 1e-9)
        // Juste à gauche du haut : presque un tour, jamais une valeur négative ni un tour entier.
        let nearlyFull = turn(-0.001, -100)
        #expect(nearlyFull > 0.99 && nearlyFull < 1)
    }

    @Test("Le point de l'anneau et son angle se répondent")
    func pointAndTurnAgree() {
        var fraction = 0.0
        while fraction < 1 {
            let point = HaloRingGeometry.point(forFraction: fraction, center: center, radius: 172)
            #expect(abs(HaloRingGeometry.turn(of: point, around: center) - fraction) < 1e-9)
            let distance = hypot(point.x - center.x, point.y - center.y)
            #expect(abs(distance - 172) < 1e-9)
            fraction += 0.0625
        }
    }

    @Test("Le volume suit l'angle, et reste dans ses bornes")
    func decibelsFollowTheAngle() {
        #expect(HaloRingGeometry.decibels(forCourse: 0, in: master) == master.lowerBound)
        #expect(HaloRingGeometry.decibels(forCourse: 1, in: master) == master.upperBound)
        #expect(abs(HaloRingGeometry.decibels(forCourse: 0.6, in: master) - -24) < 1e-9)
        #expect(abs(HaloRingGeometry.fraction(forDecibels: -24, in: master) - 0.6) < 1e-9)
        // Une course déroulée au-delà d'un bout donne ce bout, jamais plus.
        #expect(HaloRingGeometry.decibels(forCourse: 1.4, in: master) == master.upperBound)
        #expect(HaloRingGeometry.decibels(forCourse: -0.4, in: master) == master.lowerBound)
        // Un volume hors bornes ne fait pas déborder l'arc.
        #expect(HaloRingGeometry.fraction(forDecibels: 12, in: master) == 1)
        #expect(HaloRingGeometry.fraction(forDecibels: -90, in: master) == 0)
        // Un intervalle vide ne divise pas par zéro.
        #expect(HaloRingGeometry.fraction(forDecibels: 0, in: 0...0) == 0)
    }

    @Test("Passer le haut de l'anneau ne fait pas sauter le volume d'un bout à l'autre")
    func noWrapAroundAtTheTop() {
        // Presque au maximum, la main dépasse le haut : le volume reste au maximum.
        let past = HaloRingGeometry.follow(course: 0.95, turn: 0.02)
        #expect(past > 1)
        #expect(HaloRingGeometry.decibels(forCourse: past, in: master) == master.upperBound)
        // Presque au minimum, la main recule au-delà du haut : il reste au minimum.
        let before = HaloRingGeometry.follow(course: 0.05, turn: 0.97)
        #expect(before < 0)
        #expect(HaloRingGeometry.decibels(forCourse: before, in: master) == master.lowerBound)
    }

    @Test("Un geste qui fait plusieurs tours reste en butée, et en revient sans à-coup")
    func dragAroundStaysPinned() {
        // Deux tours et demi dans le sens horaire, par pas d'un vingtième de tour, depuis 0,8.
        var course = 0.8
        var step = 1
        while step <= 50 {
            let turn = (0.8 + Double(step) * 0.05).truncatingRemainder(dividingBy: 1)
            course = HaloRingGeometry.follow(course: course, turn: turn)
            if step >= 4 {
                #expect(HaloRingGeometry.decibels(forCourse: course, in: master) == master.upperBound)
            }
            #expect(course <= 1 + HaloRingGeometry.slack)
            step += 1
        }
        // La main revient juste avant le haut : le bouton est de nouveau sous elle.
        course = HaloRingGeometry.follow(course: course, turn: 0.02)
        course = HaloRingGeometry.follow(course: course, turn: 0.9)
        #expect(abs(course - 0.9) < 1e-9)

        // Dans l'autre sens, la butée est le minimum.
        course = 0.2
        step = 1
        while step <= 30 {
            let turn = (10.2 - Double(step) * 0.05).truncatingRemainder(dividingBy: 1)
            course = HaloRingGeometry.follow(course: course, turn: turn)
            if step >= 4 {
                #expect(HaloRingGeometry.decibels(forCourse: course, in: master) == master.lowerBound)
            }
            #expect(course >= -HaloRingGeometry.slack)
            step += 1
        }
    }

    @Test("Un geste ordinaire suit la main, sans déroulement")
    func plainDragFollowsTheHand() {
        var course = HaloRingGeometry.grab(turn: 0.3, currentFraction: 0.6)
        #expect(course == 0.3)
        for turn in [0.35, 0.5, 0.62, 0.48] {
            course = HaloRingGeometry.follow(course: course, turn: turn)
            #expect(course == turn)
        }
    }

    @Test("Saisir le bouton au maximum ne fait pas tomber le volume au minimum")
    func grabbingTheKnobAcrossTheSeam() {
        // Le bouton est en haut, au maximum ; le clic tombe un rien à droite du haut.
        let atMax = HaloRingGeometry.grab(turn: 0.01, currentFraction: 1)
        #expect(HaloRingGeometry.decibels(forCourse: atMax, in: master) == master.upperBound)
        // Et au minimum, un rien à gauche.
        let atMin = HaloRingGeometry.grab(turn: 0.99, currentFraction: 0)
        #expect(HaloRingGeometry.decibels(forCourse: atMin, in: master) == master.lowerBound)
        // Loin du bouton, le volume va où l'on clique, même près du haut.
        #expect(HaloRingGeometry.grab(turn: 0.01, currentFraction: 0.6) == 0.01)
        #expect(HaloRingGeometry.grab(turn: 0.75, currentFraction: 1) == 0.75)
    }

    // MARK: - Ondes

    private let times: [TimeInterval] = [0, 0.37, 1.9, 4, 7.999, 123.456, 800_000_000.25]

    @Test("Les bandes sont régulièrement échelonnées")
    func bandsAreStaggered() {
        for time in times {
            let bands = HaloWaveGeometry.bands(at: time)
            #expect(bands.count == HaloWaveGeometry.bandCount)
            #expect(bands.map(\.index) == Array(0..<HaloWaveGeometry.bandCount))
            let sorted = bands.map(\.progress).sorted()
            for (earlier, later) in zip(sorted, sorted.dropFirst()) {
                #expect(abs(later - earlier - 1 / Double(HaloWaveGeometry.bandCount)) < 1e-6)
            }
            for band in bands {
                #expect(band.progress >= 0 && band.progress < 1)
            }
        }
    }

    @Test("Une bande est transparente à sa naissance et à sa disparition")
    func bandsFadeAtBothEnds() {
        #expect(HaloWaveGeometry.band(index: 0, progress: 0).opacity == 0)
        #expect(HaloWaveGeometry.band(index: 0, progress: 1).opacity == 0)
        // Juste avant de disparaître et juste après être née : presque rien, des deux côtés.
        #expect(HaloWaveGeometry.band(index: 2, progress: 0.999).opacity < 0.001)
        #expect(HaloWaveGeometry.band(index: 2, progress: 0.001).opacity < 0.01)
        // Elle se voit entre les deux, sans jamais dépasser son plafond.
        var progress = 0.0
        var peak = 0.0
        while progress <= 1 {
            let opacity = HaloWaveGeometry.band(index: 1, progress: progress).opacity
            #expect(opacity >= 0 && opacity <= HaloWaveGeometry.peakOpacity)
            peak = max(peak, opacity)
            progress += 0.01
        }
        #expect(peak > HaloWaveGeometry.peakOpacity * 0.5)
        // Un voile, pas un trait : Baptiste a trouvé les premières ondes, à 0,8, « trop présentes ».
        #expect(HaloWaveGeometry.peakOpacity <= 0.35)
        // L'apparition n'a pas de coin : au milieu de sa montée, la bande est à mi-chemin.
        let half = HaloWaveGeometry.band(index: 0, progress: HaloWaveGeometry.fadeInShare / 2)
        let full = HaloWaveGeometry.band(index: 0, progress: HaloWaveGeometry.fadeInShare)
        #expect(half.opacity > 0 && half.opacity < full.opacity)
    }

    @Test("La boucle n'a pas de couture : une période plus tard, les mêmes bandes au même endroit")
    func loopIsSeamless() {
        for time in [0.0, 1.3, 5.75] {
            let now = HaloWaveGeometry.bands(at: time)
            let later = HaloWaveGeometry.bands(at: time + HaloWaveGeometry.period)
            for (a, b) in zip(now, later) {
                #expect(abs(a.progress - b.progress) < 1e-9)
                #expect(abs(a.opacity - b.opacity) < 1e-9)
                #expect(abs(a.radius - b.radius) < 1e-9)
            }
        }
        // Au passage de la couture, la bande qui renaît est invisible avant comme après.
        let wrap = HaloWaveGeometry.period
        let before = HaloWaveGeometry.bands(at: wrap - 0.001)[0]
        let after = HaloWaveGeometry.bands(at: wrap + 0.001)[0]
        #expect(before.progress > 0.99 && after.progress < 0.01)
        #expect(before.opacity < 0.001 && after.opacity < 0.01)
    }

    @Test("Une bande s'éloigne et s'élargit sans jamais revenir")
    func bandsTravelOutward() {
        var previous = HaloWaveGeometry.band(index: 0, progress: 0)
        #expect(abs(previous.radius - HaloWaveGeometry.birthRadius) < 1e-9)
        // Des pas entiers : une somme de 0,02 n'atteint jamais exactement 1.
        var step = 1
        while step <= 50 {
            let band = HaloWaveGeometry.band(index: 0, progress: Double(step) / 50)
            #expect(band.radius > previous.radius)
            #expect(band.lineWidth > previous.lineWidth)
            previous = band
            step += 1
        }
        #expect(abs(previous.radius - HaloWaveGeometry.reachRadius) < 1e-9)
        // Elle part de la sphère : au-delà de son bord, en deçà de l'anneau du volume.
        #expect(HaloWaveGeometry.birthRadius > 1)
        #expect(HaloWaveGeometry.birthRadius < Double(HaloMetrics.ringRatio))
        // Large dès le départ, et plus encore à l'arrivée.
        for index in 0..<HaloWaveGeometry.bandCount {
            let birth = HaloWaveGeometry.band(index: index, progress: 0).lineWidth
            let end = HaloWaveGeometry.band(index: index, progress: 1).lineWidth
            #expect(birth >= 8)
            #expect(end == HaloWaveGeometry.endWidths[index])
            #expect(end > birth * 2)
        }
    }

    @Test("Le contour ondule, mais ne s'écarte jamais de son cercle de plus que l'amplitude")
    func wobbleIsBounded() {
        #expect(HaloWaveGeometry.maxWobble > 0.08)
        #expect(HaloWaveGeometry.maxWobble < 0.25)
        for time in times {
            for band in HaloWaveGeometry.bands(at: time) {
                var lowest = Double.infinity
                var highest = -Double.infinity
                var sample = 0
                while sample < 360 {
                    let angle = 2 * Double.pi * Double(sample) / 360
                    let ratio = HaloWaveGeometry.radius(of: band, angle: angle, time: time) / band.radius
                    #expect(ratio.isFinite)
                    #expect(abs(ratio - 1) <= HaloWaveGeometry.maxWobble + 1e-9)
                    lowest = min(lowest, ratio)
                    highest = max(highest, ratio)
                    sample += 1
                }
                // Ce n'est pas un rond : le contour s'écarte vraiment de son cercle.
                #expect(highest - lowest > 0.03)
            }
        }
    }

    @Test("Le contour se referme : un tour plus loin, le même rayon")
    func outlineIsClosed() {
        for time in times {
            for band in HaloWaveGeometry.bands(at: time) {
                for angle in [0.0, 0.7, 2.1, 5.9] {
                    let here = HaloWaveGeometry.radius(of: band, angle: angle, time: time)
                    let around = HaloWaveGeometry.radius(of: band, angle: angle + 2 * Double.pi, time: time)
                    // Au millionième : un sinus d'un angle augmenté de 2π perd quelques bits.
                    #expect(abs(here - around) < 1e-6)
                }
            }
        }
    }

    @Test("Le contour bouge sans à-coup d'une image à la suivante")
    func outlineMovesSmoothly() {
        let time = 2.0
        let band = HaloWaveGeometry.band(index: 1, progress: 0.4)
        var sample = 0
        while sample < 72 {
            let angle = 2 * Double.pi * Double(sample) / 72
            let now = HaloWaveGeometry.radius(of: band, angle: angle, time: time)
            let next = HaloWaveGeometry.radius(of: band, angle: angle, time: time + HaloWaves.frameInterval)
            // À rayon égal, seule l'ondulation a bougé : une fraction de point par image, pour une
            // sphère de 140 pt de rayon.
            #expect(abs(now - next) * 140 < 1.5)
            sample += 1
        }
    }

    // MARK: - Ondes en lumière

    @Test("La cloche d'une bande n'a ni bord ni palier")
    func profileIsSoft() {
        #expect(HaloWaveField.profile(0) == 1)
        #expect(HaloWaveField.profile(1) == 0)
        #expect(HaloWaveField.profile(-1) == 0)
        #expect(HaloWaveField.profile(1.7) == 0)
        #expect(HaloWaveField.profile(-3) == 0)
        // Symétrique, et la largeur à mi-hauteur est bien celle que la géométrie annonce.
        #expect(HaloWaveField.profile(0.4) == HaloWaveField.profile(-0.4))
        #expect(abs(HaloWaveField.profile(0.5 / HaloWaveField.reachPerWidth) - 0.5) < 0.01)
        // Elle descend sans cesse du contour à sa portée, par pas minuscules : à l'arrivée elle se pose
        // sans cassure, la pente s'annulant avec elle.
        var previous = 1.0
        var step = 1
        while step <= 200 {
            let value = HaloWaveField.profile(Double(step) / 200)
            #expect(value < previous)
            #expect(previous - value < 0.01)
            previous = value
            step += 1
        }
        #expect(HaloWaveField.profile(0.99) < 1e-4)
    }

    @Test("Les bandes sont larges : elles se fondent l'une dans l'autre")
    func bandsAreWide() {
        for index in 0..<HaloWaveGeometry.bandCount {
            let end = HaloWaveGeometry.band(index: index, progress: 1)
            // Au bout de sa course, une bande déborde de plus d'un demi-rayon de sphère de chaque côté.
            #expect(HaloWaveField.reach(of: end) > 0.7)
            #expect(HaloWaveField.reach(of: end) == end.lineWidth / 140 * HaloWaveField.reachPerWidth)
        }
        // Les teintes sont celles du fond, pas du blanc ni du gris : chacune a une dominante nette.
        #expect(HaloWaveField.tints.count == HaloWaveGeometry.bandCount)
        for tint in HaloWaveField.tints {
            let high = max(tint.red, tint.green, tint.blue)
            let low = min(tint.red, tint.green, tint.blue)
            #expect(high - low > 0.35)
        }
    }

    @Test("L'image des ondes suit les proportions de la vue")
    func waveGridFollowsTheView() {
        #expect(HaloWaveField.gridSize(for: CGSize(width: 1200, height: 760)) == (160, 101))
        #expect(HaloWaveField.gridSize(for: CGSize(width: 960, height: 620)) == (160, 103))
        // Bornée dans les deux sens, et une vue sans taille ne divise pas par zéro.
        #expect(HaloWaveField.gridSize(for: CGSize(width: 4000, height: 300)) == (160, 40))
        #expect(HaloWaveField.gridSize(for: CGSize(width: 300, height: 4000)) == (160, 240))
        #expect(HaloWaveField.gridSize(for: .zero) == (160, 100))
    }

    private static let viewSize = CGSize(width: 1200, height: 760)
    private static let grid = HaloWaveField.Grid(
        viewSize: viewSize, center: CGPoint(x: 600, y: 300), sphereRadius: 140
    )

    @Test("Les ondes sont un voile discret, valide, et sans bord aux limites de la sphère")
    func wavePixelsAreAFaintVeil() {
        let grid = Self.grid
        #expect(grid.width == 160 && grid.height == 101)
        let ceiling = UInt8((HaloWaveField.maxAlpha * 255).rounded(.up))
        var brightest: UInt8 = 0
        for time in times {
            let bytes = grid.pixels(at: time)
            #expect(bytes.count == grid.width * grid.height * 4)
            var index = 0
            while index < grid.width * grid.height {
                let alpha = bytes[index * 4 + 3]
                // Prémultiplié : aucune composante ne dépasse l'alpha.
                #expect(bytes[index * 4] <= alpha && bytes[index * 4 + 1] <= alpha && bytes[index * 4 + 2] <= alpha)
                #expect(alpha <= ceiling)
                brightest = max(brightest, alpha)
                index += 1
            }
        }
        // Elles existent, mais restent un voile : jamais le tiers de l'opacité.
        #expect(brightest > 12)
        #expect(HaloWaveField.maxAlpha <= 0.34)
    }

    @Test("D'un pixel à son voisin, le voile ne fait jamais de marche")
    func waveLightHasNoSteps() {
        let grid = Self.grid
        for time in times {
            let light = grid.light(at: time)
            var largest: Float = 0
            var row = 0
            while row < grid.height {
                var column = 0
                while column < grid.width - 1 {
                    let here = (row * grid.width + column) * 3
                    var channel = 0
                    while channel < 3 {
                        largest = max(largest, abs(light[here + channel] - light[here + 3 + channel]))
                        channel += 1
                    }
                    column += 1
                }
                row += 1
            }
            // Un pixel de l'image fait 7,5 pt à l'écran : moins de 4 % d'opacité d'écart d'un pixel au
            // suivant, soit une pente douce et jamais un bord. Les anciens traits sautaient de 12 %.
            #expect(largest < 0.04)
            #expect(largest > 0)
        }
    }

    @Test("Le désordre d'arrondi reste dans un demi-niveau et ne dépend que du pixel")
    func ditherIsBoundedAndFixed() {
        var lowest = 1.0
        var highest = -1.0
        var sum = 0.0
        for index in 0..<16_000 {
            let value = HaloWaveField.dither(index)
            #expect(value >= -0.5 && value < 0.5)
            #expect(value == HaloWaveField.dither(index))
            lowest = min(lowest, value)
            highest = max(highest, value)
            sum += value
        }
        // Il couvre sa course et ne tire d'aucun côté : l'image n'est ni éclaircie ni assombrie.
        #expect(lowest < -0.45 && highest > 0.45)
        #expect(abs(sum / 16_000) < 0.02)
    }

    @Test("Les ondes ne se dessinent pas plus souvent qu'avant")
    func wavesDrawNoFasterThanBefore() {
        #expect(HaloWaves.frameInterval >= 1.0 / 30)
        #expect(HaloWaves.stillTime > 0 && HaloWaves.stillTime < HaloWaveGeometry.period)
    }

    // MARK: - Sphère, égaliseur, mesures

    @Test("La sphère respire sans jamais toucher l'anneau du volume")
    func sphereBreathesInsideTheRing() {
        var time = 0.0
        while time < HaloSphereMotion.breathPeriod * 2 {
            let scale = HaloSphereMotion.scale(at: time)
            #expect(scale >= 1 && scale <= 1 + HaloSphereMotion.breathDepth + 1e-12)
            let spin = HaloSphereMotion.spin(at: time)
            #expect(spin >= 0 && spin < 2 * Double.pi)
            time += 0.05
        }
        #expect(abs(HaloSphereMotion.scale(at: 0) - 1) < 1e-12)
        #expect(abs(HaloSphereMotion.scale(at: HaloSphereMotion.breathPeriod / 2) - 1.045) < 1e-9)
        // Inspirée, la plus petite sphère reste à distance de l'anneau et de sa bande de saisie.
        let smallest = HaloMetrics.sphereRange.lowerBound / 2
        let ring = HaloMetrics.ringRadius(forSphere: smallest * 2)
        #expect(smallest * (1 + HaloSphereMotion.breathDepth) < ring - HaloVolumeRing.grabHalfWidth)
    }

    @Test("Les barres de l'égaliseur restent dans leur course")
    func equaliserStaysInRange() {
        var time = 0.0
        while time < 6 {
            for bar in 0..<HaloEqualiserMotion.bars.count {
                let share = HaloEqualiserMotion.share(bar: bar, at: time)
                #expect(share >= HaloEqualiserMotion.lowShare - 1e-12 && share <= 1 + 1e-12)
            }
            time += 0.03
        }
        // Les trois barres ne montent pas ensemble.
        let together = (0..<3).map { HaloEqualiserMotion.share(bar: $0, at: 0.4) }
        #expect(Set(together.map { ($0 * 100).rounded() }).count == 3)
    }

    @Test("La sphère prend la taille de la maquette quand la place le permet, et rétrécit sinon")
    func sphereFitsItsZone() {
        // La fenêtre de la maquette : la sphère fait 280 pt.
        #expect(HaloMetrics.sphereDiameter(fitting: CGSize(width: 1152, height: 480)) == 280)
        // Plus serré : l'anneau tient en entier dans la place.
        for height in stride(from: 240.0, through: 420.0, by: 20) {
            let zone = CGSize(width: 912, height: height)
            let diameter = HaloMetrics.sphereDiameter(fitting: zone)
            #expect(HaloMetrics.sphereRange.contains(diameter))
            let side = HaloVolumeRing.side(forRadius: HaloMetrics.ringRadius(forSphere: diameter))
            #expect(side <= height + 1e-9)
        }
        // Jamais plus petite que le minimum, même si la place manque.
        #expect(HaloMetrics.sphereDiameter(fitting: CGSize(width: 900, height: 80)) == 150)
        #expect(
            HaloVolumeRing.side(forRadius: HaloMetrics.ringRadius(forSphere: 150))
                <= HaloMetrics.minimumZoneHeight + 1e-9
        )
        // La largeur compte autant que la hauteur.
        #expect(HaloMetrics.sphereDiameter(fitting: CGSize(width: 260, height: 600)) < 280)
    }

    @Test("Les pastilles passent à la ligne quand la largeur manque")
    func chipsWrap() {
        let chip = HaloChipMetrics.width
        let spacing = HaloChipMetrics.spacing
        func rows(_ count: Int, _ available: CGFloat) -> [[Int]] {
            HaloFlowLayout.rows(
                widths: Array(repeating: chip, count: count), available: available, spacing: spacing
            )
        }
        // Quatre enceintes et les deux commandes rondes tiennent sur une rangée à 1200 pt.
        let controls = HaloChipMetrics.controlsWidth
        let wide = HaloFlowLayout.rows(
            widths: Array(repeating: chip, count: 4) + [controls], available: 1200 - 48, spacing: spacing
        )
        #expect(wide == [[0, 1, 2, 3, 4]])
        // À la largeur minimale, trois enceintes et les commandes.
        let narrow = HaloFlowLayout.rows(
            widths: Array(repeating: chip, count: 3) + [controls], available: 960 - 48, spacing: spacing
        )
        #expect(narrow == [[0, 1, 2, 3]])
        #expect(rows(4, 960 - 48) == [[0, 1, 2], [3]])
        #expect(rows(7, 960 - 48) == [[0, 1, 2], [3, 4, 5], [6]])
        // Plus étroit qu'une pastille : une par rangée, jamais une rangée vide.
        #expect(rows(2, 100) == [[0], [1]])
        #expect(rows(0, 500).isEmpty)
    }

    @Test("Les commandes rondes ont la taille du badge des enceintes")
    func roundControlsMatchTheBadge() {
        #expect(HaloChipMetrics.badge == 40)
        #expect(HaloChipMetrics.controlsWidth == 2 * HaloChipMetrics.badge + HaloChipMetrics.controlSpacing)
        #expect(HaloChipMetrics.badge < HaloChipMetrics.height)
    }

    @Test("Le silence général reste sous la main quand les pastilles défilent")
    func controlsArePinnedWhenChipsScroll() {
        let minimal: CGFloat = 960 - 48
        let regular: CGFloat = 1200 - 48
        // Tant que tout tient sur deux rangées, les commandes suivent la dernière pastille.
        for count in 1...6 {
            #expect(!HaloChipsArrangement.pinsControls(chipCount: count, available: minimal))
        }
        #expect(!HaloChipsArrangement.pinsControls(chipCount: 8, available: regular))
        // Six pastilles remplissent deux rangées de trois, mais les commandes passeraient sur une
        // troisième : pas à 960 pt, où elles tiennent au bout de la deuxième.
        #expect(!HaloChipsArrangement.pinsControls(chipCount: 6, available: minimal))
        // Au-delà, les pastilles défilent : les commandes sortent du défilement.
        #expect(HaloChipsArrangement.pinsControls(chipCount: 7, available: minimal))
        #expect(HaloChipsArrangement.pinsControls(chipCount: 9, available: regular))
        // Deux rangées pleines sans place pour les commandes : elles sortent aussi.
        #expect(HaloChipsArrangement.pinsControls(chipCount: 6, available: 3 * HaloChipMetrics.width + 24))
        // Rien à épingler sans pastille, ni avant de connaître la largeur.
        #expect(!HaloChipsArrangement.pinsControls(chipCount: 0, available: minimal))
        #expect(!HaloChipsArrangement.pinsControls(chipCount: 12, available: .infinity))
        #expect(!HaloChipsArrangement.pinsControls(chipCount: 12, available: 0))
    }

    @Test("Le silence général dit ce qu'il fait et le niveau, et ne disparaît jamais tant que le son est coupé")
    func muteControlCopy() {
        #expect(
            HaloMuteControl.help(isMuted: false, level: "−52 dB")
                == "Couper le son des enceintes, sans les déconnecter · volume général −52 dB"
        )
        #expect(
            HaloMuteControl.help(isMuted: true, level: "−52 dB")
                == "Rétablir le son des enceintes · volume général −52 dB"
        )
        #expect(HaloMuteControl.accessibilityValue(isMuted: true, level: "−24 dB") == "activé, volume général −24 dB")
        #expect(
            HaloMuteControl.accessibilityValue(isMuted: false, level: "−24 dB") == "désactivé, volume général −24 dB"
        )
        #expect(HaloMuteControl.isShown(hasSpeakers: true, isMuted: false))
        #expect(HaloMuteControl.isShown(hasSpeakers: true, isMuted: true))
        // Sans enceinte, rien à couper ; mais un son coupé doit pouvoir se rétablir.
        #expect(!HaloMuteControl.isShown(hasSpeakers: false, isMuted: false))
        #expect(HaloMuteControl.isShown(hasSpeakers: false, isMuted: true))
    }

    // MARK: - Mots et état

    private func subtitle(
        _ phase: BridgeState.StreamingPhase, detail: String? = nil, alert: String? = nil,
        muted: Bool = false, failure: Bool = false, canToggle: Bool = true, hasSpeakers: Bool = true
    ) -> String {
        HaloCopy.subtitle(
            phase: phase, detail: detail, sourceLabel: "Son du Mac", alertTitle: alert, isMuted: muted,
            hasStartFailure: failure, canToggle: canToggle, hasSpeakers: hasSpeakers
        )
    }

    @Test("Au repos, la ligne dit ce que fait un clic, ou pourquoi le halo ne répond pas")
    func subtitleAtRest() {
        #expect(
            subtitle(.idle, detail: "3 enceintes cochées")
                == "3 enceintes cochées · clique sur le halo pour diffuser"
        )
        #expect(subtitle(.idle, canToggle: false) == "Coche une enceinte pour diffuser")
        #expect(subtitle(.idle, canToggle: false, hasSpeakers: false) == "Aucune enceinte pour l'instant")
        #expect(subtitle(.idle, failure: true) == "Clique sur le halo pour réessayer")
        // Un échec sans enceinte cochée : réessayer ne servirait à rien.
        #expect(subtitle(.idle, failure: true, canToggle: false) == "Coche une enceinte pour diffuser")
    }

    @Test("En diffusion, ce qui ne va pas passe avant le geste")
    func subtitleWhileStreaming() {
        // La source est déjà dans la barre d'outils : elle ne se répète pas.
        #expect(subtitle(.running, detail: "Son du Mac") == "Clique sur le halo pour arrêter")
        #expect(
            subtitle(.running, detail: "1 en panne, 1 en attente")
                == "1 en panne, 1 en attente · clique sur le halo pour arrêter"
        )
        #expect(
            subtitle(.running, detail: "Son du Mac", alert: "Rien ne joue")
                == "Rien ne joue · clique sur le halo pour arrêter"
        )
        #expect(
            subtitle(.running, detail: "Son du Mac", muted: true)
                == "Son coupé · clique sur le halo pour arrêter"
        )
        // Une phrase entière se suffit.
        #expect(
            subtitle(.running, detail: "La diffusion s'arrête dans un instant.")
                == "La diffusion s'arrête dans un instant."
        )
        // Une relance : le halo ne répond pas, on ne propose pas de cliquer.
        #expect(subtitle(.running, detail: "Son du Mac", canToggle: false) == "Son du Mac")
        #expect(subtitle(.starting, canToggle: false) == "Connexion aux enceintes…")
        #expect(subtitle(.stopping, canToggle: false) == "Fermeture des sessions…")
    }

    @Test("Le halo ne vit que si un son part vraiment vers une enceinte")
    func haloAudibility() {
        let streaming = BridgeState.preview(.streaming)
        #expect(streaming.isHaloAudible)

        // Toutes les enceintes qui diffusent sont coupées une à une : plus rien ne s'entend.
        for output in streaming.outputs where output.isEnabled { output.isMuted = true }
        #expect(!streaming.isHaloAudible)
        streaming.outputs.first { $0.isEnabled }?.isMuted = false
        #expect(streaming.isHaloAudible)

        streaming.isMuted = true
        #expect(!streaming.isHaloAudible)

        #expect(!BridgeState.preview(.idle).isHaloAudible)
        // La capture tourne, mais aucune enceinte ne joue encore.
        #expect(!BridgeState.preview(.starting).isHaloAudible)
        // La capture est muette : les sessions tiennent, aucun son ne part.
        #expect(!BridgeState.preview(.nothingPlaying).isHaloAudible)
        #expect(!BridgeState.preview(.trouble).isHaloAudible)
    }

    @Test("En connexion sans enceinte encore prête, le fond peut vivre mais pas le halo")
    func haloWaitsForASpeaker() {
        let state = BridgeState.preview(.streaming)
        for output in state.outputs { output.connection = .connecting }
        #expect(state.isAudiblyStreaming)
        #expect(!state.isHaloAudible)
    }
}
