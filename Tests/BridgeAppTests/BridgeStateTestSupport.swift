import AVFoundation
import AudioCore
import Foundation
import Testing

@testable import BridgeApp

// Doublures de `BridgeState` : le vrai moteur, avec une capture et des senders sans matériel, et une
// découverte qui ne touche jamais au réseau — où se trouve le vrai matériel.

/// Attend qu'une condition devienne vraie, sans dormir plus que nécessaire.
func eventually(
    timeout: Duration = .seconds(5),
    _ condition: () async -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(2))
    }
    return await condition()
}

/// Vérifie qu'une condition reste fausse un certain temps.
func staysFalse(
    during duration: Duration = .milliseconds(60),
    _ condition: () async -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now + duration
    while ContinuousClock.now < deadline {
        if await condition() { return false }
        try? await Task.sleep(for: .milliseconds(2))
    }
    return true
}

enum StubError: Error, CustomStringConvertible {
    case prepareFailed
    case absent

    var description: String {
        switch self {
        case .prepareFailed: "la capture n'a pas pu démarrer"
        case .absent: "récepteur introuvable"
        }
    }
}

/// L'ordre des arrêts, relevé par les doublures : `TEARDOWN` d'un sender, arrêt d'une capture, et ce
/// qu'un test y ajoute (relance de coreaudiod, réponse à AppKit).
nonisolated final class StopOrder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []

    func record(_ event: String) {
        lock.lock()
        recorded.append(event)
        lock.unlock()
    }

    var events: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }
}

/// Capture qui ne livre rien : on teste l'orchestration, pas le signal.
nonisolated final class StubCaptureSource: AudioCaptureSource, @unchecked Sendable {
    let requiredPermission: CapturePermission.Kind?
    private let fails: Bool
    private let stopOrder: StopOrder?

    init(
        requiredPermission: CapturePermission.Kind? = nil, fails: Bool = false,
        stopOrder: StopOrder? = nil
    ) {
        self.requiredPermission = requiredPermission
        self.fails = fails
        self.stopOrder = stopOrder
    }

    func prepare() throws -> AVAudioFormat {
        if fails { throw StubError.prepareFailed }
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: true
        ) else { fatalError("format de test impossible") }
        return format
    }

    func start(deliveringTo consumer: @escaping CaptureBlockConsumer) throws {}
    func stop() { stopOrder?.record("capture") }
}

/// Tient le compte des captures demandées au moteur.
nonisolated final class CaptureLog: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [(source: BridgeEngine.Source, options: BridgeEngine.StartOptions)] = []
    private var failing = false
    private var permission: CapturePermission.Kind?
    private let stopOrder: StopOrder?

    init(stopOrder: StopOrder? = nil) {
        self.stopOrder = stopOrder
    }

    func record(
        _ source: BridgeEngine.Source, _ options: BridgeEngine.StartOptions
    ) -> StubCaptureSource {
        lock.lock()
        defer { lock.unlock() }
        requests.append((source, options))
        return StubCaptureSource(
            requiredPermission: permission, fails: failing, stopOrder: stopOrder
        )
    }

    func failNextCaptures(_ value: Bool) {
        lock.lock()
        failing = value
        lock.unlock()
    }

    func require(permission: CapturePermission.Kind) {
        lock.lock()
        self.permission = permission
        lock.unlock()
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return requests.count
    }

    var last: (source: BridgeEngine.Source, options: BridgeEngine.StartOptions)? {
        lock.lock()
        defer { lock.unlock() }
        return requests.last
    }
}

nonisolated final class StubPermissions: CapturePermissionProviding, @unchecked Sendable {
    private let granted: Bool

    init(granted: Bool = true) {
        self.granted = granted
    }

    func status(for kind: CapturePermission.Kind) -> CapturePermission.Status {
        granted ? .authorized : .denied
    }

    func request(for kind: CapturePermission.Kind) async -> Bool { granted }
}

/// Sender sans réseau.
actor StubSender: OutputSender {
    enum Behaviour: Sendable {
        case succeed
        case fail(any Error & Sendable)
    }

    nonisolated let synchronizer: OutputSynchronizer
    nonisolated let requestID: String
    nonisolated let context: OutputSenderContext

    private(set) var state = OutputSenderState.idle
    /// Niveaux reçus par `setOutputLevel`, celui d'avant `start` compris : le moteur le règle
    /// toujours juste avant.
    private(set) var pushedLevels: [OutputLevel] = []
    private(set) var startedLevel: OutputLevel?
    private(set) var startedVolume: Float?
    private(set) var startedDelay: TimeInterval?
    private(set) var startedBass: Float?
    private(set) var startedTreble: Float?
    private(set) var pushedVolumes: [Float] = []
    private(set) var pushedDelays: [TimeInterval] = []
    private(set) var pushedBass: [Float] = []
    private(set) var pushedTreble: [Float] = []
    private(set) var stopCount = 0
    private var errorMessage: String?
    private var statistics = OutputStatistics()
    private let behaviour: Behaviour
    private let stopHangs: Bool
    private let stopOrder: StopOrder?
    private var stopContinuation: CheckedContinuation<Void, Never>?

    init(
        requestID: String, context: OutputSenderContext, behaviour: Behaviour, stopHangs: Bool,
        stopOrder: StopOrder? = nil
    ) {
        self.requestID = requestID
        self.context = context
        self.behaviour = behaviour
        self.stopHangs = stopHangs
        self.stopOrder = stopOrder
        self.synchronizer = OutputSynchronizer(
            label: requestID, clock: context.clock, outputSampleRate: 44_100
        )
    }

    func start(volume: Float) async throws {
        startedVolume = volume
        startedLevel = pushedLevels.last
        startedDelay = synchronizer.manualOffsetSeconds
        startedBass = pushedBass.last
        startedTreble = pushedTreble.last
        if case let .fail(error) = behaviour {
            state = .failed
            throw error
        }
        synchronizer.beginStreaming(atCaptureFrame: context.ring.totalFramesRead)
        state = .streaming
    }

    func stop() async {
        stopCount += 1
        stopOrder?.record("TEARDOWN \(requestID)")
        if stopHangs { await withCheckedContinuation { stopContinuation = $0 } }
        state = .idle
    }

    func releaseStop() {
        stopContinuation?.resume()
        stopContinuation = nil
    }

    func setVolume(_ volume: Float) async throws { pushedVolumes.append(volume) }
    func setOutputLevel(_ level: OutputLevel) { pushedLevels.append(level) }
    /// Le moteur règle le délai juste avant `start` : seul ce qui suit est une poussée.
    func setManualDelay(seconds: TimeInterval) {
        if startedVolume != nil { pushedDelays.append(seconds) }
        synchronizer.manualOffsetSeconds = seconds
    }
    func setBassBoost(decibels: Float) { pushedBass.append(decibels) }
    func setTrebleCut(decibels: Float) { pushedTreble.append(decibels) }

    func currentOutputState() -> OutputSenderState { state }
    func currentOutputStatistics() -> OutputStatistics { statistics }
    func currentOutputError() -> String? { errorMessage }

    func become(_ state: OutputSenderState, error: String? = nil) {
        self.state = state
        errorMessage = error
    }

    func setStatistics(_ statistics: OutputStatistics) { self.statistics = statistics }
}

/// Fabrique pilotée par le test.
nonisolated final class StubSenderFactory: OutputSenderFactory, @unchecked Sendable {
    private let lock = NSLock()
    private var created: [String: [StubSender]] = [:]
    private var requests: [String: [BridgeEngine.OutputRequest]] = [:]
    private var behaviours: [String: [StubSender.Behaviour]] = [:]
    private var absent: Set<String> = []
    private var stopHanging: Set<String> = []
    private let stopOrder: StopOrder?

    init(stopOrder: StopOrder? = nil) {
        self.stopOrder = stopOrder
    }

    func script(_ id: String, _ list: [StubSender.Behaviour]) {
        lock.lock()
        behaviours[id] = list
        lock.unlock()
    }

    func markAbsent(_ id: String, _ isAbsent: Bool = true) {
        lock.lock()
        if isAbsent { absent.insert(id) } else { absent.remove(id) }
        lock.unlock()
    }

    func makeStopHang(_ id: String) {
        lock.lock()
        stopHanging.insert(id)
        lock.unlock()
    }

    func makeSender(
        for request: BridgeEngine.OutputRequest, context: OutputSenderContext
    ) async throws -> any OutputSender {
        try next(for: request, context: context)
    }

    private func next(
        for request: BridgeEngine.OutputRequest, context: OutputSenderContext
    ) throws -> StubSender {
        lock.lock()
        defer { lock.unlock() }
        requests[request.id, default: []].append(request)
        if absent.contains(request.id) { throw StubError.absent }
        var behaviour = StubSender.Behaviour.succeed
        if var list = behaviours[request.id], !list.isEmpty {
            behaviour = list.removeFirst()
            behaviours[request.id] = list
        }
        let sender = StubSender(
            requestID: request.id, context: context, behaviour: behaviour,
            stopHangs: stopHanging.contains(request.id), stopOrder: stopOrder
        )
        created[request.id, default: []].append(sender)
        return sender
    }

    func senders(_ id: String) -> [StubSender] {
        lock.lock()
        defer { lock.unlock() }
        return created[id] ?? []
    }

    func latest(_ id: String) -> StubSender? { senders(id).last }

    func lastRequest(_ id: String) -> BridgeEngine.OutputRequest? {
        lock.lock()
        defer { lock.unlock() }
        return requests[id]?.last
    }

    var createdCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return created.values.reduce(0) { $0 + $1.count }
    }
}

/// Découverte pilotée par le test, qui compte ses recherches et ce qui se chevauche.
final class StubDiscovery: OutputDiscovering {
    var result = OutputDiscoveryResult()
    private(set) var roundCount = 0
    private(set) var running = 0
    private(set) var maximumRunning = 0
    /// Bloque les recherches jusqu'à `release`.
    var holds = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func discover() async -> OutputDiscoveryResult {
        roundCount += 1
        running += 1
        maximumRunning = max(maximumRunning, running)
        defer { running -= 1 }
        if holds {
            await withCheckedContinuation { waiting.append($0) }
        }
        // Une vraie recherche prend du temps : c'est ce qui laisse à une autre l'occasion de
        // chevaucher celle-ci.
        await Task.yield()
        return result
    }

    func release() {
        holds = false
        for continuation in waiting { continuation.resume() }
        waiting = []
    }
}

final class StubActivity: StreamingActivityHolding {
    private(set) var isHeld = false
    private(set) var beginCount = 0

    func begin() {
        isHeld = true
        beginCount += 1
    }

    func end() { isHeld = false }
}

extension BridgeEnvironment.Timing {
    /// Délais courts : les tests n'ont pas à dormir.
    static var fast: BridgeEnvironment.Timing {
        var timing = BridgeEnvironment.Timing()
        timing.pollInterval = .milliseconds(2)
        timing.discoveryInterval = .seconds(3_600)
        timing.panelRefreshMinimumAge = .zero
        timing.settingsSaveDelay = .milliseconds(10)
        timing.wakeResumeDelay = .milliseconds(5)
        timing.emptySelectionGrace = .milliseconds(30)
        timing.minimumToggleInterval = .zero
        timing.sourceCheckInterval = .zero
        return timing
    }
}

/// `BridgeState` branché sur ses doublures.
final class BridgeHarness {
    /// `TEARDOWN` des senders et arrêts de capture, dans l'ordre où le moteur les fait.
    let stopOrder: StopOrder
    let factory: StubSenderFactory
    let captures: CaptureLog
    let discovery = StubDiscovery()
    let store: InMemorySettingsStore
    let activity = StubActivity()
    var sources: [CaptureSource] = [.systemWide, .inputDevice]
    var layout = RoomLayout()
    /// Processus partis. Les autres sont réputés vivants : un test n'en a que des fictifs.
    var deadPIDs: Set<pid_t> = []
    private(set) var layoutSaveCount = 0

    private(set) lazy var state = makeState()

    private let timing: BridgeEnvironment.Timing
    private let permissions: StubPermissions
    private let tuning: BridgeEngine.Tuning
    /// Le volume du Mac : aucune sortie par défaut, donc rien de lié (`SystemVolumeLinkTests`).
    private let systemVolume: any SystemVolumeControlling
    /// Les sorties du Mac : aucune par défaut, donc rien ne bascule (`VideoSyncSwitchTests`).
    private let outputSwitch: any DefaultOutputSwitching

    init(
        settings: BridgeSettings = BridgeSettings(),
        timing: BridgeEnvironment.Timing = .fast,
        permissions: StubPermissions = StubPermissions(),
        tuning: BridgeEngine.Tuning? = nil,
        systemVolume: any SystemVolumeControlling = NoSystemVolumeControl(),
        outputSwitch: any DefaultOutputSwitching = InertDefaultOutputSwitch()
    ) {
        let stopOrder = StopOrder()
        self.stopOrder = stopOrder
        self.factory = StubSenderFactory(stopOrder: stopOrder)
        self.captures = CaptureLog(stopOrder: stopOrder)
        self.store = InMemorySettingsStore(settings)
        self.timing = timing
        self.permissions = permissions
        self.tuning = tuning ?? Self.fastTuning
        self.systemVolume = systemVolume
        self.outputSwitch = outputSwitch
    }

    static var fastTuning: BridgeEngine.Tuning {
        var tuning = BridgeEngine.Tuning()
        tuning.retryInitialDelay = .milliseconds(5)
        tuning.retryMaximumDelay = .milliseconds(20)
        tuning.stopTimeout = .milliseconds(300)
        tuning.monitorInterval = .milliseconds(2)
        tuning.healthInterval = .seconds(3_600)
        tuning.routeChangeDebounce = .milliseconds(2)
        return tuning
    }

    private func makeState() -> BridgeState {
        let captures = self.captures
        return BridgeState(
            environment: BridgeEnvironment(
                engineDependencies: BridgeEngine.Dependencies(
                    makeSource: { source, options in captures.record(source, options) },
                    senderFactory: factory,
                    permissions: permissions,
                    tuning: tuning
                ),
                discovery: discovery,
                settingsStore: store,
                // Faibles : certains tests ne gardent que l'état, et celui-ci survit au banc d'essai.
                loadRoomLayout: { [weak self] in self?.layout ?? RoomLayout() },
                saveRoomLayout: { [weak self] saved in
                    self?.layout = saved
                    self?.layoutSaveCount += 1
                },
                availableSources: { [weak self] in self?.sources ?? [.systemWide, .inputDevice] },
                streamingActivity: activity,
                timing: timing,
                isProcessAlive: { [weak self] pid in !(self?.deadPIDs.contains(pid) ?? false) },
                systemVolume: systemVolume,
                outputSwitch: outputSwitch
            )
        )
    }

    /// Une recherche qui rapporte ces appareils.
    func discover(
        raop: [RAOPDevice] = [], airplay2: [AirPlay2Device] = []
    ) async {
        discovery.result = OutputDiscoveryResult(raop: raop, airplay2: airplay2)
        await state.refreshOutputs()
    }

    func output(_ id: String) -> OutputState? {
        state.outputs.first { $0.id == id }
    }

    /// Démarre et attend que toutes ces sorties diffusent.
    func startStreaming(expecting ids: [String]) async {
        state.toggleStreaming()
        #expect(await eventually { state.isStreaming })
        for id in ids {
            #expect(await eventually { output(id)?.connection == .streaming })
        }
    }

    func stopStreaming() async {
        state.toggleStreaming()
        #expect(await eventually { state.streamingPhase == .idle })
    }
}

// MARK: - Appareils

enum Devices {
    static let genevaID = "raop/AABBCCDDEEFF@Geneva"
    static let leftID = "airplay2/Salon"
    static let rightID = "airplay2/Salon (2)"
    static let appleTVRaopID = "raop/001122334455@Apple TV Salon"
    static let appleTVAirPlay2ID = "airplay2/Apple TV Salon"

    /// Relevé sur l'appareil (commit 7a71166) : aucun bit de pairing, un récepteur AirPlay 1.
    static let genevaFeatures = "0x444c0a00"
    /// Bit 48 sans bit 43 : ce qu'annonce le mock.
    static let transientFeatures = "0x405f4200,0x1c300"
    /// Bits 43, 46 et 48 : proposer l'appairage système n'empêche pas d'accepter le transitoire.
    static let homePodFeatures = "0x4A7FDFD5,0x3C155FDE"
    /// Bits 43 et 46, sans le 48.
    static let pairingOnlyFeatures = "0x4A7FDFD5,0x3C0A4800"

    static let genevaRAOP = RAOPDevice(
        serviceName: "AABBCCDDEEFF@Geneva", host: "192.168.1.42", port: 7000,
        txt: ["et": "0,4", "cn": "0,1"]
    )
    static let genevaAirPlay2 = AirPlay2Device(
        serviceName: "Geneva", host: "192.168.1.42", port: 7000,
        txt: ["features": genevaFeatures]
    )
    // Deux HomePod baptisés « Salon » : le suffixe vient du conflit Bonjour en `_airplay._tcp`,
    // l'adresse matérielle l'évite en `_raop._tcp`.
    static let leftRAOP = RAOPDevice(
        serviceName: "111111111111@Salon", host: "192.168.1.158", port: 7000, txt: ["et": "0,3,5"]
    )
    static let left = AirPlay2Device(
        serviceName: "Salon", host: "192.168.1.158", port: 7000,
        txt: ["features": homePodFeatures, "model": "AudioAccessory5,1"]
    )
    static let rightRAOP = RAOPDevice(
        serviceName: "222222222222@Salon", host: "192.168.1.88", port: 7000, txt: ["et": "0,3,5"]
    )
    static let right = AirPlay2Device(
        serviceName: "Salon (2)", host: "192.168.1.88", port: 7000,
        txt: ["features": homePodFeatures, "model": "AudioAccessory5,1"]
    )
    static let appleTVRAOP = RAOPDevice(
        serviceName: "001122334455@Apple TV Salon", host: "192.168.1.51", port: 7000,
        txt: ["et": "0,3,5", "cn": "0,1,2,3"]
    )
    static let appleTVPairingOnly = AirPlay2Device(
        serviceName: "Apple TV Salon", host: "192.168.1.51", port: 7000,
        txt: ["features": pairingOnlyFeatures, "model": "AppleTV14,1"]
    )
    static let appleTVAnnouncingTransient = AirPlay2Device(
        serviceName: "Apple TV Salon", host: "192.168.1.51", port: 7000,
        txt: ["features": homePodFeatures, "model": "AppleTV14,1"]
    )

    /// L'installation complète, telle que les deux découvertes la rapportent.
    static let allRAOP = [genevaRAOP, leftRAOP, rightRAOP, appleTVRAOP]
    static let allAirPlay2 = [genevaAirPlay2, left, right, appleTVPairingOnly]
}
