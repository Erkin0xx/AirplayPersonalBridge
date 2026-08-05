import AVFoundation
import AudioCore
import Foundation

// CLI de validation du jalon 1 (CDC section 11) : les trois modes de capture, chacun
// dumpant un .wav relisible par `afplay`.
//
//   audiocap [--mode global|app|input] [--app <nom|pid>] [--list] [durée_s] [sortie.wav]
//
// À lancer via ./audiocap (wrapper `open`), jamais par le binaire interne : l'autorisation
// TCC est attribuée au bundle, pas au binaire nu.

/// Sortie du CLI, dupliquée dans un fichier.
///
/// Lancé via `open` (indispensable pour que TCC attribue l'autorisation au bundle), le
/// process n'hérite ni du terminal ni des variables d'environnement : stdout et stderr
/// partent dans le vide. Le wrapper `./audiocap` lit donc ce fichier à la place.
enum CLIOutput {
    static let path = "/tmp/audiocap-output.txt"
    nonisolated(unsafe) private static var handle: FileHandle? = {
        FileManager.default.createFile(atPath: path, contents: nil)
        return FileHandle(forWritingAtPath: path)
    }()

    static func write(_ text: String) {
        let line = Data("\(text)\n".utf8)
        FileHandle.standardError.write(line)
        handle?.write(line)
    }
}

func note(_ text: String) { CLIOutput.write(text) }

enum Mode: String {
    case global, app, input
}

var mode = Mode.global
var appHint: String?
var duration: Double = 10
var outputPath: String?
var listOnly = false

var arguments = Array(CommandLine.arguments.dropFirst())
var index = 0
while index < arguments.count {
    let argument = arguments[index]
    switch argument {
    case "--mode":
        index += 1
        guard index < arguments.count, let parsed = Mode(rawValue: arguments[index]) else {
            FileHandle.standardError.write(Data("--mode attend global|app|input\n".utf8))
            exit(2)
        }
        mode = parsed
    case "--app":
        index += 1
        guard index < arguments.count else {
            FileHandle.standardError.write(Data("--app attend un nom ou un pid\n".utf8))
            exit(2)
        }
        appHint = arguments[index]
        mode = .app
    case "--list":
        listOnly = true
    case "--help", "-h":
        note("""
            audiocap — capture audio de validation (jalon 1)

              --mode global|app|input   mode de capture (défaut : global)
              --app <nom|pid>           application à capter (implique --mode app)
              --list                    liste les process audio et quitte
              <durée_s> <sortie.wav>    durée et fichier de sortie

            Exemples :
              ./audiocap --list
              ./audiocap 10 systeme.wav
              ./audiocap --app Music 10 music.wav
              ./audiocap --mode input 10 entree.wav
            """)
        exit(0)
    default:
        if let value = Double(argument), outputPath == nil, value > 0, argument.first != "-" {
            duration = value
        } else if argument.first != "-" {
            outputPath = argument
        }
    }
    index += 1
}


// --- Mode liste ---
if listOnly {
    do {
        let processes = try AudioProcessList.all().sorted {
            ($0.isPlaying ? 0 : 1, $0.displayName) < ($1.isPlaying ? 0 : 1, $1.displayName)
        }
        note("Process audio (● = en train de jouer) :\n")
        for process in processes {
            note(String(
                format: "  %@ %-28@ pid=%-7d %@",
                process.isPlaying ? "●" : "○",
                process.displayName as NSString,
                process.pid,
                process.bundleID
            ))
        }
        exit(0)
    } catch {
        note("ERREUR : \(error)")
        exit(1)
    }
}

let outputURL = URL(fileURLWithPath: outputPath ?? "capture-\(mode.rawValue).wav")

// --- Collecteur alimenté par le ring buffer ---
//
// Le callback de capture écrit dans un ring buffer lock-free (invariant section 12) ; cette
// boucle, hors temps réel, le draine et écrit le .wav. C'est exactement la frontière que
// franchiront les senders des jalons 2 et 3, à ceci près qu'ils écriront sur le réseau.
final class CaptureSink: @unchecked Sendable {
    let ring: AudioRingBuffer
    let format: AVAudioFormat
    private var scratch: [Float]
    fileprivate var interleaveScratch: [Float]

    init(format: AVAudioFormat, capacityFrames: Int = 48_000) {
        self.format = format
        self.ring = AudioRingBuffer(
            capacityFrames: capacityFrames, channelCount: Int(format.channelCount)
        )
        self.scratch = [Float](
            repeating: 0, count: capacityFrames * Int(format.channelCount)
        )
        // Tampon d'entrelacement, alloué une fois : le chemin temps réel n'alloue jamais.
        self.interleaveScratch = [Float](repeating: 0, count: 8192 * Int(format.channelCount))
    }

    /// Entrelace des canaux planaires puis écrit dans le ring buffer.
    ///
    /// Appelé depuis le thread de rendu d'AVAudioEngine. `interleaveScratch` est alloué une
    /// fois à l'init : rien n'est alloué ici (CDC section 13).
    func interleaveAndWrite(_ channels: UnsafePointer<UnsafeMutablePointer<Float>>, frames: Int) {
        let channelCount = Int(format.channelCount)
        let capacityFrames = interleaveScratch.count / channelCount
        var offset = 0
        while offset < frames {
            let chunk = min(frames - offset, capacityFrames)
            interleaveScratch.withUnsafeMutableBufferPointer { buffer in
                guard let base = buffer.baseAddress else { return }
                for frame in 0..<chunk {
                    for channel in 0..<channelCount {
                        base[frame * channelCount + channel] = channels[channel][offset + frame]
                    }
                }
                ring.write(from: base, frameCount: chunk)
            }
            offset += chunk
        }
    }

    /// Draine le ring buffer vers le writer. Hors contexte temps réel.
    func drain(into writer: WAVWriter, meter: inout LevelMeter) throws {
        let channels = Int(format.channelCount)
        while ring.availableFrames > 0 {
            let frames = min(ring.availableFrames, scratch.count / channels)
            guard frames > 0 else { break }
            let read = scratch.withUnsafeMutableBufferPointer { buffer -> Int in
                guard let base = buffer.baseAddress else { return 0 }
                return ring.read(into: base, frameCount: frames)
            }
            guard read > 0,
                  let buffer = AVAudioPCMBuffer(
                      pcmFormat: format, frameCapacity: AVAudioFrameCount(read))
            else { break }
            buffer.frameLength = AVAudioFrameCount(read)

            if format.isInterleaved {
                if let destination = buffer.audioBufferList.pointee.mBuffers.mData {
                    scratch.withUnsafeBufferPointer { source in
                        if let base = source.baseAddress {
                            destination.copyMemory(
                                from: base, byteCount: read * channels * MemoryLayout<Float>.size
                            )
                        }
                    }
                }
            } else if let destination = buffer.floatChannelData {
                // Désentrelacement : le ring buffer stocke toujours en entrelacé.
                scratch.withUnsafeBufferPointer { source in
                    guard let base = source.baseAddress else { return }
                    for channel in 0..<channels {
                        for frame in 0..<read {
                            destination[channel][frame] = base[frame * channels + channel]
                        }
                    }
                }
            }
            meter.consume(buffer)
            try writer.write(buffer)
        }
    }
}

func report(_ writer: WAVWriter, _ meter: LevelMeter, _ ring: AudioRingBuffer) {
    print("""

        Résultat
          fichier        : \(outputURL.path)
          durée écrite   : \(String(format: "%.2f", writer.duration)) s
          crête          : \(String(format: "%.1f", meter.peakDBFS)) dBFS
          RMS            : \(String(format: "%.6f", meter.rms))
          trames refusées: \(ring.droppedFrames)
          silence total  : \(meter.isDigitalSilence ? "OUI (aucun échantillon non nul)" : "non")
        """)
}

// --- Capture ---
do {
    note("Mode : \(mode.rawValue)   durée : \(duration) s   sortie : \(outputURL.path)")

    var meter = LevelMeter()

    switch mode {
    case .global, .app:
        let permission = CapturePermission.status(for: .systemAudio)
        note("Autorisation « sons du système » : \(permission.rawValue)")
        if permission != .authorized {
            let granted = await CapturePermission.request(for: .systemAudio)
            if !granted {
                note(CapturePermission.guidance(for: .systemAudio))
                exit(3)
            }
        }

        let tapMode: ProcessTapCapture.Mode
        if mode == .app {
            guard let hint = appHint else {
                note("--mode app exige --app <nom|pid>")
                exit(2)
            }
            let process = try AudioProcessList.find(matching: hint)
            note("Application ciblée : \(process.displayName) (pid \(process.pid), "
                + "\(process.isPlaying ? "en lecture" : "silencieuse"))")
            tapMode = .processes(pids: [process.pid])
        } else {
            tapMode = .globalExcluding(pids: [])
        }

        // Le sink doit exister avant le démarrage, mais son format vient du tap : on crée
        // d'abord un tap sans consommateur pour lire le format, d'où cette indirection.
        nonisolated(unsafe) var sink: CaptureSink?
        let capture = ProcessTapCapture { bufferList, frames in
            guard let sink, frames > 0 else { return }
            let list = UnsafeMutableAudioBufferListPointer(
                UnsafeMutablePointer(mutating: bufferList))
            guard let data = list.first?.mData else { return }
            // Écriture lock-free et sans allocation depuis le thread temps réel.
            sink.ring.write(
                from: data.assumingMemoryBound(to: Float.self), frameCount: Int(frames))
        }

        try capture.start(mode: tapMode)
        guard let format = capture.format else { throw AudioCaptureError.tapFormatUnavailable }
        note("Format : \(format.sampleRate) Hz, \(format.channelCount) canaux, "
            + "\(format.isInterleaved ? "entrelacé" : "planaire")")
        let activeSink = CaptureSink(format: format)
        sink = activeSink

        let writer = try WAVWriter(url: outputURL, format: format)
        let deadline = Date().addingTimeInterval(duration)
        while Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
            try activeSink.drain(into: writer, meter: &meter)
        }
        capture.stop()
        try activeSink.drain(into: writer, meter: &meter)
        report(writer, meter, activeSink.ring)
        exit(meter.isDigitalSilence ? 2 : 0)

    case .input:
        let permission = CapturePermission.status(for: .microphone)
        note("Autorisation micro : \(permission.rawValue)")
        if permission != .authorized {
            let granted = await CapturePermission.request(for: .microphone)
            if !granted {
                note(CapturePermission.guidance(for: .microphone))
                exit(3)
            }
        }

        nonisolated(unsafe) var sink: CaptureSink?
        let capture = InputDeviceCapture { buffer in
            guard let sink else { return }
            let frames = Int(buffer.frameLength)
            guard frames > 0 else { return }
            if buffer.format.isInterleaved {
                if let data = buffer.audioBufferList.pointee.mBuffers.mData {
                    sink.ring.write(
                        from: data.assumingMemoryBound(to: Float.self), frameCount: frames)
                }
            } else if let channels = buffer.floatChannelData {
                // AVAudioEngine livre du planaire : le ring buffer attend de l'entrelacé.
                sink.interleaveAndWrite(channels, frames: frames)
            }
        }

        try capture.start()
        guard let format = capture.format else { throw AudioCaptureError.noInputDevice }
        note("Format : \(format.sampleRate) Hz, \(format.channelCount) canaux, "
            + "\(format.isInterleaved ? "entrelacé" : "planaire")")
        let activeSink = CaptureSink(format: format)
        sink = activeSink

        let writer = try WAVWriter(url: outputURL, format: format)
        let deadline = Date().addingTimeInterval(duration)
        while Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
            try activeSink.drain(into: writer, meter: &meter)
        }
        capture.stop()
        try activeSink.drain(into: writer, meter: &meter)
        report(writer, meter, activeSink.ring)
        exit(meter.isDigitalSilence ? 2 : 0)
    }
} catch {
    note("ERREUR : \(error)")
    exit(1)
}
