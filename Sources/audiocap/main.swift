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
/// Nom (partiel) du récepteur RAOP visé. Non nul = jalon 2 : on diffuse au lieu d'écrire
/// un .wav.
var airplayTarget: String?
var airplayVolume: Float = -20
var browseOnly = false
/// Nom (partiel) du récepteur AirPlay 2 visé (jalon 3).
/// Combiné à `--airplay`, les deux sorties diffusent **en parallèle**, chacune sur son
/// propre ring buffer (invariant section 12).
var airplay2Target: String?
/// Fichier de credentials d'appairage système, pour un récepteur qui refuse le transitoire.
var airplay2CredentialsPath: String?
var airplay2Volume: Float = -20
var browse2Only = false
/// Réglage manuel du délai par sortie, en millisecondes (CDC 4.5 : fine-tune et filet de
/// sécurité, en complément de l'alignement automatique, jamais à sa place).
var airplayDelayMs: Double = 0
var airplay2DelayMs: Double = 0

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
    case "--airplay":
        index += 1
        guard index < arguments.count else {
            FileHandle.standardError.write(Data("--airplay attend un nom de récepteur\n".utf8))
            exit(2)
        }
        airplayTarget = arguments[index]
    case "--volume":
        index += 1
        guard index < arguments.count, let value = Float(arguments[index]) else {
            FileHandle.standardError.write(Data("--volume attend un nombre en dB\n".utf8))
            exit(2)
        }
        airplayVolume = value
    case "--browse":
        browseOnly = true
    case "--airplay2":
        index += 1
        guard index < arguments.count else {
            FileHandle.standardError.write(Data("--airplay2 attend un nom de récepteur\n".utf8))
            exit(2)
        }
        airplay2Target = arguments[index]
    case "--volume2":
        index += 1
        guard index < arguments.count, let value = Float(arguments[index]) else {
            FileHandle.standardError.write(Data("--volume2 attend un nombre en dB\n".utf8))
            exit(2)
        }
        airplay2Volume = value
    case "--delay":
        index += 1
        guard index < arguments.count, let value = Double(arguments[index]) else {
            FileHandle.standardError.write(Data("--delay attend un nombre en ms\n".utf8))
            exit(2)
        }
        airplayDelayMs = value
    case "--delay2":
        index += 1
        guard index < arguments.count, let value = Double(arguments[index]) else {
            FileHandle.standardError.write(Data("--delay2 attend un nombre en ms\n".utf8))
            exit(2)
        }
        airplay2DelayMs = value
    case "--credentials2":
        index += 1
        guard index < arguments.count else {
            FileHandle.standardError.write(Data("--credentials2 attend un chemin\n".utf8))
            exit(1)
        }
        airplay2CredentialsPath = arguments[index]
    case "--browse2":
        browse2Only = true
    case "--help", "-h":
        note("""
            audiocap — capture audio et diffusion AirPlay 1/2 synchronisée (jalons 1 à 4)

              --mode global|app|input   mode de capture (défaut : global)
              --app <nom|pid>           application à capter (implique --mode app)
              --list                    liste les process audio et quitte
              --browse                  liste les récepteurs _raop._tcp et quitte
              --airplay <nom>           diffuse vers ce récepteur RAOP au lieu d'écrire
                                        un .wav (correspondance partielle sur le nom)
              --volume <dB>             volume RAOP, −144 ou −30…0 (défaut : −20)
              --browse2                 liste les récepteurs _airplay._tcp et quitte
              --airplay2 <nom>          diffuse vers ce récepteur AirPlay 2
              --volume2 <dB>            volume AirPlay 2 (défaut : −20)
              --delay <ms>              décalage manuel de la sortie RAOP, en ms
                                        (positif = restituer plus tard). Fine-tune en
                                        complément de l'alignement automatique, pas à sa place
              --delay2 <ms>             décalage manuel de la sortie AirPlay 2, en ms
              <durée_s> <sortie.wav>    durée et fichier de sortie

            Exemples :
              ./audiocap --list
              ./audiocap 10 systeme.wav
              ./audiocap --app Music 10 music.wav
              ./audiocap --mode input 10 entree.wav
              ./audiocap --browse
              ./audiocap --airplay Geneva 30
              ./audiocap --browse2
              ./audiocap --airplay2 ApTV 30
              ./audiocap --airplay Geneva --airplay2 ApTV 30   # deux sorties en parallèle
              ./audiocap --airplay Geneva --airplay2 ApTV --delay2 25 3700   # validation 1 h
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

// --- Parcours des récepteurs RAOP (jalon 2) ---
if browseOnly {
    let devices = await RAOPDiscovery().browse()
    if devices.isEmpty {
        note("Aucun récepteur _raop._tcp trouvé sur le réseau.")
        exit(1)
    }
    note("Récepteurs RAOP découverts :\n")
    for device in devices {
        note("""
              \(device.displayName)  (\(device.serviceName))
                adresse      : \(device.host):\(device.port)
                format       : \(device.sampleRate) Hz, \(device.bitDepth) bits, \
            \(device.channelCount) canaux
                chiffrement  : \(device.supportsRSAEncryption ? "RSA-AES (et=1)" : "aucun")
                compression  : \(device.supportsALAC ? "ALAC (cn=1)" : "PCM seul")
                mot de passe : \(device.requiresPassword ? "OUI" : "non")
            """)
    }
    exit(0)
}

// --- Parcours des récepteurs AirPlay 2 (jalon 3) ---
if browse2Only {
    // Plusieurs passages : NWBrowser rend parfois une liste vide au premier, sans erreur.
    let discovery = AirPlay2Discovery()
    var devices = await discovery.browse()
    if devices.isEmpty { devices = await discovery.browse(timeout: .seconds(8)) }
    if devices.isEmpty {
        note("Aucun récepteur _airplay._tcp trouvé sur le réseau.")
        exit(1)
    }
    note("Récepteurs AirPlay 2 découverts :\n")
    for device in devices {
        note("""
              \(device.serviceName)
                adresse      : \(device.host):\(device.port)
                features     : 0x\(String(device.features, radix: 16))
                pairing      : \(device.supportsTransientPairing ? "transitoire (bit 48)" : "transitoire NON proposé")\
            \(device.requiresSystemPairing ? ", appairage système exigé (bit 43)" : "")
                identifiant  : \(device.pairingIdentifier.isEmpty ? "—" : device.pairingIdentifier)
                clé publique : \(device.publicKey.map { "\($0.count) octets" } ?? "absente")
            """)
    }
    exit(0)
}

let outputURL = URL(fileURLWithPath: outputPath ?? "capture-\(mode.rawValue).wav")

// --- Collecteur alimenté par le ring buffer ---
//
// Le callback de capture écrit dans un ring buffer lock-free (invariant section 12) ; cette
// boucle, hors temps réel, le draine et écrit le .wav. C'est exactement la frontière que
// franchiront les senders des jalons 2 et 3, à ceci près qu'ils écriront sur le réseau.
final class CaptureSink: @unchecked Sendable {
    /// Ring buffer du pipeline principal (dump `.wav`, ou première sortie AirPlay).
    let ring: AudioRingBuffer
    /// Ring buffer d'une **seconde** sortie, quand deux destinations diffusent en parallèle.
    ///
    /// Invariant section 12 : « le flux PCM capturé est dupliqué en lecture seule vers
    /// chaque pipeline de sortie », avec « un ring buffer lock-free par pipeline de
    /// sortie ». Les deux senders lisent donc chacun le sien et ne se volent aucun
    /// échantillon — une sortie qui décroche n'affame pas l'autre.
    private(set) var secondaryRing: AudioRingBuffer?
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

    /// Arme un second pipeline de sortie, avec son propre ring buffer.
    ///
    /// À appeler **avant** de démarrer la capture : le callback temps réel n'alloue rien, et
    /// créer le tampon pendant qu'il tourne violerait cette règle.
    func enableSecondaryPipeline(capacityFrames: Int = 48_000) -> AudioRingBuffer {
        let ring = AudioRingBuffer(
            capacityFrames: capacityFrames, channelCount: Int(format.channelCount)
        )
        secondaryRing = ring
        return ring
    }

    /// Écrit un bloc entrelacé dans **tous** les pipelines de sortie actifs.
    ///
    /// Appelé depuis le callback temps réel : lock-free, sans allocation (invariant
    /// section 12). La duplication est une simple recopie vers chaque ring buffer ; aucun
    /// sender ne voit le tampon d'un autre.
    func writeToAllPipelines(_ samples: UnsafePointer<Float>, frameCount: Int) {
        ring.write(from: samples, frameCount: frameCount)
        secondaryRing?.write(from: samples, frameCount: frameCount)
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
                writeToAllPipelines(base, frameCount: chunk)
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

/// Cadence des lignes d'avancement : une par seconde sur une session courte, une toutes les
/// 30 s au-delà. Une validation d'une heure produirait sinon 7 200 lignes illisibles.
func progressInterval(for duration: Double) -> Double { duration > 300 ? 30 : 1 }

/// Résumé d'une sortie du point de vue de la synchronisation (CDC 4.5).
func describe(_ snapshot: SyncSnapshot) -> String {
    func ms(_ value: TimeInterval?) -> String {
        guard let value else { return "—" }
        return String(format: "%.2f ms", value * 1000)
    }
    let timing = snapshot.timing
    // Un décalage absent doit se lire comme tel, avec sa raison : un récepteur qui n'horodate
    // pas ses requêtes rend la mesure impossible, ce qui n'est pas un défaut du sender.
    let offset = timing.offsetSeconds.map { String(format: "%.3f ms", $0 * 1000) }
        ?? (timing.unstampedCount > 0 ? "non mesurable (requêtes non horodatées)" : "—")
    let spread = timing.spreadSeconds.map { String(format: "%.3f ms", $0 * 1000) } ?? "—"
    return """
          délai manuel        : \(ms(snapshot.manualOffsetSeconds))
          latence récepteur   : \(snapshot.receiverLatencySeconds > 0 ? ms(snapshot.receiverLatencySeconds) + " (annoncée par lui)" : "non annoncée")
          délai de pipeline   : \(ms(snapshot.pipelineDelaySeconds))
          consigne            : \(ms(snapshot.targetDelaySeconds))
          écart résiduel      : \(ms(snapshot.residualErrorSeconds))
          latence totale est. : \(ms(snapshot.estimatedTotalLatencySeconds))
          corrections         : +\(snapshot.framesInserted) / −\(snapshot.framesRemoved) trames
          canal de timing     : \(timing.sampleCount) requêtes (\(timing.unstampedCount) sans estampille)
          décalage d'horloge  : \(offset), gigue \(spread)
        """
}

/// Diffuse le contenu du ring buffer vers un récepteur RAOP pour la durée demandée.
///
/// Le sender **lit** le ring buffer et ne l'écrit jamais : c'est exactement la frontière
/// posée par l'invariant section 12. La capture, elle, ignore tout de cette destination.
func streamToRAOP(
    target: String,
    ring: AudioRingBuffer,
    format: AVAudioFormat,
    volume: Float,
    duration: Double,
    clock: PlaybackClockProtocol? = nil,
    manualDelaySeconds: TimeInterval = 0
) async throws {
    note("Recherche du récepteur RAOP « \(target) »…")
    let device = try await RAOPDiscovery().find(named: target)
    note("""
        Récepteur : \(device.displayName) (\(device.serviceName))
          adresse     : \(device.host):\(device.port)
          format cible: \(device.sampleRate) Hz, \(device.bitDepth) bits, \
        \(device.channelCount) canaux
          chiffrement : \(device.supportsRSAEncryption ? "RSA-AES" : "aucun")
        """)

    let sender = RAOPSender(device: device, ring: ring, captureFormat: format, clock: clock)
    await sender.setManualDelay(seconds: manualDelaySeconds)
    try await sender.start(volume: volume)
    note("Session RAOP établie, diffusion pendant \(duration) s "
        + "(volume \(volume) dB, délai manuel \(manualDelaySeconds * 1000) ms)…")

    let interval = progressInterval(for: duration)
    let deadline = Date().addingTimeInterval(duration)
    while Date() < deadline {
        try await Task.sleep(for: .seconds(interval))
        let statistics = await sender.statistics
        let sync = sender.synchronizer.snapshot()
        let residual = sync.residualErrorSeconds.map { String(format: "%+.2f ms", $0 * 1000) }
            ?? "stabilisation"
        note(String(
            format: "  RAOP %6d paquets  %4d sync  %3d timing  %d err  dérive %@  ±%d trames",
            statistics.packetsSent, statistics.syncPacketsSent,
            statistics.timingResponsesSent, statistics.errors,
            residual as NSString, statistics.framesInserted + statistics.framesRemoved
        ))
    }

    let final = await sender.statistics
    let sync = sender.synchronizer.snapshot()
    await sender.stop()
    note("""

        Résultat de la diffusion RAOP
          récepteur          : \(device.displayName) (\(device.host):\(device.port))
          paquets audio      : \(final.packetsSent)
          paquets de synchro : \(final.syncPacketsSent) dont \(final.anchoredSyncPackets) ancrés
          réponses de timing : \(final.timingResponsesSent)
          trames lues        : \(final.framesRead)
          erreurs            : \(final.errors)
          recalages          : \(final.resyncs)
          reconnexions       : \(final.reconnections) (dont \(final.reconnectionAttempts) tentatives échouées)
          trames refusées    : \(ring.droppedFrames) au total, dont \
        \(final.droppedBeforeStreaming) pendant la négociation
          dont en diffusion  : \(ring.droppedFrames - final.droppedBeforeStreaming)

        Synchronisation RAOP (CDC 4.5)
        \(describe(sync))
        """)
}

/// Diffuse vers un récepteur AirPlay 2 (jalon 3).
///
/// Même frontière qu'en RAOP : le sender **lit** son ring buffer et ne l'écrit jamais, et
/// la capture ignore tout de cette destination (invariant section 12).
func streamToAirPlay2(
    credentialsPath: String? = nil,
    target: String,
    ring: AudioRingBuffer,
    format: AVAudioFormat,
    volume: Float,
    duration: Double,
    clock: PlaybackClockProtocol? = nil,
    manualDelaySeconds: TimeInterval = 0
) async throws {
    note("Recherche du récepteur AirPlay 2 « \(target) »…")
    let device = try await AirPlay2Discovery().find(named: target)
    note("""
        Récepteur : \(device.serviceName)
          adresse     : \(device.host):\(device.port)
          features    : 0x\(String(device.features, radix: 16))
          pairing     : \(device.supportsTransientPairing ? "transitoire" : "transitoire NON proposé")
        """)

    // Un récepteur qui exige l'appairage système (un Apple TV) refuse le transitoire en 470.
    // Ses credentials, obtenus une fois, se rejouent alors par pair-verify.
    var credentials: HapCredentials?
    if let path = credentialsPath {
        credentials = try HapCredentials.load(contentsOf: URL(fileURLWithPath: path))
        note("Credentials d'appairage système chargés depuis \(path)")
    }
    let sender = AirPlay2Sender(
        device: device, ring: ring, captureFormat: format, clock: clock,
        credentials: credentials
    )
    await sender.setManualDelay(seconds: manualDelaySeconds)
    try await sender.start(volume: volume)
    note("Session AirPlay 2 établie, diffusion pendant \(duration) s "
        + "(volume \(volume) dB, délai manuel \(manualDelaySeconds * 1000) ms)…")

    let interval = progressInterval(for: duration)
    let deadline = Date().addingTimeInterval(duration)
    while Date() < deadline {
        try await Task.sleep(for: .seconds(interval))
        let statistics = await sender.statistics
        let sync = sender.synchronizer.snapshot()
        let residual = sync.residualErrorSeconds.map { String(format: "%+.2f ms", $0 * 1000) }
            ?? "stabilisation"
        note(String(
            format: "  AP2  %6d paquets  %4d sync  %d err  dérive %@  ±%d trames",
            statistics.packetsSent, statistics.syncPacketsSent, statistics.errors,
            residual as NSString, statistics.framesInserted + statistics.framesRemoved
        ))
    }

    let final = await sender.statistics
    let sync = sender.synchronizer.snapshot()
    await sender.stop()
    note("""

        Résultat de la diffusion AirPlay 2
          récepteur          : \(device.serviceName) (\(device.host):\(device.port))
          paquets audio      : \(final.packetsSent)
          paquets de synchro : \(final.syncPacketsSent) dont \(final.anchoredSyncPackets) ancrés
          canal d'événements : \(final.eventChannelConnected ? "ouvert" : "indisponible")
          retransmissions    : \(final.retransmitRequests) demandes reçues
          trames lues        : \(final.framesRead)
          erreurs            : \(final.errors)
          recalages          : \(final.resyncs)
          reconnexions       : \(final.reconnections) (dont \(final.reconnectionAttempts) tentatives échouées)
          trames refusées    : \(ring.droppedFrames) au total, dont \
        \(final.droppedBeforeStreaming) pendant la négociation
          dont en diffusion  : \(ring.droppedFrames - final.droppedBeforeStreaming)

        Synchronisation AirPlay 2 (CDC 4.5)
        \(describe(sync))
        """)
}

/// Diffuse simultanément vers les deux sorties — l'objectif fonctionnel du projet (CDC 2).
///
/// Les deux senders tournent dans des tâches **indépendantes**, chacun sur son propre ring
/// buffer. C'est ce qui matérialise l'invariant section 12 : « une panne ou déconnexion sur
/// une sortie n'interrompt jamais la capture ni l'autre sortie ». Un `async let` qui
/// propagerait l'erreur annulerait l'autre branche ; ici chaque échec est capturé et
/// journalisé dans sa propre tâche, sans toucher à l'autre.
///
/// **Jalon 4** : les deux senders reçoivent ici la **même** horloge de restitution. C'est
/// elle, et rien d'autre, qui les aligne : chacun en tire l'instant auquel le récepteur doit
/// restituer la trame captée qu'il est en train d'envoyer, et l'annonce sur son propre canal
/// de synchronisation. Aucun des deux ne sait que l'autre existe (invariant section 12).
func streamToBothOutputs(
    airplay2CredentialsPath: String?,
    raopTarget: String,
    airplay2Target: String,
    raopRing: AudioRingBuffer,
    airplay2Ring: AudioRingBuffer,
    format: AVAudioFormat,
    raopVolume: Float,
    airplay2Volume: Float,
    duration: Double,
    clock: PlaybackClockProtocol,
    raopDelaySeconds: TimeInterval,
    airplay2DelaySeconds: TimeInterval
) async {
    note("Diffusion simultanée vers deux sorties (RAOP + AirPlay 2), horloge commune\n")

    await withTaskGroup(of: Void.self) { group in
        group.addTask {
            do {
                try await streamToRAOP(
                    target: raopTarget, ring: raopRing, format: format,
                    volume: raopVolume, duration: duration,
                    clock: clock, manualDelaySeconds: raopDelaySeconds
                )
            } catch {
                // Panne confinée : l'autre sortie continue.
                note("SORTIE RAOP EN ÉCHEC : \(error)")
                note("→ la sortie AirPlay 2 continue (invariant section 12).")
            }
        }
        group.addTask {
            do {
                try await streamToAirPlay2(
                    credentialsPath: airplay2CredentialsPath,
                    target: airplay2Target, ring: airplay2Ring, format: format,
                    volume: airplay2Volume, duration: duration,
                    clock: clock, manualDelaySeconds: airplay2DelaySeconds
                )
            } catch {
                note("SORTIE AIRPLAY 2 EN ÉCHEC : \(error)")
                note("→ la sortie RAOP continue (invariant section 12).")
            }
        }
    }
}

/// Aiguille vers la ou les sorties AirPlay demandées en ligne de commande.
///
/// Rend `false` si aucune n'est demandée — le CLI retombe alors sur le dump `.wav` du
/// jalon 1. Factorisé parce que les trois modes de capture en ont besoin à l'identique : la
/// capture ignore ses destinations (invariant section 12), c'est donc bien le même code.
///
/// **L'horloge de restitution commune est créée ici**, une seule fois, et passée aux deux
/// senders. Elle est ancrée sur l'état courant de la capture pour que sa trame n° 0
/// corresponde bien au premier échantillon capté, et non à l'instant de sa création.
@MainActor
func runRequestedOutputs(sink: CaptureSink, format: AVAudioFormat) async throws -> Bool {
    guard airplayTarget != nil || airplay2Target != nil else { return false }

    let clock = SharedPlaybackClock(captureSampleRate: format.sampleRate)
    clock.startIfNeeded(framesAlreadyWritten: sink.ring.totalFramesWritten)
    let raopDelay = airplayDelayMs / 1000
    let airplay2Delay = airplay2DelayMs / 1000

    if let raopTarget = airplayTarget, let ap2Target = airplay2Target,
        let secondaryRing = sink.secondaryRing {
        // Deux sorties : chacune son ring buffer (invariant section 12), la même horloge.
        await streamToBothOutputs(
            airplay2CredentialsPath: airplay2CredentialsPath,
            raopTarget: raopTarget, airplay2Target: ap2Target,
            raopRing: sink.ring, airplay2Ring: secondaryRing,
            format: format, raopVolume: airplayVolume,
            airplay2Volume: airplay2Volume, duration: duration,
            clock: clock, raopDelaySeconds: raopDelay,
            airplay2DelaySeconds: airplay2Delay
        )
        return true
    }
    if let target = airplayTarget {
        try await streamToRAOP(
            target: target, ring: sink.ring, format: format,
            volume: airplayVolume, duration: duration,
            clock: clock, manualDelaySeconds: raopDelay
        )
        return true
    }
    if let target = airplay2Target {
        try await streamToAirPlay2(
            credentialsPath: airplay2CredentialsPath,
            target: target, ring: sink.ring, format: format,
            volume: airplay2Volume, duration: duration,
            clock: clock, manualDelaySeconds: airplay2Delay
        )
        return true
    }
    return false
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
            // Duplication vers chaque pipeline de sortie (invariant section 12).
            sink.writeToAllPipelines(
                data.assumingMemoryBound(to: Float.self), frameCount: Int(frames))
        }

        try capture.start(mode: tapMode)
        guard let format = capture.format else { throw AudioCaptureError.tapFormatUnavailable }
        note("Format : \(format.sampleRate) Hz, \(format.channelCount) canaux, "
            + "\(format.isInterleaved ? "entrelacé" : "planaire")")
        let activeSink = CaptureSink(format: format)
        // Second pipeline armé AVANT le démarrage de la capture, et seulement si deux
        // sorties sont demandées : le callback temps réel n'alloue jamais (invariant
        // section 12), et une sortie unique n'a aucune raison de payer un second tampon.
        if airplayTarget != nil && airplay2Target != nil {
            _ = activeSink.enableSecondaryPipeline()
        }
        sink = activeSink

        // --- Jalons 2 à 4 : diffusion réseau au lieu du dump .wav ---
        if try await runRequestedOutputs(sink: activeSink, format: format) {
            capture.stop()
            exit(0)
        }

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
                    sink.writeToAllPipelines(
                        data.assumingMemoryBound(to: Float.self), frameCount: frames)
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
        // Second pipeline armé AVANT le démarrage de la capture, et seulement si deux
        // sorties sont demandées : le callback temps réel n'alloue jamais (invariant
        // section 12), et une sortie unique n'a aucune raison de payer un second tampon.
        if airplayTarget != nil && airplay2Target != nil {
            _ = activeSink.enableSecondaryPipeline()
        }
        sink = activeSink

        if try await runRequestedOutputs(sink: activeSink, format: format) {
            capture.stop()
            exit(0)
        }

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
