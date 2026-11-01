import AVFoundation
import Foundation

/// Ramène les blocs d'une source quelconque au format des ring buffers : float32, entrelacé,
/// stéréo.
///
/// ## Pourquoi au niveau du format
///
/// Le Process Tap livre de l'entrelacé stéréo, l'entrée physique du **mono planaire**, et une
/// interface audio peut exposer dix-huit canaux (`CLAUDE.md`, jalon 1). Les senders, eux,
/// reçoivent un ring buffer et un format, et n'ont pas à connaître la source (invariant
/// section 12). Normaliser ici leur évite de porter autant de cas que de sources.
///
/// **Le tampon de la source n'est jamais modifié** : la duplication se fait dans un tampon
/// propre à cet adaptateur, alloué une fois.
///
/// Le chemin stéréo entrelacé, celui du Process Tap, reste **sans copie** : le pointeur de la
/// source part directement vers le fanout, exactement comme avant l'existence de ce type.
///
/// Le callback de capture appelle ``consume(_:frameCount:)`` : ni allocation, ni verrou.
final class CaptureBlockAdapter: @unchecked Sendable {
    /// Trames recopiées par passe. Un bloc plus long est traité en plusieurs passes.
    private static let scratchFrames = 4_096
    private static let outputChannels = 2

    let outputFormat: AVAudioFormat
    private let fanout: CaptureFanout
    private let sourceChannels: Int
    private let sourceIsInterleaved: Bool
    private let isPassthrough: Bool
    private let scratch: UnsafeMutablePointer<Float>

    /// Format que les ring buffers et les senders verront pour une source donnée.
    ///
    /// Le format de la source est rendu tel quel quand il convient : c'est lui que le
    /// rééchantillonneur des senders a toujours reçu sur le chemin du Process Tap.
    static func normalizedFormat(for source: AVAudioFormat) throws -> AVAudioFormat {
        guard source.commonFormat == .pcmFormatFloat32 else {
            throw AudioCaptureError.unsupportedFormat(
                "seul le float32 est pris en charge (reçu : \(source))")
        }
        guard source.channelCount > 0, source.sampleRate > 0 else {
            throw AudioCaptureError.unsupportedFormat("format vide (\(source))")
        }
        if source.channelCount == outputChannels, source.isInterleaved { return source }
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: source.sampleRate,
            channels: AVAudioChannelCount(outputChannels),
            interleaved: true
        ) else {
            throw AudioCaptureError.unsupportedFormat("stéréo entrelacé à \(source.sampleRate) Hz")
        }
        return format
    }

    init(sourceFormat: AVAudioFormat, fanout: CaptureFanout) throws {
        self.outputFormat = try Self.normalizedFormat(for: sourceFormat)
        self.fanout = fanout
        self.sourceChannels = Int(sourceFormat.channelCount)
        self.sourceIsInterleaved = sourceFormat.isInterleaved
        self.isPassthrough = sourceFormat.channelCount == Self.outputChannels
            && sourceFormat.isInterleaved
        self.scratch = .allocate(capacity: Self.scratchFrames * Self.outputChannels)
        scratch.initialize(repeating: 0, count: Self.scratchFrames * Self.outputChannels)
    }

    deinit {
        scratch.deinitialize(count: Self.scratchFrames * Self.outputChannels)
        scratch.deallocate()
    }

    /// Le consommateur à remettre à la source.
    ///
    /// Fabriqué ici et non chez l'appelant : une fermeture formée dans l'acteur du moteur en
    /// hériterait l'isolation, alors qu'elle s'exécutera sur le thread temps réel.
    func makeConsumer() -> CaptureBlockConsumer {
        { [self] list, frames in consume(list, frameCount: frames) }
    }

    /// Consomme un bloc de la source. **Appelé depuis le callback de capture.**
    func consume(_ list: UnsafePointer<AudioBufferList>, frameCount: UInt32) {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
        guard frameCount > 0, buffers.count > 0, let first = buffers[0].mData else { return }

        if isPassthrough {
            fanout.write(first.assumingMemoryBound(to: Float.self), frameCount: Int(frameCount))
            return
        }

        // Canaux retenus : les deux premiers, ou le seul dupliqué. Au-delà de deux, c'est une
        // interface multicanal dont l'utilisateur branche la paire 1-2 : mélanger des entrées
        // sans rapport serait moins prévisible que de les ignorer.
        let left: UnsafePointer<Float>
        let right: UnsafePointer<Float>
        let stride: Int
        if sourceIsInterleaved {
            let base = UnsafePointer(first.assumingMemoryBound(to: Float.self))
            left = base
            right = sourceChannels > 1 ? base + 1 : base
            stride = sourceChannels
        } else {
            let base = UnsafePointer(first.assumingMemoryBound(to: Float.self))
            left = base
            if sourceChannels > 1, buffers.count > 1, let second = buffers[1].mData {
                right = UnsafePointer(second.assumingMemoryBound(to: Float.self))
            } else {
                right = base
            }
            stride = 1
        }

        // Le tampon de la source fait foi : ne jamais lire au-delà de ce qu'il déclare.
        let available = Int(buffers[0].mDataByteSize) / (stride * MemoryLayout<Float>.size)
        let frames = min(Int(frameCount), available)

        // `while` et non `for … in 0..<n` : hors optimisation, l'itérateur de `Range` alloue à
        // chaque tour (relevé par la sonde de `RealTimePathTests`). Une application lancée depuis
        // Xcode en Debug passerait ici 44 000 fois par seconde.
        var offset = 0
        while offset < frames {
            let chunk = min(frames - offset, Self.scratchFrames)
            var frame = 0
            while frame < chunk {
                let position = (offset + frame) * stride
                scratch[frame * 2] = left[position]
                scratch[frame * 2 + 1] = right[position]
                frame += 1
            }
            fanout.write(UnsafePointer(scratch), frameCount: chunk)
            offset += chunk
        }
    }
}
