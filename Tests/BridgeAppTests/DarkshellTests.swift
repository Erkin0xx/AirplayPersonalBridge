import CoreGraphics
import Foundation
import Testing

@testable import BridgeApp

/// La matière « Darkshells » des commandes de la console : ce qui se calcule hors des vues. Le liseré qui
/// s'éteint, le voile sous le niveau, et la place du trait, de la prise et des tirets dans la coque.
@Suite("Vue Console — matière Darkshells")
struct DarkshellTests {
    private let trim = BridgeSettings.Limits.trimDB

    // MARK: - Liseré

    @Test("Le liseré est net en haut et s'éteint en descendant, sans jamais se rallumer", arguments: Darkshell.Lip.allCases)
    func lipFadesDownward(lip: Darkshell.Lip) throws {
        let stops = lip.stops
        let first = try #require(stops.first)
        let last = try #require(stops.last)
        // Il couvre toute la hauteur : sans arrêt à 0 ni à 1, le dégradé prolongerait une valeur au hasard.
        #expect(first.location == 0 && last.location == 1)
        // Net au sommet : c'est lui qui dessine la lèvre. Presque rien au pied, mais pas rien : la coque
        // garde un contour sur le verre de la tuile.
        #expect(first.opacity >= 0.9)
        #expect(last.opacity > 0 && last.opacity <= 0.05)
        for (above, below) in zip(stops, stops.dropFirst()) {
            #expect(below.location > above.location)
            #expect(below.opacity < above.opacity)
        }
    }

    @Test("Sur le rail vertical, la lumière descend le long des bords avant de mourir")
    func faderLipRunsDownTheSides() {
        let stops = Darkshell.Lip.fader.stops
        // Un arrêt intermédiaire encore lisible dans le premier quart, puis l'extinction avant la moitié.
        #expect(stops.contains { $0.location > 0 && $0.location <= 0.25 && $0.opacity >= 0.3 })
        #expect(stops.contains { $0.location < 0.5 && $0.opacity <= 0.1 })
    }

    // MARK: - Voile

    @Test("Le voile est le plus clair sous le niveau et meurt dans le noir, sans jamais faire un bloc blanc")
    func veilDiesIntoTheGround() throws {
        let stops = Darkshell.veilStops(isSilenced: false)
        let first = try #require(stops.first)
        let last = try #require(stops.last)
        #expect(first.location == 0 && last.location == 1)
        // Un voile, pas un remplissage : même au plus clair, le noir de la coque domine.
        #expect(first.opacity > 0.3 && first.opacity < 0.5)
        #expect(last.opacity > 0 && last.opacity < 0.1)
        for (near, far) in zip(stops, stops.dropFirst()) {
            #expect(far.location > near.location)
            #expect(far.opacity < near.opacity)
        }
    }

    @Test("Son coupé ou enceinte décochée : le voile reste, éteint")
    func silencedVeilIsDimmedNotRemoved() {
        let lit = Darkshell.veilStops(isSilenced: false)
        let dimmed = Darkshell.veilStops(isSilenced: true)
        #expect(lit.count == dimmed.count)
        for (bright, dim) in zip(lit, dimmed) {
            #expect(dim.location == bright.location)
            // Nettement plus sombre, à chaque arrêt : l'état se lit d'un coup d'œil. Mais encore là : il
            // dit le niveau que le rétablissement rendra.
            #expect(dim.opacity > 0)
            #expect(dim.opacity <= bright.opacity * 0.5)
        }
    }

    // MARK: - Curseur vertical

    @Test("Le trait du niveau est au sommet du voile, et les deux remplissent le rail jusqu'au pied")
    func levelSitsOnTopOfTheVeil() {
        let height: CGFloat = 318
        var decibels = trim.lowerBound
        while decibels <= trim.upperBound {
            let fill = ConsoleFaderScale.fillHeight(for: decibels, in: trim, trackHeight: height, floor: 26)
            let level = DarkshellFaderGeometry.levelY(fill: fill, trackHeight: height)
            #expect(level == height - fill)
            #expect(level + DarkshellFaderGeometry.veilHeight(fill: fill, trackHeight: height) == height)
            // Le trait est là où le geste lit cette valeur : ce qu'on voit est ce qu'on attrape.
            #expect(
                ConsoleFaderScale.value(
                    atY: level, trackHeight: height, floor: 26, in: trim, step: PanelToneStep.step
                ) == decibels
            )
            decibels += PanelToneStep.step
        }
        // Plus haut que le rail, plus bas que rien, ou illisible : rien ne sort de la coque.
        #expect(DarkshellFaderGeometry.levelY(fill: 400, trackHeight: height) == 0)
        #expect(DarkshellFaderGeometry.levelY(fill: -20, trackHeight: height) == height)
        #expect(DarkshellFaderGeometry.levelY(fill: .nan, trackHeight: height) == height)
        #expect(DarkshellFaderGeometry.veilHeight(fill: .nan, trackHeight: height) == 0)
        #expect(DarkshellFaderGeometry.veilHeight(fill: 400, trackHeight: height) == height)
    }

    @Test("La prise est à cheval sur le trait, et reste entière aux deux bouts de la course")
    func gripStraddlesTheLineAndStaysInside() {
        let height: CGFloat = 318
        let half = DarkshellFaderGeometry.grip.height / 2
        // En pleine course : centrée sur le milieu du trait.
        #expect(
            DarkshellFaderGeometry.gripCenterY(levelY: 147, trackHeight: height)
                == 147 + DarkshellFaderGeometry.lineThickness / 2
        )
        // Au maximum, le trait touche la lèvre : la prise s'arrête contre le liseré, entière.
        let top = DarkshellFaderGeometry.gripCenterY(levelY: 0, trackHeight: height)
        #expect(top - half == Darkshell.lipWidth)
        // Et de même au pied, si le socle venait à disparaître.
        let bottom = DarkshellFaderGeometry.gripCenterY(levelY: height, trackHeight: height)
        #expect(bottom + half == height - Darkshell.lipWidth)
        // Sur toute la course d'une enceinte, elle ne quitte le trait qu'au sommet.
        var level: CGFloat = 0
        while level <= height - 26 {
            let center = DarkshellFaderGeometry.gripCenterY(levelY: level, trackHeight: height)
            #expect(center - half >= Darkshell.lipWidth)
            #expect(center + half <= height - Darkshell.lipWidth)
            // Elle recouvre toujours le trait, au moins en partie.
            #expect(center - half <= level + DarkshellFaderGeometry.lineThickness)
            #expect(center + half >= level)
            level += 0.5
        }
        // Un rail plus bas que la prise : au milieu, sans valeur absurde.
        #expect(DarkshellFaderGeometry.gripCenterY(levelY: 1, trackHeight: 4) == 2)
    }

    @Test("À 0 dB, le trait du niveau recouvre exactement les tirets du repère")
    func levelLineCoversTheMarkAtUnity() {
        for height: CGFloat in [250, 318, 480] {
            let unity = ConsoleFaderScale.fillHeight(for: 0, in: trim, trackHeight: height, floor: 26)
            let mark = DarkshellFaderGeometry.markY(fill: unity, trackHeight: height)
            let level = DarkshellFaderGeometry.levelY(fill: unity, trackHeight: height)
            #expect(mark >= level)
            #expect(mark + DarkshellFaderGeometry.mark.height <= level + DarkshellFaderGeometry.lineThickness)
            // Un demi-décibel plus bas, les tirets se voient au-dessus du trait.
            let lower = ConsoleFaderScale.fillHeight(for: -0.5, in: trim, trackHeight: height, floor: 26)
            #expect(mark + DarkshellFaderGeometry.mark.height <= DarkshellFaderGeometry.levelY(fill: lower, trackHeight: height))
        }
        // Les deux tirets et leur retrait tiennent dans la largeur du rail, en laissant le milieu à la prise.
        let side = Darkshell.lipWidth + DarkshellFaderGeometry.markInset + DarkshellFaderGeometry.mark.width
        #expect(2 * side + DarkshellFaderGeometry.grip.width <= 72)
    }

    // MARK: - Rail couché du volume général

    @Test("Le voile du volume général s'arrête sous la prise ronde, sans jamais la dépasser ni sortir du rail")
    func barVeilEndsUnderTheKnob() {
        let knob: CGFloat = 28
        let width: CGFloat = 300
        let travel = width - knob
        // Au minimum, il reste un pied de voile sous la moitié gauche de la prise ; au maximum, il s'arrête
        // au centre de la prise, avant le bout du rail.
        #expect(DarkshellBarGeometry.veilWidth(knobOffset: 0, knob: knob, width: width) == knob / 2)
        #expect(DarkshellBarGeometry.veilWidth(knobOffset: travel, knob: knob, width: width) == width - knob / 2)
        var offset: CGFloat = 0
        while offset <= travel {
            let veil = DarkshellBarGeometry.veilWidth(knobOffset: offset, knob: knob, width: width)
            // Son bout est caché par la prise : ni avant son bord gauche, ni après son bord droit.
            #expect(veil > offset && veil < offset + knob)
            offset += 4
        }
        // Une prise hors du rail ou une position illisible : rien ne déborde.
        #expect(DarkshellBarGeometry.veilWidth(knobOffset: 900, knob: knob, width: width) == width)
        #expect(DarkshellBarGeometry.veilWidth(knobOffset: -90, knob: knob, width: width) == 0)
        #expect(DarkshellBarGeometry.veilWidth(knobOffset: .nan, knob: knob, width: width) == 0)
    }
}
