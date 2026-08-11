import AVFoundation
import Foundation
import OSLog

/// Orchestration d'une session de diffusion : une capture, N sorties.
///
/// ## Pourquoi ce type existe
///
/// L'orchestration vivait dans `Sources/audiocap/main.swift`, sous une forme taillée pour la
/// ligne de commande : durée fixée d'avance, destinations nommées en arguments, compte rendu
/// imprimé. Une interface a besoin de l'inverse — démarrer sans échéance, s'arrêter sur
/// commande, et publier un état qu'on peut afficher. C'est ce que ce moteur fournit.
///
/// ## Invariants section 12
///
/// - **Un ring buffer par pipeline de sortie**, alloué avant le démarrage de la capture : le
///   callback temps réel n'alloue jamais. Le flux est dupliqué en lecture seule vers chacun ;
///   aucun sender ne voit le tampon d'un autre.
/// - **La capture ignore ses destinations.** Elle écrit dans des ring buffers, un point c'est
///   tout. Ce sont les senders qui savent où ils diffusent, et chacun ignore l'existence de
///   l'autre.
/// - **Les pannes sont confinées.** Chaque sortie tourne dans sa propre tâche ; son échec est
///   consigné dans son état et n'interrompt ni la capture ni les autres sorties.
public actor BridgeEngine {

    public enum Failure: Error, CustomStringConvertible {
        case captureFormatUnavailable
        case alreadyRunning
        case noOutputRequested
        case permissionDenied(String)

        public var description: String {
            switch self {
            case .captureFormatUnavailable:
                return "format de capture indisponible — le tap n'a pas démarré"
            case .alreadyRunning:
                return "une diffusion est déjà en cours"
            case .noOutputRequested:
                return "aucune sortie demandée"
            case let .permissionDenied(guidance):
                return guidance
            }
        }
    }

    /// Protocole d'une sortie. Les deux senders ont des API jumelles mais des types distincts.
    public enum OutputProtocol: Sendable, Hashable {
        case raop
        case airplay2
    }

    /// Ce qu'on demande au moteur pour une sortie donnée.
    public struct OutputRequest: Sendable, Identifiable {
        public let id: String
        public let proto: OutputProtocol
        /// Nom du récepteur, en correspondance partielle comme dans la découverte.
        public let deviceName: String
        public let volumeDB: Float
        public let manualDelaySeconds: TimeInterval

        public init(
            id: String,
            proto: OutputProtocol,
            deviceName: String,
            volumeDB: Float,
            manualDelaySeconds: TimeInterval = 0
        ) {
            self.id = id
            self.proto = proto
            self.deviceName = deviceName
            self.volumeDB = volumeDB
            self.manualDelaySeconds = manualDelaySeconds
        }
    }

    /// Où en est une sortie. `failed` porte le message tel qu'il sera affiché.
    public enum Phase: Sendable, Equatable {
        case idle
        case connecting
        case streaming
        case failed(String)
    }

    /// État publiable d'une sortie, rafraîchi chaque seconde pendant la diffusion.
    public struct OutputSnapshot: Sendable, Identifiable {
        public let id: String
        public var phase: Phase
        public var packetsSent = 0
        public var errors = 0
        /// Écart résiduel de synchronisation, en secondes. `nil` tant que la mesure se cale.
        public var residualErrorSeconds: TimeInterval?
        /// Corrections de dérive appliquées, insertions et suppressions confondues.
        public var driftCorrections = 0
    }

    private let log = AudioLog.capture
    private var capture: ProcessTapCapture?
    private var fanout: CaptureFanout?
    private var tasks: [Task<Void, Never>] = []
    private var snapshots: [String: OutputSnapshot] = [:]
    private(set) public var isRunning = false

    public init() {}

    /// État courant de toutes les sorties, dans l'ordre où elles ont été demandées.
    public private(set) var outputOrder: [String] = []
    public var outputs: [OutputSnapshot] { outputOrder.compactMap { snapshots[$0] } }

    /// Démarre la capture et toutes les sorties demandées.
    ///
    /// Rend la main dès que la capture tourne : les sorties se connectent en arrière-plan et
    /// publient leur avancement dans `outputs`. Une sortie qui échoue passe en `.failed` sans
    /// affecter les autres.
    public func start(mode: ProcessTapCapture.Mode, outputs requests: [OutputRequest]) async throws {
        guard !isRunning else { throw Failure.alreadyRunning }
        guard !requests.isEmpty else { throw Failure.noOutputRequested }

        // L'autorisation « sons du système » est propre à chaque bundle : l'app doit obtenir
        // la sienne, celle du CLI ne vaut pas pour elle. Sans ce contrôle, le tap démarrerait
        // et ne livrerait qu'un silence numérique, sans la moindre erreur (piège du jalon 1).
        if CapturePermission.status(for: .systemAudio) != .authorized {
            guard await CapturePermission.request(for: .systemAudio) else {
                throw Failure.permissionDenied(CapturePermission.guidance(for: .systemAudio))
            }
        }

        // Le sink doit exister avant le démarrage de la capture, mais son format vient du tap :
        // d'où cette indirection, reprise telle quelle du CLI où elle est éprouvée.
        nonisolated(unsafe) var sink: CaptureFanout?
        let capture = ProcessTapCapture { bufferList, frames in
            guard let sink, frames > 0 else { return }
            let list = UnsafeMutableAudioBufferListPointer(
                UnsafeMutablePointer(mutating: bufferList))
            guard let data = list.first?.mData else { return }
            sink.write(data.assumingMemoryBound(to: Float.self), frameCount: Int(frames))
        }

        try capture.start(mode: mode)
        guard let format = capture.format else {
            capture.stop()
            throw Failure.captureFormatUnavailable
        }

        // Un ring par sortie, tous alloués maintenant : rien ne s'alloue une fois le callback
        // temps réel démarré.
        let active = CaptureFanout(format: format, pipelineCount: requests.count)
        sink = active

        self.capture = capture
        self.fanout = active
        self.isRunning = true
        self.outputOrder = requests.map(\.id)
        self.snapshots = Dictionary(
            uniqueKeysWithValues: requests.map { ($0.id, OutputSnapshot(id: $0.id, phase: .connecting)) }
        )

        // Horloge de restitution commune aux deux sorties : c'est elle qui leur donne un
        // référentiel unique, condition de l'alignement (CDC 4.5).
        let clock = SharedPlaybackClock(captureSampleRate: format.sampleRate)

        for (index, request) in requests.enumerated() {
            let ring = active.ring(at: index)
            tasks.append(Task { [weak self] in
                await self?.run(request, ring: ring, format: format, clock: clock)
            })
        }
        log.info("Moteur démarré : \(requests.count) sortie(s), \(format.sampleRate, format: .fixed(precision: 0)) Hz")
    }

    /// Arrête toutes les sorties puis la capture. Idempotent.
    public func stop() async {
        guard isRunning else { return }
        isRunning = false
        for task in tasks { task.cancel() }
        for task in tasks { _ = await task.value }
        tasks.removeAll()
        capture?.stop()
        capture = nil
        fanout = nil
        for id in outputOrder {
            snapshots[id]?.phase = .idle
        }
        log.info("Moteur arrêté")
    }

    // MARK: - Boucle d'une sortie

    private func run(
        _ request: OutputRequest,
        ring: AudioRingBuffer,
        format: AVAudioFormat,
        clock: SharedPlaybackClock
    ) async {
        do {
            switch request.proto {
            case .raop:
                let device = try await RAOPDiscovery().find(named: request.deviceName)
                let sender = RAOPSender(
                    device: device, ring: ring, captureFormat: format, clock: clock
                )
                await sender.setManualDelay(seconds: request.manualDelaySeconds)
                try await sender.start(volume: request.volumeDB)
                await update(request.id) { $0.phase = .streaming }
                await monitorRAOP(sender, id: request.id)
                await sender.stop()

            case .airplay2:
                let device = try await AirPlay2Discovery().find(named: request.deviceName)
                let sender = AirPlay2Sender(
                    device: device, ring: ring, captureFormat: format, clock: clock
                )
                await sender.setManualDelay(seconds: request.manualDelaySeconds)
                try await sender.start(volume: request.volumeDB)
                await update(request.id) { $0.phase = .streaming }
                await monitorAirPlay2(sender, id: request.id)
                await sender.stop()
            }
        } catch is CancellationError {
            await update(request.id) { $0.phase = .idle }
        } catch {
            // Panne confinée : consignée sur cette sortie, sans toucher aux autres ni à la
            // capture (invariant section 12).
            log.error("Sortie \(request.id, privacy: .public) en échec : \(error)")
            await update(request.id) { $0.phase = .failed("\(error)") }
        }
    }

    /// Rafraîchit l'état d'une sortie RAOP jusqu'à l'annulation de la tâche.
    private func monitorRAOP(_ sender: RAOPSender, id: String) async {
        while !Task.isCancelled {
            do { try await Task.sleep(for: .seconds(1)) } catch { break }
            let statistics = await sender.statistics
            let sync = sender.synchronizer.snapshot()
            await update(id) {
                $0.packetsSent = statistics.packetsSent
                $0.errors = statistics.errors
                $0.residualErrorSeconds = sync.residualErrorSeconds
                $0.driftCorrections = statistics.framesInserted + statistics.framesRemoved
            }
        }
    }

    private func monitorAirPlay2(_ sender: AirPlay2Sender, id: String) async {
        while !Task.isCancelled {
            do { try await Task.sleep(for: .seconds(1)) } catch { break }
            let statistics = await sender.statistics
            let sync = sender.synchronizer.snapshot()
            await update(id) {
                $0.packetsSent = statistics.packetsSent
                $0.errors = statistics.errors
                $0.residualErrorSeconds = sync.residualErrorSeconds
                $0.driftCorrections = statistics.framesInserted + statistics.framesRemoved
            }
        }
    }

    private func update(_ id: String, _ change: (inout OutputSnapshot) -> Void) {
        guard var snapshot = snapshots[id] else { return }
        change(&snapshot)
        snapshots[id] = snapshot
    }
}

/// Duplique le flux capturé vers un ring buffer par pipeline de sortie.
///
/// Écrit depuis le callback temps réel : lock-free, sans allocation (invariant section 12).
/// Les tampons sont tous créés à l'initialisation, jamais pendant la diffusion.
final class CaptureFanout: @unchecked Sendable {
    let format: AVAudioFormat
    private let rings: [AudioRingBuffer]

    init(format: AVAudioFormat, pipelineCount: Int, capacityFrames: Int = 48_000) {
        self.format = format
        self.rings = (0..<max(1, pipelineCount)).map { _ in
            AudioRingBuffer(
                capacityFrames: capacityFrames, channelCount: Int(format.channelCount)
            )
        }
    }

    func ring(at index: Int) -> AudioRingBuffer { rings[min(index, rings.count - 1)] }

    /// Recopie le bloc vers **tous** les pipelines. Aucun sender ne voit le tampon d'un autre.
    func write(_ samples: UnsafePointer<Float>, frameCount: Int) {
        for ring in rings {
            ring.write(from: samples, frameCount: frameCount)
        }
    }
}
