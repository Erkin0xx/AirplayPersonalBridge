import AVFoundation
import Foundation

/// Sinusoïde de niveau réglable, cadencée en temps réel.
///
/// Permet une diffusion de bout en bout sans Process Tap ni autorisation : l'unique moyen de
/// tester le moteur et les senders contre les mocks **sans reconstruire le bundle**, ce qui
/// révoquerait l'autorisation TCC de Baptiste (`CLAUDE.md`, jalon 4).
///
/// Le fil de génération reproduit les règles du callback de capture (CDC section 13) : thread
/// classique, mémoire allouée une fois, ni verrou ni Swift Concurrency. Un défaut que cette
/// source ferait apparaître en aval vaudrait donc pour la vraie capture.
public final class ToneCaptureSource: AudioCaptureSource, @unchecked Sendable {
    public let frequency: Double
    public let levelDBFS: Double
    public let sampleRate: Double
    public let blockFrames: Int
    private let channelCount: Int
    private let interleaved: Bool

    /// Le fil de génération, partagé avec les autres sources synthétiques.
    private let pacer = SyntheticBlockPacer(threadName: "fr.baptiste.airplaymultioutput.tone")

    public var requiredPermission: CapturePermission.Kind? { nil }

    /// - Parameters:
    ///   - frequency: fréquence, en Hz.
    ///   - levelDBFS: niveau crête. `-50` reste discret sur les haut-parleurs du Mac, où
    ///     shairport-sync joue ce qu'il reçoit.
    ///   - sampleRate: fréquence d'échantillonnage. 48 kHz comme le Process Tap, ce qui fait
    ///     passer le flux par le même rééchantillonnage que la vraie capture.
    ///   - channelCount: nombre de canaux. `1` associé à `interleaved: false` reproduit le
    ///     format de l'entrée physique (mono planaire).
    ///   - interleaved: disposition des canaux.
    ///   - blockFrames: taille des blocs, celle que le tap livre couramment.
    public init(
        frequency: Double = 440,
        levelDBFS: Double = -50,
        sampleRate: Double = 48_000,
        channelCount: Int = 2,
        interleaved: Bool = true,
        blockFrames: Int = 512
    ) {
        self.frequency = frequency
        self.levelDBFS = levelDBFS
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.interleaved = interleaved
        self.blockFrames = blockFrames
    }

    public func prepare() throws -> AVAudioFormat {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: AVAudioChannelCount(channelCount),
            interleaved: interleaved
        ) else {
            throw AudioCaptureError.unsupportedFormat(
                "sinusoïde \(sampleRate) Hz, \(channelCount) canaux")
        }
        return format
    }

    public func start(deliveringTo consumer: @escaping CaptureBlockConsumer) throws {
        // Un générateur neuf à chaque démarrage : la phase repart de zéro, comme avant le partage
        // du fil avec les autres sources.
        let generator = ToneBlockGenerator(
            frequency: frequency, levelDBFS: levelDBFS, sampleRate: sampleRate,
            channelCount: channelCount, interleaved: interleaved, blockFrames: blockFrames
        )
        pacer.start(generator, sampleRate: sampleRate, deliveringTo: consumer)
    }

    public func stop() {
        pacer.stop()
    }

    public func isAudioExpected() -> Bool? { true }
}

/// Génère les blocs de la sinusoïde dans une mémoire allouée une fois pour toutes.
///
/// Séparé de `ToneCaptureSource` pour être vérifiable à l'unité : la phase doit rester continue
/// d'un bloc à l'autre, faute de quoi un clic reviendrait à chaque bloc.
final class ToneBlockGenerator: SyntheticBlockGenerator, @unchecked Sendable {
    let blockFrames: Int
    private let amplitude: Float
    private let phaseStep: Double
    private let channelCount: Int
    private let bufferCount: Int
    private let samples: UnsafeMutablePointer<Float>
    private let sampleCount: Int
    private let list: UnsafeMutableAudioBufferListPointer
    private var phase: Double = 0

    init(
        frequency: Double,
        levelDBFS: Double,
        sampleRate: Double,
        channelCount: Int,
        interleaved: Bool,
        blockFrames: Int
    ) {
        self.blockFrames = blockFrames
        self.amplitude = Float(pow(10, levelDBFS / 20))
        self.phaseStep = 2 * .pi * frequency / sampleRate
        self.channelCount = channelCount
        self.sampleCount = blockFrames * channelCount
        self.samples = .allocate(capacity: blockFrames * channelCount)
        samples.initialize(repeating: 0, count: blockFrames * channelCount)

        let bufferCount = interleaved ? 1 : channelCount
        self.bufferCount = bufferCount
        self.list = AudioBufferList.allocate(maximumBuffers: bufferCount)
        let channelsPerBuffer = interleaved ? channelCount : 1
        for index in 0..<bufferCount {
            list[index] = AudioBuffer(
                mNumberChannels: UInt32(channelsPerBuffer),
                mDataByteSize: UInt32(blockFrames * channelsPerBuffer * MemoryLayout<Float>.size),
                mData: UnsafeMutableRawPointer(samples + index * blockFrames)
            )
        }
    }

    deinit {
        samples.deinitialize(count: sampleCount)
        samples.deallocate()
        free(list.unsafeMutablePointer)
    }

    /// Boucles `while` : hors optimisation, `for … in 0..<n` alloue à chaque tour, et ce fil suit
    /// les règles du callback de capture.
    func renderNextBlock() {
        var frame = 0
        while frame < blockFrames {
            let value = amplitude * Float(sin(phase))
            phase += phaseStep
            if phase >= 2 * .pi { phase -= 2 * .pi }
            var channel = 0
            while channel < channelCount {
                let index = bufferCount == 1
                    ? frame * channelCount + channel
                    : channel * blockFrames + frame
                samples[index] = value
                channel += 1
            }
            frame += 1
        }
    }

    func withBufferList(_ body: (UnsafePointer<AudioBufferList>) -> Void) {
        body(UnsafePointer(list.unsafePointer))
    }
}
