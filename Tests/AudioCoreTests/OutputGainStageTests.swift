import Foundation
import Testing

@testable import AudioCore

/// L'étage de gain d'une sortie : niveau exact, glissement sans pas, contournement au bit près,
/// aucun retard, aucune allocation.
@Suite("Étage de gain d'une sortie")
struct OutputGainStageTests {
    private static let sampleRate = 48_000.0

    private func stage() -> OutputGainStage {
        OutputGainStage(sampleRate: Self.sampleRate, channelCount: 2)
    }

    /// Passe `frames` trames constantes à `value` dans l'étage, et rend ce qui en sort.
    private func run(_ stage: inout OutputGainStage, frames: Int, value: Float = 1) -> [Float] {
        var samples = [Float](repeating: value, count: frames * 2)
        samples.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            stage.process(base, frameCount: frames)
        }
        return samples
    }

    /// Un signal qui ne se laisse pas confondre avec un autre : bruit, valeurs extrêmes, sous-normaux
    /// et une charge utile de NaN. Le moindre passage en arithmétique en changerait un bit.
    private func awkwardSignal(frames: Int) -> [Float] {
        var generator = SystemRandomNumberGenerator()
        var samples = (0..<(frames * 2)).map { _ in Float.random(in: -1...1, using: &generator) }
        samples[0] = .leastNonzeroMagnitude
        samples[1] = -.greatestFiniteMagnitude
        samples[2] = Float(bitPattern: 0x7FC0_1234)
        samples[3] = -0.0
        return samples
    }

    private func bits(_ samples: [Float]) -> [UInt32] { samples.map(\.bitPattern) }

    // MARK: - Contournement

    @Test("À 0 dB hors silence, l'étage est contourné au bit près")
    func unityIsBitExact() {
        var gain = stage()
        #expect(gain.isTransparent)
        let original = awkwardSignal(frames: 4_096)
        var copy = original
        copy.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            gain.process(base, frameCount: 4_096)
        }
        #expect(bits(copy) == bits(original))

        // Une consigne de 0 dB explicite, ou un gain positif ramené à 0 dB, ne réveille rien.
        gain.setLevel(OutputLevel(gainDB: 0))
        gain.setLevel(OutputLevel(gainDB: 6))
        #expect(gain.isTransparent)
    }

    @Test("Revenu à 0 dB, le contournement reprend au bit près dès la fin du glissement")
    func returnToUnityIsBitExact() {
        var gain = stage()
        gain.setLevel(OutputLevel(gainDB: -6))
        _ = run(&gain, frames: 2_000)
        gain.setLevel(.unity)
        #expect(!gain.isTransparent)

        // Le glissement finit au milieu de ce bloc : tout ce qui suit sa dernière trame est intact.
        let frames = gain.fadeFrames + 300
        let original = awkwardSignal(frames: frames)
        var copy = original
        copy.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            gain.process(base, frameCount: frames)
        }
        let tail = gain.fadeFrames * 2
        #expect(bits(Array(copy[tail...])) == bits(Array(original[tail...])))
        #expect(gain.isTransparent)
        #expect(gain.appliedGain == 1)

        let next = awkwardSignal(frames: 1_024)
        var nextCopy = next
        nextCopy.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            gain.process(base, frameCount: 1_024)
        }
        #expect(bits(nextCopy) == bits(next))
    }

    // MARK: - Niveau

    @Test("En régime établi, le niveau est exactement celui de la consigne", arguments: [-6, -12, -0.5])
    func steadyLevelIsExact(decibels: Float) {
        var gain = stage()
        gain.setLevel(OutputLevel(gainDB: decibels))
        let output = run(&gain, frames: gain.fadeFrames + 1_000, value: 0.8)
        let expected = 0.8 * powf(10, decibels / 20)
        let settled = output[(gain.fadeFrames * 2)...]
        #expect(settled.allSatisfy { $0 == expected })
        #expect(abs(20 * log10(Double(expected / 0.8)) - Double(decibels)) < 1e-4)
    }

    @Test("Le silence est un fondu de 10 à 20 ms qui finit sur des zéros exacts")
    func muteFadesToExactZero() throws {
        var gain = stage()
        gain.setLevel(OutputLevel(isMuted: true))
        let output = run(&gain, frames: 2_000)
        let left = stride(from: 0, to: output.count, by: 2).map { output[$0] }

        // La première trame nulle marque la fin du fondu.
        let firstZero = try #require(left.firstIndex(of: 0))
        let fadeMilliseconds = Double(firstZero + 1) / Self.sampleRate * 1_000
        #expect(fadeMilliseconds >= 10 && fadeMilliseconds <= 20, "fondu de \(fadeMilliseconds) ms")
        #expect(left[0] < 1 && left[0] > 0.99)
        #expect(output[(gain.fadeFrames * 2)...].allSatisfy { $0 == 0 && $0.sign == .plus })
        #expect(gain.isSilent)

        // Le silence installé ne laisse plus rien passer, quel que soit le signal.
        let silent = run(&gain, frames: 512, value: 0.9)
        #expect(silent.allSatisfy { $0 == 0 })
    }

    @Test("Aucun pas brusque pendant un glissement, même repris en cours de route")
    func rampHasNoAbruptStep() {
        var gain = stage()
        // Pas maximal d'un glissement complet de 1 à 0, la plus grande excursion possible.
        let allowed = 1 / Float(gain.fadeFrames) * 1.001

        gain.setLevel(OutputLevel(isMuted: true))
        var trace = run(&gain, frames: gain.fadeFrames / 3)
        // Une nouvelle consigne au tiers du fondu : le gain repart d'où il en est.
        gain.setLevel(OutputLevel(gainDB: -3))
        trace += run(&gain, frames: gain.fadeFrames + 100)
        gain.setLevel(.unity)
        trace += run(&gain, frames: gain.fadeFrames + 100)

        let left = stride(from: 0, to: trace.count, by: 2).map { trace[$0] }
        // Entrée unité : la sortie est le gain lui-même, trame par trame, depuis 1.
        let steps = zip([Float(1)] + left, left).map { abs($1 - $0) }
        let largest = steps.max() ?? 0
        #expect(largest <= allowed, "pas le plus grand : \(largest), permis : \(allowed)")
        // Les deux canaux d'une trame reçoivent le même gain : l'image stéréo ne bouge pas.
        #expect(stride(from: 0, to: trace.count, by: 2).allSatisfy { trace[$0] == trace[$0 + 1] })
        #expect(left.last == 1)
    }

    /// Le curseur repousse la même valeur d'un tour à l'autre : le glissement en cours ne doit pas
    /// repartir pour une durée complète à chaque fois.
    @Test("Une consigne inchangée ne relance aucun glissement")
    func unchangedTargetDoesNotRestart() {
        var gain = stage()
        gain.setLevel(OutputLevel(gainDB: -6))
        let half = gain.fadeFrames / 2
        _ = run(&gain, frames: half)
        gain.setLevel(OutputLevel(gainDB: -6))
        _ = run(&gain, frames: gain.fadeFrames - half)
        #expect(gain.appliedGain == powf(10, -6 / 20))
        #expect(!gain.isTransparent && !gain.isSilent)
    }

    @Test("Hors bornes ou non finie, la consigne est ramenée dans la plage")
    func sanitizesTarget() {
        var gain = stage()
        gain.setLevel(OutputLevel(gainDB: -200))
        #expect(gain.level.gainDB == -60)
        gain.setLevel(OutputLevel(gainDB: .nan))
        #expect(gain.level.gainDB == 0)
        gain.setLevel(OutputLevel(gainDB: 12))
        #expect(gain.level.gainDB == 0)
    }

    @Test("Une reprise de flux rejoint la consigne sans glissement")
    func resetJumpsToTarget() {
        var gain = stage()
        gain.setLevel(OutputLevel(gainDB: -6))
        gain.reset()
        let output = run(&gain, frames: 4, value: 1)
        #expect(output.allSatisfy { $0 == powf(10, -6 / 20) })
    }

    // MARK: - Calage

    /// CDC 4.5 : rien ne doit décaler une sortie par rapport aux autres.
    @Test("Aucun retard : chaque trame ressort à sa place, en glissement comme en régime établi")
    func addsNoDelay() {
        for level in [OutputLevel(gainDB: -6), OutputLevel(gainDB: -20)] {
            var gain = stage()
            gain.setLevel(level)
            var samples = [Float](repeating: 0, count: 2_000 * 2)
            for frame in [3, 400, 1_500] { samples[frame * 2] = 1 }
            samples.withUnsafeMutableBufferPointer { buffer in
                guard let base = buffer.baseAddress else { return }
                gain.process(base, frameCount: 2_000)
            }
            let nonZero = samples.indices.filter { samples[$0] != 0 }
            #expect(nonZero == [6, 800, 3_000])
        }
    }
}

/// À part, et sérialisé : la sonde d'allocation observe un seul thread à la fois.
@Suite(
    "Étage de gain d'une sortie — sans allocation",
    .serialized,
    .enabled(if: AllocationProbe.isUsable, "le Thread Sanitizer remplace l'allocateur")
)
struct OutputGainStageAllocationTests {
    @Test("Glissement, régime établi, silence et contournement : aucune allocation")
    func processDoesNotAllocate() throws {
        var gain = OutputGainStage(sampleRate: 48_000, channelCount: 2)
        let buffer = UnsafeMutablePointer<Float>.allocate(capacity: 4_096 * 2)
        defer { buffer.deallocate() }
        buffer.initialize(repeating: 0.5, count: 4_096 * 2)

        // Amorçage hors sonde : ce que le runtime ne fait qu'une fois dans la vie du processus.
        gain.setLevel(OutputLevel(gainDB: -6))
        gain.process(buffer, frameCount: 4_096)
        gain.setLevel(.unity)
        gain.process(buffer, frameCount: 4_096)

        let count = try #require(
            AllocationProbe.allocations {
                gain.setLevel(OutputLevel(gainDB: -6))
                gain.process(buffer, frameCount: 300)
                gain.process(buffer, frameCount: 4_096)
                gain.setLevel(OutputLevel(gainDB: -6, isMuted: true))
                gain.process(buffer, frameCount: 4_096)
                gain.process(buffer, frameCount: 4_096)
                gain.setLevel(.unity)
                gain.process(buffer, frameCount: 4_096)
                gain.process(buffer, frameCount: 4_096)
            }
        )
        #expect(count == 0, "première allocation :\n\(AllocationProbe.firstAllocationStack)")
    }
}
