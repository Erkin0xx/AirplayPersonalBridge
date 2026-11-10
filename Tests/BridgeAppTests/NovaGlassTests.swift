import CoreGraphics
import Foundation
import Testing

@testable import BridgeApp

@Suite("Verre de la sphère et matière de l'anneau")
struct NovaGlassTests {
    /// Les instants d'un cycle, à l'échelle des dates que reçoit la vue (secondes depuis 2001).
    private static let start: TimeInterval = 815_000_000
    private static func instants(step: TimeInterval = 0.25) -> [TimeInterval] {
        stride(from: 0, to: NovaGlassMotion.period, by: step).map { start + $0 }
    }

    // MARK: - Mouvement des reflets

    @Test("Les reflets reviennent exactement à leur place une période plus tard : aucune couture")
    func motionIsPeriodic() {
        for layer in NovaGlass.Layer.allCases {
            for time in Self.instants(step: 1.7) {
                let now = NovaGlassMotion.pose(of: layer, at: time)
                let later = NovaGlassMotion.pose(of: layer, at: time + NovaGlassMotion.period)
                #expect(abs(now.angle - later.angle) < 1e-6)
                #expect(abs(now.slide - later.slide) < 1e-6)
            }
        }
    }

    @Test("Chaque couche reste dans ses bornes, et bouge vraiment")
    func motionIsBoundedAndAlive() {
        for layer in NovaGlass.Layer.allCases {
            var angles: [Double] = []
            var slides: [Double] = []
            for time in Self.instants() {
                let pose = NovaGlassMotion.pose(of: layer, at: time)
                #expect(abs(pose.angle) <= NovaGlassMotion.maxAngle + 1e-12)
                #expect(abs(pose.slide) <= NovaGlassMotion.maxSlide + 1e-12)
                angles.append(pose.angle)
                slides.append(pose.slide)
            }
            // Un reflet figé ne dirait pas « ça joue » : chaque couche parcourt au moins la moitié de
            // sa course permise, dans les deux sens.
            #expect((angles.max() ?? 0) - (angles.min() ?? 0) > NovaGlassMotion.maxAngle)
            #expect((slides.max() ?? 0) - (slides.min() ?? 0) > NovaGlassMotion.maxSlide)
        }
        // Les couches ne bougent pas d'un bloc : c'est leur décalage qui fait le verre.
        let quarter = Self.start + NovaGlassMotion.period / 4
        let sheets = NovaGlassMotion.pose(of: .sheets, at: quarter)
        let accents = NovaGlassMotion.pose(of: .accents, at: quarter)
        #expect(abs(sheets.angle - accents.angle) > NovaGlassMotion.maxAngle / 2)
    }

    @Test("D'une image à la suivante, un reflet ne saute pas")
    func motionIsSmooth() {
        let frame = HaloSphere.frameInterval
        for layer in NovaGlass.Layer.allCases {
            // Image par image, en passant deux fois le retour de la phase à zéro : c'est là qu'une
            // couture se verrait, pas ailleurs.
            var time = Self.start - 2
            var before = NovaGlassMotion.pose(of: layer, at: time - frame)
            var now = NovaGlassMotion.pose(of: layer, at: time)
            while time < Self.start + NovaGlassMotion.period + 2 {
                let next = NovaGlassMotion.pose(of: layer, at: time + frame)
                // Moins d'un demi-point d'écran au bord d'une sphère de 140 pt de rayon.
                #expect(abs(now.angle - next.angle) * 140 < 0.5, "angle à \(time - Self.start) s")
                #expect(abs(now.slide - next.slide) * 140 < 0.5, "glissement à \(time - Self.start) s")
                // Et il ne rebondit pas : sa vitesse non plus ne saute pas.
                #expect(abs(next.angle - 2 * now.angle + before.angle) * 140 < 0.05, "rebond à \(time - Self.start) s")
                #expect(abs(next.slide - 2 * now.slide + before.slide) * 140 < 0.05, "rebond à \(time - Self.start) s")
                before = now
                now = next
                time += frame
            }
        }
        // Le cycle se referme bien là où les tests le croient.
        #expect(NovaGlassMotion.phase(at: Self.start) < 1e-6)
    }

    @Test("À l'instant de repos, la nappe principale est à sa place de dessin")
    func stillPoseIsTheDrawing() {
        let pose = NovaGlassMotion.pose(of: .sheets, at: HaloSphere.stillTime)
        #expect(pose == NovaGlassMotion.Pose(angle: 0, slide: 0))
        #expect(NovaGlassMotion.transform(for: pose) == .identity)
    }

    @Test("Une couche glissée couvre toujours toute la bille")
    func layersCoverTheSphere() {
        for layer in NovaGlass.Layer.allCases {
            for time in Self.instants(step: 0.5) {
                let inverse = NovaGlassMotion.transform(for: NovaGlassMotion.pose(of: layer, at: time)).inverted()
                var step = 0
                while step < 72 {
                    let angle = 2 * Double.pi * Double(step) / 72
                    let local = CGPoint(x: cos(angle), y: sin(angle)).applying(inverse)
                    #expect(abs(local.x) <= NovaGlassTextures.layerExtent)
                    #expect(abs(local.y) <= NovaGlassTextures.layerExtent)
                    step += 1
                }
            }
        }
        // La borne tient par construction, pas par chance sur ces instants.
        #expect(NovaGlassTextures.layerExtent >= 1 + NovaGlassMotion.maxSlide)
    }

    // MARK: - Lisibilité du logo

    /// La luminance la plus forte derrière le logo, sur tout le cycle.
    private static func brightestBackdrop(veil: Double = 1) -> Double {
        let half = NovaGlass.glyphHalfSize
        var brightest = 0.0
        for time in instants(step: 0.5) {
            var row = -4
            while row <= 4 {
                var column = -4
                while column <= 4 {
                    let x = Double(half.width) * Double(column) / 4
                    let y = Double(half.height) * Double(row) / 4
                    brightest = max(brightest, NovaGlass.backdropLuminance(x: x, y: y, time: time, veil: veil))
                    column += 1
                }
                row += 1
            }
        }
        return brightest
    }

    @Test("Le logo blanc garde un contraste d'au moins 4,5 pour 1 à tout instant du cycle")
    func glyphStaysLegible() {
        let brightest = Self.brightestBackdrop()
        // Blanc sur un fond de luminance L : (1 + 0,05) / (L + 0,05).
        let contrast = 1.05 / (brightest + 0.05)
        #expect(contrast >= 4.5, "contraste \(contrast), luminance \(brightest)")
        // Voilée (son coupé), la bille est plus sombre encore.
        #expect(Self.brightestBackdrop(veil: HaloSphere.veiledShare) <= brightest)
    }

    @Test("Le cœur surexposé existe bien, mais hors du logo")
    func coreIsBrightOutsideTheGlyph() {
        // Sous le logo, plus bas sur la bille : la nappe y monte au blanc.
        var brightest = 0.0
        var y = 0.4
        while y < 0.95 {
            brightest = max(brightest, NovaGlass.backdropLuminance(x: 0, y: y, time: HaloSphere.stillTime))
            y += 0.01
        }
        #expect(brightest > 0.6)
        // Et le centre de la bille, lui, est noir : ce qui n'est pas éclairé ne luit pas.
        #expect(NovaGlass.backdropLuminance(x: 0, y: 0, time: HaloSphere.stillTime) < 0.02)
    }

    @Test("Le creux sous le logo est plein au centre, nul à son bord, et ne remonte jamais")
    func wellFadesOut() {
        #expect(abs(NovaGlass.wellAlpha(atShare: 0) - NovaGlass.wellDepth) < 1e-12)
        #expect(abs(NovaGlass.wellAlpha(atShare: NovaGlass.wellPlateau) - NovaGlass.wellDepth) < 1e-12)
        #expect(NovaGlass.wellAlpha(atShare: 1) == 0)
        #expect(NovaGlass.wellAlpha(atShare: 1.6) == 0)
        var previous = NovaGlass.wellAlpha(atShare: 0)
        var share = 0.05
        while share <= 1 {
            let alpha = NovaGlass.wellAlpha(atShare: share)
            #expect(alpha <= previous)
            previous = alpha
            share += 0.05
        }
        // Le creux déborde du logo : ses coins y sont encore.
        #expect(NovaGlass.wellAlpha(x: NovaGlass.glyphHalfSize.width, y: NovaGlass.glyphHalfSize.height) > 0)
        #expect(NovaGlass.wellAlpha(x: 1, y: 0) == 0)
    }

    // MARK: - Bord

    @Test("Le liseré n'existe qu'en haut à gauche")
    func lipIsUpperLeftOnly() {
        let edge = 0.986
        let diagonal = edge / 2.0.squareRoot()
        #expect(NovaGlass.rim(x: -diagonal, y: -diagonal).luminance > 0.8)
        #expect(NovaGlass.resting(x: -diagonal, y: -diagonal).luminance > 0.8)
        // À l'opposé, en haut à droite et en bas à gauche : plus de liseré.
        for (x, y) in [(diagonal, diagonal), (diagonal, -diagonal), (-diagonal, diagonal)] {
            #expect(NovaGlass.rim(x: x, y: y).luminance < 0.12)
            #expect(NovaGlass.resting(x: x, y: y).luminance < 0.05)
        }
        // Au repos, le verre est gris : aucune couleur.
        let grey = NovaGlass.resting(x: -0.6, y: -0.6)
        #expect(abs(grey.red - grey.blue) < 0.01 && abs(grey.red - grey.green) < 0.01)
    }

    // MARK: - Textures

    @Test("Une texture est cuite point par point, du coin haut gauche au coin bas droit")
    func bakeSamplesTheFunction() throws {
        let image = NovaGlassTextures.bake(side: 4, extent: 2) { x, y in
            NovaGlass.RGB(red: x < 0 ? 1 : 0, green: y < 0 ? 1 : 0, blue: 0.5)
        }
        #expect(image.width == 4 && image.height == 4)
        let data = try #require(image.dataProvider?.data as Data?)
        // Premier pixel : haut gauche, x et y négatifs.
        #expect(data[0] == 255 && data[1] == 255)
        #expect(data[2] == UInt8(NovaGlass.encode(0.5) * 255 + 0.5))
        // Dernier pixel : bas droit.
        let last = (4 * 4 - 1) * 4
        #expect(data[last] == 0 && data[last + 1] == 0)
        #expect(abs(NovaGlass.decode(NovaGlass.encode(0.3)) - 0.3) < 1e-9)
    }

    // MARK: - Anneau

    @Test("Le dégradé de l'arc a des arrêts croissants à tout niveau, et finit blanc à la pointe")
    func arcStopsAreOrdered() {
        var fraction = 0.0
        while fraction <= 1.0001 {
            let stops = HaloRingPaint.arcStops(fraction: min(fraction, 1))
            var previous = -1.0
            for stop in stops {
                #expect(stop.location >= previous)
                #expect(stop.location >= 0 && stop.location <= 1)
                previous = stop.location
            }
            #expect(stops.first?.location == 0 && stops.last?.location == 1)
            // La pointe est blanche, et le reste jusqu'au bout de son arrondi.
            let tip = stops.filter { $0.tone == 1 }
            #expect(tip.count == 2)
            #expect(abs((tip.first?.location ?? -1) - min(fraction, 1)) < 1e-12)
            // De part et d'autre du haut de l'anneau, la même couleur : l'arrondi de l'origine déborde.
            #expect(stops.first?.tone == stops.last?.tone)
            fraction += 0.01
        }
    }

    @Test("L'arc reste blanc ou presque : froid, jamais rose")
    func arcStaysWhite() {
        var tone = 0.0
        while tone <= 1 {
            let color = HaloRingPaint.bodyComponents(tone: tone)
            #expect(color.red >= 0.6 && color.green >= 0.75 && color.blue >= 0.85)
            // Un rose aurait plus de rouge que de vert.
            #expect(color.red <= color.green && color.green <= color.blue)
            tone += 0.1
        }
        let white = HaloRingPaint.bodyComponents(tone: 1)
        #expect(white.red == 1 && white.green == 1 && white.blue == 1)
    }

    @Test("Coupé, l'arc allumé s'éteint ; au repos, il se met en retrait")
    func litArcFollowsTheState() {
        #expect(HaloRingPaint.litOpacity(isMuted: true, isLive: true) == 0)
        #expect(HaloRingPaint.litOpacity(isMuted: true, isLive: false) == 0)
        #expect(HaloRingPaint.litOpacity(isMuted: false, isLive: true) == 1)
        let resting = HaloRingPaint.litOpacity(isMuted: false, isLive: false)
        #expect(resting > 0.4 && resting < 1)
    }

    @Test("La matière de l'anneau tient dans la place que la vue lui réserve")
    func ringPaintFitsItsOverhang() {
        #expect(HaloVolumeRing.lineWidth <= 7)
        #expect(HaloVolumeRing.lineWidth / 2 + HaloRingPaint.haloReach <= HaloMetrics.ringOverhang)
        // Le halo de l'arc ne déborde pas de la bande de saisie : il ne touche pas la sphère inspirée.
        #expect(HaloVolumeRing.lineWidth / 2 + HaloRingPaint.haloReach <= HaloVolumeRing.grabHalfWidth)
        #expect(HaloVolumeRing.knobDiameter / 2 * HaloVolumeRing.knobGrowth <= HaloMetrics.ringOverhang)
    }
}
