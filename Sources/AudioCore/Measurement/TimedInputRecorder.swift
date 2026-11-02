import AVFoundation
import Atomics
import Foundation

/// Enregistrement daté d'une entrée audio, pour la mesure acoustique du calage entre enceintes.
///
/// ## Ce qu'il garde
///
/// La **première voie** de l'entrée, en mono : un micro n'en a qu'une, et c'est assez pour repérer
/// des salves. Et des **points d'ancrage** : la position, dans l'enregistrement, de la première trame
/// d'un bloc dont l'horodatage hôte est connu (`AVAudioTime.hostTime`). Un ancrage par bloc au plus,
/// un toutes les `anchorIntervalSeconds` au moins espacés, le tout premier bloc compris. Ils datent
/// chaque échantillon sur l'horloge hôte malgré la dérive de l'horloge du micro (quelques dizaines de
/// ppm, soit des millisecondes sur une minute) et malgré un éventuel trou de capture.
///
/// ## Temps réel
///
/// Le consommateur remis à la source suit les règles du callback de capture (CDC section 13) : il
/// recopie dans un ring buffer lock-free et note l'ancrage dans une mémoire réservée d'avance, sans
/// allocation ni verrou. Le fichier s'écrit hors temps réel, par ``drain(into:)``.
public final class TimedInputRecorder: @unchecked Sendable {
    public struct Anchor: Sendable, Equatable {
        /// Position dans l'enregistrement, en trames.
        public let frame: Int
        /// Instant hôte de cette trame, en ticks `mach_absolute_time`.
        public let hostTicks: UInt64

        public init(frame: Int, hostTicks: UInt64) {
            self.frame = frame
            self.hostTicks = hostTicks
        }
    }

    public let sampleRate: Double
    /// Format des tampons remis au fichier : mono flottant, à la fréquence de l'entrée.
    public let recordingFormat: AVAudioFormat

    private let ring: AudioRingBuffer
    private let scratch: UnsafeMutablePointer<Float>
    private let scratchFrames = 8_192
    private let anchorFrames: UnsafeMutablePointer<Int>
    private let anchorTicks: UnsafeMutablePointer<UInt64>
    private let anchorCapacity: Int
    /// Publié après l'écriture de l'ancrage qu'il rend visible.
    private let anchorCount = ManagedAtomic<Int>(0)
    private let anchorIntervalFrames: Int

    // État du seul producteur, le fil de la source.
    private var framesQueued = 0
    private var nextAnchorFrame = 0

    // État du seul consommateur, hors temps réel.
    private let drainBuffer: AVAudioPCMBuffer
    public private(set) var framesDrained = 0

    /// - Parameters:
    ///   - sourceFormat: format des blocs de la source, flottant, entrelacé ou non.
    ///   - bufferSeconds: profondeur du tampon entre la source et le fichier.
    ///   - anchorIntervalSeconds: espacement minimal de deux ancrages.
    ///   - anchorCapacity: ancrages au plus. 65 536 à 0,25 s couvrent quatre heures.
    public init(
        sourceFormat: AVAudioFormat,
        bufferSeconds: Double = 30,
        anchorIntervalSeconds: Double = 0.25,
        anchorCapacity: Int = 65_536
    ) throws {
        guard sourceFormat.commonFormat == .pcmFormatFloat32, sourceFormat.sampleRate > 0,
              sourceFormat.channelCount > 0
        else {
            throw AudioCaptureError.unsupportedFormat("enregistrement : \(sourceFormat)")
        }
        guard let mono = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: sourceFormat.sampleRate, channels: 1,
            interleaved: false
        ), let drainBuffer = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: 16_384) else {
            throw AudioCaptureError.unsupportedFormat("enregistrement mono à \(sourceFormat.sampleRate) Hz")
        }
        self.sampleRate = sourceFormat.sampleRate
        self.recordingFormat = mono
        self.drainBuffer = drainBuffer
        self.ring = AudioRingBuffer(
            capacityFrames: max(4_096, Int(bufferSeconds * sourceFormat.sampleRate)), channelCount: 1
        )
        self.scratch = .allocate(capacity: scratchFrames)
        scratch.initialize(repeating: 0, count: scratchFrames)
        self.anchorCapacity = max(1, anchorCapacity)
        self.anchorFrames = .allocate(capacity: max(1, anchorCapacity))
        self.anchorTicks = .allocate(capacity: max(1, anchorCapacity))
        self.anchorIntervalFrames = max(1, Int(anchorIntervalSeconds * sourceFormat.sampleRate))
    }

    deinit {
        scratch.deinitialize(count: scratchFrames)
        scratch.deallocate()
        anchorFrames.deallocate()
        anchorTicks.deallocate()
    }

    /// Le consommateur à remettre à la source. **Appelé depuis son fil temps réel.**
    ///
    /// Formé ici, hors de tout acteur : une fermeture formée dans un acteur en hérite l'isolation
    /// (`CLAUDE.md`, jalon 5).
    public func makeConsumer() -> TimedCaptureBlockConsumer {
        { [self] list, frameCount, hostTicks in
            consume(list, frameCount: Int(frameCount), hostTicks: hostTicks)
        }
    }

    /// Recopie la première voie d'un bloc et note son ancrage. Sans allocation ni verrou.
    func consume(_ list: UnsafePointer<AudioBufferList>, frameCount: Int, hostTicks: UInt64) {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
        guard frameCount > 0, buffers.count > 0, let data = buffers[0].mData else { return }
        // Entrelacé : toutes les voies dans le premier tampon. Planaire : la première seule.
        let stride = max(1, Int(buffers[0].mNumberChannels))
        let available = Int(buffers[0].mDataByteSize) / (stride * MemoryLayout<Float>.size)
        let frames = min(frameCount, available)
        guard frames > 0 else { return }

        let firstFrame = framesQueued
        let source = data.assumingMemoryBound(to: Float.self)
        var written = 0
        if stride == 1 {
            written = ring.write(from: source, frameCount: frames)
        } else {
            var offset = 0
            while offset < frames {
                let chunk = min(scratchFrames, frames - offset)
                var frame = 0
                while frame < chunk {
                    scratch[frame] = source[(offset + frame) * stride]
                    frame += 1
                }
                written += ring.write(from: scratch, frameCount: chunk)
                offset += chunk
            }
        }
        framesQueued += written

        // Un bloc refusé en entier n'a pas de trame dans le fichier : son instant n'y date rien. Un
        // bloc tronqué perd sa fin, sa première trame reste bien à `firstFrame`.
        guard hostTicks != 0, written > 0, firstFrame >= nextAnchorFrame else { return }
        let count = anchorCount.load(ordering: .relaxed)
        guard count < anchorCapacity else { return }
        anchorFrames[count] = firstFrame
        anchorTicks[count] = hostTicks
        anchorCount.store(count + 1, ordering: .releasing)
        nextAnchorFrame = firstFrame + anchorIntervalFrames
    }

    /// Ancrages notés jusqu'ici, dans l'ordre. Hors temps réel.
    public var anchors: [Anchor] {
        let count = anchorCount.load(ordering: .acquiring)
        var result: [Anchor] = []
        result.reserveCapacity(count)
        var index = 0
        while index < count {
            result.append(Anchor(frame: anchorFrames[index], hostTicks: anchorTicks[index]))
            index += 1
        }
        return result
    }

    /// Trames refusées faute de place : non nul, l'enregistrement a des trous que les ancrages
    /// situent, mais qui méritent d'être signalés.
    public var droppedFrames: Int { ring.droppedFrames }

    /// Vide le tampon, bloc par bloc. Hors temps réel, un seul appelant à la fois.
    ///
    /// - Returns: le nombre de trames rendues.
    @discardableResult
    public func drain(_ body: (AVAudioPCMBuffer) throws -> Void) rethrows -> Int {
        guard let channel = drainBuffer.floatChannelData?[0] else { return 0 }
        var total = 0
        while true {
            let read = ring.read(into: channel, frameCount: Int(drainBuffer.frameCapacity))
            guard read > 0 else { break }
            drainBuffer.frameLength = AVAudioFrameCount(read)
            try body(drainBuffer)
            total += read
        }
        framesDrained += total
        return total
    }

    /// Vide le tampon vers un fichier ouvert avec ``recordingFormat``.
    @discardableResult
    public func drain(into writer: WAVWriter) throws -> Int {
        try drain { try writer.write($0) }
    }
}
