import AVFoundation
import Foundation

/// Écriture d'un fichier `.wav` à partir du flux capturé.
///
/// Sert uniquement à la validation au terminal (CDC section 11 : dump du flux dans un
/// `.wav` puis lecture via `afplay`). N'est jamais sur le chemin temps réel : il est
/// alimenté depuis le consommateur du ring buffer, pas depuis le callback de capture.
public final class WAVWriter {
    private let file: AVAudioFile
    private let format: AVAudioFormat
    public private(set) var framesWritten: AVAudioFramePosition = 0

    /// - Parameter format: format du flux entrant (celui du tap ou de l'entrée physique).
    ///   Le fichier est écrit en PCM entier 16 bits, format universellement lisible et
    ///   accepté par `afplay`, quel que soit le format flottant d'origine.
    public init(url: URL, format: AVAudioFormat) throws {
        self.format = format
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        // `interleaved` doit décrire le format des buffers fournis à `write(from:)`, pas
        // celui du fichier sur disque : le tap livre du float32 non entrelacé, et une
        // valeur incohérente ici fait échouer ExtAudioFileWrite avec l'OSStatus -50.
        self.file = try AVAudioFile(
            forWriting: url,
            settings: settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: format.isInterleaved
        )
    }

    public func write(_ buffer: AVAudioPCMBuffer) throws {
        guard buffer.frameLength > 0 else { return }
        try file.write(from: buffer)
        framesWritten += AVAudioFramePosition(buffer.frameLength)
    }

    public var duration: TimeInterval {
        format.sampleRate > 0 ? Double(framesWritten) / format.sampleRate : 0
    }
}

/// Mesure du niveau audio d'un buffer.
///
/// C'est l'outil de décision du test DRM du jalon 1 : distinguer « capté » d'un flux de
/// silence numérique parfait, un fichier `.wav` muet ayant exactement la même taille qu'un
/// fichier `.wav` contenant du son.
public struct LevelMeter: Sendable {
    public private(set) var peak: Float = 0
    public private(set) var sumOfSquares: Double = 0
    public private(set) var sampleCount: Int = 0

    public init() {}

    public mutating func consume(_ buffer: AVAudioPCMBuffer) {
        guard let channels = buffer.floatChannelData else { return }
        let frames = Int(buffer.frameLength)
        for channel in 0..<Int(buffer.format.channelCount) {
            let samples = channels[channel]
            for frame in 0..<frames {
                let value = samples[frame]
                let magnitude = abs(value)
                if magnitude > peak { peak = magnitude }
                sumOfSquares += Double(value) * Double(value)
            }
        }
        sampleCount += frames * Int(buffer.format.channelCount)
    }

    public var rms: Double {
        sampleCount > 0 ? (sumOfSquares / Double(sampleCount)).squareRoot() : 0
    }

    /// dBFS crête. `-inf` (représenté par `-200`) pour un silence numérique parfait.
    public var peakDBFS: Double {
        peak > 0 ? 20 * log10(Double(peak)) : -200
    }

    /// Vrai si le flux est un silence numérique strict (tous échantillons à zéro).
    ///
    /// Volontairement strict : c'est le résultat qu'on attendrait d'un blocage DRM, alors
    /// qu'un passage silencieux d'un vrai morceau conserve presque toujours du bruit de fond.
    public var isDigitalSilence: Bool { peak == 0 }
}
