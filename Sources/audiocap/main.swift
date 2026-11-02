import AVFoundation
import AudioCore
import Foundation

// CLI de validation (CDC section 11) : capture vers un .wav relisible par `afplay`, ou
// diffusion vers les sorties AirPlay.
//
//   audiocap [--mode global|app|input] [--app <nom|pid>] [--tone|--clicks|--channel-test] [--list]
//            [durée_s] [sortie.wav]
//
// À lancer via ./audiocap (wrapper `open`), jamais par le binaire interne : l'autorisation
// TCC est attribuée au bundle, pas au binaire nu. Seules les sources synthétiques (`--tone`,
// `--clicks`, `--channel-test`) s'en passent, n'utilisant ni tap ni micro : ce sont elles qui
// permettent de tester la chaîne avec `swift run`, sans reconstruire le bundle et donc sans
// révoquer l'autorisation. `--record-input` ouvre en revanche le micro.

/// Sortie du CLI, sur stderr. Le wrapper `./audiocap` la récupère via `open --stderr`
/// (voir `CLIRuntime`).
func note(_ text: String) { FileHandle.standardError.write(Data("\(text)\n".utf8)) }

CLIRuntime.start()

enum Mode: String {
    case global, app, input, tone, clicks
    case channelTest = "channel-test"

    /// Source synthétique : aucune capture Core Audio, donc compatible avec `--record-input`.
    var isSynthetic: Bool { self == .tone || self == .clicks || self == .channelTest }
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
/// Noms (partiels) des récepteurs AirPlay 2 visés (jalon 3), dans l'ordre. Répétable : les
/// deux HomePod « Salon » et « Salon (2) » ensemble. Combinées à `--airplay`, toutes les
/// sorties diffusent **en parallèle**, chacune sur son propre ring buffer (invariant section 12).
var airplay2Targets: [String] = []
/// Fichiers de credentials d'appairage système, pour un récepteur qui refuse le transitoire.
var airplay2CredentialsPaths: [String] = []
/// `--volume2` et `--delay2` : une fois pour toutes les sorties AirPlay 2, ou une fois par sortie
/// dans l'ordre des `--airplay2` (``RepeatedOption``).
var airplay2Volumes: [Float] = []
var browse2Only = false
/// Réglage manuel du délai par sortie, en millisecondes (CDC 4.5 : fine-tune et filet de
/// sécurité, en complément de l'alignement automatique, jamais à sa place).
var airplayDelayMs: Double = 0
var airplay2DelaysMs: [Double] = []
/// Renfort de basses de la sortie RAOP, en dB (ADR-002). `nil` : aucun.
var airplayBassDB: Float?
/// Niveau des sources synthétiques. `nil` : celui propre à chaque source (``defaultLevel(for:)``).
var toneLevelDBFS: Double?
var toneFrequency: Double = 440
/// `--record-input` : enregistre le micro pendant la diffusion, avec un JSON de datation.
var recordInputPath: String?

/// Niveau crête par défaut d'une source synthétique. La sinusoïde reste discrète : shairport-sync
/// la joue sur les haut-parleurs du Mac. Les clics et le test de canaux sont faits pour s'entendre
/// et se capter à quelques mètres.
func defaultLevel(for mode: Mode) -> Double {
    mode == .tone ? -50 : -20
}

/// Coupe le son du Mac pendant la capture, pour ne pas l'entendre en double avec les enceintes.
var muteLocalOutput = false

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
    case "--tone":
        mode = .tone
    case "--clicks":
        mode = .clicks
    case "--channel-test":
        mode = .channelTest
    case "--record-input":
        index += 1
        guard index < arguments.count, arguments[index].first != "-" else {
            FileHandle.standardError.write(Data("--record-input attend un fichier .wav\n".utf8))
            exit(2)
        }
        recordInputPath = arguments[index]
    case "--bass":
        index += 1
        guard index < arguments.count, let value = Float(arguments[index]) else {
            FileHandle.standardError.write(Data("--bass attend un gain en dB\n".utf8))
            exit(2)
        }
        airplayBassDB = value
    case "--tone-level":
        index += 1
        guard index < arguments.count, let value = Double(arguments[index]) else {
            FileHandle.standardError.write(Data("--tone-level attend un niveau en dBFS\n".utf8))
            exit(2)
        }
        toneLevelDBFS = value
    case "--tone-freq":
        index += 1
        guard index < arguments.count, let value = Double(arguments[index]), value > 0 else {
            FileHandle.standardError.write(Data("--tone-freq attend une fréquence en Hz\n".utf8))
            exit(2)
        }
        toneFrequency = value
    case "--mute-local":
        muteLocalOutput = true
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
        airplay2Targets.append(arguments[index])
    case "--volume2":
        index += 1
        guard index < arguments.count, let value = Float(arguments[index]) else {
            FileHandle.standardError.write(Data("--volume2 attend un nombre en dB\n".utf8))
            exit(2)
        }
        airplay2Volumes.append(value)
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
        airplay2DelaysMs.append(value)
    case "--credentials2":
        index += 1
        guard index < arguments.count else {
            FileHandle.standardError.write(Data("--credentials2 attend un chemin\n".utf8))
            exit(1)
        }
        airplay2CredentialsPaths.append(arguments[index])
    case "--browse2":
        browse2Only = true
    case "--help", "-h":
        note("""
            audiocap — capture audio et diffusion AirPlay 1/2 synchronisée (jalons 1 à 5)

              --mode global|app|input   mode de capture (défaut : global)
              --app <nom|pid>           application à capter (implique --mode app)
              --tone                    sinusoïde à la place de la capture : aucun tap, aucune
                                        autorisation, utilisable avec `swift run`
              --tone-freq <Hz>          fréquence de la sinusoïde (défaut : 440)
              --clicks                  salves de mesure à la place de la capture, sans tap ni
                                        autorisation : 5 ms à 3 kHz en fenêtre de Hann, sur les
                                        deux canaux, au début de chaque trame de capture multiple
                                        de 96 000, donc toutes les 2 s exactement. Repère : une
                                        salve sur cinq est doublée 250 ms plus tard
              --channel-test            test d'écoute gauche/droite, en boucle toutes les 4 s :
                                          0,0 s  UN bip grave (400 Hz, 0,4 s), GAUCHE seul
                                          2,0 s  DEUX bips aigus (1 600 Hz, 0,15 s), DROITE seul
                                        jamais les deux canaux à la fois
              --tone-level <dBFS>       niveau crête de --tone, --clicks, --channel-test
                                        (défaut : −50 pour --tone, −20 pour les deux autres)
              --mute-local              coupe le son du Mac pendant la capture (Process Tap)
              --list                    liste les process audio et quitte
              --browse                  liste les récepteurs _raop._tcp et quitte
              --airplay <nom>           diffuse vers ce récepteur RAOP au lieu d'écrire
                                        un .wav (nom exact d'abord, sinon partiel)
              --volume <dB>             volume RAOP, −144 ou −30…0 (défaut : −20)
              --delay <ms>              décalage manuel de la sortie RAOP, en ms
                                        (positif = restituer plus tard). Fine-tune en
                                        complément de l'alignement automatique, pas à sa place
              --bass <dB>               renfort de basses de la sortie RAOP (défaut : aucun)
              --browse2                 liste les récepteurs _airplay._tcp et quitte
              --airplay2 <nom>          diffuse vers ce récepteur AirPlay 2. RÉPÉTABLE : une
                                        sortie par --airplay2. Nom exact d'abord, sinon partiel :
                                        « Salon » ne vise jamais « Salon (2) » s'il existe
              --volume2 <dB>            volume AirPlay 2 (défaut : −20)
              --delay2 <ms>             décalage manuel d'une sortie AirPlay 2, en ms
              --credentials2 <chemin>   credentials d'appairage système (Apple TV)
                                        --volume2, --delay2, --credentials2 : donnés une fois, ils
                                        valent pour tous les --airplay2 ; répétés, ils s'appliquent
                                        dans l'ordre, un par --airplay2, autant que de --airplay2
              --record-input <f.wav>    enregistre l'entrée par défaut (Réglages Son > Entrée)
                                        pendant la diffusion, et écrit <f>.json pour dater chaque
                                        échantillon et chaque salve sur l'horloge hôte. Exige une
                                        source synthétique (une seule capture Core Audio à la
                                        fois) et au moins une sortie. Analyse :
                                        scripts/measure-clicks.py <f.wav>
              <durée_s> <sortie.wav>    durée et fichier de sortie

            Identifiants des sorties dans le compte rendu : raop/<nom> et airplay2/<nom>.

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
              ./audiocap --clicks --airplay2 Salon --record-input salon.wav 40
              ./audiocap --clicks --airplay Geneva --airplay2 Salon --airplay2 "Salon (2)" \\
                  --volume2 -20 --delay2 0 --delay2 3 --record-input trois.wav 60
              ./audiocap --channel-test --airplay2 Salon --airplay2 "Salon (2)" 40
              swift run audiocap --tone --airplay Geneva-Mock --volume -30 10   # sans bundle
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
// boucle, hors temps réel, le draine et écrit le .wav. Le fichier garde le format natif de la
// source : c'est lui qu'on veut vérifier à l'oreille.
final class CaptureSink: @unchecked Sendable {
    let ring: AudioRingBuffer
    let format: AVAudioFormat
    private var scratch: [Float]
    /// Tampon d'entrelacement, alloué une fois : le chemin temps réel n'alloue jamais.
    private let interleaveScratch: UnsafeMutablePointer<Float>
    private let interleaveFrames = 8_192

    init(format: AVAudioFormat, capacityFrames: Int = 48_000) {
        self.format = format
        self.ring = AudioRingBuffer(
            capacityFrames: capacityFrames, channelCount: Int(format.channelCount)
        )
        self.scratch = [Float](
            repeating: 0, count: capacityFrames * Int(format.channelCount)
        )
        self.interleaveScratch = .allocate(capacity: interleaveFrames * Int(format.channelCount))
    }

    deinit { interleaveScratch.deallocate() }

    /// Le consommateur à remettre à la source. **Appelé depuis le thread temps réel.**
    func makeConsumer() -> CaptureBlockConsumer {
        let channels = Int(format.channelCount)
        let interleaved = format.isInterleaved
        return { [self] list, frameCount in
            let frames = Int(frameCount)
            guard frames > 0 else { return }
            let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
            if interleaved {
                if let data = buffers[0].mData {
                    ring.write(from: data.assumingMemoryBound(to: Float.self), frameCount: frames)
                }
                return
            }
            // Planaire (entrée physique) : le ring buffer attend de l'entrelacé.
            guard buffers.count >= channels else { return }
            var offset = 0
            while offset < frames {
                let chunk = min(frames - offset, interleaveFrames)
                // `while` : hors optimisation, `for … in 0..<n` alloue à chaque tour.
                var channel = 0
                while channel < channels {
                    guard let data = buffers[channel].mData else { return }
                    let source = data.assumingMemoryBound(to: Float.self)
                    var frame = 0
                    while frame < chunk {
                        interleaveScratch[frame * channels + channel] = source[offset + frame]
                        frame += 1
                    }
                    channel += 1
                }
                ring.write(from: interleaveScratch, frameCount: chunk)
                offset += chunk
            }
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

@MainActor
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

func describe(_ phase: BridgeEngine.Phase) -> String {
    switch phase {
    case .idle: return "à l'arrêt"
    case .connecting: return "connexion"
    case let .waitingForReceiver(attempt, lastError):
        return "récepteur attendu (essai \(attempt) : \(lastError))"
    case .streaming: return "diffusion"
    case .reconnecting: return "reconnexion"
    case let .failed(reason): return "ÉCHEC : \(reason)"
    }
}

func describe(_ health: BridgeEngine.CaptureHealth) -> String {
    switch health.diagnosis {
    case .notRunning: return "capture à l'arrêt"
    case .waitingForFirstBlock: return "capture en attente d'un premier son"
    case .healthy: return "capture active"
    case .stalled: return "CAPTURE INTERROMPUE"
    case .silentWhilePlaying:
        return "SILENCE STRICT alors qu'une application joue — autorisation perdue ?"
    case .silentNothingPlaying: return "silence strict, aucune application ne joue"
    case .silentUnknown: return "silence strict"
    }
}

/// Diffuse vers les sorties demandées, par le même moteur que l'application.
///
/// Chaque sortie reçoit son propre ring buffer et la même horloge de restitution, et une panne
/// sur l'une n'atteint pas l'autre (invariant section 12) : tout cela vit dans `BridgeEngine`, ce
/// qui fait valider par ce CLI le code réellement employé par l'interface.
@MainActor
func runRequestedOutputs(source: BridgeEngine.Source, plan: OutputPlan) async throws -> Bool {
    guard !plan.isEmpty else { return false }
    var requests: [BridgeEngine.OutputRequest] = []
    for output in plan.outputs {
        // Un récepteur qui exige l'appairage système (un Apple TV) refuse le transitoire en 470.
        // Ses credentials, obtenus une fois, se rejouent alors par pair-verify.
        var credentials: HapCredentials?
        if let path = output.credentialsPath {
            credentials = try HapCredentials.load(contentsOf: URL(fileURLWithPath: path))
            note("Credentials d'appairage système chargés depuis \(path) pour \(output.id)")
        }
        requests.append(BridgeEngine.OutputRequest(
            id: output.id, proto: output.proto, deviceName: output.deviceName,
            nameMatching: .partial, volumeDB: output.volumeDB,
            manualDelaySeconds: output.manualDelayMs / 1000, bassBoostDB: output.bassBoostDB,
            credentials: credentials
        ))
    }

    // Le micro d'abord : il enregistre ainsi les toutes premières salves, et le temps qu'il met à
    // démarrer ne retarde pas la négociation.
    var recording: MeasurementRecording?
    if let recordInputPath {
        recording = try await MeasurementRecording.start(path: recordInputPath)
    }

    let engine = BridgeEngine()
    try await engine.start(
        source: source, outputs: requests,
        options: BridgeEngine.StartOptions(muteLocalOutput: muteLocalOutput)
    )
    recording?.observe(await engine.playbackTimeline)
    note("Diffusion vers \(requests.count) sortie(s) pendant \(duration) s, horloge commune\n")

    let idWidth = requests.map(\.id.count).max() ?? 4
    let interval = progressInterval(for: duration)
    let deadline = Date().addingTimeInterval(duration)
    while Date() < deadline, !CLIInterruption.requested {
        try await interruptibleSleep(seconds: interval)
        for output in await engine.outputs {
            let statistics = output.statistics
            let residual = output.residualErrorSeconds
                .map { String(format: "%+.2f ms", $0 * 1000) } ?? "stabilisation"
            note(String(
                format: "  %@ %6d paquets  %4d sync  %d err  dérive %@  ±%d trames  %@",
                output.id.padding(toLength: idWidth, withPad: " ", startingAt: 0) as NSString,
                statistics.packetsSent, statistics.syncPacketsSent, statistics.errors,
                residual as NSString, output.driftCorrections, describe(output.phase) as NSString
            ))
        }
        let health = await engine.captureHealth
        if health.diagnosis != .healthy { note("  \(describe(health))") }
        recording?.observe(await engine.playbackTimeline)
    }

    let final = await engine.outputs
    let health = await engine.captureHealth
    // Relue avant l'arrêt, qui la détruit.
    let timeline = await engine.playbackTimeline
    await engine.stop()

    var anyPacketSent = false
    for output in final {
        let statistics = output.statistics
        anyPacketSent = anyPacketSent || statistics.packetsSent > 0
        note("""

            Résultat de la sortie \(output.id)
              état final         : \(describe(output.phase))
              paquets audio      : \(statistics.packetsSent)
              paquets de synchro : \(statistics.syncPacketsSent) dont \(statistics.anchoredSyncPackets) ancrés
              réponses de timing : \(statistics.timingResponsesSent.map(String.init) ?? "—")
              retransmissions    : \(statistics.retransmitRequests.map { "\($0) demandes reçues" } ?? "—")
              canal d'événements : \(statistics.eventChannelConnected.map { $0 ? "ouvert" : "indisponible" } ?? "—")
              trames lues        : \(statistics.framesRead)
              erreurs            : \(statistics.errors)
              recalages          : \(statistics.resyncs)
              reconnexions       : \(statistics.reconnections) (dont \(statistics.reconnectionAttempts) tentatives échouées)
              trames refusées    : \(statistics.droppedBeforeStreaming) pendant la négociation, \
            \(output.droppedWhileStreaming) ensuite
            """)
        if let sync = output.sync {
            note("Synchronisation (CDC 4.5)\n\(describe(sync))")
        }
    }
    note("\n\(describe(health)), \(health.framesCaptured) trames captées")

    if let recording {
        let outputs = plan.outputs.map { planned -> MeasurementDocument.OutputInfo in
            let snapshot = final.first { $0.id == planned.id }
            return MeasurementDocument.OutputInfo(
                id: planned.id,
                protocole: planned.proto == .raop ? "raop" : "airplay2",
                nomDemande: planned.deviceName,
                volumeDb: planned.volumeDB,
                delaiDemandeMs: planned.manualDelayMs,
                delaiManuelMs: snapshot?.sync.map { $0.manualOffsetSeconds * 1000 },
                latenceRecepteurMs: snapshot?.sync.map { $0.receiverLatencySeconds * 1000 },
                renfortBassesDb: planned.proto == .raop ? planned.bassBoostDB : nil,
                etatFinal: snapshot.map { describe($0.phase) } ?? "jamais lancée",
                paquets: snapshot?.statistics.packetsSent ?? 0
            )
        }
        try recording.finish(
            source: measurementSource(), outputs: outputs, timeline: timeline
        )
    }
    if !anyPacketSent { exit(1) }
    return true
}

/// Ce que le JSON de mesure dit de la source.
@MainActor
func measurementSource() -> MeasurementDocument.SourceInfo {
    let level = toneLevelDBFS ?? defaultLevel(for: mode)
    switch mode {
    case .clicks: return .clicks(levelDBFS: level)
    case .channelTest: return .other("test-canaux", levelDBFS: level)
    case .tone: return .other("sinusoide-\(toneFrequency)-hz", levelDBFS: level)
    case .global, .app, .input: return .other(mode.rawValue, levelDBFS: level)
    }
}

/// La demande correspondant au mode de la ligne de commande.
@MainActor
func requestedSource() throws -> BridgeEngine.Source {
    let level = toneLevelDBFS ?? defaultLevel(for: mode)
    switch mode {
    case .global:
        return .processTap(.globalExcluding(pids: []))
    case .app:
        guard let hint = appHint else {
            note("--mode app exige --app <nom|pid>")
            exit(2)
        }
        let process = try AudioProcessList.find(matching: hint)
        note("Application ciblée : \(process.displayName) (pid \(process.pid), "
            + "\(process.isPlaying ? "en lecture" : "silencieuse"))")
        return .processTap(.processes(pids: [process.pid]))
    case .input:
        return .inputDevice
    case .tone:
        return .tone(frequency: toneFrequency, levelDBFS: level)
    case .clicks:
        return .clicks(levelDBFS: level)
    case .channelTest:
        return .channelTest(levelDBFS: level)
    }
}

/// Source effective pour le dump `.wav`, qui se passe du moteur.
@MainActor
func makeSource(for request: BridgeEngine.Source) -> any AudioCaptureSource {
    switch request {
    case let .processTap(tapMode):
        return ProcessTapCapture(mode: tapMode, muteLocalOutput: muteLocalOutput)
    case .inputDevice:
        return InputDeviceCapture()
    case let .tone(frequency, levelDBFS):
        return ToneCaptureSource(frequency: frequency, levelDBFS: levelDBFS)
    case let .clicks(levelDBFS):
        return PatternCaptureSource.clicks(levelDBFS: levelDBFS)
    case let .channelTest(levelDBFS):
        return PatternCaptureSource.channelTest(levelDBFS: levelDBFS)
    }
}

// --- Capture ---
do {
    let plan = try OutputPlan.make(
        raopTarget: airplayTarget, raopVolumeDB: airplayVolume, raopDelayMs: airplayDelayMs,
        raopBassDB: airplayBassDB, airplay2Targets: airplay2Targets,
        airplay2Volumes: airplay2Volumes, airplay2DelaysMs: airplay2DelaysMs,
        airplay2Credentials: airplay2CredentialsPaths
    )
    if recordInputPath != nil {
        // L'entrée physique sera la capture Core Audio du processus : une autre source en ouvrirait
        // une seconde (invariant section 12).
        guard mode.isSynthetic else {
            throw CLIUsageError(
                "--record-input exige --clicks, --channel-test ou --tone : une seule capture "
                    + "Core Audio à la fois, et le micro en est déjà une")
        }
        guard !plan.isEmpty else {
            throw CLIUsageError("--record-input exige au moins une sortie (--airplay, --airplay2)")
        }
    }

    if plan.isEmpty {
        note("Mode : \(mode.rawValue)   durée : \(duration) s   sortie : \(outputURL.path)")
    } else {
        note("Source : \(mode.rawValue)   durée : \(duration) s   sorties : "
            + plan.outputs.map(\.id).joined(separator: ", "))
    }
    let request = try requestedSource()

    // --- Diffusion réseau au lieu du dump .wav ---
    if try await runRequestedOutputs(source: request, plan: plan) {
        exit(0)
    }

    let source = makeSource(for: request)
    if let kind = source.requiredPermission {
        let permission = CapturePermission.status(for: kind)
        note("Autorisation : \(permission.rawValue)")
        if permission != .authorized {
            let granted = await CapturePermission.request(for: kind)
            if !granted {
                note(CapturePermission.guidance(for: kind))
                exit(3)
            }
        }
    }

    // Le format est connu avant le premier bloc : le collecteur existe déjà quand l'IO démarre,
    // et le callback temps réel n'a aucune référence à attendre.
    let format = try source.prepare()
    note("Format : \(format.sampleRate) Hz, \(format.channelCount) canaux, "
        + "\(format.isInterleaved ? "entrelacé" : "planaire")")
    let sink = CaptureSink(format: format)
    try source.start(deliveringTo: sink.makeConsumer())

    var meter = LevelMeter()
    let writer = try WAVWriter(url: outputURL, format: format)
    let deadline = Date().addingTimeInterval(duration)
    while Date() < deadline, !CLIInterruption.requested {
        try await Task.sleep(for: .milliseconds(50))
        try sink.drain(into: writer, meter: &meter)
    }
    source.stop()
    try sink.drain(into: writer, meter: &meter)
    writer.close()
    report(writer, meter, sink.ring)
    exit(meter.isDigitalSilence ? 2 : 0)
} catch let usage as CLIUsageError {
    note("ERREUR : \(usage)")
    exit(2)
} catch {
    note("ERREUR : \(error)")
    exit(1)
}
