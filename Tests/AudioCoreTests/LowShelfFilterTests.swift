import Foundation
import Testing

@testable import AudioCore

/// Le renfort de basses est mesuré comme on le mesurerait au banc : on envoie des sinusoïdes
/// et on lit ce qui sort, plutôt que de vérifier les coefficients contre eux-mêmes.
@Suite("Renfort de basses")
struct LowShelfFilterTests {
    private static let sampleRate = 48_000.0

    private func sine(
        hz: Double, amplitude: Double = 0.1, frames: Int, sampleRate: Double = sampleRate,
        channels: Int = 2
    ) -> [Float] {
        var samples = [Float](repeating: 0, count: frames * channels)
        for frame in 0..<frames {
            let value = Float(amplitude * sin(2 * .pi * hz * Double(frame) / sampleRate))
            for channel in 0..<channels { samples[frame * channels + channel] = value }
        }
        return samples
    }

    private func run(_ filter: inout LowShelfFilter, _ samples: inout [Float]) {
        let frames = samples.count / filter.channelCount
        samples.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            filter.process(base, frameCount: frames)
        }
    }

    private func rms(_ samples: ArraySlice<Float>) -> Double {
        let energy = samples.reduce(0.0) { $0 + Double($1) * Double($1) }
        return (energy / Double(samples.count)).squareRoot()
    }

    /// Gain mesuré à une fréquence, une fois le régime établi.
    private func measuredGain(
        hz: Double, gain: Double, sampleRate: Double = sampleRate
    ) -> Double {
        var filter = LowShelfFilter(sampleRate: sampleRate, channelCount: 2)
        filter.setGain(decibels: gain)
        let frames = Int(sampleRate)  // 1 s : largement de quoi passer rampe et transitoire
        let input = sine(hz: hz, frames: frames, sampleRate: sampleRate)
        var output = input
        run(&filter, &output)
        let settled = frames  // la seconde moitié, en échantillons (2 canaux)
        return 20 * log10(rms(output[settled...]) / rms(input[settled...]))
    }

    @Test("La réponse vaut environ +G à 40 Hz et 0 dB à 2 kHz, quelle que soit la fréquence")
    func measuredResponse() {
        for sampleRate in [44_100.0, 48_000.0, 96_000.0] {
            for gain in [3.0, 6.0, 12.0] {
                let bass = measuredGain(hz: 40, gain: gain, sampleRate: sampleRate)
                let treble = measuredGain(hz: 2_000, gain: gain, sampleRate: sampleRate)
                // Un octave sous la charnière, le plateau n'est pas tout à fait atteint : on
                // tolère 1 dB d'écart, mesuré à 0,86 dB au pire pour +12 dB.
                #expect(abs(bass - gain) < 1.0, "\(sampleRate) Hz, +\(gain) dB : \(bass) dB à 40 Hz")
                #expect(abs(treble) < 0.1, "\(sampleRate) Hz, +\(gain) dB : \(treble) dB à 2 kHz")
            }
        }
    }

    @Test("À 0 dB le flux ressort identique au bit près, valeurs hors échelle comprises")
    func transparentAtZero() {
        var filter = LowShelfFilter(sampleRate: Self.sampleRate, channelCount: 2)
        filter.setGain(decibels: 0)
        #expect(filter.isTransparent)

        var generator = SystemRandomNumberGenerator()
        var samples = (0..<96_000).map { _ in Float.random(in: -1.5...1.5, using: &generator) }
        samples[10] = .leastNonzeroMagnitude
        samples[11] = -0.0
        let original = samples.map(\.bitPattern)
        run(&filter, &samples)
        #expect(samples.map(\.bitPattern) == original)
    }

    @Test("Après un retour à 0 dB, le contournement reprend et redevient bit à bit")
    func backToTransparent() {
        var filter = LowShelfFilter(sampleRate: Self.sampleRate, channelCount: 2)
        filter.setGain(decibels: 6)
        var warm = sine(hz: 40, frames: 48_000)
        run(&filter, &warm)
        #expect(!filter.isTransparent)

        filter.setGain(decibels: 0)
        var tail = sine(hz: 40, frames: 96_000)
        run(&filter, &tail)
        #expect(filter.isTransparent, "la queue du filtre doit s'être éteinte")

        var samples = sine(hz: 40, frames: 4_800)
        let original = samples.map(\.bitPattern)
        run(&filter, &samples)
        #expect(samples.map(\.bitPattern) == original)
    }

    @Test("Aucune sortie hors de [−1 ; 1], même sur une onde carrée pleine échelle à +12 dB")
    func neverClips() {
        var filter = LowShelfFilter(sampleRate: Self.sampleRate, channelCount: 2)
        filter.setGain(decibels: 12)

        // Pire cas : une onde carrée en plein grave, qui fait exploser le filtre, suivie d'une
        // sinusoïde pleine échelle et d'un bruit qui dépasse déjà l'échelle à l'entrée.
        var samples = [Float](repeating: 0, count: 288_000)
        var generator = SystemRandomNumberGenerator()
        for index in stride(from: 0, to: samples.count, by: 2) {
            let frame = index / 2
            let value: Float
            switch frame {
            case ..<48_000: value = (frame / 300) % 2 == 0 ? 1 : -1
            case ..<96_000: value = Float(sin(2 * .pi * 40 * Double(frame) / Self.sampleRate))
            default: value = Float.random(in: -1.5...1.5, using: &generator)
            }
            samples[index] = value
            samples[index + 1] = -value
        }
        run(&filter, &samples)
        let peak = samples.map { abs($0) }.max() ?? 0
        #expect(peak <= 1, "crête \(peak)")
        #expect(peak > 0.9, "le limiteur ne doit pas écraser le signal : crête \(peak)")
    }

    @Test("Sans dépassement, le limiteur n'intervient pas")
    func limiterStaysOutOfTheWay() {
        // +6 dB sur une sinusoïde à 0,1 : la crête reste très loin du plafond. Le gain mesuré
        // ne doit donc rien devoir au limiteur, et l'onde garde sa forme.
        let gain = measuredGain(hz: 40, gain: 6)
        #expect(abs(gain - 5.6) < 0.3, "gain mesuré \(gain) dB")
    }

    @Test("Monter le curseur en pleine lecture ne produit aucun clic")
    func gainChangeIsClickFree() {
        var filter = LowShelfFilter(sampleRate: Self.sampleRate, channelCount: 2)
        let settle = 48_000
        var first = sine(hz: 40, amplitude: 0.2, frames: settle)
        run(&filter, &first)

        // Bond du curseur : 0 à +12 dB d'un coup.
        filter.setGain(decibels: 12)
        let during = 24_000
        var transition = [Float](repeating: 0, count: during * 2)
        for frame in 0..<during {
            let value = Float(
                0.2 * sin(2 * .pi * 40 * Double(frame + settle) / Self.sampleRate)
            )
            transition[frame * 2] = value
            transition[frame * 2 + 1] = value
        }
        run(&filter, &transition)

        // Un clic est un saut d'un échantillon au suivant. La plus grande pente légitime est
        // celle de la sinusoïde au gain final : 2π·40/48 000 × 0,2 × 3,6 ≈ 0,0038.
        var largestStep: Float = 0
        for frame in 1..<during {
            largestStep = max(largestStep, abs(transition[frame * 2] - transition[(frame - 1) * 2]))
        }
        #expect(largestStep < 0.006, "saut de \(largestStep) entre deux échantillons")

        // Et le gain ne doit pas être passé d'un coup : à mi-rampe, on n'y est pas encore.
        var midRamp = LowShelfFilter(sampleRate: Self.sampleRate, channelCount: 1)
        midRamp.setGain(decibels: 12)
        var short = [Float](repeating: 0, count: 960)  // 20 ms, soit 40 % de la rampe
        run(&midRamp, &short)
        #expect(midRamp.coefficients.b0 != LowShelfFilter.coefficients(
            gainDecibels: 12, cornerHz: 80, q: 0.7, sampleRate: Self.sampleRate
        ).b0)
    }

    @Test("Le filtre n'introduit aucun décalage de trame, et un retard de groupe documenté")
    func noFrameDelay() {
        // Causalité : la toute première sortie porte déjà la toute première entrée.
        var impulseFilter = LowShelfFilter(sampleRate: Self.sampleRate, channelCount: 1)
        impulseFilter.setGain(decibels: 12)
        impulseFilter.reset()
        var impulse = [Float](repeating: 0, count: 64)
        impulse[0] = 0.5
        run(&impulseFilter, &impulse)
        #expect(abs(impulse[0]) > 0.4, "aucune latence de bloc : \(impulse[0])")

        // Retard de groupe calculé sur la fonction de transfert. Ce sont les chiffres annoncés
        // dans la documentation du filtre : s'ils bougent, la documentation ment.
        let coefficients = LowShelfFilter.coefficients(
            gainDecibels: 12, cornerHz: 80, q: 0.7, sampleRate: Self.sampleRate
        )
        func phase(_ hz: Double) -> Double {
            let w = 2 * Double.pi * hz / Self.sampleRate
            let numerator = (
                coefficients.b0 + coefficients.b1 * cos(w) + coefficients.b2 * cos(2 * w),
                -coefficients.b1 * sin(w) - coefficients.b2 * sin(2 * w)
            )
            let denominator = (
                1 + coefficients.a1 * cos(w) + coefficients.a2 * cos(2 * w),
                -coefficients.a1 * sin(w) - coefficients.a2 * sin(2 * w)
            )
            return atan2(numerator.1, numerator.0) - atan2(denominator.1, denominator.0)
        }
        func groupDelayMilliseconds(_ hz: Double) -> Double {
            let delta = 0.01
            let slope = (phase(hz + delta) - phase(hz - delta)) / (2 * delta)
            return -slope / (2 * .pi) * 1_000
        }
        #expect(abs(groupDelayMilliseconds(40) - 2.5) < 0.2, "\(groupDelayMilliseconds(40)) ms à 40 Hz")
        #expect(abs(groupDelayMilliseconds(80)) < 0.1, "\(groupDelayMilliseconds(80)) ms à 80 Hz")
        #expect(abs(groupDelayMilliseconds(120) + 0.8) < 0.1, "\(groupDelayMilliseconds(120)) ms à 120 Hz")
        let oneSample = 1_000 / Self.sampleRate
        #expect(abs(groupDelayMilliseconds(1_000)) < oneSample, "\(groupDelayMilliseconds(1_000)) ms à 1 kHz")
    }

    @Test("Chaque canal garde son propre état : un signal à gauche ne fuit pas à droite")
    func channelsAreIndependent() {
        var filter = LowShelfFilter(sampleRate: Self.sampleRate, channelCount: 2)
        filter.setGain(decibels: 12)
        var samples = [Float](repeating: 0, count: 48_000 * 2)
        for frame in 0..<48_000 {
            samples[frame * 2] = Float(0.1 * sin(2 * .pi * 40 * Double(frame) / Self.sampleRate))
        }
        run(&filter, &samples)
        for frame in 0..<48_000 {
            #expect(samples[frame * 2 + 1] == 0)
        }
    }

    @Test("Une valeur non finie à l'entrée ne contamine pas le filtre")
    func nonFiniteInputIsContained() {
        var filter = LowShelfFilter(sampleRate: Self.sampleRate, channelCount: 1)
        filter.setGain(decibels: 12)
        var samples = sine(hz: 40, frames: 4_800, channels: 1)
        samples[100] = .nan
        samples[101] = .infinity
        run(&filter, &samples)
        #expect(samples.allSatisfy { $0.isFinite })
        #expect(rms(samples[4_000...]) > 0.05, "le signal doit continuer de passer")
    }

    @Test("La consigne reste dans les bornes du curseur")
    func gainIsClamped() {
        var filter = LowShelfFilter(sampleRate: Self.sampleRate, channelCount: 1)
        filter.setGain(decibels: 40)
        #expect(filter.gainDecibels == 12)
        filter.setGain(decibels: -6)
        #expect(filter.gainDecibels == 0)
        filter.setGain(decibels: 6)
        filter.setGain(decibels: .nan)
        #expect(filter.gainDecibels == 0)
    }

    @Test("reset oublie la queue et le limiteur, sans toucher à la consigne")
    func resetForgetsHistory() {
        var filter = LowShelfFilter(sampleRate: Self.sampleRate, channelCount: 1)
        filter.setGain(decibels: 12)
        var loud = sine(hz: 40, amplitude: 1, frames: 48_000, channels: 1)
        run(&filter, &loud)

        filter.reset()
        #expect(filter.gainDecibels == 12)
        var silence = [Float](repeating: 0, count: 64)
        run(&filter, &silence)
        #expect(silence.allSatisfy { $0 == 0 }, "aucune queue de l'ancien flux ne doit ressortir")
    }
}
