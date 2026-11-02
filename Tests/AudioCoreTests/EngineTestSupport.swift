import AVFoundation
import Foundation
import Testing

@testable import AudioCore

// Doublures du moteur : une source qu'on actionne à la main, un sender sans réseau. C'est ce que
// l'injection par protocole (CDC section 13) rend possible — tester le moteur sans matériel ni
// autorisation TCC.

/// Attend qu'une condition devienne vraie, sans dormir plus que nécessaire.
func eventually(
    timeout: Duration = .seconds(10),
    _ condition: @Sendable () async -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(2))
    }
    return await condition()
}

func stereoFormat(sampleRate: Double = 48_000) -> AVAudioFormat {
    guard let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 2, interleaved: true
    ) else { fatalError("format de test impossible") }
    return format
}

func monoPlanarFormat(sampleRate: Double = 48_000) -> AVAudioFormat {
    guard let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false
    ) else { fatalError("format de test impossible") }
    return format
}

enum FakeError: Error, Equatable {
    case absent
    case prepareFailed
}

/// Tient le compte des captures actives, tous objets confondus : c'est lui qui vérifie
/// l'invariant « une seule capture active à la fois ».
final class CaptureLedger: @unchecked Sendable {
    private let lock = NSLock()
    private var active = 0
    private var maximum = 0
    private(set) var created: [ManualCaptureSource] = []

    func didStart() {
        lock.lock()
        active += 1
        maximum = max(maximum, active)
        lock.unlock()
    }

    func didStop() {
        lock.lock()
        active -= 1
        lock.unlock()
    }

    func register(_ source: ManualCaptureSource) {
        lock.lock()
        created.append(source)
        lock.unlock()
    }

    var maximumActive: Int {
        lock.lock()
        defer { lock.unlock() }
        return maximum
    }

    var activeCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return active
    }

    var createdCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return created.count
    }
}

/// Source pilotée par le test : chaque `push` joue le rôle d'un passage du callback de capture.
final class ManualCaptureSource: AudioCaptureSource, @unchecked Sendable {
    private let lock = NSLock()
    private var consumer: CaptureBlockConsumer?
    private var routeHandler: (@Sendable () -> Void)?
    private var preparedFormats: [AVAudioFormat]
    private var runningFlag = false
    private var nextSample: Float = 1

    private(set) var prepareCount = 0
    private(set) var startCount = 0
    private(set) var stopCount = 0

    let requiredPermission: CapturePermission.Kind?
    let ledger: CaptureLedger?
    /// Bloc émis depuis `start` lui-même, avant son retour : ce qu'une vraie source peut faire.
    var framesPushedDuringStart = 0
    var routeChanged = false
    var expectation: Bool?
    var preparesToFail = 0
    var startsToFail = 0

    init(
        format: AVAudioFormat = stereoFormat(),
        laterFormats: [AVAudioFormat] = [],
        permission: CapturePermission.Kind? = nil,
        ledger: CaptureLedger? = nil
    ) {
        self.preparedFormats = [format] + laterFormats
        self.requiredPermission = permission
        self.ledger = ledger
        ledger?.register(self)
    }

    func prepare() throws -> AVAudioFormat {
        lock.lock()
        defer { lock.unlock() }
        prepareCount += 1
        if preparesToFail > 0 {
            preparesToFail -= 1
            throw FakeError.prepareFailed
        }
        // Comme une vraie source : une capture préparée porte sur la route courante.
        routeChanged = false
        let format = preparedFormats[0]
        if preparedFormats.count > 1 { preparedFormats.removeFirst() }
        return format
    }

    func start(deliveringTo consumer: @escaping CaptureBlockConsumer) throws {
        lock.lock()
        if startsToFail > 0 {
            startsToFail -= 1
            lock.unlock()
            throw FakeError.prepareFailed
        }
        self.consumer = consumer
        startCount += 1
        runningFlag = true
        let early = framesPushedDuringStart
        lock.unlock()
        ledger?.didStart()
        if early > 0 { push(frames: early) }
    }

    func stop() {
        lock.lock()
        let wasRunning = runningFlag
        runningFlag = false
        consumer = nil
        stopCount += 1
        lock.unlock()
        if wasRunning { ledger?.didStop() }
    }

    func setRouteChangeHandler(_ handler: (@Sendable () -> Void)?) {
        lock.lock()
        routeHandler = handler
        lock.unlock()
    }

    func routeRequiresRebuild() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return routeChanged
    }

    func isAudioExpected() -> Bool? { expectation }

    /// Simule une notification Core Audio de changement de sortie.
    func fireRouteChange() {
        lock.lock()
        routeChanged = true
        let handler = routeHandler
        lock.unlock()
        handler?()
    }

    var hasRouteHandler: Bool {
        lock.lock()
        defer { lock.unlock() }
        return routeHandler != nil
    }

    /// Émet un bloc stéréo entrelacé dont chaque trame vaut la suivante de la série 1, 2, 3…
    /// Trames perdues et réordonnancements se voient donc à la lecture.
    @discardableResult
    func push(frames: Int) -> Bool {
        var samples = [Float](repeating: 0, count: frames * 2)
        lock.lock()
        for frame in 0..<frames {
            samples[frame * 2] = nextSample
            samples[frame * 2 + 1] = nextSample
            nextSample += 1
        }
        lock.unlock()
        return deliver(&samples, frames: frames, channels: 2)
    }

    /// Émet un bloc de zéros : le silence strict d'une autorisation perdue.
    @discardableResult
    func pushSilence(frames: Int) -> Bool {
        var samples = [Float](repeating: 0, count: frames * 2)
        return deliver(&samples, frames: frames, channels: 2)
    }

    /// Émet un bloc dans un seul tampon, avec les valeurs données.
    @discardableResult
    func pushRaw(_ samples: [Float], frames: Int, channels: Int) -> Bool {
        var copy = samples
        return deliver(&copy, frames: frames, channels: channels)
    }

    private func deliver(_ samples: inout [Float], frames: Int, channels: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let consumer else { return false }
        samples.withUnsafeMutableBytes { raw in
            var list = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(
                    mNumberChannels: UInt32(channels),
                    mDataByteSize: UInt32(raw.count),
                    mData: raw.baseAddress
                )
            )
            consumer(&list, UInt32(frames))
        }
        return true
    }
}

/// Autorisations pilotées par le test. `request` reste suspendu tant que le test n'a pas répondu,
/// comme le ferait un dialogue laissé ouvert.
final class FakePermissions: CapturePermissionProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var current: CapturePermission.Status
    private var pending: [CheckedContinuation<Bool, Never>] = []
    private(set) var requestedKinds: [CapturePermission.Kind] = []

    init(status: CapturePermission.Status = .authorized) {
        self.current = status
    }

    func status(for kind: CapturePermission.Kind) -> CapturePermission.Status {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    func request(for kind: CapturePermission.Kind) async -> Bool {
        await withCheckedContinuation { continuation in
            lock.lock()
            requestedKinds.append(kind)
            pending.append(continuation)
            lock.unlock()
        }
    }

    var requestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return requestedKinds.count
    }

    func answer(_ granted: Bool) {
        lock.lock()
        let waiting = pending
        pending = []
        current = granted ? .authorized : .denied
        lock.unlock()
        for continuation in waiting { continuation.resume(returning: granted) }
    }
}

/// Sender sans réseau.
actor FakeSender: OutputSender {
    enum StartBehaviour: Sendable {
        case succeed
        case fail(FakeError)
        case failWith(any Error & Sendable)
        case failPermanently
        /// Reste en négociation jusqu'à `releaseStart` ou `stop`.
        case hang
    }

    nonisolated let synchronizer: OutputSynchronizer
    nonisolated let context: OutputSenderContext
    nonisolated let requestID: String

    private(set) var state = OutputSenderState.idle
    private(set) var startedVolume: Float?
    private(set) var startedDelay: TimeInterval?
    private(set) var pushedVolumes: [Float] = []
    private(set) var pushedDelays: [TimeInterval] = []
    private(set) var pushedBassBoosts: [Float] = []
    private(set) var startedBassBoost: Float?
    private var errorMessage: String?
    private(set) var stopCount = 0
    private var statistics = OutputStatistics()
    private let behaviour: StartBehaviour
    private let stopHangs: Bool
    private var startContinuation: CheckedContinuation<Void, Error>?
    private var stopContinuation: CheckedContinuation<Void, Never>?
    private var stopped = false

    init(
        requestID: String, context: OutputSenderContext, behaviour: StartBehaviour, stopHangs: Bool
    ) {
        self.requestID = requestID
        self.context = context
        self.behaviour = behaviour
        self.stopHangs = stopHangs
        self.synchronizer = OutputSynchronizer(
            label: requestID, clock: context.clock, outputSampleRate: 44_100
        )
    }

    func start(volume: Float) async throws {
        startedVolume = volume
        startedDelay = synchronizer.manualOffsetSeconds
        startedBassBoost = pushedBassBoosts.last
        state = .connecting
        switch behaviour {
        case .succeed:
            break
        case let .fail(error):
            state = .failed
            throw error
        case let .failWith(error):
            state = .failed
            throw error
        case .failPermanently:
            state = .failed
            throw RAOPSenderError.alacUnsupported(requestID)
        case .hang:
            if stopped { throw CancellationError() }
            try await withCheckedThrowingContinuation { startContinuation = $0 }
        }
        _ = drain()
        synchronizer.beginStreaming(atCaptureFrame: context.ring.totalFramesRead)
        state = .streaming
    }

    func releaseStart() {
        startContinuation?.resume()
        startContinuation = nil
    }

    var isNegotiating: Bool { startContinuation != nil }

    func stop() async {
        stopCount += 1
        stopped = true
        startContinuation?.resume(throwing: CancellationError())
        startContinuation = nil
        if stopHangs { await withCheckedContinuation { stopContinuation = $0 } }
        state = .idle
    }

    func releaseStop() {
        stopContinuation?.resume()
        stopContinuation = nil
    }

    func setVolume(_ volume: Float) async throws { pushedVolumes.append(volume) }
    func setManualDelay(seconds: TimeInterval) {
        pushedDelays.append(seconds)
        synchronizer.manualOffsetSeconds = seconds
    }

    func setBassBoost(decibels: Float) { pushedBassBoosts.append(decibels) }

    func currentOutputError() -> String? { errorMessage }
    func currentOutputState() -> OutputSenderState { state }
    func currentOutputStatistics() -> OutputStatistics { statistics }

    func setState(_ state: OutputSenderState) { self.state = state }
    func setError(_ message: String?) { errorMessage = message }
    func setStatistics(_ statistics: OutputStatistics) { self.statistics = statistics }

    /// Lit tout l'arriéré du tampon, comme la boucle d'un vrai sender.
    @discardableResult
    func drain() -> [Float] {
        let ring = context.ring
        let channels = Int(context.captureFormat.channelCount)
        var collected: [Float] = []
        var scratch = [Float](repeating: 0, count: 4_096 * channels)
        while ring.availableFrames > 0 {
            let read = scratch.withUnsafeMutableBufferPointer { buffer -> Int in
                guard let base = buffer.baseAddress else { return 0 }
                return ring.read(into: base, frameCount: 4_096)
            }
            if read == 0 { break }
            collected.append(contentsOf: scratch[0..<(read * channels)])
        }
        return collected
    }
}

/// Fabrique pilotée par le test : par sortie, ce que doivent faire les tentatives successives.
final class FakeSenderFactory: OutputSenderFactory, @unchecked Sendable {
    private let lock = NSLock()
    private var scripts: [String: [FakeSender.StartBehaviour]] = [:]
    private var discoveryFailures: [String: Int] = [:]
    private var stopHanging: Set<String> = []
    private var created: [String: [FakeSender]] = [:]

    /// Comportements des tentatives successives. Une fois la liste épuisée, tout réussit.
    func script(_ id: String, _ behaviours: [FakeSender.StartBehaviour]) {
        lock.lock()
        scripts[id] = behaviours
        lock.unlock()
    }

    /// Simule un récepteur absent de Bonjour pour les N prochaines recherches.
    func failDiscovery(_ id: String, times: Int) {
        lock.lock()
        discoveryFailures[id] = times
        lock.unlock()
    }

    func makeStopHang(_ id: String) {
        lock.lock()
        stopHanging.insert(id)
        lock.unlock()
    }

    func makeSender(
        for request: BridgeEngine.OutputRequest,
        context: OutputSenderContext
    ) async throws -> any OutputSender {
        try nextSender(for: request, context: context)
    }

    private func nextSender(
        for request: BridgeEngine.OutputRequest, context: OutputSenderContext
    ) throws -> FakeSender {
        lock.lock()
        defer { lock.unlock() }
        if let remaining = discoveryFailures[request.id], remaining > 0 {
            discoveryFailures[request.id] = remaining - 1
            throw FakeError.absent
        }
        var behaviour = FakeSender.StartBehaviour.succeed
        if var script = scripts[request.id], !script.isEmpty {
            behaviour = script.removeFirst()
            scripts[request.id] = script
        }
        let sender = FakeSender(
            requestID: request.id, context: context, behaviour: behaviour,
            stopHangs: stopHanging.contains(request.id)
        )
        created[request.id, default: []].append(sender)
        return sender
    }

    func senders(_ id: String) -> [FakeSender] {
        lock.lock()
        defer { lock.unlock() }
        return created[id] ?? []
    }

    func allSenders() -> [FakeSender] {
        lock.lock()
        defer { lock.unlock() }
        return created.values.flatMap { $0 }
    }

    func latest(_ id: String) -> FakeSender? { senders(id).last }
}

extension BridgeEngine.Tuning {
    /// Délais courts : les tests n'ont pas à dormir. Le relevé de santé périodique est écarté,
    /// les tests qui s'y intéressent l'appelant eux-mêmes, à des dates choisies.
    static var fast: BridgeEngine.Tuning {
        var tuning = BridgeEngine.Tuning()
        tuning.retryInitialDelay = .milliseconds(5)
        tuning.retryMaximumDelay = .milliseconds(20)
        tuning.stopTimeout = .milliseconds(300)
        tuning.monitorInterval = .milliseconds(2)
        tuning.healthInterval = .seconds(3_600)
        tuning.routeChangeDebounce = .milliseconds(2)
        tuning.rebuildRetryInitialDelay = .milliseconds(2)
        tuning.rebuildRetryMaximumDelay = .milliseconds(5)
        return tuning
    }
}

func makeEngine(
    source: ManualCaptureSource,
    factory: FakeSenderFactory,
    permissions: FakePermissions = FakePermissions(),
    tuning: BridgeEngine.Tuning = .fast
) -> BridgeEngine {
    BridgeEngine(
        dependencies: BridgeEngine.Dependencies(
            makeSource: { _, _ in source },
            senderFactory: factory,
            permissions: permissions,
            tuning: tuning
        )
    )
}

func request(
    _ id: String, volume: Float = -20, delay: TimeInterval = 0,
    proto: BridgeEngine.OutputProtocol = .raop, bassBoost: Float = 0
) -> BridgeEngine.OutputRequest {
    BridgeEngine.OutputRequest(
        id: id, proto: proto, deviceName: id, volumeDB: volume, manualDelaySeconds: delay,
        bassBoostDB: bassBoost
    )
}

extension BridgeEngine {
    func phase(of id: String) -> Phase? { outputs.first { $0.id == id }?.phase }
    func snapshot(of id: String) -> OutputSnapshot? { outputs.first { $0.id == id } }
}
