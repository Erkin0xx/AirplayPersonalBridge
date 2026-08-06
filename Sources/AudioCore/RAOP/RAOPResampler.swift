import AVFoundation
import Foundation

/// Conversion du flux capturé vers le format exigé par RAOP.
///
/// La capture livre du float32 entrelacé à 48 kHz (constaté au jalon 1), tandis que RAOP
/// impose 44 100 Hz / 16 bits / stéréo (`sr`, `ss`, `ch` de l'enregistrement TXT). Cette
/// classe fait les deux conversions — fréquence et profondeur — en un seul passage.
///
/// **Emplacement**, pour lever toute ambiguïté avec la section 13 : cette conversion tourne
/// dans la tâche propre au sender, **en aval du ring buffer**, jamais dans le callback de
/// capture. Le CDC 4.5 l'autorise explicitement à cet endroit. Elle ne lit que des copies
/// déjà extraites du ring buffer et ne touche jamais le tampon partagé (invariant
/// section 12).
///
/// `AVAudioConverter` est le premier choix du CDC 4.5 : natif, sans dépendance C
/// supplémentaire, et il maintient son propre état de filtre entre les appels — ce qui est
/// indispensable ici, un flux continu ne pouvant pas être reéchantillonné bloc par bloc de
/// façon indépendante sans introduire une discontinuité à chaque jointure.
/// `@unchecked Sendable` : le bloc que `AVAudioConverter.convert` rappelle est marqué
/// `@Sendable` par l'API, alors qu'il s'exécute en réalité de façon synchrone sur le thread
/// appelant. L'instance est par ailleurs possédée exclusivement par l'acteur `RAOPSender`,
/// qui sérialise tous les accès : il n'y a pas de concurrence réelle à protéger.
public final class RAOPResampler: @unchecked Sendable {
    public let inputFormat: AVAudioFormat
    public let outputFormat: AVAudioFormat

    private let converter: AVAudioConverter
    private let inputBuffer: AVAudioPCMBuffer
    private let outputBuffer: AVAudioPCMBuffer

    /// Trames d'entrée en attente dans `inputBuffer`, non encore soumises au convertisseur.
    private var pendingInputFrames: AVAudioFrameCount = 0

    public init(
        inputFormat: AVAudioFormat,
        outputSampleRate: Double = 44_100,
        channelCount: AVAudioChannelCount = 2,
        maximumInputFrames: AVAudioFrameCount = 2_048
    ) throws {
        self.inputFormat = inputFormat
        // Entier 16 bits signé, entrelacé, petit-boutiste : c'est ce qu'attend l'encodeur
        // ALAC, et ce que le SDP annonce au récepteur.
        guard let output = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: outputSampleRate,
            channels: channelCount,
            interleaved: true
        ) else {
            throw RAOPResamplerError.unsupportedOutputFormat(
                sampleRate: outputSampleRate, channels: channelCount
            )
        }
        self.outputFormat = output

        guard let converter = AVAudioConverter(from: inputFormat, to: output) else {
            throw RAOPResamplerError.converterUnavailable(
                from: inputFormat.sampleRate, to: outputSampleRate
            )
        }
        // Qualité maximale : la conversion tourne hors temps réel et le coût CPU est
        // négligeable devant le confort d'écoute, qui est l'objet du projet.
        converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
        self.converter = converter

        // Capacité de sortie majorée : un ratio 44,1/48 réduit le nombre de trames, mais la
        // marge couvre le cas d'un format d'entrée plus lent que la sortie.
        let ratio = outputSampleRate / inputFormat.sampleRate
        let outputCapacity = AVAudioFrameCount(Double(maximumInputFrames) * ratio) + 1_024

        guard let input = AVAudioPCMBuffer(
                pcmFormat: inputFormat, frameCapacity: maximumInputFrames),
              let outputPCM = AVAudioPCMBuffer(
                pcmFormat: output, frameCapacity: outputCapacity)
        else {
            throw RAOPResamplerError.bufferAllocationFailed
        }
        self.inputBuffer = input
        self.outputBuffer = outputPCM
    }

    /// Convertit un bloc de trames entrelacées float32 en trames entrelacées Int16 à
    /// 44,1 kHz.
    ///
    /// - Parameters:
    ///   - source: échantillons entrelacés, `frameCount * canaux d'entrée` valeurs.
    ///   - frameCount: nombre de trames d'entrée.
    /// - Returns: les échantillons Int16 entrelacés produits. Peut être vide si le
    ///   convertisseur retient encore des trames pour son filtre — ce n'est pas une erreur.
    public func convert(_ source: UnsafePointer<Float>, frameCount: Int) throws -> [Int16] {
        guard frameCount > 0 else { return [] }
        let channels = Int(inputFormat.channelCount)
        var produced: [Int16] = []
        var offset = 0

        while offset < frameCount {
            let chunk = min(frameCount - offset, Int(inputBuffer.frameCapacity))
            try fillInputBuffer(source.advanced(by: offset * channels), frames: chunk)
            produced.append(contentsOf: try drainConverter())
            offset += chunk
        }
        return produced
    }

    private func fillInputBuffer(_ source: UnsafePointer<Float>, frames: Int) throws {
        let channels = Int(inputFormat.channelCount)
        inputBuffer.frameLength = AVAudioFrameCount(frames)

        if inputFormat.isInterleaved {
            guard let destination = inputBuffer.audioBufferList.pointee.mBuffers.mData else {
                throw RAOPResamplerError.bufferAllocationFailed
            }
            destination.copyMemory(
                from: source, byteCount: frames * channels * MemoryLayout<Float>.size
            )
        } else if let destination = inputBuffer.floatChannelData {
            // Le ring buffer stocke toujours de l'entrelacé : désentrelacement ici si le
            // format d'entrée déclaré est planaire.
            for channel in 0..<channels {
                for frame in 0..<frames {
                    destination[channel][frame] = source[frame * channels + channel]
                }
            }
        } else {
            throw RAOPResamplerError.bufferAllocationFailed
        }
        pendingInputFrames = AVAudioFrameCount(frames)
    }

    /// Pousse le bloc courant dans le convertisseur et récupère tout ce qu'il rend.
    private func drainConverter() throws -> [Int16] {
        var produced: [Int16] = []
        while true {
            outputBuffer.frameLength = 0
            var conversionError: NSError?
            let status = converter.convert(to: outputBuffer, error: &conversionError) {
                _, outStatus in
                // Le convertisseur redemande des données tant qu'il peut : ne fournir le
                // bloc courant qu'une fois, puis déclarer la disette. Sans ce garde-fou, le
                // même bloc serait resoumis en boucle.
                guard self.pendingInputFrames > 0 else {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                self.pendingInputFrames = 0
                outStatus.pointee = .haveData
                return self.inputBuffer
            }

            if let conversionError {
                throw RAOPResamplerError.conversionFailed(conversionError.localizedDescription)
            }
            let frames = Int(outputBuffer.frameLength)
            if frames > 0, let data = outputBuffer.int16ChannelData {
                let channels = Int(outputFormat.channelCount)
                produced.append(
                    contentsOf: UnsafeBufferPointer(start: data[0], count: frames * channels)
                )
            }

            // PIÈGE vérifié à la sonde : `convert` ne rend **jamais plus de 4096 trames par
            // appel**, quelle que soit la capacité du tampon de sortie, et signale alors
            // `.inputRanDry` alors qu'il retient encore des trames. Sortir sur ce seul
            // statut perdrait ces trames — ~6,5 % du flux sur un bloc de 4800, soit un
            // défaut audible et permanent. On ne s'arrête donc que sur un appel réellement
            // improductif, ou sur un statut terminal.
            if frames == 0 { break }
            if status == .error || status == .endOfStream { break }
        }
        return produced
    }
}

public enum RAOPResamplerError: Error, CustomStringConvertible {
    case unsupportedOutputFormat(sampleRate: Double, channels: AVAudioChannelCount)
    case converterUnavailable(from: Double, to: Double)
    case bufferAllocationFailed
    case conversionFailed(String)

    public var description: String {
        switch self {
        case let .unsupportedOutputFormat(sampleRate, channels):
            return "format de sortie RAOP impossible à décrire (\(sampleRate) Hz, \(channels) canaux)"
        case let .converterUnavailable(from, to):
            return "AVAudioConverter indisponible pour \(from) Hz → \(to) Hz"
        case .bufferAllocationFailed:
            return "allocation des tampons de conversion en échec"
        case let .conversionFailed(reason):
            return "conversion audio en échec : \(reason)"
        }
    }
}
