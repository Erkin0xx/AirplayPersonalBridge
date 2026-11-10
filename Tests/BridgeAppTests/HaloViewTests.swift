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
        #expect(peak > 0.4)
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
        var progress = 0.02
        while progress <= 1 {
            let band = HaloWaveGeometry.band(index: 0, progress: progress)
            #expect(band.radius > previous.radius)
            #expect(band.lineWidth > previous.lineWidth)
            previous = band
            progress += 0.02
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
                    #expect(abs(here - around) < 1e-9)
                }
                let outline = HaloWaveGeometry.outline(
                    of: band, time: time, center: center, sphereRadius: 140, samples: 72
                )
                #expect(outline.count == 72)
                #expect(outline.allSatisfy { $0.x.isFinite && $0.y.isFinite })
                // Le dernier point ne répète pas le premier, et n'en est pas loin : le tracé se referme
                // sur un segment comme les autres.
                let first = outline[0]
                let last = outline[71]
                let closing = hypot(first.x - last.x, first.y - last.y)
                let step = hypot(outline[1].x - first.x, outline[1].y - first.y)
                #expect(closing > 0)
                #expect(closing < step * 2)
                // Tous les points restent dans la couronne permise.
                let reach = band.radius * 140
                for point in outline {
                    let distance = hypot(point.x - center.x, point.y - center.y)
                    #expect(abs(distance / reach - 1) <= HaloWaveGeometry.maxWobble + 1e-9)
                }
            }
        }
    }

    @Test("Le contour bouge sans à-coup d'une image à la suivante")
    func outlineMovesSmoothly() {
        let time = 2.0
        let frame = 1.0 / 30
        let band = HaloWaveGeometry.band(index: 1, progress: 0.4)
        let now = HaloWaveGeometry.outline(of: band, time: time, center: center, sphereRadius: 140)
        let next = HaloWaveGeometry.outline(of: band, time: time + frame, center: center, sphereRadius: 140)
        for (a, b) in zip(now, next) {
            // À rayon égal, seule l'ondulation a bougé : une fraction de point par image.
            #expect(hypot(a.x - b.x, a.y - b.y) < 1.5)
        }
    }

    @Test("Le tracé passe par le contour et l'enferme")
    func closedPathEnclosesTheOutline() {
        let band = HaloWaveGeometry.band(index: 0, progress: 0.5)
        let outline = HaloWaveGeometry.outline(of: band, time: 3, center: center, sphereRadius: 100)
        let path = HaloWaveGeometry.closedPath(through: outline)
        #expect(!path.isEmpty)
        #expect(path.contains(center))
        let bounds = path.boundingRect
        let reach = band.radius * 100 * (1 + HaloWaveGeometry.maxWobble)
        #expect(bounds.width <= reach * 2 + 1 && bounds.height <= reach * 2 + 1)
        #expect(bounds.width > band.radius * 100 && bounds.height > band.radius * 100)
        // Trop peu de points pour une courbe : rien, plutôt qu'un tracé dégénéré.
        #expect(HaloWaveGeometry.closedPath(through: Array(outline.prefix(2))).isEmpty)
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
        // Quatre enceintes et le bouton de recherche tiennent sur une rangée à 1200 pt.
        let wide = HaloFlowLayout.rows(
            widths: Array(repeating: chip, count: 4) + [32], available: 1200 - 48, spacing: spacing
        )
        #expect(wide == [[0, 1, 2, 3, 4]])
        // À la largeur minimale, trois par rangée.
        #expect(rows(4, 960 - 48) == [[0, 1, 2], [3]])
        #expect(rows(7, 960 - 48) == [[0, 1, 2], [3, 4, 5], [6]])
        // Plus étroit qu'une pastille : une par rangée, jamais une rangée vide.
        #expect(rows(2, 100) == [[0], [1]])
        #expect(rows(0, 500).isEmpty)
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
