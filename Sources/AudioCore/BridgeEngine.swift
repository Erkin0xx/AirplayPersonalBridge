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
/// - **Une seule capture active.** L'acteur étant réentrant, son état ne peut pas se déduire de
///   « une méthode est en cours » : ``Lifecycle`` est posé *avant* la première suspension, pour
///   que deux appels rapprochés ne démarrent jamais deux captures.
/// - **Un ring buffer par pipeline de sortie**, alloué avant le démarrage de la capture : le
///   callback temps réel n'alloue jamais, y compris quand une sortie s'ajoute à chaud. Le flux
///   est dupliqué en lecture seule vers chacun ; aucun sender ne voit le tampon d'un autre.
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
        /// `stop()` est survenu pendant que `start` attendait l'autorisation.
        case stoppedDuringStart
        /// La sortie demandée n'a de sens que pendant une diffusion.
        case notRunning
        /// Deux sorties portent le même identifiant.
        case duplicateOutput(String)
        /// Tous les ring buffers pré-alloués sont pris.
        case tooManyOutputs(limit: Int)

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
            case .stoppedDuringStart:
                return "diffusion arrêtée pendant son démarrage"
            case .notRunning:
                return "aucune diffusion en cours"
            case let .duplicateOutput(id):
                return "la sortie « \(id) » est déjà demandée"
            case let .tooManyOutputs(limit):
                return "au plus \(limit) sorties simultanées"
            }
        }
    }

    /// Ce qui est capté.
    public enum Source: Sendable {
        /// Son système global ou application précise.
        case processTap(ProcessTapCapture.Mode)
        /// Entrée physique, celle choisie dans Réglages Son > Entrée.
        case inputDevice
        /// Sinusoïde : diffusion de bout en bout sans capture ni autorisation.
        case tone(frequency: Double, levelDBFS: Double)
    }

    public struct StartOptions: Sendable {
        /// Coupe le son du Mac pendant la capture (Process Tap seulement). Désactivé par défaut :
        /// c'est le comportement validé sur le matériel, et le son local reste un filet si les
        /// enceintes ne répondent pas.
        public var muteLocalOutput: Bool

        public init(muteLocalOutput: Bool = false) {
            self.muteLocalOutput = muteLocalOutput
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
        public var volumeDB: Float
        public var manualDelaySeconds: TimeInterval
        /// Credentials d'appairage système, pour un récepteur qui refuse le transitoire. Sans
        /// objet en RAOP.
        public let credentials: HapCredentials?

        public init(
            id: String,
            proto: OutputProtocol,
            deviceName: String,
            volumeDB: Float,
            manualDelaySeconds: TimeInterval = 0,
            credentials: HapCredentials? = nil
        ) {
            self.id = id
            self.proto = proto
            self.deviceName = deviceName
            self.volumeDB = volumeDB
            self.manualDelaySeconds = manualDelaySeconds
            self.credentials = credentials
        }
    }

    /// Où en est une sortie. Les messages sont faits pour être affichés tels quels.
    public enum Phase: Sendable, Equatable {
        case idle
        /// Première tentative de connexion.
        case connecting
        /// Récepteur introuvable ou injoignable : le moteur réessaie en tâche de fond.
        case waitingForReceiver(attempt: Int, lastError: String)
        case streaming
        /// Session perdue, le sender la rétablit sans toucher à la capture ni aux autres.
        case reconnecting
        /// Échec qu'un nouvel essai ne résoudra pas : capacité absente, authentification.
        case failed(String)
    }

    /// État publiable d'une sortie, rafraîchi chaque seconde pendant la diffusion.
    ///
    /// N'expose que ce qui est mesuré : une grandeur absente reste `nil`.
    public struct OutputSnapshot: Sendable, Identifiable {
        public let id: String
        public var phase: Phase
        /// Compteurs du sender. Cumulés sur toute la vie de la sortie, reconnexions comprises.
        public var statistics = OutputStatistics()
        /// Alignement et dérive. `nil` tant que le sender n'est pas connecté.
        public var sync: SyncSnapshot?
        /// Trames refusées par le ring buffer depuis le début de la diffusion, y compris
        /// pendant une reconnexion. Non nul hors reconnexion, il signale un sender bloqué.
        public var droppedWhileStreaming = 0
        /// Prochaine tentative, pendant `waitingForReceiver`. `nil` quand une tentative est en
        /// cours ou qu'aucune n'est prévue.
        public var nextAttemptAt: Date?

        public var packetsSent: Int { statistics.packetsSent }
        public var errors: Int { statistics.errors }
        /// Écart résiduel de synchronisation, en secondes. `nil` tant que la mesure se cale.
        public var residualErrorSeconds: TimeInterval? { sync?.residualErrorSeconds }
        /// Corrections de dérive appliquées, insertions et suppressions confondues.
        public var driftCorrections: Int { statistics.framesInserted + statistics.framesRemoved }

        init(id: String, phase: Phase) {
            self.id = id
            self.phase = phase
        }
    }

    /// Ce que le moteur sait de la santé de la capture.
    public struct CaptureHealth: Sendable, Equatable {
        public enum Diagnosis: Sendable, Equatable {
            case notRunning
            /// Aucun bloc reçu depuis le démarrage. Le tap ne livre rien tant que rien ne joue :
            /// c'est l'attente normale, pas une panne.
            case waitingForFirstBlock
            case healthy
            /// Les blocs ont cessé d'arriver (périphérique perdu, reconstruction en échec).
            case stalled
            /// Silence strict alors qu'une application captée joue : **autorisation perdue ou
            /// tap mal câblé**. Typiquement juste après un rebuild, qui révoque l'autorisation
            /// sans la moindre erreur (`CLAUDE.md`).
            case silentWhilePlaying
            /// Silence strict et rien ne joue : rien d'anormal.
            case silentNothingPlaying
            /// Silence strict, et la source ne sait pas dire si quelque chose devrait jouer.
            case silentUnknown
        }

        public var diagnosis: Diagnosis = .notRunning
        /// Trames produites depuis le démarrage de la capture.
        public var framesCaptured = 0
        /// Début du silence strict en cours, à partir du seuil de détection. Un seul échantillon
        /// non nul le remet à `nil`.
        public var silentSince: Date?
        /// Dernier bloc reçu, quand les blocs ont cessé d'arriver.
        public var stalledSince: Date?
        /// État de l'autorisation exigée par la source, `nil` si elle n'en exige aucune.
        public var permission: CapturePermission.Status?
        /// Reconstructions de la capture réussies, après changement de périphérique.
        public var rebuilds = 0
        /// Dernière erreur de reconstruction, tant qu'aucune n'a abouti depuis.
        public var lastRebuildError: String?
        /// Durée cumulée des interruptions reportées sur l'horloge commune, en secondes.
        public var interruptedSeconds: TimeInterval = 0

        public init() {}
    }

    /// Réglages de temporisation, injectables pour que les tests ne dorment pas.
    public struct Tuning: Sendable {
        /// Attente avant de réessayer un récepteur absent, doublée à chaque échec.
        public var retryInitialDelay: Duration = .seconds(2)
        public var retryMaximumDelay: Duration = .seconds(30)
        /// Temps laissé aux sorties pour se fermer. Un récepteur muet peut retenir un
        /// `TEARDOWN` : au-delà, la capture s'arrête quand même et la sortie finit seule.
        public var stopTimeout: Duration = .seconds(4)
        public var monitorInterval: Duration = .seconds(1)
        public var healthInterval: Duration = .milliseconds(250)
        /// Silence strict au-delà duquel `silentSince` est publié.
        public var silenceThresholdSeconds: TimeInterval = 3
        /// Immobilité de la graduation au-delà de laquelle la capture est dite interrompue.
        public var stallThresholdSeconds: TimeInterval = 1
        /// Regroupe la rafale de notifications d'un changement de périphérique.
        public var routeChangeDebounce: Duration = .milliseconds(300)
        public var rebuildRetryInitialDelay: Duration = .milliseconds(500)
        public var rebuildRetryMaximumDelay: Duration = .seconds(8)
        public var maximumOutputs = CaptureFanout.defaultSlotCount

        public init() {}
    }

    /// Ce que le moteur reçoit de l'extérieur (CDC section 13 : injection par protocole).
    public struct Dependencies: Sendable {
        public var makeSource: @Sendable (Source, StartOptions) -> any AudioCaptureSource
        public var senderFactory: any OutputSenderFactory
        public var permissions: any CapturePermissionProviding
        public var tuning: Tuning

        public init(
            makeSource: @escaping @Sendable (Source, StartOptions) -> any AudioCaptureSource,
            senderFactory: any OutputSenderFactory,
            permissions: any CapturePermissionProviding,
            tuning: Tuning = Tuning()
        ) {
            self.makeSource = makeSource
            self.senderFactory = senderFactory
            self.permissions = permissions
            self.tuning = tuning
        }

        public static var live: Dependencies {
            Dependencies(
                makeSource: { source, options in
                    switch source {
                    case let .processTap(mode):
                        return ProcessTapCapture(
                            mode: mode, muteLocalOutput: options.muteLocalOutput
                        )
                    case .inputDevice:
                        return InputDeviceCapture()
                    case let .tone(frequency, levelDBFS):
                        return ToneCaptureSource(frequency: frequency, levelDBFS: levelDBFS)
                    }
                },
                senderFactory: LiveOutputSenderFactory(),
                permissions: SystemCapturePermissions()
            )
        }
    }

    /// Cycle de vie de la capture. Chaque transition précède la première suspension de la
    /// méthode qui la déclenche.
    private enum Lifecycle: Equatable {
        case idle
        /// `start` en cours. Le jeton dit à un `start` réveillé s'il est encore d'actualité.
        case starting(UInt64)
        case running
        case stopping
    }

    /// Ce que le moteur garde d'une sortie.
    private struct OutputEntry {
        var request: OutputRequest
        /// Distingue cette sortie d'une précédente du même identifiant : une tâche retirée qui
        /// se termine en retard ne doit pas écrire dans l'état de sa remplaçante.
        let token: UInt64
        var task: Task<Void, Never>?
        var sender: (any OutputSender)?
    }

    private let log = AudioLog.capture
    private let dependencies: Dependencies
    private var tuning: Tuning { dependencies.tuning }

    private var lifecycle = Lifecycle.idle
    private var nextToken: UInt64 = 0
    /// Arrêt en cours, que `start` et un second `stop` attendent.
    private var stopTask: Task<Void, Never>?

    // État de la capture active.
    private var source: (any AudioCaptureSource)?
    private var fanout: CaptureFanout?
    private var adapter: CaptureBlockAdapter?
    private var clock: SharedPlaybackClock?
    private var healthTask: Task<Void, Never>?
    private var routeTask: Task<Void, Never>?

    private var entries: [String: OutputEntry] = [:]
    private var snapshots: [String: OutputSnapshot] = [:]

    // Mesure de la santé de la capture.
    private var health = CaptureHealth()
    private var lastHealthDate = Date()
    private var lastHealthFrames = 0
    private var lastFlowDate = Date()
    private var stallAccumulator: TimeInterval = 0
    private var lastExpectationCheck: Date?
    private var lastExpectation: Bool?

    public init(dependencies: Dependencies = .live) {
        self.dependencies = dependencies
    }

    // MARK: - État publié

    public var isRunning: Bool { lifecycle == .running }

    /// État courant de toutes les sorties, dans l'ordre où elles ont été demandées.
    public private(set) var outputOrder: [String] = []
    public var outputs: [OutputSnapshot] { outputOrder.compactMap { snapshots[$0] } }

    /// Santé de la capture, rafraîchie plusieurs fois par seconde.
    public var captureHealth: CaptureHealth { health }

    // MARK: - Démarrage

    /// Démarre une capture Process Tap et toutes les sorties demandées.
    public func start(
        mode: ProcessTapCapture.Mode,
        outputs requests: [OutputRequest],
        options: StartOptions = StartOptions()
    ) async throws {
        try await start(source: .processTap(mode), outputs: requests, options: options)
    }

    /// Démarre la capture et toutes les sorties demandées.
    ///
    /// Rend la main dès que la capture tourne : les sorties se connectent en arrière-plan et
    /// publient leur avancement dans `outputs`. Une sortie absente passe en
    /// `waitingForReceiver` et continue d'être cherchée, une sortie qui échoue sans recours
    /// passe en `failed` ; aucune n'affecte les autres.
    public func start(
        source sourceRequest: Source,
        outputs requests: [OutputRequest],
        options: StartOptions = StartOptions()
    ) async throws {
        // Un arrêt en cours libère la capture : démarrer sans l'attendre en ferait deux.
        if let stopTask { await stopTask.value }

        guard lifecycle == .idle else { throw Failure.alreadyRunning }
        guard !requests.isEmpty else { throw Failure.noOutputRequested }
        guard Set(requests.map(\.id)).count == requests.count else {
            throw Failure.duplicateOutput(requests.map(\.id).first { id in
                requests.filter { $0.id == id }.count > 1
            } ?? "")
        }
        guard requests.count <= tuning.maximumOutputs else {
            throw Failure.tooManyOutputs(limit: tuning.maximumOutputs)
        }

        // Posé avant toute suspension : c'est ce qui rend un second `start` impossible.
        let token = makeToken()
        lifecycle = .starting(token)

        let source = dependencies.makeSource(sourceRequest, options)

        // L'autorisation est propre à chaque bundle : l'app doit obtenir la sienne, celle du CLI
        // ne vaut pas pour elle. Sans ce contrôle, le tap démarrerait et ne livrerait qu'un
        // silence numérique, sans la moindre erreur (piège du jalon 1).
        if let kind = source.requiredPermission,
            dependencies.permissions.status(for: kind) != .authorized
        {
            let granted = await dependencies.permissions.request(for: kind)
            // L'attente peut durer aussi longtemps que le dialogue reste ouvert.
            guard lifecycle == .starting(token) else { throw Failure.stoppedDuringStart }
            guard granted else {
                lifecycle = .idle
                throw Failure.permissionDenied(CapturePermission.guidance(for: kind))
            }
        }

        do {
            let nativeFormat = try source.prepare()
            try openCapture(source, nativeFormat: nativeFormat)
            self.source = source
        } catch {
            source.stop()
            lifecycle = .idle
            throw error
        }

        lifecycle = .running
        health = CaptureHealth()
        health.diagnosis = .waitingForFirstBlock
        resetHealthReferences(frames: fanout?.framesCaptured ?? 0, now: Date())
        outputOrder = []
        snapshots = [:]
        entries = [:]

        source.setRouteChangeHandler { [weak self] in
            Task { await self?.noteRouteChange() }
        }
        healthTask = Task { [weak self, interval = tuning.healthInterval] in
            while !Task.isCancelled {
                await self?.tickHealth()
                do { try await Task.sleep(for: interval) } catch { return }
            }
        }

        for request in requests {
            // Le nombre de sorties a été vérifié plus haut : l'échec n'est pas attendu ici.
            do { try launch(request) } catch {
                log.error("Sortie \(request.id, privacy: .public) non lancée : \(error)")
            }
        }
        log.info("Moteur démarré : \(requests.count) sortie(s)")
    }

    /// Crée fanout, adaptateur et horloge pour un format de source, puis lance l'IO.
    ///
    /// Tout existe avant le premier bloc : le callback n'a aucune référence à attendre, ni aucun
    /// état mutable à relire. C'est le seul ordre sûr, et le format connu dès `prepare` le permet.
    private func openCapture(
        _ source: any AudioCaptureSource, nativeFormat: AVAudioFormat
    ) throws {
        let format = try CaptureBlockAdapter.normalizedFormat(for: nativeFormat)
        let fanout = CaptureFanout(
            format: format,
            slotCount: tuning.maximumOutputs,
            capacityFrames: max(48_000, Int(format.sampleRate))
        )
        let adapter = try CaptureBlockAdapter(sourceFormat: nativeFormat, fanout: fanout)
        try source.start(deliveringTo: adapter.makeConsumer())

        // Horloge de restitution commune à toutes les sorties : c'est elle qui leur donne un
        // référentiel unique, condition de l'alignement (CDC 4.5). Posée ici et non par le
        // premier sender venu : sa trame n° 0 doit être celle de la capture, sinon elle retarde
        // de toute la durée de la découverte Bonjour.
        let clock = SharedPlaybackClock(captureSampleRate: format.sampleRate)
        clock.startIfNeeded(framesAlreadyWritten: fanout.framesCaptured)

        self.fanout = fanout
        self.adapter = adapter
        self.clock = clock
    }

    // MARK: - Arrêt

    /// Arrête toutes les sorties puis la capture. Idempotent.
    ///
    /// Borné : un récepteur muet peut retenir un `TEARDOWN` ou une négociation, et il n'a pas à
    /// retenir aussi l'interface ni la capture. Une sortie en retard finit seule et libère ses
    /// ressources quand son délai réseau expire.
    public func stop() async {
        if let stopTask {
            await stopTask.value
            return
        }
        switch lifecycle {
        case .idle, .stopping:
            return
        case .starting:
            // `start` attend l'autorisation et n'a encore rien créé. Il verra à son réveil qu'il
            // n'est plus d'actualité.
            lifecycle = .idle
            return
        case .running:
            break
        }

        lifecycle = .stopping
        let task = Task { await self.performStop() }
        stopTask = task
        await task.value
        stopTask = nil
    }

    private func performStop() async {
        healthTask?.cancel()
        healthTask = nil
        routeTask?.cancel()
        routeTask = nil
        source?.setRouteChangeHandler(nil)

        let tasks = entries.values.compactMap(\.task)
        for task in tasks { task.cancel() }
        if await !Self.waitForCompletion(of: tasks, timeout: tuning.stopTimeout) {
            log.error("Sorties encore en cours de fermeture à l'arrêt : elles finiront seules")
        }

        source?.stop()
        source = nil
        fanout = nil
        adapter = nil
        clock = nil
        entries = [:]
        for id in outputOrder {
            snapshots[id]?.phase = .idle
            snapshots[id]?.nextAttemptAt = nil
        }
        health = CaptureHealth()
        lifecycle = .idle
        log.info("Moteur arrêté")
    }

    /// Attend la fin de tâches, sans dépasser un délai.
    ///
    /// Ni groupe de tâches ni `async let` : ils attendent tous leurs enfants à la sortie, et
    /// `await task.value` ne s'interrompt pas sur annulation. Le délai ne vaudrait rien.
    private static func waitForCompletion(
        of tasks: [Task<Void, Never>], timeout: Duration
    ) async -> Bool {
        guard !tasks.isEmpty else { return true }
        let once = OnceThrowingResumer<Bool>()
        let finished = try? await withCheckedThrowingContinuation { continuation in
            once.attach(continuation)
            Task {
                for task in tasks { await task.value }
                once.resume(returning: true)
            }
            Task {
                try? await Task.sleep(for: timeout)
                once.resume(returning: false)
            }
        }
        return finished ?? false
    }

    // MARK: - Sorties à chaud

    /// Ajoute une sortie à une diffusion en cours, sans perturber ni la capture ni les autres.
    ///
    /// Son ring buffer existe déjà : le callback temps réel commence à l'alimenter à son prochain
    /// bloc, et la situe sur la graduation de capture à cette trame-là. Elle partage l'horloge
    /// commune, donc s'aligne sur les sorties déjà en place, quelle que soit la durée de sa
    /// négociation.
    public func addOutput(_ request: OutputRequest) throws {
        guard lifecycle == .running else { throw Failure.notRunning }
        if let existing = snapshots[request.id] {
            // Une sortie en échec définitif n'a plus de tâche : la recocher est une nouvelle
            // tentative, pas un doublon.
            guard case .failed = existing.phase else {
                throw Failure.duplicateOutput(request.id)
            }
            entries[request.id] = nil
        }
        try launch(request)
    }

    /// Retire une sortie d'une diffusion en cours. Sans effet si elle n'existe pas.
    ///
    /// La capture continue même sans aucune sortie : c'est à l'appelant de décider de `stop()`,
    /// et une sortie cochée juste après ne repaie pas un démarrage de capture.
    public func removeOutput(id: String) async {
        guard let entry = entries.removeValue(forKey: id) else { return }
        snapshots[id] = nil
        outputOrder.removeAll { $0 == id }
        guard let task = entry.task else { return }
        task.cancel()
        // Le tampon ne revient au pool qu'à la vraie fin de la tâche : son consommateur doit
        // avoir disparu avant qu'un autre le reprenne (un seul consommateur par tampon).
        if await !Self.waitForCompletion(of: [task], timeout: tuning.stopTimeout) {
            log.error("Sortie \(id, privacy: .public) encore en cours de fermeture : elle finira seule")
        }
    }

    private func launch(_ request: OutputRequest) throws {
        guard let fanout, let clock else { throw Failure.notRunning }
        guard let slot = fanout.acquireSlot() else {
            throw Failure.tooManyOutputs(limit: fanout.slotCount)
        }
        let context = OutputSenderContext(
            ring: fanout.ring(atSlot: slot), captureFormat: fanout.format, clock: clock
        )
        let token = makeToken()
        let id = request.id
        entries[id] = OutputEntry(request: request, token: token)
        snapshots[id] = OutputSnapshot(id: id, phase: .connecting)
        if !outputOrder.contains(id) { outputOrder.append(id) }
        entries[id]?.task = Task { [weak self] in
            await self?.runOutput(id: id, token: token, context: context)
            // Dans la tâche et non dans `removeOutput` : quelle que soit la façon dont la sortie
            // se termine, le tampon n'est rendu qu'une fois son consommateur réellement parti.
            await self?.releaseSlot(slot, of: fanout)
        }
    }

    private func releaseSlot(_ slot: Int, of fanout: CaptureFanout) {
        fanout.releaseSlot(slot)
    }

    private func makeToken() -> UInt64 {
        nextToken &+= 1
        return nextToken
    }

    // MARK: - Boucle d'une sortie

    private enum MonitorOutcome {
        case cancelled
        case senderGaveUp
    }

    /// Fait vivre une sortie : découverte, connexion, surveillance, et nouvel essai si besoin.
    ///
    /// Un sender neuf par tentative : un sender en échec reste `failed`, et son `start` refuse
    /// de repartir de cet état.
    private func runOutput(id: String, token: UInt64, context: OutputSenderContext) async {
        var attempt = 0
        while !Task.isCancelled {
            guard let request = entries[id]?.request, entries[id]?.token == token else { return }

            var lastError: String
            var sender: (any OutputSender)?
            do {
                let created = try await dependencies.senderFactory.makeSender(
                    for: request, context: context
                )
                sender = created
                try Task.checkCancellation()
                await created.setManualDelay(seconds: request.manualDelaySeconds)
                try await Self.startSender(created, volume: request.volumeDB)
                // Un `start` qui aboutit malgré l'annulation laisse une session ouverte : le
                // `catch` ci-dessous la referme.
                try Task.checkCancellation()

                await attach(created, id: id, token: token, startedWith: request)
                attempt = 0
                let outcome = await monitor(created, id: id, token: token, ring: context.ring)
                detach(id: id, token: token)
                await created.stop()
                sender = nil
                if outcome == .cancelled { break }
                lastError = "session perdue"
            } catch {
                detach(id: id, token: token)
                // Toujours, y compris sur un `start` en échec : c'est ce qui garantit qu'une
                // sortie annulée en pleine négociation ne laisse ni socket ni tâche.
                if let sender { await sender.stop() }
                if Task.isCancelled || error is CancellationError { break }

                // Panne confinée : consignée sur cette sortie, sans toucher aux autres ni à la
                // capture (invariant section 12).
                log.error("Sortie \(id, privacy: .public) en échec : \(error)")
                if isPermanentOutputFailure(error) {
                    update(id, token: token) {
                        $0.phase = .failed("\(error)")
                        $0.nextAttemptAt = nil
                    }
                    return
                }
                lastError = "\(error)"
            }

            attempt += 1
            let delay = Self.retryDelay(attempt: attempt, tuning: tuning)
            let retryAt = Date().addingTimeInterval(Self.seconds(delay))
            update(id, token: token) {
                $0.phase = .waitingForReceiver(attempt: attempt, lastError: lastError)
                $0.nextAttemptAt = retryAt
            }
            do { try await Task.sleep(for: delay) } catch { break }
            update(id, token: token) { $0.nextAttemptAt = nil }
        }
        update(id, token: token) {
            $0.phase = .idle
            $0.nextAttemptAt = nil
        }
    }

    /// Démarre un sender en faisant suivre l'annulation.
    ///
    /// `start` enchaîne des requêtes réseau sans surveiller l'annulation, et `RTSPClient` attend
    /// jusqu'à 10 s par requête. `stop`, lui, ferme la connexion : la requête en cours échoue et
    /// la négociation s'interrompt d'elle-même.
    private static func startSender(_ sender: any OutputSender, volume: Float) async throws {
        try await withTaskCancellationHandler {
            try await sender.start(volume: volume)
        } onCancel: {
            Task { await sender.stop() }
        }
    }

    /// Délai avant la tentative suivante : repli exponentiel, plafonné.
    static func retryDelay(attempt: Int, tuning: Tuning) -> Duration {
        var delay = tuning.retryInitialDelay
        for _ in 1..<max(1, attempt) {
            delay *= 2
            if delay >= tuning.retryMaximumDelay { return tuning.retryMaximumDelay }
        }
        return min(delay, tuning.retryMaximumDelay)
    }

    private static func seconds(_ duration: Duration) -> TimeInterval {
        let (seconds, attoseconds) = duration.components
        return Double(seconds) + Double(attoseconds) / 1e18
    }

    /// Rend le sender joignable par `setVolume`/`setManualDelay`, et rattrape les réglages faits
    /// pendant la négociation.
    ///
    /// Sans ce rattrapage, un volume poussé avant la fin de la connexion était perdu : l'appelant
    /// le croyait transmis et ne le renvoyait jamais.
    private func attach(
        _ sender: any OutputSender, id: String, token: UInt64, startedWith request: OutputRequest
    ) async {
        guard entries[id]?.token == token else { return }
        entries[id]?.sender = sender
        update(id, token: token) {
            $0.phase = .streaming
            $0.nextAttemptAt = nil
        }
        guard let latest = entries[id]?.request else { return }
        if latest.manualDelaySeconds != request.manualDelaySeconds {
            await sender.setManualDelay(seconds: latest.manualDelaySeconds)
        }
        if latest.volumeDB != request.volumeDB {
            do { try await sender.setVolume(latest.volumeDB) } catch {
                log.error("Volume refusé par la sortie \(id, privacy: .public) : \(error)")
            }
        }
    }

    private func detach(id: String, token: UInt64) {
        guard entries[id]?.token == token else { return }
        entries[id]?.sender = nil
    }

    /// Recopie l'état du sender dans l'instantané publié, jusqu'à l'annulation de la tâche.
    private func monitor(
        _ sender: any OutputSender, id: String, token: UInt64, ring: AudioRingBuffer
    ) async -> MonitorOutcome {
        while !Task.isCancelled {
            let state = await sender.currentOutputState()
            let statistics = await sender.currentOutputStatistics()
            sender.synchronizer.noteRefusedCaptureFrames(total: ring.droppedFrames)
            let sync = sender.synchronizer.snapshot()
            let refused = ring.droppedFrames
            update(id, token: token) {
                $0.statistics = statistics
                $0.sync = sync
                $0.droppedWhileStreaming = max(0, refused - statistics.droppedBeforeStreaming)
                switch state {
                case .reconnecting: $0.phase = .reconnecting
                case .streaming: $0.phase = .streaming
                case .idle, .connecting, .failed: break
                }
            }
            // Les senders réels se rétablissent seuls et ne passent jamais par là ; un sender qui
            // abandonne n'a de toute façon plus rien à attendre.
            if state == .failed { return .senderGaveUp }
            do { try await Task.sleep(for: tuning.monitorInterval) } catch { return .cancelled }
        }
        return .cancelled
    }

    /// Pousse un volume à une sortie, sans interrompre le flux.
    ///
    /// Une sortie pas encore connectée le recevra en se connectant : ce réglage n'est jamais
    /// perdu. Les erreurs ne sont pas propagées — un récepteur qui refuse un changement de volume
    /// ne doit pas faire tomber la session.
    public func setVolume(_ volumeDB: Float, for id: String) async {
        guard entries[id] != nil else { return }
        entries[id]?.request.volumeDB = volumeDB
        guard let sender = entries[id]?.sender else { return }
        do {
            try await sender.setVolume(volumeDB)
        } catch {
            log.error("Volume refusé par la sortie \(id, privacy: .public) : \(error)")
        }
    }

    /// Pousse un décalage manuel à une sortie.
    ///
    /// Sans rupture de flux : le réglage agit sur l'ancrage annoncé dans les paquets de
    /// synchronisation, pas sur les échantillons (CDC 4.5). C'est ce qui permet d'aligner
    /// deux enceintes à l'oreille pendant qu'elles jouent, seule méthode praticable — aucune
    /// mesure réseau ne capture le tampon interne d'un récepteur.
    public func setManualDelay(_ seconds: TimeInterval, for id: String) async {
        guard entries[id] != nil else { return }
        entries[id]?.request.manualDelaySeconds = seconds
        guard let sender = entries[id]?.sender else { return }
        await sender.setManualDelay(seconds: seconds)
    }

    private func update(_ id: String, token: UInt64, _ change: (inout OutputSnapshot) -> Void) {
        guard entries[id]?.token == token, var snapshot = snapshots[id] else { return }
        change(&snapshot)
        snapshots[id] = snapshot
    }

    // MARK: - Changement de périphérique

    private func noteRouteChange() {
        guard lifecycle == .running else { return }
        routeTask?.cancel()
        routeTask = Task { [weak self, debounce = tuning.routeChangeDebounce] in
            do { try await Task.sleep(for: debounce) } catch { return }
            await self?.rebuildCaptureIfNeeded()
        }
    }

    /// Reconstruit la capture sans toucher aux senders.
    ///
    /// L'agrégat du tap tient son horloge du périphérique de sortie courant (piège n° 2 de
    /// `CLAUDE.md`) : débrancher un casque lui retire. Les senders n'ont pas à le savoir : pendant
    /// la reconstruction leur tampon reste vide, ils attendent, et le flux reprend.
    ///
    /// Un seul cas impose de les relancer : un changement de **fréquence**, car leur
    /// rééchantillonneur est construit pour la précédente. Les laisser en place ferait jouer tout
    /// le flux à la mauvaise hauteur, sans erreur.
    func rebuildCaptureIfNeeded() async {
        guard lifecycle == .running, let source, source.routeRequiresRebuild() else { return }
        log.info("Périphérique de sortie changé — reconstruction de la capture")

        let stoppedAt = Date()
        let compensatedBefore = health.interruptedSeconds
        source.stop()

        var delay = tuning.rebuildRetryInitialDelay
        while lifecycle == .running, !Task.isCancelled {
            do {
                let nativeFormat = try source.prepare()
                let format = try CaptureBlockAdapter.normalizedFormat(for: nativeFormat)
                if let fanout, format.sampleRate == fanout.format.sampleRate {
                    let adapter = try CaptureBlockAdapter(
                        sourceFormat: nativeFormat, fanout: fanout
                    )
                    try source.start(deliveringTo: adapter.makeConsumer())
                    self.adapter = adapter
                    // Le trou de capture ne doit pas entamer la marge de restitution.
                    let elapsed = Date().timeIntervalSince(stoppedAt)
                    let remaining = elapsed - (health.interruptedSeconds - compensatedBefore)
                    if remaining > 0 {
                        clock?.shiftOrigin(bySeconds: remaining)
                        health.interruptedSeconds += remaining
                    }
                } else {
                    try await restartOutputs(source, nativeFormat: nativeFormat)
                }
                resetHealthReferences(frames: fanout?.framesCaptured ?? 0, now: Date())
                health.rebuilds += 1
                health.lastRebuildError = nil
                log.info("Capture reconstruite")
                return
            } catch {
                source.stop()
                log.error("Reconstruction de la capture en échec : \(error)")
                health.lastRebuildError = "\(error)"
                do { try await Task.sleep(for: delay) } catch { return }
                delay = min(delay * 2, tuning.rebuildRetryMaximumDelay)
            }
        }
    }

    /// Relance capture et sorties pour une nouvelle fréquence d'échantillonnage.
    private func restartOutputs(
        _ source: any AudioCaptureSource, nativeFormat: AVAudioFormat
    ) async throws {
        log.info("Fréquence de capture changée : relance des sorties")
        let previous = outputOrder.compactMap { entries[$0] }
        for entry in previous { entry.task?.cancel() }
        _ = await Self.waitForCompletion(
            of: previous.compactMap(\.task), timeout: tuning.stopTimeout
        )
        guard lifecycle == .running else { return }

        try openCapture(source, nativeFormat: nativeFormat)
        entries = [:]
        for entry in previous {
            try launch(entry.request)
        }
    }

    // MARK: - Santé de la capture

    private func resetHealthReferences(frames: Int, now: Date) {
        lastHealthDate = now
        lastHealthFrames = frames
        lastFlowDate = now
        stallAccumulator = 0
    }

    /// Mesure la capture : interruption, silence strict, arrêt des blocs.
    ///
    /// Rien de tout cela n'est calculé dans le callback temps réel, qui se contente de tenir deux
    /// compteurs atomiques (`CaptureFanout`).
    func tickHealth(now: Date = Date()) {
        guard lifecycle == .running, let fanout, let clock, let source else { return }
        let frames = fanout.framesCaptured
        let rate = fanout.format.sampleRate

        // Interruption : la graduation prend du retard sur l'heure. L'écart est reporté sur
        // l'horloge commune (voir `shiftOrigin`), à partir de 200 ms cumulées. Un écart plus
        // petit peut venir d'un gros bloc d'IO à cheval sur deux relevés, et le relevé suivant
        // le rattrape : c'est pourquoi le cumul repart de zéro dès qu'un relevé est normal, ce
        // qui écarte aussi la dérive d'horloge, de plusieurs ordres de grandeur plus faible.
        let elapsed = now.timeIntervalSince(lastHealthDate)
        let advanced = Double(frames - lastHealthFrames) / rate
        let deficit = elapsed - advanced
        if deficit > 0.05 {
            stallAccumulator += deficit
            if stallAccumulator >= 0.2 {
                clock.shiftOrigin(bySeconds: stallAccumulator)
                health.interruptedSeconds += stallAccumulator
                stallAccumulator = 0
            }
        } else {
            stallAccumulator = 0
        }

        if frames != lastHealthFrames { lastFlowDate = now }
        lastHealthDate = now
        lastHealthFrames = frames

        health.framesCaptured = frames
        if let kind = source.requiredPermission {
            health.permission = dependencies.permissions.status(for: kind)
        }

        let idleSeconds = now.timeIntervalSince(lastFlowDate)
        health.stalledSince =
            frames > 0 && idleSeconds >= tuning.stallThresholdSeconds ? lastFlowDate : nil

        let silentSeconds = Double(fanout.framesSinceLastSignal) / rate
        let isSilent = frames > 0 && silentSeconds >= tuning.silenceThresholdSeconds
        health.silentSince = isSilent ? now.addingTimeInterval(-silentSeconds) : nil

        if frames == 0 {
            health.diagnosis = .waitingForFirstBlock
        } else if health.stalledSince != nil {
            health.diagnosis = .stalled
        } else if isSilent {
            switch silenceExpectation(source, now: now) {
            case true?: health.diagnosis = .silentWhilePlaying
            case false?: health.diagnosis = .silentNothingPlaying
            case nil: health.diagnosis = .silentUnknown
            }
        } else {
            health.diagnosis = .healthy
        }
    }

    /// Demande à la source si quelque chose devrait jouer, au plus une fois par seconde : la
    /// réponse passe par plusieurs lectures de propriétés Core Audio.
    private func silenceExpectation(_ source: any AudioCaptureSource, now: Date) -> Bool? {
        if let last = lastExpectationCheck, now.timeIntervalSince(last) < 1 {
            return lastExpectation
        }
        lastExpectationCheck = now
        lastExpectation = source.isAudioExpected()
        return lastExpectation
    }
}
