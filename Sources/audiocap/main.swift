import AVFoundation
import AudioCore
import Foundation

// CLI minimal de validation (CDC section 11). Première étape du jalon 1 : capture système
// globale vers un .wav, pour le test DRM. Les autres modes viennent après ce test.

let arguments = CommandLine.arguments
let duration = arguments.count > 1 ? (Double(arguments[1]) ?? 10) : 10
let outputPath = arguments.count > 2 ? arguments[2] : "capture-globale.wav"
let outputURL = URL(fileURLWithPath: outputPath)

FileHandle.standardError.write(Data("""
    Capture système globale
      durée   : \(duration) s
      sortie  : \(outputURL.path)

    """.utf8))

// Le writer et le compteur de niveau sont alimentés depuis le callback temps réel via une
// file dédiée : à ce stade (test DRM) on privilégie la simplicité de lecture. Le ring
// buffer lock-free exigé par la section 12 arrive juste après ce test, pour le CLI complet.
final class CaptureSession: @unchecked Sendable {
    private let lock = NSLock()
    private var pendingBuffers: [AVAudioPCMBuffer] = []
    var meter = LevelMeter()

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        pendingBuffers.append(buffer)
        lock.unlock()
    }

    func drain() -> [AVAudioPCMBuffer] {
        lock.lock()
        defer { pendingBuffers.removeAll(); lock.unlock() }
        return pendingBuffers
    }
}

let session = CaptureSession()
var capturedFormat: AVAudioFormat?

nonisolated(unsafe) var callbackCount = 0
nonisolated(unsafe) var totalFramesSeen: UInt32 = 0
nonisolated(unsafe) var rawNonZeroSamples = 0

let capture = ProcessTapCapture { bufferList, frames in
    // Contexte temps réel : on copie les échantillons dans un AVAudioPCMBuffer et on
    // empile. Voir la note ci-dessus sur le ring buffer.
    callbackCount += 1
    totalFramesSeen += frames

    // Le buffer list arrive en lecture seule ; UnsafeMutableAudioBufferListPointer offre
    // l'itération sur les mBuffers, d'où ce cast explicite (aucune écriture n'est faite).
    let list = UnsafeMutableAudioBufferListPointer(
        UnsafeMutablePointer(mutating: bufferList)
    )
    // Diagnostic : compte les échantillons non nuls directement dans le buffer livré par
    // Core Audio, avant toute conversion, pour distinguer « le tap ne fournit rien » de
    // « la conversion vers AVAudioPCMBuffer perd le signal ».
    for buffer in list {
        guard let data = buffer.mData else { continue }
        let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
        let samples = data.assumingMemoryBound(to: Float.self)
        for index in 0..<count where samples[index] != 0 {
            rawNonZeroSamples += 1
        }
    }

    guard let format = capturedFormat, frames > 0,
          let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)
    else { return }
    copy.frameLength = frames

    // Format entrelacé : un seul mBuffer contenant les canaux imbriqués, donc une copie
    // mémoire directe plutôt qu'un parcours par canal.
    if format.isInterleaved {
        guard let src = list.first?.mData, let dst = copy.audioBufferList.pointee.mBuffers.mData
        else { return }
        let bytes = min(
            Int(list.first?.mDataByteSize ?? 0),
            Int(copy.audioBufferList.pointee.mBuffers.mDataByteSize)
        )
        dst.copyMemory(from: src, byteCount: bytes)
    } else if let dst = copy.floatChannelData {
        for (channel, buffer) in list.enumerated() where channel < Int(format.channelCount) {
            guard let data = buffer.mData else { continue }
            dst[channel].update(
                from: data.assumingMemoryBound(to: Float.self), count: Int(frames)
            )
        }
    }
    session.append(copy)
}

do {
    // Sans autorisation, le Process Tap ne signale aucune erreur : il livre des buffers de
    // silence numérique. On lit donc l'état réel de kTCCServiceAudioCapture avant, sous
    // peine d'interpréter à tort ce silence comme un blocage DRM.
    let granted = await CapturePermission.request(for: .systemAudio)
    let permissionStatus = CapturePermission.status(for: .systemAudio)
    FileHandle.standardError.write(Data(
        "Autorisation « sons du système » : \(permissionStatus.rawValue)\n".utf8))
    if !granted {
        FileHandle.standardError.write(Data(
            "\(CapturePermission.guidance(for: .systemAudio))\n".utf8))
        exit(3)
    }

    try capture.start(mode: .globalExcluding(pids: []))
    guard let format = capture.format else {
        throw AudioCaptureError.tapFormatUnavailable
    }
    capturedFormat = format
    FileHandle.standardError.write(Data("""
        Format livré par le tap
          échantillonnage : \(format.sampleRate) Hz
          canaux          : \(format.channelCount)
          entrelacé       : \(format.isInterleaved ? "oui" : "non")
          format commun   : \(format.commonFormat.rawValue)

        """.utf8))

    let writer = try WAVWriter(url: outputURL, format: format)
    let deadline = Date().addingTimeInterval(duration)

    while Date() < deadline {
        // Boucle de drainage, hors contexte temps réel : Swift Concurrency y est approprié
        // (CDC section 13, la contrainte ne porte que sur le callback de rendu audio).
        try await Task.sleep(for: .milliseconds(100))
        for buffer in session.drain() {
            session.meter.consume(buffer)
            try writer.write(buffer)
        }
    }

    capture.stop()
    for buffer in session.drain() {
        session.meter.consume(buffer)
        try writer.write(buffer)
    }

    let meter = session.meter
    print("""

        Diagnostic callback
          appels         : \(callbackCount)
          trames vues    : \(totalFramesSeen)
          échant. non nuls (buffer brut) : \(rawNonZeroSamples)

        Résultat
          fichier        : \(outputURL.path)
          durée écrite   : \(String(format: "%.2f", writer.duration)) s
          crête          : \(String(format: "%.1f", meter.peakDBFS)) dBFS
          RMS            : \(String(format: "%.6f", meter.rms))
          silence total  : \(meter.isDigitalSilence ? "OUI (aucun échantillon non nul)" : "non")
        """)

    if meter.isDigitalSilence {
        // Un silence numérique parfait n'est presque jamais du vrai contenu : c'est le
        // symptôme d'une autorisation manquante. Ne pas le confondre avec un blocage DRM.
        FileHandle.standardError.write(Data(
            "\n\(CapturePermission.guidance(for: .systemAudio))\n".utf8))
    }
    exit(meter.isDigitalSilence ? 2 : 0)
} catch {
    FileHandle.standardError.write(Data("ERREUR : \(error)\n".utf8))
    capture.stop()
    exit(1)
}
