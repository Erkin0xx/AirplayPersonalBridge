import AppKit
import CoreGraphics
import Foundation
import QuartzCore
import Testing

@testable import BridgeApp

/// La recette du fond : bandes, rampe, nappe claire, mouvement, grain. Tout y est calcul pur, et
/// **hors du MainActor** : ces balayages de grille n'ont pas à retarder les suites qui s'y partagent le
/// temps (`CLAUDE.md`, « Aucun plafond de temps serré sur ce qui reprend sur le MainActor »).
@Suite("Fond — recette et mouvement")
nonisolated struct GrainientBackgroundTests {
    private typealias Field = GrainientField

    /// Les proportions des deux tailles de fenêtre rendues, et deux extrêmes.
    private static let aspects: [Double] = [960.0 / 620, 1200.0 / 760, 1.0, 2.4]

    /// Une grille de points de la vue, bords compris.
    private static func grid(_ steps: Int = 24) -> [(x: Double, y: Double)] {
        var points: [(x: Double, y: Double)] = []
        for row in 0...steps {
            for column in 0...steps {
                points.append((Double(column) / Double(steps), Double(row) / Double(steps)))
            }
        }
        return points
    }

    private static func isClose(_ a: Field.RGB, _ b: Field.RGB, tolerance: Double = 1e-9) -> Bool {
        abs(a.red - b.red) <= tolerance && abs(a.green - b.green) <= tolerance
            && abs(a.blue - b.blue) <= tolerance
    }

    // MARK: - Mouvement

    @Test("Le fond revient exactement à lui-même à chaque période : aucune couture")
    func cycleIsSeamless() {
        for time in [0.0, 3.7, 13.5, 26.9, 41.2, Field.period - 0.01] {
            let now = Field.phase(at: time)
            let later = Field.phase(at: time + Field.period)
            for point in Self.grid(8) {
                let a = Field.color(x: point.x, y: point.y, aspect: 1.58, phase: now, gain: Field.liveGain)
                let b = Field.color(x: point.x, y: point.y, aspect: 1.58, phase: later, gain: Field.liveGain)
                #expect(Self.isClose(a, b, tolerance: 1e-6))
            }
        }
        // Et la recette elle-même est périodique en phase : la dernière image-clé rejoint la première.
        for point in Self.grid(8) {
            let start = Field.color(x: point.x, y: point.y, aspect: 1.58, phase: 0, gain: 1)
            let end = Field.color(x: point.x, y: point.y, aspect: 1.58, phase: 2 * .pi, gain: 1)
            #expect(Self.isClose(start, end))
        }
    }

    @Test("La phase reste entre 0 et 2π, avance avec le temps, et accepte un instant négatif")
    func phaseIsBounded() {
        #expect(Field.phase(at: 0) == 0)
        #expect(abs(Field.phase(at: Field.period / 4) - .pi / 2) < 1e-12)
        for time in [-1000.0, -0.1, 0, 1, Field.period - 0.001, Field.period, 1e6] {
            let phase = Field.phase(at: time)
            #expect(phase >= 0 && phase < 2 * .pi)
        }
        #expect(abs(Field.phase(at: -Field.period / 4) - 1.5 * .pi) < 1e-12)
        #expect(Field.period >= 30)
    }

    @Test("Les images-clés se partagent le cycle à parts égales, et le rang final retombe sur le premier")
    func keyframePhases() {
        #expect(Field.keyframePhase(0) == 0)
        #expect(Field.keyframePhase(Field.keyframeCount) == 0)
        #expect(abs(Field.keyframePhase(Field.keyframeCount / 2) - .pi) < 1e-12)
        let step = Field.keyframePhase(1)
        for index in 1..<Field.keyframeCount {
            #expect(abs(Field.keyframePhase(index) - Field.keyframePhase(index - 1) - step) < 1e-12)
        }
    }

    @Test("Les bandes ne s'écartent jamais de leur place de plus que leurs ondulations et leur balancement")
    func bandWarpIsBounded() {
        for aspect in Self.aspects {
            for index in 0..<Field.keyframeCount {
                let phase = Field.keyframePhase(index)
                #expect(abs(Field.slope(phase: phase) - Field.slope) <= Field.slopeSway + 1e-12)
                for point in Self.grid(12) {
                    let band = Field.band(x: point.x, y: point.y, aspect: aspect, phase: phase)
                    let limit = Field.slowWarp + Field.fineWarp + Field.slopeSway * point.y + 1e-12
                    #expect(abs(band - (point.x + Field.slope * point.y)) <= limit)
                }
            }
        }
        // Les bandes restent penchées du même côté, sans jamais se coucher.
        #expect(Field.slope - Field.slopeSway >= 0.2)
        #expect(Field.slope + Field.slopeSway <= 0.4)
        // Et elles bougent bien : la même bande, un quart de cycle plus tard, n'est plus au même endroit.
        let before = Field.band(x: 0.4, y: 0.3, aspect: 1.58, phase: 0)
        let after = Field.band(x: 0.4, y: 0.3, aspect: 1.58, phase: .pi / 2)
        #expect(abs(before - after) > 0.01)
    }

    @Test("La nappe claire dérive sur un petit cercle autour de sa place, sous le coin bas droit")
    func poolDriftIsBounded() {
        for aspect in Self.aspects {
            for index in 0..<Field.keyframeCount {
                let center = Field.poolCenter(aspect: aspect, phase: Field.keyframePhase(index))
                let drift = hypot(center.x - 1.02 * aspect, center.y - 1.55)
                #expect(abs(drift - Field.poolDrift) < 1e-12)
            }
        }
        // Et elle respire : son rayon enfle et se retire autour de sa valeur, sans s'en éloigner.
        var widest = -Double.infinity
        var narrowest = Double.infinity
        for index in 0..<Field.keyframeCount {
            let radius = Field.poolRadius(phase: Field.keyframePhase(index))
            widest = max(widest, radius)
            narrowest = min(narrowest, radius)
        }
        #expect(abs(widest - (Field.poolRadius + Field.poolBreath)) < 1e-3)
        #expect(abs(narrowest - (Field.poolRadius - Field.poolBreath)) < 1e-3)
        // C'est bien ce rayon qui borne la nappe : à 0,9 hauteur de son centre, la profondeur le suit.
        for phase in [Double.pi / 2 - 0.9, 1.5 * Double.pi - 0.9] {
            let center = Field.poolCenter(aspect: 1.6, phase: phase)
            let depth = Field.poolDepth(x: (center.x - 0.9) / 1.6, y: center.y, aspect: 1.6, phase: phase)
            #expect(abs(depth - (Field.poolRadius(phase: phase) - 0.9) / Field.poolFalloff) < 1e-9)
        }
        #expect(Field.poolBreath > 0.02)
    }

    /// Le déplacement le plus grand d'une bande entre deux images-clés voisines, en fraction de la largeur.
    private static func widestKeyframeStep(aspect: Double) -> Double {
        var widest = 0.0
        for index in 0..<Field.keyframeCount {
            let now = Field.keyframePhase(index)
            let next = Field.keyframePhase(index + 1)
            for point in grid() {
                let a = Field.band(x: point.x, y: point.y, aspect: aspect, phase: now)
                let b = Field.band(x: point.x, y: point.y, aspect: aspect, phase: next)
                widest = max(widest, abs(a - b))
            }
        }
        return widest
    }

    @Test("Entre deux images-clés, aucune bande ne bouge de plus de 15 points d'une fenêtre de 1200")
    func keyframeStepStaysSmall() {
        for aspect in Self.aspects {
            // Un fondu entre deux images décalées de davantage dédoublerait le filet violet.
            #expect(Self.widestKeyframeStep(aspect: aspect) * 1200 <= 15)
        }
        // La nappe, elle, bouge moins encore : dérive et respiration, en points d'une fenêtre de 760 de haut.
        let turn = 2 * Double.pi / Double(Field.keyframeCount)
        #expect((Field.poolDrift + Field.poolBreath) * turn * 760 <= 8)
    }

    @Test("Le mouvement se remarque : en cinq secondes, une bande avance de plusieurs dizaines de points")
    func motionIsNoticeable() {
        let aspect = 1200.0 / 760
        // Le chemin d'une bande sur un cycle, au milieu de la fenêtre : d'un extrême à l'autre.
        var low = Double.infinity
        var high = -Double.infinity
        for index in 0..<Field.keyframeCount {
            let band = Field.band(x: 0.4, y: 0.5, aspect: aspect, phase: Field.keyframePhase(index))
            low = min(low, band)
            high = max(high, band)
        }
        #expect((high - low) * 1200 >= 200)
        #expect((high - low) * 1200 <= 400)

        // En cinq secondes, à n'importe quel moment du cycle : la part de l'image qui a changé d'au moins
        // 6 niveaux sur 255, ce qu'on voit sans chercher : la moitié au moins, mesurée à 51 % au pire.
        var smallest = 1.0
        for start in stride(from: 0.0, to: Field.period, by: 3) {
            let before = Field.pixels(
                width: 80, height: 50, aspect: aspect, phase: Field.phase(at: start), gain: Field.liveGain
            )
            let after = Field.pixels(
                width: 80, height: 50, aspect: aspect, phase: Field.phase(at: start + 5), gain: Field.liveGain
            )
            var changed = 0
            var pixel = 0
            while pixel < before.count {
                let gap = max(
                    abs(Int(before[pixel]) - Int(after[pixel])), abs(Int(before[pixel + 1]) - Int(after[pixel + 1])),
                    abs(Int(before[pixel + 2]) - Int(after[pixel + 2]))
                )
                if gap >= 6 { changed += 1 }
                pixel += 4
            }
            smallest = min(smallest, Double(changed) / Double(before.count / 4))
        }
        #expect(smallest >= 0.30)
        // Baptiste l'a voulu « plus doucement » le 2026-11-11 : un cycle d'une minute environ.
        #expect(Field.period >= 50 && Field.period <= 70)
    }

    @Test("Le fond bouge tout le temps, au repos comme en diffusion, et jamais sous « Réduire les animations »")
    func animationRule() {
        #expect(Field.isAnimated(isLive: true, reduceMotion: false))
        #expect(Field.isAnimated(isLive: false, reduceMotion: false))
        #expect(!Field.isAnimated(isLive: true, reduceMotion: true))
        #expect(!Field.isAnimated(isLive: false, reduceMotion: true))
    }

    // MARK: - Couleurs

    @Test("La rampe rend ses couleurs à leurs positions, s'arrête à ses bouts, et mélange en lumière linéaire")
    func rampStops() {
        #expect(Field.color(in: Field.ramp, at: 0) == Field.RGB(hex: 0xF5A26F))
        #expect(Self.isClose(Field.color(in: Field.ramp, at: 0.32), Field.RGB(hex: 0xDF3880), tolerance: 1e-12))
        #expect(Field.color(in: Field.ramp, at: 1) == Field.RGB(hex: 0x08090C))
        #expect(Field.color(in: Field.ramp, at: -3) == Field.RGB(hex: 0xF5A26F))
        #expect(Field.color(in: Field.ramp, at: 7) == Field.RGB(hex: 0x08090C))
        #expect(Self.isClose(Field.color(in: Field.pool, at: 0.42), Field.RGB(hex: 0x2F56C8), tolerance: 1e-12))

        // À mi-chemin de deux arrêts : la moyenne des lumières, pas celle des codes sRGB.
        let low = Field.RGB(hex: 0xDF3880)
        let high = Field.RGB(hex: 0xB3246F)
        let middle = Field.color(in: Field.ramp, at: 0.37)
        #expect(abs(middle.red - (low.red + high.red) / 2) < 1e-12)
        #expect(abs(middle.blue - (low.blue + high.blue) / 2) < 1e-12)
        let gammaAverage = Field.linear(fromSRGB: (Double(0xDF) + Double(0xB3)) / 2 / 255)
        #expect(abs(middle.red - gammaAverage) > 1e-3)
    }

    @Test("La rampe porte le filet clair de la référence : un creux, une remontée, puis le noir")
    func rampHasItsBrightThread() {
        let dip = Field.color(in: Field.ramp, at: 0.50).luminance
        let thread = Field.color(in: Field.ramp, at: 0.56).luminance
        let after = Field.color(in: Field.ramp, at: 0.62).luminance
        #expect(thread > dip * 1.5)
        #expect(thread > after * 1.5)
        #expect(Field.color(in: Field.ramp, at: 0.84).luminance < 0.004)
    }

    @Test("sRGB et lumière linéaire se répondent, aux bornes comme au milieu")
    func transferRoundTrip() {
        for value in [0.0, 0.002, 0.04, 0.2, 0.5, 0.9, 1.0] {
            #expect(abs(Field.srgb(fromLinear: Field.linear(fromSRGB: value)) - value) < 1e-9)
        }
        #expect(Field.srgb(fromLinear: -1) == 0)
        #expect(abs(Field.srgb(fromLinear: 4) - 1) < 1e-12)
    }

    @Test("La nappe claire occupe le coin bas droit, et lui seul")
    func poolSitsInTheLowerRightCorner() {
        for aspect in Self.aspects {
            for index in 0..<Field.keyframeCount {
                let phase = Field.keyframePhase(index)
                // Au plus loin de sa dérive et au plus étroit de sa respiration, elle tient encore le coin.
                #expect(Field.poolDepth(x: 1, y: 1, aspect: aspect, phase: phase) > 0.75)
                #expect(Field.poolDepth(x: 0, y: 0, aspect: aspect, phase: phase) == 0)
                #expect(Field.poolDepth(x: 1, y: 0, aspect: aspect, phase: phase) == 0)
                #expect(Field.poolDepth(x: 0.4, y: 0.3, aspect: aspect, phase: phase) == 0)
            }
        }
        #expect(Field.poolCover(depth: 0) == 0)
        #expect(Field.poolCover(depth: 0.45) == 1)
        #expect(Field.poolCover(depth: 1) == 1)
        #expect(abs(Field.poolCover(depth: 0.225) - 0.5) < 1e-12)
    }

    @Test("Aux points clés : chaud à gauche, noir en haut à droite, bleu clair en bas à droite")
    func keyPoints() {
        for aspect in Self.aspects {
            for index in 0..<Field.keyframeCount {
                let phase = Field.keyframePhase(index)
                let left = Field.color(x: 0.02, y: 0.3, aspect: aspect, phase: phase, gain: 1)
                #expect(left.red > left.blue * 2)
                let topRight = Field.color(x: 0.95, y: 0.08, aspect: aspect, phase: phase, gain: 1)
                #expect(topRight.luminance < 0.004)
                let corner = Field.color(x: 0.99, y: 0.99, aspect: aspect, phase: phase, gain: 1)
                #expect(corner.blue > corner.red)
                #expect(corner.luminance > 0.25)
            }
        }
    }

    @Test("Un texte blanc garde un contraste de 4,5 au moins partout sur le fond, à tout instant")
    func whiteTextStaysReadable() {
        var worst = Double.infinity
        for aspect in Self.aspects {
            for index in 0..<Field.keyframeCount {
                for point in Self.grid() {
                    let color = Field.color(
                        x: point.x, y: point.y, aspect: aspect, phase: Field.keyframePhase(index),
                        gain: Field.liveGain
                    )
                    worst = min(worst, color.contrastWithWhite)
                    #expect(color.red >= 0 && color.red <= 1)
                    #expect(color.green >= 0 && color.green <= 1)
                    #expect(color.blue >= 0 && color.blue <= 1)
                }
            }
        }
        #expect(worst >= 4.5)
        // Là où un texte est posé à nu (« Diffusion vers 3 enceintes », « Rechercher des enceintes ») :
        // bien davantage.
        for index in 0..<Field.keyframeCount {
            for point in [(0.5, 0.75), (0.5, 0.80), (0.38, 0.75), (0.62, 0.80), (0.73, 0.74)] {
                let color = Field.color(
                    x: point.0, y: point.1, aspect: 1200.0 / 760, phase: Field.keyframePhase(index),
                    gain: Field.liveGain
                )
                #expect(color.contrastWithWhite >= 7)
            }
        }
    }

    @Test("Au repos le fond garde les mêmes couleurs, bien plus sombres")
    func restIsADimmerTrace() {
        #expect(Field.restGain < Field.liveGain / 3)
        #expect(Field.restGain > 0)
        let live = Field.color(x: 0.1, y: 0.5, aspect: 1.58, phase: 0, gain: Field.liveGain)
        let rest = Field.color(x: 0.1, y: 0.5, aspect: 1.58, phase: 0, gain: Field.restGain)
        let ratio = Field.restGain / Field.liveGain
        #expect(Self.isClose(rest, live.scaled(by: ratio)))
    }

    // MARK: - Images

    @Test("Une image-clé a la taille prévue, est opaque, et se répète à l'octet près")
    func keyframeImage() throws {
        let bytes = Field.pixels(width: 16, height: 10, aspect: 1.6, phase: 1, gain: Field.liveGain)
        #expect(bytes.count == 16 * 10 * 4)
        #expect(bytes == Field.pixels(width: 16, height: 10, aspect: 1.6, phase: 1, gain: Field.liveGain))
        #expect(bytes != Field.pixels(width: 16, height: 10, aspect: 1.6, phase: 2, gain: Field.liveGain))
        #expect(bytes == Field.pixels(width: 16, height: 10, aspect: 1.6, phase: 1 + 2 * .pi, gain: Field.liveGain))
        #expect(Field.pixels(width: 0, height: 10, aspect: 1.6, phase: 0, gain: 1).isEmpty)

        let image = try #require(Field.image(aspect: 1.6, phase: 0, gain: Field.liveGain))
        #expect(image.width == Field.pixelWidth)
        #expect(image.height == Field.pixelHeight)
        #expect(image.alphaInfo == .noneSkipLast)
    }

    @Test("Les proportions sont arrondies au vingtième et bornées, sans division par zéro")
    func aspectIsQuantized() {
        #expect(Field.quantizedAspect(width: 1200, height: 760) == 1.6)
        #expect(Field.quantizedAspect(width: 1201, height: 760) == 1.6)
        #expect(Field.quantizedAspect(width: 960, height: 620) == 1.55)
        #expect(Field.quantizedAspect(width: 0, height: 0) == 1.6)
        #expect(Field.quantizedAspect(width: 100, height: 0) == 1.6)
        #expect(Field.quantizedAspect(width: 10_000, height: 10) == 4)
        #expect(Field.quantizedAspect(width: 10, height: 10_000) == 0.5)
    }

    // MARK: - Grain

    @Test("Le grain est fixe, monochrome, à moyenne nulle, et ne dépasse jamais son amplitude")
    func grain() throws {
        let noise = Field.grainNoise()
        #expect(noise.count == 256 * 256)
        #expect(noise == Field.grainNoise())
        let mean = noise.reduce(0, +) / Double(noise.count)
        #expect(abs(mean) < 0.01)
        #expect(noise.allSatisfy { $0 >= -1 && $0 <= 1 })
        // Du relief, pas un aplat : l'écart type d'une loi en triangle est 1/√6.
        let deviation = (noise.reduce(0) { $0 + $1 * $1 } / Double(noise.count)).squareRoot()
        #expect(abs(deviation - 1 / 6.0.squareRoot()) < 0.01)

        let bytes = Field.grainPixels()
        let ceiling = UInt8((Field.grainAmplitude * 255).rounded())
        var index = 0
        while index < bytes.count {
            #expect(bytes[index] == bytes[index + 1] && bytes[index] == bytes[index + 2])
            // Prémultiplié : du blanc (valeur = alpha) ou du noir (valeur nulle).
            #expect(bytes[index] == 0 || bytes[index] == bytes[index + 3])
            #expect(bytes[index + 3] <= ceiling)
            index += 4
        }
        #expect(Field.grainAmplitude >= 0.03 && Field.grainAmplitude <= 0.09)

        let tile = try #require(Field.grainImage())
        #expect(tile.width == 256)
        #expect(tile.height == 256)
    }

    @Test("Un cycle compte toutes ses images-clés, à la taille demandée")
    func keyframes() {
        let frames = Field.keyframes(aspect: 1.6, width: 8, height: 5)
        #expect(frames.count == Field.keyframeCount)
        #expect(frames.allSatisfy { $0.width == 8 && $0.height == 5 })
    }

}

/// Le calque animé, vérifié sans fenêtre sur ce qu'il confie à Core Animation.
@Suite("Fond — calque animé")
struct GrainientMotionLayerTests {
    /// De toutes petites images : c'est l'animation qu'on vérifie, et le MainActor n'attend pas.
    private static func motion(aspect: Double = 1.6) -> GrainientMotion {
        GrainientMotion(aspect: aspect, frames: GrainientField.keyframes(aspect: aspect, width: 8, height: 5))
    }

    @Test("Le calque confie tout le cycle à Core Animation : un fondu linéaire, sans fin, sans couture")
    func layerLoopsSeamlessly() throws {
        let view = GrainientMotionView(frame: CGRect(x: 0, y: 0, width: 320, height: 200))
        let motion = Self.motion()
        #expect(motion.frames.count == GrainientField.keyframeCount)
        view.show(motion)

        let animation = try #require(
            view.stage.animation(forKey: GrainientMotionView.animationKey) as? CAKeyframeAnimation
        )
        #expect(animation.keyPath == "contents")
        #expect(animation.calculationMode == .linear)
        #expect(animation.duration == GrainientField.period)
        #expect(animation.repeatCount == .infinity)
        let values = try #require(animation.values)
        #expect(values.count == GrainientField.keyframeCount + 1)
        // La dernière image est la première : la boucle se referme sur elle-même.
        #expect((values.first as AnyObject?) === (values.last as AnyObject?))
        #expect((values.first as AnyObject?) === motion.frames[0])
        #expect((view.stage.contents as AnyObject?) === motion.frames[0])
        // Le serveur de rendu n'a pas à suivre le rythme de l'écran.
        #expect(animation.preferredFrameRateRange.maximum <= 30)
        #expect(view.hitTest(CGPoint(x: 10, y: 10)) == nil)
    }

    @Test("Les mêmes proportions ne relancent rien ; d'autres reprennent le cycle à la même phase")
    func layerKeepsItsPhase() throws {
        let view = GrainientMotionView(frame: CGRect(x: 0, y: 0, width: 320, height: 200))
        view.show(Self.motion())
        let first = try #require(view.stage.animation(forKey: GrainientMotionView.animationKey))
        view.show(Self.motion())
        let same = try #require(view.stage.animation(forKey: GrainientMotionView.animationKey))
        #expect(same.beginTime == first.beginTime)
        #expect((same as? CAKeyframeAnimation)?.values?.first as AnyObject? === (first as? CAKeyframeAnimation)?.values?.first as AnyObject?)

        let wider = Self.motion(aspect: 2)
        view.show(wider)
        let replaced = try #require(
            view.stage.animation(forKey: GrainientMotionView.animationKey) as? CAKeyframeAnimation
        )
        #expect((replaced.values?.first as AnyObject?) === wider.frames[0])
        #expect(replaced.beginTime == first.beginTime)
    }

    @Test("En pause le calque se fige où il en est, et repart de là")
    func layerPauses() async throws {
        let view = GrainientMotionView(frame: CGRect(x: 0, y: 0, width: 320, height: 200))
        view.show(Self.motion())
        #expect(view.stage.speed == 1)

        view.isPaused = true
        #expect(view.stage.speed == 0)
        let frozen = view.stage.convertTime(CACurrentMediaTime(), from: nil)
        #expect(view.stage.convertTime(CACurrentMediaTime() + 5, from: nil) == frozen)

        // Une vraie pause d'une seconde : sans elle, repartir de l'instant figé ou de l'instant présent
        // reviendrait au même. Les deux lectures qui suivent se font d'une traite, sans suspension.
        try await Task.sleep(for: .seconds(1))
        #expect(view.stage.convertTime(CACurrentMediaTime(), from: nil) == frozen)

        view.isPaused = false
        #expect(view.stage.speed == 1)
        // L'horloge du calque repart de l'instant figé, pas de celui qu'il aurait atteint sans pause.
        let resumed = view.stage.convertTime(CACurrentMediaTime(), from: nil)
        #expect(resumed >= frozen - 1e-6)
        #expect(resumed - frozen < 0.5)
        #expect(view.stage.animation(forKey: GrainientMotionView.animationKey) != nil)
    }

    @Test("Un calque qui a perdu son animation à l'arrière-plan la retrouve au retour, à la même phase")
    func layerRecoversItsAnimationOnResume() throws {
        let view = GrainientMotionView(frame: CGRect(x: 0, y: 0, width: 320, height: 200))
        view.show(Self.motion())
        let first = try #require(view.stage.animation(forKey: GrainientMotionView.animationKey))

        view.isPaused = true
        // Ce que ferait Core Animation en sortant le calque de l'arbre de rendu.
        view.stage.removeAllAnimations()
        #expect(view.stage.animation(forKey: GrainientMotionView.animationKey) == nil)

        view.isPaused = false
        let back = try #require(
            view.stage.animation(forKey: GrainientMotionView.animationKey) as? CAKeyframeAnimation
        )
        #expect(back.beginTime == first.beginTime)
        #expect(back.values?.count == GrainientField.keyframeCount + 1)
        #expect(view.stage.speed == 1)
    }
}
