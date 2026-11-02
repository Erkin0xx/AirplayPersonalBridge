import AVFoundation
import AudioCore
import Foundation

/// `--record-input` : le micro enregistré pendant la diffusion, et un JSON qui date chaque
/// échantillon et chaque salve **sur la même horloge**, l'horloge hôte.
///
/// ## Une seule capture Core Audio
///
/// L'entrée physique est la seule capture du processus : `main.swift` n'accepte `--record-input`
/// qu'avec une source synthétique (`--clicks`, `--channel-test`, `--tone`), qui n'en ouvre aucune.
/// Invariant section 12 tenu.
///
/// ## Les deux horloges
///
/// - Chaque bloc du micro arrive daté en ticks hôte (`AVAudioTime.hostTime`), convertis en ns par
///   ``HostTimebase``. Les ancrages `[trame, instant hôte]` datent tout l'enregistrement.
/// - L'instant de restitution attendu d'une trame de capture est en temps Unix
///   (``BridgeEngine/PlaybackTimeline``). Deux relevés ``HostClockMapping``, au début et à la fin,
///   le convertissent en instant hôte.
@MainActor
final class MeasurementRecording {
    let wavURL: URL
    let jsonURL: URL
    private let capture: InputDeviceCapture
    private let recorder: TimedInputRecorder
    private let writer: WAVWriter
    private let timebase: HostTimebase
    private let startPair: WallHostPair
    private let latency: InputDeviceCapture.InputLatency
    private var drainTask: Task<Void, Never>?
    private var drainFailure: String?
    private var timelineChanges: [MeasurementDocument.TimelineChange] = []
    private var lastTimeline: BridgeEngine.PlaybackTimeline?

    /// Le JSON accompagnant `mesure.wav` : `mesure.json`.
    nonisolated static func jsonURL(for wavURL: URL) -> URL {
        wavURL.deletingPathExtension().appendingPathExtension("json")
    }

    private init(
        wavURL: URL, capture: InputDeviceCapture, recorder: TimedInputRecorder, writer: WAVWriter,
        timebase: HostTimebase, startPair: WallHostPair, latency: InputDeviceCapture.InputLatency
    ) {
        self.wavURL = wavURL
        self.jsonURL = Self.jsonURL(for: wavURL)
        self.capture = capture
        self.recorder = recorder
        self.writer = writer
        self.timebase = timebase
        self.startPair = startPair
        self.latency = latency
    }

    /// Ouvre l'entrée par défaut (Réglages Son > Entrée) et commence à enregistrer.
    static func start(path: String) async throws -> MeasurementRecording {
        let wavURL = URL(fileURLWithPath: path)
        if CapturePermission.status(for: .microphone) != .authorized {
            guard await CapturePermission.request(for: .microphone) else {
                throw CLIUsageError(CapturePermission.guidance(for: .microphone))
            }
        }
        let capture = InputDeviceCapture()
        let format = try capture.prepare()
        let recorder = try TimedInputRecorder(sourceFormat: format)
        let writer = try WAVWriter(url: wavURL, format: recorder.recordingFormat)
        let timebase = HostTimebase.current()
        let startPair = HostClockMapping.measure(timebase: timebase)
        try capture.start(deliveringTimedBlocksTo: recorder.makeConsumer())
        let recording = MeasurementRecording(
            wavURL: wavURL, capture: capture, recorder: recorder, writer: writer,
            timebase: timebase, startPair: startPair, latency: capture.inputLatency()
        )
        recording.startDraining()
        note("""
            Enregistrement de l'entrée : \(recording.latency.deviceName ?? "périphérique inconnu"), \
            \(format.sampleRate) Hz → \(wavURL.path)
            """)
        return recording
    }

    /// Vide le tampon vers le fichier dix fois par seconde, hors temps réel.
    private func startDraining() {
        drainTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.drainOnce()
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
            }
        }
    }

    private func drainOnce() {
        guard drainFailure == nil else { return }
        do { try recorder.drain(into: writer) } catch {
            drainFailure = "\(error)"
            note("ERREUR d'écriture de l'enregistrement : \(error)")
        }
    }

    /// Prend note de l'horloge commune. Un report de son origine (trou de capture) est consigné
    /// avec l'instant où il a été vu : les salves d'avant et d'après ne s'attendent plus au même
    /// instant.
    func observe(_ timeline: BridgeEngine.PlaybackTimeline?) {
        guard let timeline else { return }
        if let lastTimeline,
           abs(lastTimeline.frameZeroPresentationUnixTime - timeline.frameZeroPresentationUnixTime)
            < 1e-6
        {
            return
        }
        let now = HostClockMapping.measure(timebase: timebase, attempts: 8)
        let mapping = HostClockMapping(timebase: timebase, pairs: [startPair, now])
        timelineChanges.append(MeasurementDocument.TimelineChange(
            observeHoteNs: now.hostNanoseconds,
            trame0RestitutionUnixS: timeline.frameZeroPresentationUnixTime,
            trame0RestitutionHoteNs: Int64(
                mapping.hostNanoseconds(forUnixTime: timeline.frameZeroPresentationUnixTime)
                    .rounded()
            )
        ))
        lastTimeline = timeline
    }

    /// Arrête l'enregistrement sans écrire de JSON : la diffusion n'a pas démarré, il n'y a rien à
    /// dater. Le WAV reste lisible.
    func abandon() {
        drainTask?.cancel()
        drainTask = nil
        capture.stop()
        drainOnce()
        writer.close()
    }

    /// Arrête l'enregistrement, finit le fichier et écrit le JSON.
    ///
    /// - Parameters:
    ///   - timeline: l'horloge commune relue juste avant l'arrêt du moteur, qui la détruit.
    func finish(
        source: MeasurementDocument.SourceInfo,
        outputs: [MeasurementDocument.OutputInfo],
        timeline: BridgeEngine.PlaybackTimeline?
    ) throws {
        observe(timeline)
        drainTask?.cancel()
        drainTask = nil
        capture.stop()
        drainOnce()
        writer.close()
        let endPair = HostClockMapping.measure(timebase: timebase)
        let mapping = HostClockMapping(timebase: timebase, pairs: [startPair, endPair])

        let document = MeasurementDocument.make(
            wavFile: wavURL.lastPathComponent,
            recorder: recorder,
            mapping: mapping,
            latency: latency,
            timeline: timeline ?? lastTimeline,
            timelineChanges: timelineChanges,
            source: source,
            outputs: outputs
        )
        try document.encoded().write(to: jsonURL)

        let seconds = Double(recorder.framesDrained) / recorder.sampleRate
        note("""

            Enregistrement de l'entrée
              fichier            : \(wavURL.path)
              durée              : \(String(format: "%.2f", seconds)) s
              trames perdues     : \(recorder.droppedFrames)
              ancrages hôte      : \(recorder.anchors.count)
              horloge murale     : \(String(format: "%+.2f", mapping.rateDeviationPPM)) ppm sur l'horloge hôte
              JSON               : \(jsonURL.path)
              analyse            : scripts/measure-clicks.py \(wavURL.path)
            """)
        if let drainFailure { throw CLIUsageError("enregistrement incomplet : \(drainFailure)") }
    }
}

/// Le JSON écrit à côté de l'enregistrement. Clés en français sans accent, en `snake_case`.
///
/// Tout instant `*_hote_ns` est un instant `mach_absolute_time` converti en nanosecondes : celui
/// d'`AVAudioTime.hostTime`, sur lequel le micro date ses blocs.
struct MeasurementDocument: Encodable {
    struct Recording: Encodable {
        let frequenceHz: Double
        let voies: Int
        let tramesEcrites: Int
        let tramesPerdues: Int
        /// Instant hôte de la trame 0 de l'enregistrement : l'`AVAudioTime.hostTime` du premier bloc.
        let premierEchantillonHoteNs: UInt64?
        /// Vrai si le premier bloc n'était pas daté : la valeur est alors extrapolée du premier
        /// ancrage, à la fréquence nominale.
        let premierEchantillonExtrapole: Bool
        /// `[trame, instant hôte en ns]`.
        let ancrages: [[UInt64]]
        let peripherique: String?
        let latencePresentationS: Double
        let latencePeripheriqueTrames: UInt32?
        let margeSecuriteTrames: UInt32?
    }

    struct ClockPair: Encodable {
        let unixS: Double
        let hoteNs: UInt64
        let incertitudeNs: UInt64
    }

    struct HostClock: Encodable {
        let baseNumer: UInt32
        let baseDenom: UInt32
        /// Relevés simultanés de l'horloge murale (temps Unix) et de l'horloge hôte, au début et à
        /// la fin. Entre deux : interpolation linéaire.
        let releves: [ClockPair]
        let ecartRythmePpm: Double
    }

    struct TimelineChange: Encodable {
        let observeHoteNs: UInt64
        let trame0RestitutionUnixS: Double
        let trame0RestitutionHoteNs: Int64
    }

    struct PlaybackClock: Encodable {
        let frequenceCaptureHz: Double
        let delaiRestitutionS: Double
        /// Instant de restitution attendu de la trame de capture 0, le même pour toutes les
        /// sorties, avant le délai manuel de chacune. En temps Unix, l'horloge des estampilles NTP.
        let trame0RestitutionUnixS: Double
        /// Le même, converti en instant hôte.
        let trame0RestitutionHoteNs: Int64
        let interruptionsReporteesS: Double
        /// Valeurs successives observées en cours de mesure. Une seule : l'horloge n'a pas bougé.
        let changements: [TimelineChange]
    }

    struct SourceInfo: Encodable {
        let type: String
        let niveauDbfs: Double
        let frequenceHz: Double
        let periodeTrames: Int?
        let salveTrames: Int?
        let salveFrequenceHz: Double?
        let repereToutesLes: Int?
        let repereDecalageTrames: Int?

        static func clicks(levelDBFS: Double) -> SourceInfo {
            SourceInfo(
                type: "clics", niveauDbfs: levelDBFS, frequenceHz: ClickPattern.sampleRate,
                periodeTrames: ClickPattern.periodFrames, salveTrames: ClickPattern.burstFrames,
                salveFrequenceHz: ClickPattern.burstFrequency,
                repereToutesLes: ClickPattern.markerEvery,
                repereDecalageTrames: ClickPattern.markerOffsetFrames
            )
        }

        static func other(_ type: String, levelDBFS: Double) -> SourceInfo {
            SourceInfo(
                type: type, niveauDbfs: levelDBFS, frequenceHz: 48_000, periodeTrames: nil,
                salveTrames: nil, salveFrequenceHz: nil, repereToutesLes: nil,
                repereDecalageTrames: nil
            )
        }
    }

    struct OutputInfo: Encodable {
        let id: String
        let protocole: String
        let nomDemande: String
        let volumeDb: Float
        /// Délai manuel demandé en ligne de commande.
        let delaiDemandeMs: Double
        /// Délai manuel appliqué par le sender, relu en fin de mesure. `nil` s'il ne s'est jamais
        /// connecté.
        let delaiManuelMs: Double?
        /// Latence interne annoncée par le récepteur (la Geneva : 4 096 trames), déjà retranchée de
        /// l'ancrage par le sender. Pour information.
        let latenceRecepteurMs: Double?
        let renfortBassesDb: Float?
        let etatFinal: String
        let paquets: Int
        /// Instant hôte attendu pour la trame de capture 0 sur cette sortie : l'horloge commune
        /// plus son délai manuel.
        var trame0AttendueHoteNs: Int64?
    }

    let format = "audiocap-mesure"
    let version = 1
    let creeLe: String
    let fichierWav: String
    let enregistrement: Recording
    let horlogeHote: HostClock
    let horlogeCommune: PlaybackClock?
    let source: SourceInfo
    let sorties: [OutputInfo]
    let explications: [String: String]

    static func make(
        wavFile: String,
        recorder: TimedInputRecorder,
        mapping: HostClockMapping,
        latency: InputDeviceCapture.InputLatency,
        timeline: BridgeEngine.PlaybackTimeline?,
        timelineChanges: [TimelineChange],
        source: SourceInfo,
        outputs: [OutputInfo],
        createdAt: Date = Date()
    ) -> MeasurementDocument {
        let timebase = mapping.timebase
        let anchors = recorder.anchors
        let first = anchors.first.map { anchor -> (UInt64, Bool) in
            let nanoseconds = timebase.nanoseconds(fromTicks: anchor.hostTicks)
            guard anchor.frame > 0 else { return (nanoseconds, false) }
            let back = UInt64((Double(anchor.frame) / recorder.sampleRate * 1e9).rounded())
            return (nanoseconds > back ? nanoseconds - back : 0, true)
        }

        let common = timeline.map { timeline in
            PlaybackClock(
                frequenceCaptureHz: timeline.captureSampleRate,
                delaiRestitutionS: timeline.playoutDelaySeconds,
                trame0RestitutionUnixS: timeline.frameZeroPresentationUnixTime,
                trame0RestitutionHoteNs: Int64(
                    mapping.hostNanoseconds(forUnixTime: timeline.frameZeroPresentationUnixTime)
                        .rounded()
                ),
                interruptionsReporteesS: timeline.interruptedSeconds,
                changements: timelineChanges
            )
        }
        let perOutput = outputs.map { output -> OutputInfo in
            var output = output
            if let common {
                let delay = output.delaiManuelMs ?? output.delaiDemandeMs
                output.trame0AttendueHoteNs =
                    common.trame0RestitutionHoteNs + Int64((delay * 1e6).rounded())
            }
            return output
        }

        return MeasurementDocument(
            creeLe: ISO8601DateFormatter().string(from: createdAt),
            fichierWav: wavFile,
            enregistrement: Recording(
                frequenceHz: recorder.sampleRate,
                voies: 1,
                tramesEcrites: recorder.framesDrained,
                tramesPerdues: recorder.droppedFrames,
                premierEchantillonHoteNs: first?.0,
                premierEchantillonExtrapole: first?.1 ?? false,
                ancrages: anchors.map {
                    [UInt64($0.frame), timebase.nanoseconds(fromTicks: $0.hostTicks)]
                },
                peripherique: latency.deviceName,
                latencePresentationS: latency.presentationLatencySeconds,
                latencePeripheriqueTrames: latency.deviceLatencyFrames,
                margeSecuriteTrames: latency.safetyOffsetFrames
            ),
            horlogeHote: HostClock(
                baseNumer: timebase.numer,
                baseDenom: timebase.denom,
                releves: mapping.pairs.map {
                    ClockPair(
                        unixS: $0.unixTime, hoteNs: $0.hostNanoseconds,
                        incertitudeNs: $0.uncertaintyNanoseconds
                    )
                },
                ecartRythmePpm: mapping.rateDeviationPPM
            ),
            horlogeCommune: common,
            source: source,
            sorties: perOutput,
            explications: explanations
        )
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    static let explanations: [String: String] = [
        "instants_hote":
            "Tout *_hote_ns est un instant mach_absolute_time en ns, l'horloge d'AVAudioTime.hostTime.",
        "echantillon":
            "Instant hôte de la trame i de l'enregistrement : interpolation linéaire entre les deux "
            + "ancrages qui l'encadrent, extrapolée à la fréquence nominale au-delà.",
        "salve":
            "Salve k (trames de capture k * periode_trames) attendue à trame0_restitution_hote_ns "
            + "+ k * periode_trames / frequence_capture_hz * 1e9, plus le délai manuel de la sortie. "
            + "Si k est multiple de repere_toutes_les, une doublure suit à + repere_decalage_trames.",
        "horloge_commune":
            "trame0_restitution_unix_s est en temps Unix (Date), l'horloge que les senders annoncent "
            + "en NTP (Unix + 2208988800 s) et sur laquelle les récepteurs se calent. Conversion en "
            + "hôte : droite passant par les relevés de horloge_hote.",
        "ce_qui_est_mesure":
            "Écart acoustique = arrivée au micro - instant attendu. Il inclut la propagation (2,9 ms "
            + "par mètre) et la latence d'entrée du micro, communes à toutes les enceintes à distance "
            + "égale : ce sont les écarts ENTRE enceintes qui comptent.",
    ]
}
