import Foundation
import Testing

@testable import AudioCore

// Basses et aigus de la Geneva, mesurés comme on les mesurerait au banc : on envoie des sinusoïdes et
// on lit ce qui sort, plutôt que de vérifier les coefficients contre eux-mêmes. L'ancien renfort
// (`LegacyLowShelfReference`) tourne à côté, sur les mêmes signaux, pour mesurer ce qui a changé au
// lieu de l'affirmer.

/// Le banc : générateurs, mesures, et les deux chaînes à comparer.
enum ToneBench {
    static let sampleRate = 48_000.0

    static func sine(
        hz: Double, amplitude: Double, frames: Int, channels: Int = 2,
        sampleRate: Double = ToneBench.sampleRate, startFrame: Int = 0
    ) -> [Float] {
        var samples = [Float](repeating: 0, count: frames * channels)
        for frame in 0..<frames {
            let phase = 2 * Double.pi * hz * Double(frame + startFrame) / sampleRate
            let value = Float(amplitude * sin(phase))
            for channel in 0..<channels { samples[frame * channels + channel] = value }
        }
        return samples
    }

    static func sum(_ a: [Float], _ b: [Float]) -> [Float] {
        zip(a, b).map { $0 + $1 }
    }

    static func run(_ tone: inout ToneControl, _ samples: inout [Float]) {
        let frames = samples.count / tone.channelCount
        samples.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            tone.process(base, frameCount: frames)
        }
    }

    static func run(_ legacy: inout LegacyLowShelfReference, _ samples: inout [Float]) {
        let frames = samples.count / legacy.channelCount
        samples.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            legacy.process(base, frameCount: frames)
        }
    }

    static func rms(_ samples: ArraySlice<Float>) -> Double {
        let energy = samples.reduce(0.0) { $0 + Double($1) * Double($1) }
        return (energy / Double(samples.count)).squareRoot()
    }

    /// Amplitude d'une composante, par une DFT à une seule raie sur le canal 0. Sur un nombre entier
    /// de périodes de chaque composante, les autres n'y fuient pas.
    static func amplitude(
        at hz: Double, in samples: [Float], channels: Int = 2, frames: Range<Int>,
        sampleRate: Double = ToneBench.sampleRate
    ) -> Double {
        var real = 0.0
        var imaginary = 0.0
        for frame in frames {
            let value = Double(samples[frame * channels])
            let phase = 2 * Double.pi * hz * Double(frame) / sampleRate
            real += value * cos(phase)
            imaginary -= value * sin(phase)
        }
        return 2 * (real * real + imaginary * imaginary).squareRoot() / Double(frames.count)
    }

    /// Gain en régime établi de la nouvelle chaîne : 1 s pour passer rampes et transitoires, puis
    /// 1 s de mesure, soit un nombre entier de périodes à toute fréquence entière.
    static func gain(
        hz: Double, bass: Double = 0, treble: Double = 0, sampleRate: Double = ToneBench.sampleRate
    ) -> Double {
        var tone = ToneControl(sampleRate: sampleRate, channelCount: 2)
        tone.setBassBoost(decibels: bass)
        tone.setTrebleCut(decibels: treble)
        let frames = Int(2 * sampleRate)
        let input = sine(hz: hz, amplitude: 0.1, frames: frames, sampleRate: sampleRate)
        var output = input
        run(&tone, &output)
        let settled = frames  // la seconde moitié, en échantillons (2 canaux)
        return 20 * log10(rms(output[settled...]) / rms(input[settled...]))
    }

    /// La même mesure sur l'ancien plateau seul.
    static func legacyGain(hz: Double, bass: Double, sampleRate: Double = ToneBench.sampleRate) -> Double {
        var legacy = LegacyLowShelfReference(sampleRate: sampleRate, channelCount: 2)
        legacy.setGain(decibels: bass)
        let frames = Int(2 * sampleRate)
        let input = sine(hz: hz, amplitude: 0.1, frames: frames, sampleRate: sampleRate)
        var output = input
        run(&legacy, &output)
        let settled = frames
        return 20 * log10(rms(output[settled...]) / rms(input[settled...]))
    }

    /// Le plus grand saut d'un échantillon au suivant, sur le canal 0 : c'est ce qu'est un clic.
    static func largestStep(_ samples: [Float], channels: Int = 2) -> Float {
        var largest: Float = 0
        var frame = 1
        while frame < samples.count / channels {
            largest = max(largest, abs(samples[frame * channels] - samples[(frame - 1) * channels]))
            frame += 1
        }
        return largest
    }

    static func peak(_ samples: [Float]) -> Float {
        samples.map { abs($0) }.max() ?? 0
    }

    /// Retard de groupe d'une réponse impulsionnelle, en ms, par la pente de sa phase.
    static func groupDelayMilliseconds(
        _ impulse: [Double], at hz: Double, sampleRate: Double = ToneBench.sampleRate
    ) -> Double {
        func phase(_ f: Double) -> Double {
            var real = 0.0
            var imaginary = 0.0
            for (index, value) in impulse.enumerated() {
                let w = 2 * Double.pi * f * Double(index) / sampleRate
                real += value * cos(w)
                imaginary -= value * sin(w)
            }
            return atan2(imaginary, real)
        }
        let delta = 0.01
        var difference = phase(hz + delta) - phase(hz - delta)
        while difference > .pi { difference -= 2 * .pi }
        while difference < -.pi { difference += 2 * .pi }
        return -difference / (2 * .pi * 2 * delta) * 1_000
    }

    /// Réponse impulsionnelle de la chaîne, réglages atteints d'emblée, sur 1 s.
    static func impulseResponse(bass: Double, treble: Double) -> [Double] {
        var tone = ToneControl(sampleRate: sampleRate, channelCount: 1)
        tone.setBassBoost(decibels: bass)
        tone.setTrebleCut(decibels: treble)
        tone.reset()
        var impulse = [Float](repeating: 0, count: Int(sampleRate))
        impulse[0] = 0.5
        run(&tone, &impulse)
        return impulse.map { Double($0) / 0.5 }
    }

    /// Réponse impulsionnelle d'un SVF seul, en double précision.
    static func impulseResponse(_ coefficients: StateVariableFilter.Coefficients) -> [Double] {
        var filter = StateVariableFilter(channelCount: 1, coefficients: coefficients)
        var response = [Double](repeating: 0, count: Int(sampleRate))
        var index = 0
        while index < response.count {
            response[index] = filter.tick(index == 0 ? 1 : 0, channel: 0)
            index += 1
        }
        return response
    }

    static var bassPrewarp: Double {
        StateVariableFilter.Coefficients.prewarp(cornerHz: ToneControl.bassCornerHz, sampleRate: sampleRate)
    }

    static var subsonicCoefficients: StateVariableFilter.Coefficients {
        .highPass(
            prewarped: StateVariableFilter.Coefficients.prewarp(
                cornerHz: ToneControl.subsonicCornerHz, sampleRate: sampleRate
            ),
            q: ToneControl.subsonicQ
        )
    }
}

// MARK: - Réponse en fréquence

@Suite("DSP — réponse en fréquence")
struct DSPToneResponseTests {
    /// Les valeurs théoriques citées viennent des prototypes analogiques par transformée bilinéaire
    /// (cookbook RBJ, Butterworth), à 48 kHz : la mesure doit y tomber au dixième de dB.
    @Test("À +12 dB, le passe-haut borne le renfort sous 30 Hz, sans toucher à 60 et 80 Hz ni à 1 kHz")
    func subsonicFilterBoundsTheBoost() {
        let old20 = ToneBench.legacyGain(hz: 20, bass: 12)
        let new20 = ToneBench.gain(hz: 20, bass: 12)
        // L'ancien plateau donnait +11,9 dB à 20 Hz. Le Butterworth d'ordre 2 à 30 Hz en retire
        // exactement 1/√(1 + (30/20)⁴), soit 7,83 dB.
        #expect(abs(old20 - 11.92) < 0.1, "ancien plateau à 20 Hz : \(old20) dB")
        #expect(abs((old20 - new20) - 7.83) < 0.1, "retiré à 20 Hz : \(old20 - new20) dB")
        #expect(new20 < 4.2, "nouvelle chaîne à 20 Hz : \(new20) dB")

        // L'accentuation tient là où le boomer restitue.
        let new60 = ToneBench.gain(hz: 60, bass: 12)
        let old60 = ToneBench.legacyGain(hz: 60, bass: 12)
        #expect(abs(new60 - 8.49) < 0.1, "60 Hz : \(new60) dB")
        #expect(old60 - new60 < 0.3, "60 Hz perd \(old60 - new60) dB")
        let new80 = ToneBench.gain(hz: 80, bass: 12)
        let old80 = ToneBench.legacyGain(hz: 80, bass: 12)
        #expect(abs(new80 - 5.91) < 0.1, "80 Hz : \(new80) dB")
        #expect(old80 - new80 < 0.1, "80 Hz perd \(old80 - new80) dB")

        let new1k = ToneBench.gain(hz: 1_000, bass: 12)
        #expect(abs(new1k) < 0.1, "1 kHz : \(new1k) dB")
    }

    @Test("La réponse ne dépend pas de la fréquence d'échantillonnage")
    func responseHoldsAcrossSampleRates() {
        for sampleRate in [44_100.0, 96_000.0] {
            for (hz, expected) in [(20.0, 4.09), (60.0, 8.49), (1_000.0, 0.0)] {
                let measured = ToneBench.gain(hz: hz, bass: 12, sampleRate: sampleRate)
                #expect(abs(measured - expected) < 0.1, "\(sampleRate) Hz, \(hz) Hz : \(measured) dB")
            }
            let treble = ToneBench.gain(hz: 8_000, treble: -6, sampleRate: sampleRate)
            #expect(abs(treble + 5.9) < 0.15, "\(sampleRate) Hz, aigus à 8 kHz : \(treble) dB")
        }
    }

    @Test("Aigus à −6 dB : −6 dB à 8 kHz, rien à 200 Hz ; −9 dB atteint en haut du spectre")
    func trebleCut() {
        let at8k = ToneBench.gain(hz: 8_000, treble: -6)
        // Le plateau est atteint à 0,1 dB près une octave et demie au-dessus de la charnière.
        #expect(abs(at8k + 5.90) < 0.1, "8 kHz : \(at8k) dB")
        let at200 = ToneBench.gain(hz: 200, treble: -6)
        #expect(abs(at200) < 0.1, "200 Hz : \(at200) dB")
        let at3k = ToneBench.gain(hz: 3_000, treble: -6)
        #expect(abs(at3k + 3) < 0.1, "la charnière prend la moitié de la coupe : \(at3k) dB")
        let deepest = ToneBench.gain(hz: 16_000, treble: -9)
        #expect(abs(deepest + 9) < 0.1, "16 kHz à −9 dB : \(deepest) dB")
    }

    @Test("Basses et aigus se règlent sans se gêner")
    func bassAndTrebleAreIndependent() {
        #expect(abs(ToneBench.gain(hz: 60, bass: 12, treble: -6) - 8.49) < 0.1)
        #expect(abs(ToneBench.gain(hz: 8_000, bass: 12, treble: -6) + 5.90) < 0.1)
        #expect(abs(ToneBench.gain(hz: 1_000, bass: 12, treble: -6) + 0.09) < 0.05)
    }

    @Test("Le plateau grave est exactement celui de l'ADR-002 : même charnière, même Q, même courbe")
    func bassShelfIsTheCookbookShelf() {
        // Réponse impulsionnelle du plateau SVF contre celle de l'ancien biquad, au même réglage.
        var legacy = LegacyLowShelfReference(sampleRate: ToneBench.sampleRate, channelCount: 1)
        legacy.setGain(decibels: 12)
        legacy.reset()
        var legacyImpulse = [Float](repeating: 0, count: 4_096)
        legacyImpulse[0] = 0.01  // assez bas pour que l'ancien limiteur reste hors jeu
        ToneBench.run(&legacy, &legacyImpulse)

        let svf = ToneBench.impulseResponse(
            .lowShelf(prewarped: ToneBench.bassPrewarp, q: ToneControl.bassQ, gainDecibels: 12)
        )
        var largestError = 0.0
        for index in 0..<legacyImpulse.count {
            largestError = max(largestError, abs(Double(legacyImpulse[index]) / 0.01 - svf[index]))
        }
        #expect(largestError < 1e-5, "écart maximal \(largestError)")
    }

    @Test("Le passe-haut est un Butterworth d'ordre 2 : −3 dB à 30 Hz, puis 12 dB par octave")
    func subsonicIsButterworth() {
        let impulse = ToneBench.impulseResponse(ToneBench.subsonicCoefficients)
        func gain(_ hz: Double) -> Double {
            var real = 0.0
            var imaginary = 0.0
            for (index, value) in impulse.enumerated() {
                let w = 2 * Double.pi * hz * Double(index) / ToneBench.sampleRate
                real += value * cos(w)
                imaginary -= value * sin(w)
            }
            return 10 * log10(real * real + imaginary * imaginary)
        }
        #expect(abs(gain(30) + 3.01) < 0.02, "30 Hz : \(gain(30)) dB")
        #expect(abs(gain(15) + 12.30) < 0.05, "15 Hz : \(gain(15)) dB")
        #expect(abs(gain(7.5) + 24.08) < 0.05, "7,5 Hz : \(gain(7.5)) dB")
        #expect(abs(gain(200)) < 0.01, "200 Hz : \(gain(200)) dB")
    }
}

/// Imprime la courbe mesurée, pour la comparer à une mesure au micro quand il faudra ajuster les
/// constantes. Inerte tant que la variable d'environnement n'est pas posée :
///
/// ```
/// DSP_RESPONSE_TABLE=1 swift test --filter DSPResponseTable
/// ```
@Suite("DSP — courbe mesurée, à la demande")
struct DSPResponseTable {
    @Test(
        "Imprime la réponse en dB par fréquence pour quelques réglages",
        .enabled(if: ProcessInfo.processInfo.environment["DSP_RESPONSE_TABLE"] != nil)
    )
    func printTable() {
        let frequencies: [Double] = [
            20, 25, 30, 40, 50, 60, 80, 100, 120, 200, 500, 1_000, 2_000, 3_000, 5_000, 8_000, 12_000, 16_000,
        ]
        let columns: [(String, (Double) -> Double)] = [
            ("ancien +6", { ToneBench.legacyGain(hz: $0, bass: 6) }),
            ("basses +6", { ToneBench.gain(hz: $0, bass: 6) }),
            ("ancien +12", { ToneBench.legacyGain(hz: $0, bass: 12) }),
            ("basses +12", { ToneBench.gain(hz: $0, bass: 12) }),
            ("aigus −3", { ToneBench.gain(hz: $0, treble: -3) }),
            ("aigus −6", { ToneBench.gain(hz: $0, treble: -6) }),
            ("aigus −9", { ToneBench.gain(hz: $0, treble: -9) }),
            ("+12 / −6", { ToneBench.gain(hz: $0, bass: 12, treble: -6) }),
        ]
        var lines = ["| Hz | " + columns.map(\.0).joined(separator: " | ") + " |"]
        lines.append("|---:|" + columns.map { _ in "---:" }.joined(separator: "|") + "|")
        for hz in frequencies {
            let cells = columns.map { String(format: "%+.2f", $0.1(hz)) }
            lines.append("| \(Int(hz)) | " + cells.joined(separator: " | ") + " |")
        }
        print(lines.joined(separator: "\n"))
    }
}

// MARK: - Alignement

@Suite("DSP — alignement")
struct DSPToneAlignmentTests {
    @Test("Aucun décalage de trame, et le retard de groupe documenté, passe-haut compris")
    func groupDelayIsDocumented() {
        // Causalité : la toute première sortie porte déjà la toute première entrée.
        let chain = ToneBench.impulseResponse(bass: 12, treble: 0)
        #expect(abs(chain[0]) > 0.9, "aucune latence de bloc : \(chain[0])")

        // Les chiffres annoncés dans la documentation de `ToneControl` : s'ils bougent, elle ment.
        let subsonic = ToneBench.impulseResponse(ToneBench.subsonicCoefficients)
        let at40 = ToneBench.groupDelayMilliseconds(subsonic, at: 40)
        let at80 = ToneBench.groupDelayMilliseconds(subsonic, at: 80)
        #expect(abs(at40 - 5.0) < 0.05, "passe-haut à 40 Hz : \(at40) ms")
        #expect(abs(at80 - 1.18) < 0.03, "passe-haut à 80 Hz : \(at80) ms")

        let shelf = ToneBench.impulseResponse(
            .lowShelf(prewarped: ToneBench.bassPrewarp, q: ToneControl.bassQ, gainDecibels: 12)
        )
        #expect(abs(ToneBench.groupDelayMilliseconds(shelf, at: 40) - 2.5) < 0.1)
        #expect(abs(ToneBench.groupDelayMilliseconds(shelf, at: 80)) < 0.05)

        let chain40 = ToneBench.groupDelayMilliseconds(chain, at: 40)
        let chain80 = ToneBench.groupDelayMilliseconds(chain, at: 80)
        let chain1k = ToneBench.groupDelayMilliseconds(chain, at: 1_000)
        #expect(abs(chain40 - 7.53) < 0.1, "chaîne à 40 Hz : \(chain40) ms")
        #expect(abs(chain80 - 1.18) < 0.05, "chaîne à 80 Hz : \(chain80) ms")
        let oneSample = 1_000 / ToneBench.sampleRate
        #expect(abs(chain1k) < oneSample, "chaîne à 1 kHz : \(chain1k) ms")

        let treble = ToneBench.impulseResponse(bass: 0, treble: -9)
        for hz in [200.0, 1_000, 2_000, 5_000, 8_000] {
            let delay = ToneBench.groupDelayMilliseconds(treble, at: hz)
            #expect(abs(delay) < 0.06, "aigus à −9 dB, \(hz) Hz : \(delay) ms")
        }
    }
}

// MARK: - Dynamique

@Suite("DSP — correction dynamique du grave")
struct DSPToneDynamicsTests {
    /// Le défaut corrigé : un grave qui dépasse faisait baisser tout le signal, voix comprise.
    @Test("Pas de pompage : un grave qui sature fait reculer le renfort, pas le 1 kHz")
    func noPumping() {
        let frames = 96_000
        let input = ToneBench.sum(
            ToneBench.sine(hz: 50, amplitude: 0.5, frames: frames),
            ToneBench.sine(hz: 1_000, amplitude: 0.1, frames: frames)
        )
        let window = 48_000..<96_000
        let midIn = ToneBench.amplitude(at: 1_000, in: input, frames: window)

        // L'ancien limiteur pleine bande, sur le même signal : il baissait le 1 kHz de plusieurs dB.
        var legacy = LegacyLowShelfReference(sampleRate: ToneBench.sampleRate, channelCount: 2)
        legacy.setGain(decibels: 12)
        var old = input
        ToneBench.run(&legacy, &old)
        let oldMid = 20 * log10(ToneBench.amplitude(at: 1_000, in: old, frames: window) / midIn)
        #expect(oldMid < -3, "l'ancien limiteur baissait le 1 kHz de \(oldMid) dB")

        var tone = ToneControl(sampleRate: ToneBench.sampleRate, channelCount: 2)
        tone.setBassBoost(decibels: 12)
        var output = input
        ToneBench.run(&tone, &output)
        let mid = 20 * log10(ToneBench.amplitude(at: 1_000, in: output, frames: window) / midIn)
        #expect(abs(mid) <= 0.2, "le 1 kHz a bougé de \(mid) dB (ancien : \(oldMid) dB)")

        // Le renfort a bien dû reculer, il n'a pas disparu, et rien ne dépasse le plafond.
        #expect(tone.bassDepth < 0.6, "profondeur \(tone.bassDepth)")
        let bassIn = ToneBench.amplitude(at: 50, in: input, frames: window)
        let bassOut = ToneBench.amplitude(at: 50, in: output, frames: window)
        #expect(20 * log10(bassOut / bassIn) > 2, "renfort restant : \(20 * log10(bassOut / bassIn)) dB")
        #expect(ToneBench.peak(output) <= Float(ToneControl.ceiling), "crête \(ToneBench.peak(output))")
        #expect(tone.safetyLimitedFrames == 0, "le limiteur de sécurité ne devait pas servir")
    }

    @Test("Sur une source sous le plafond, le limiteur de sécurité ne sert jamais, aigus coupés compris")
    func safetyLimiterIsRare() {
        // Un mélange chargé en grave, crête 0,9, où la rotation de phase du passe-haut aurait pu
        // faire monter la crête au-dessus du plafond.
        let frames = 96_000
        var input = ToneBench.sine(hz: 31, amplitude: 0.3, frames: frames)
        input = ToneBench.sum(input, ToneBench.sine(hz: 47, amplitude: 0.25, frames: frames))
        input = ToneBench.sum(input, ToneBench.sine(hz: 63, amplitude: 0.15, frames: frames))
        input = ToneBench.sum(input, ToneBench.sine(hz: 700, amplitude: 0.12, frames: frames))
        input = ToneBench.sum(input, ToneBench.sine(hz: 3_100, amplitude: 0.08, frames: frames))
        #expect(ToneBench.peak(input) < 0.91)

        var tone = ToneControl(sampleRate: ToneBench.sampleRate, channelCount: 2)
        tone.setBassBoost(decibels: 12)
        tone.setTrebleCut(decibels: -9)
        var output = input
        ToneBench.run(&tone, &output)
        #expect(tone.safetyLimitedFrames == 0)
        #expect(ToneBench.peak(output) <= Float(ToneControl.ceiling))
        #expect(tone.bassDepth < 1, "la correction du grave a dû agir")
    }

    /// Sans maintien, la profondeur remonterait entre deux crêtes pour être rabattue à la suivante :
    /// le grave serait modulé à sa propre fréquence, donc déformé.
    @Test("Sous correction, un grave tenu ne se déforme pas")
    func sustainedBassStaysClean() {
        let frames = 96_000
        let input = ToneBench.sine(hz: 50, amplitude: 0.5, frames: frames)
        var tone = ToneControl(sampleRate: ToneBench.sampleRate, channelCount: 2)
        tone.setBassBoost(decibels: 12)
        var output = input
        ToneBench.run(&tone, &output)

        let window = 48_000..<96_000
        let fundamental = ToneBench.amplitude(at: 50, in: output, frames: window)
        for harmonic in [100.0, 150, 200, 250] {
            let level = 20 * log10(ToneBench.amplitude(at: harmonic, in: output, frames: window) / fundamental)
            #expect(level < -60, "\(harmonic) Hz à \(level) dB du fondamental")
        }
        // Le grave reste aussi fort que le plafond le permet.
        let peak = Double(ToneBench.peak(Array(output[(window.lowerBound * 2)...])))
        #expect(peak > ToneControl.ceiling * 0.995, "crête tenue à \(peak)")
        #expect(tone.safetyLimitedFrames == 0)
    }

    @Test("Aucune sortie au-dessus du plafond, même sur une onde carrée pleine échelle à +12 dB")
    func neverClips() {
        var tone = ToneControl(sampleRate: ToneBench.sampleRate, channelCount: 2)
        tone.setBassBoost(decibels: 12)
        tone.setTrebleCut(decibels: -9)

        // Pire cas : une onde carrée en plein grave, une sinusoïde pleine échelle, puis un bruit qui
        // dépasse déjà l'échelle à l'entrée.
        var samples = [Float](repeating: 0, count: 288_000)
        var generator = SystemRandomNumberGenerator()
        for index in stride(from: 0, to: samples.count, by: 2) {
            let frame = index / 2
            let value: Float
            switch frame {
            case ..<48_000: value = (frame / 300) % 2 == 0 ? 1 : -1
            case ..<96_000: value = Float(sin(2 * .pi * 40 * Double(frame) / ToneBench.sampleRate))
            default: value = Float.random(in: -1.5...1.5, using: &generator)
            }
            samples[index] = value
            samples[index + 1] = -value
        }
        ToneBench.run(&tone, &samples)
        let peak = ToneBench.peak(samples)
        #expect(peak <= Float(ToneControl.ceiling), "crête \(peak)")
        #expect(peak > 0.9, "la chaîne ne doit pas écraser le signal : crête \(peak)")
    }

    @Test("Sans dépassement, la correction n'intervient pas")
    func staysOutOfTheWay() {
        // +6 dB sur une sinusoïde à 0,1 : la crête reste très loin du plafond. Le gain mesuré est
        // celui de la courbe, plateau et passe-haut, sans rien devoir à la dynamique.
        let gain = ToneBench.gain(hz: 40, bass: 6)
        #expect(abs(gain - 4.40) < 0.1, "gain mesuré \(gain) dB")
        var tone = ToneControl(sampleRate: ToneBench.sampleRate, channelCount: 2)
        tone.setBassBoost(decibels: 6)
        var samples = ToneBench.sine(hz: 40, amplitude: 0.1, frames: 48_000)
        ToneBench.run(&tone, &samples)
        #expect(tone.bassDepth == 1)
        #expect(tone.limiterGain == 1)
    }
}

// MARK: - Transitions

@Suite("DSP — transparence et transitions")
struct DSPToneTransitionTests {
    @Test("À 0 dB / 0 dB le flux ressort identique au bit près, valeurs hors échelle comprises")
    func transparentAtZero() {
        var tone = ToneControl(sampleRate: ToneBench.sampleRate, channelCount: 2)
        tone.setBassBoost(decibels: 0)
        tone.setTrebleCut(decibels: 0)
        #expect(tone.isTransparent)

        var generator = SystemRandomNumberGenerator()
        var samples = (0..<96_000).map { _ in Float.random(in: -1.5...1.5, using: &generator) }
        samples[10] = .leastNonzeroMagnitude
        samples[11] = -0.0
        samples[12] = .nan
        let original = samples.map(\.bitPattern)
        ToneBench.run(&tone, &samples)
        #expect(samples.map(\.bitPattern) == original)
    }

    @Test("Revenus à 0 dB, basses et aigus redeviennent bit à bit dès la fin des rampes")
    func backToTransparent() {
        var tone = ToneControl(sampleRate: ToneBench.sampleRate, channelCount: 2)
        tone.setBassBoost(decibels: 12)
        tone.setTrebleCut(decibels: -9)
        var warm = ToneBench.sum(
            ToneBench.sine(hz: 40, amplitude: 0.1, frames: 48_000),
            ToneBench.sine(hz: 6_000, amplitude: 0.05, frames: 48_000)
        )
        ToneBench.run(&tone, &warm)
        #expect(!tone.isTransparent)

        tone.setBassBoost(decibels: 0)
        tone.setTrebleCut(decibels: 0)
        // Les rampes durent 50 ms : 100 ms suffisent, aucune queue de filtre n'est attendue.
        var tail = ToneBench.sine(hz: 40, amplitude: 0.1, frames: 4_800, startFrame: 48_000)
        ToneBench.run(&tone, &tail)
        #expect(tone.isTransparent, "le contournement doit avoir repris")

        var samples = ToneBench.sine(hz: 40, amplitude: 0.1, frames: 4_800, startFrame: 52_800)
        let original = samples.map(\.bitPattern)
        ToneBench.run(&tone, &samples)
        #expect(samples.map(\.bitPattern) == original)
    }

    /// Joue une sinusoïde continue par blocs, en changeant les réglages entre deux blocs.
    private func play(
        hz: Double, amplitude: Double, blocks: [(frames: Int, bass: Double, treble: Double)],
        tone: inout ToneControl
    ) -> [Float] {
        var output: [Float] = []
        var start = 0
        for block in blocks {
            tone.setBassBoost(decibels: block.bass)
            tone.setTrebleCut(decibels: block.treble)
            var samples = ToneBench.sine(
                hz: hz, amplitude: amplitude, frames: block.frames, startFrame: start
            )
            ToneBench.run(&tone, &samples)
            output += samples
            start += block.frames
        }
        return output
    }

    @Test("Monter puis couper les basses en pleine lecture ne produit aucun clic")
    func bassChangeIsClickFree() {
        var tone = ToneControl(sampleRate: ToneBench.sampleRate, channelCount: 2)
        // Bond du curseur de 0 à +12 dB d'un coup, puis retour à 0 d'un coup : le passe-haut entre puis
        // sort, le plateau monte puis descend.
        let output = play(
            hz: 40, amplitude: 0.2,
            blocks: [(48_000, 0, 0), (24_000, 12, 0), (24_000, 0, 0)], tone: &tone
        )
        // La plus grande pente légitime est celle de la sinusoïde au gain final, 9,86 dB à 40 Hz :
        // 2π·40/48 000 × 0,2 × 3,11 ≈ 0,0033.
        let step = ToneBench.largestStep(output)
        #expect(step < 0.006, "saut de \(step) entre deux échantillons")
        #expect(tone.isTransparent)

        // Et rien ne passe d'un coup : à 20 ms d'un bond, on n'y est pas encore.
        var midRamp = ToneControl(sampleRate: ToneBench.sampleRate, channelCount: 1)
        midRamp.setBassBoost(decibels: 12)
        var short = [Float](repeating: 0, count: 960)
        ToneBench.run(&midRamp, &short)
        #expect(midRamp.bassCurrent > 0 && midRamp.bassCurrent < 12, "\(midRamp.bassCurrent) dB")
        #expect(midRamp.subsonicMix > 0 && midRamp.subsonicMix < 1, "fondu à \(midRamp.subsonicMix)")
    }

    @Test("Couper puis rendre les aigus en pleine lecture glisse, sans clic")
    func trebleChangeGlides() {
        var tone = ToneControl(sampleRate: ToneBench.sampleRate, channelCount: 2)
        let output = play(
            hz: 6_000, amplitude: 0.1,
            blocks: [(4_800, 0, 0), (9_600, 0, -9), (9_600, 0, 0)], tone: &tone
        )
        // La coupe glisse : les 5 premières ms après le bond sont entre les deux niveaux.
        let reference = 0.1
        func level(_ frames: Range<Int>) -> Double {
            20 * log10(ToneBench.amplitude(at: 6_000, in: output, frames: frames) / reference)
        }
        let early = level(4_800..<5_040)
        let settled = level(12_000..<14_400)
        #expect(early > -4 && early < -0.1, "5 premières ms : \(early) dB")
        #expect(abs(settled + 8.44) < 0.1, "régime établi : \(settled) dB")
        #expect(abs(level(21_600..<24_000)) < 0.05, "retour à 0 dB")

        // Pas de saut au-delà de la pente de la sinusoïde : 2π·6 000/48 000 × 0,1 ≈ 0,079.
        let step = ToneBench.largestStep(output)
        #expect(step < 0.082, "saut de \(step)")
        #expect(tone.isTransparent)
    }

    @Test("Chaque canal garde son propre état : un signal à gauche ne fuit pas à droite")
    func channelsAreIndependent() {
        var tone = ToneControl(sampleRate: ToneBench.sampleRate, channelCount: 2)
        tone.setBassBoost(decibels: 12)
        tone.setTrebleCut(decibels: -9)
        var samples = [Float](repeating: 0, count: 48_000 * 2)
        for frame in 0..<48_000 {
            samples[frame * 2] = Float(0.1 * sin(2 * .pi * 40 * Double(frame) / ToneBench.sampleRate))
        }
        ToneBench.run(&tone, &samples)
        for frame in 0..<48_000 {
            #expect(samples[frame * 2 + 1] == 0)
        }
    }

    @Test("Une valeur non finie à l'entrée ne contamine pas la chaîne")
    func nonFiniteInputIsContained() {
        var tone = ToneControl(sampleRate: ToneBench.sampleRate, channelCount: 1)
        tone.setBassBoost(decibels: 12)
        tone.setTrebleCut(decibels: -6)
        var samples = ToneBench.sine(hz: 40, amplitude: 0.1, frames: 4_800, channels: 1)
        samples[100] = .nan
        samples[101] = .infinity
        ToneBench.run(&tone, &samples)
        #expect(samples.allSatisfy { $0.isFinite })
        #expect(ToneBench.rms(samples[4_000...]) > 0.05, "le signal doit continuer de passer")
    }

    @Test("Les consignes restent dans les bornes des curseurs")
    func settingsAreClamped() {
        var tone = ToneControl(sampleRate: ToneBench.sampleRate, channelCount: 1)
        tone.setBassBoost(decibels: 40)
        #expect(tone.bassBoostDecibels == 12)
        tone.setBassBoost(decibels: -6)
        #expect(tone.bassBoostDecibels == 0)
        tone.setBassBoost(decibels: .nan)
        #expect(tone.bassBoostDecibels == 0)
        tone.setTrebleCut(decibels: -20)
        #expect(tone.trebleCutDecibels == -9)
        tone.setTrebleCut(decibels: 3)
        #expect(tone.trebleCutDecibels == 0)
        tone.setTrebleCut(decibels: -4)
        tone.setTrebleCut(decibels: .infinity)
        #expect(tone.trebleCutDecibels == 0)
    }

    @Test("reset oublie l'état des filtres et des gains, sans toucher aux consignes")
    func resetForgetsHistory() {
        var tone = ToneControl(sampleRate: ToneBench.sampleRate, channelCount: 1)
        tone.setBassBoost(decibels: 12)
        tone.setTrebleCut(decibels: -6)
        var loud = ToneBench.sine(hz: 40, amplitude: 1, frames: 48_000, channels: 1)
        ToneBench.run(&tone, &loud)
        #expect(tone.bassDepth < 1)

        tone.reset()
        #expect(tone.bassBoostDecibels == 12)
        #expect(tone.trebleCutDecibels == -6)
        #expect(tone.bassDepth == 1)
        #expect(tone.limiterGain == 1)
        var silence = [Float](repeating: 0, count: 64)
        ToneBench.run(&tone, &silence)
        #expect(silence.allSatisfy { $0 == 0 }, "aucune queue de l'ancien flux ne doit ressortir")
    }
}

// MARK: - Temps réel

extension RealTimePathTests {
    /// Le chemin du sender, entre le ring buffer et le rééchantillonneur : rampes, correction
    /// dynamique et limiteur de sécurité doivent tous y passer pendant la mesure.
    @Test("Basses et aigus n'allouent rien, rampes, correction du grave et limiteur compris")
    func toneControlDoesNotAllocate() throws {
        // 1 024 trames : exactement une période à 46,875 Hz, si bien que le bloc rejoué en boucle reste
        // une sinusoïde continue.
        let frames = 1_024
        let source = UnsafeMutablePointer<Float>.allocate(capacity: frames * 2)
        let block = UnsafeMutablePointer<Float>.allocate(capacity: frames * 2)
        defer {
            source.deallocate()
            block.deallocate()
        }
        // Un grave que le renfort ferait déborder, et une salve qui dépasse déjà l'échelle sans lui :
        // la correction du grave et le limiteur de sécurité travaillent tous deux.
        var index = 0
        while index < frames {
            let time = Double(index) / 48_000
            var value = 0.6 * sin(2 * Double.pi * 46.875 * time)
            if index >= 600, index < 640 { value += 0.7 * sin(2 * Double.pi * 3_000 * time) }
            source[index * 2] = Float(value)
            source[index * 2 + 1] = Float(-value)
            index += 1
        }

        var tone = ToneControl(sampleRate: 48_000, channelCount: 2)
        var passes = 0
        let pass = {
            // Un nouveau réglage tous les 40 blocs : les rampes recalculent les coefficients.
            if passes % 40 == 0 {
                let high = (passes / 40) % 2 == 0
                tone.setBassBoost(decibels: high ? 12 : 6)
                tone.setTrebleCut(decibels: high ? -9 : -3)
            }
            block.update(from: source, count: frames * 2)
            tone.process(block, frameCount: frames)
            passes += 1
        }
        var warmUp = 0
        while warmUp < 300 {
            pass()
            warmUp += 1
        }
        let observed = AllocationProbe.allocations {
            var run = 0
            while run < 1_000 {
                pass()
                run += 1
            }
        }
        let count = try #require(observed)
        #expect(count == 0, "\(count) allocations pour 1 000 blocs\n\(AllocationProbe.firstAllocationStack)")
        #expect(tone.bassDepth < 1, "la correction du grave doit avoir travaillé")
        #expect(tone.safetyLimitedFrames > 0, "le limiteur de sécurité doit avoir travaillé")
    }
}
