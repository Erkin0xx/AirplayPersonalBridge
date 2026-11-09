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
        /// Salves de mesure du calage acoustique, aux trames de capture `k · 96 000`
        /// (``ClickPattern``). Aucune capture ni autorisation, comme la sinusoïde.
        case clicks(levelDBFS: Double)
        /// Test d'écoute gauche/droite (``ChannelTestPattern``).
        case channelTest(levelDBFS: Double)
    }

    /// L'horloge commune vue de l'extérieur : ce qu'il faut pour dater une trame de capture.
    ///
    /// Les instants sont en **temps Unix**, l'horloge murale de `Date` : c'est elle que les senders
    /// traduisent en estampilles NTP (``NTPTime``, époque 1900) et sur laquelle les récepteurs se
    /// calent par le canal de timing. Le passage à l'horloge hôte (`mach_absolute_time`, celle
    /// d'`AVAudioTime`) se fait par ``HostClockMapping``.
    public struct PlaybackTimeline: Sendable, Equatable {
        public let captureSampleRate: Double
        /// Délai commun entre la production d'une trame et sa restitution.
        public let playoutDelaySeconds: Double
        /// Instant de restitution attendu de la trame de capture n° 0, le même pour toutes les
        /// sorties. La trame `F` est attendue `F / captureSampleRate` secondes plus tard, plus le
        /// délai manuel de chaque sortie.
        public let frameZeroPresentationUnixTime: TimeInterval
        /// Interruptions de capture reportées sur l'horloge depuis le démarrage : un report déplace
        /// ``frameZeroPresentationUnixTime`` d'autant.
        public let interruptedSeconds: TimeInterval

        public init(
            captureSampleRate: Double, playoutDelaySeconds: Double,
            frameZeroPresentationUnixTime: TimeInterval, interruptedSeconds: TimeInterval
        ) {
            self.captureSampleRate = captureSampleRate
            self.playoutDelaySeconds = playoutDelaySeconds
            self.frameZeroPresentationUnixTime = frameZeroPresentationUnixTime
            self.interruptedSeconds = interruptedSeconds
        }

        /// Instant de restitution attendu d'une trame de capture.
        public func presentationUnixTime(forCaptureFrame frame: Double) -> TimeInterval {
            frameZeroPresentationUnixTime + frame / captureSampleRate
        }
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

        /// Basses et aigus ne valent que pour la Geneva, seule sortie AirPlay 1 de l'installation
        /// (ADR-002, CDC section 2) : les HomePod gardent une stéréo pleine bande intacte, et ne
        /// reçoivent jamais ces réglages.
        public var supportsToneControl: Bool { self == .raop }
    }

    /// Ce qu'on demande au moteur pour une sortie donnée.
    public struct OutputRequest: Sendable, Identifiable {
        public let id: String
        public let proto: OutputProtocol
        /// Nom du récepteur.
        public let deviceName: String
        /// Comment ce nom désigne un appareil. Exact par défaut : l'application connaît le nom de
        /// ses sorties, seule la ligne de commande demande une partie du nom.
        public let nameMatching: ReceiverNameMatching
        public var volumeDB: Float
        /// Gain numérique et silence propres à cette sortie (``OutputGainStage``), les deux
        /// protocoles confondus. `unity` par défaut : l'étage est contourné.
        public var outputLevel: OutputLevel
        public var manualDelaySeconds: TimeInterval
        /// Renfort de basses, en dB (ADR-002). Ignoré hors RAOP : le CDC ne le prévoit que pour la
        /// Geneva, les HomePod gardant une pleine bande intacte.
        public var bassBoostDB: Float
        /// Coupe des aigus, en dB, de 0 à −9. Ignorée hors RAOP, comme les basses.
        public var trebleCutDB: Float
        /// Credentials d'appairage système, pour un récepteur qui refuse le transitoire. Sans
        /// objet en RAOP.
        public let credentials: HapCredentials?

        public init(
            id: String,
            proto: OutputProtocol,
            deviceName: String,
            nameMatching: ReceiverNameMatching = .exact,
            volumeDB: Float,
            outputLevel: OutputLevel = .unity,
            manualDelaySeconds: TimeInterval = 0,
            bassBoostDB: Float = 0,
            trebleCutDB: Float = 0,
            credentials: HapCredentials? = nil
        ) {
            self.id = id
            self.proto = proto
            self.deviceName = deviceName
            self.nameMatching = nameMatching
            self.volumeDB = volumeDB
            self.outputLevel = outputLevel
            self.manualDelaySeconds = manualDelaySeconds
            self.bassBoostDB = bassBoostDB
            self.trebleCutDB = trebleCutDB
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
        /// Ce que le sender dit de sa panne, rédigé pour l'affichage. Renseigné en `reconnecting`
        /// (ce qui retarde le rétablissement) et en `failed` ; `nil` quand tout va bien.
        public var lastError: String?

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
            /// Les blocs ont cessé d'arriver alors que quelque chose joue, ou sans qu'on puisse dire
            /// si quelque chose joue (périphérique perdu, reconstruction en échec).
            case stalled
            /// Silence strict alors qu'une application captée a un flux ouvert. En mode global, seule
            /// une application de l'utilisateur compte, ni démon ni outil en ligne de commande
            /// (``AudioProcessClassifying``). Soit elle garde un flux muet, et il n'y a rien
            /// d'anormal, soit **autorisation perdue ou tap mal câblé**, typiquement juste après un
            /// rebuild, qui révoque l'autorisation sans la moindre erreur (`CLAUDE.md`). C'est
            /// `permission` qui permet de pencher pour l'un ou l'autre.
            case silentWhilePlaying
            /// Silence strict, ou plus aucun bloc, et aucune application ne joue : rien d'anormal. Un
            /// démon ou un outil au flux ouvert et muet mène ici.
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
        /// Prochaine reconstruction prévue d'une capture bloquée. `nil` si aucune ne l'est : c'est
        /// ce qui permet de dire « nouvel essai en cours » sans mentir.
        public var nextStallRebuild: Date?
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
        /// Retard de la graduation à partir duquel un trou est reporté sur l'horloge commune, une
        /// fois confirmé au relevé suivant (voir ``trackInterruption(deficit:clock:)``).
        public var interruptionThresholdSeconds: TimeInterval = 0.2
        /// Capture bloquée pendant qu'une application joue : délai avant de la reconstruire, doublé
        /// à chaque essai resté sans effet, jusqu'au maximum.
        public var stallRebuildDelaySeconds: TimeInterval = 5
        public var stallRebuildMaximumDelaySeconds: TimeInterval = 60
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
        /// Le tour de pairing, passé à toutes les sorties du moteur : deux pair-setups AirPlay 2 ne
        /// partent jamais ensemble (voir ``PairingGate``). Un tour neuf par valeur créée.
        public var pairingGate: any PairingGate

        public init(
            makeSource: @escaping @Sendable (Source, StartOptions) -> any AudioCaptureSource,
            senderFactory: any OutputSenderFactory,
            permissions: any CapturePermissionProviding,
            tuning: Tuning = Tuning(),
            pairingGate: any PairingGate = SerialPairingGate()
        ) {
            self.makeSource = makeSource
            self.senderFactory = senderFactory
            self.permissions = permissions
            self.tuning = tuning
            self.pairingGate = pairingGate
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
                    case let .clicks(levelDBFS):
                        return PatternCaptureSource.clicks(levelDBFS: levelDBFS)
                    case let .channelTest(levelDBFS):
                        return PatternCaptureSource.channelTest(levelDBFS: levelDBFS)
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
    /// Regroupe les notifications d'un changement de périphérique. Une nouvelle l'annule.
    private var routeTask: Task<Void, Never>?
    /// Reconstruction en cours. Une notification ne l'annule pas : elle relit la route en
    /// terminant, et deux reconstructions simultanées lanceraient deux IO sur le même tampon.
    private var rebuildTask: Task<Void, Never>?
    /// Options de la session, pour une source qui en remplace une autre en cours de route.
    private var startOptions = StartOptions()
    /// Les sorties ont été arrêtées pour une nouvelle fréquence, et attendent d'être relancées.
    /// Tant que c'est vrai, une sortie cochée entre dans la liste sans démarrer : c'est la relance
    /// qui la lancera, sur le bon tampon. Vrai aussi après une relance ratée, tant qu'aucune
    /// reconstruction n'a abouti.
    private var outputsAwaitingRelaunch = false

    private var entries: [String: OutputEntry] = [:]
    private var snapshots: [String: OutputSnapshot] = [:]

    // Mesure de la santé de la capture.
    private var health = CaptureHealth()
    private var lastHealthDate = Date()
    private var lastHealthFrames = 0
    private var lastFlowDate = Date()
    /// Retard de la graduation pas encore reporté sur l'horloge : un doute, jusqu'à confirmation.
    private var pendingInterruption: TimeInterval = 0
    /// Le trou en cours est avéré : tant qu'il dure, chaque relevé le reporte sans attendre.
    private var interruptionConfirmed = false
    /// Délai avant la prochaine reconstruction d'une capture bloquée, s'il faut y revenir.
    private var stallRebuildDelay: TimeInterval = 0
    private var nextStallRebuild: Date?
    /// Depuis quand les blocs arrivent sans blocage : c'est ce flux établi qui remet le repli à zéro.
    private var flowSince: Date?
    /// Une reconstruction tournait au relevé précédent.
    private var rebuildRanAtLastTick = false
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

    /// L'horloge commune de la diffusion en cours, `nil` hors diffusion.
    ///
    /// Relue à chaque appel : un trou de capture la reporte (``SharedPlaybackClock/shiftOrigin(bySeconds:)``),
    /// et une relance pour une nouvelle fréquence en pose une nouvelle.
    public var playbackTimeline: PlaybackTimeline? {
        guard let clock, let frameZero = clock.presentationUnixTime(forCaptureFrame: 0) else {
            return nil
        }
        return PlaybackTimeline(
            captureSampleRate: clock.captureSampleRate,
            playoutDelaySeconds: clock.playoutDelaySeconds,
            frameZeroPresentationUnixTime: frameZero,
            interruptedSeconds: health.interruptedSeconds
        )
    }

    /// Une reconstruction ou un changement de source est-il en cours ? Interne : uniquement lu par
    /// les tests qui avancent l'heure à la main, et l'attendent à chaque pas.
    var isRebuildingCapture: Bool { rebuildTask != nil }

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
        startOptions = options
        outputsAwaitingRelaunch = false
        health = CaptureHealth()
        health.diagnosis = .waitingForFirstBlock
        resetHealthReferences(frames: fanout?.framesCaptured ?? 0, now: Date())
        resetStallRecovery()
        outputOrder = []
        snapshots = [:]
        entries = [:]

        watchRoute(of: source)
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

    private func watchRoute(of source: any AudioCaptureSource) {
        source.setRouteChangeHandler { [weak self] in
            Task { await self?.noteRouteChange() }
        }
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
    }

    private func performStop() async {
        healthTask?.cancel()
        healthTask = nil
        routeTask?.cancel()
        routeTask = nil
        source?.setRouteChangeHandler(nil)
        // Elle pilote la source : la laisser finir évite de l'arrêter sous ses pieds.
        if let rebuild = rebuildTask {
            rebuild.cancel()
            await rebuild.value
        }

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
        outputsAwaitingRelaunch = false
        for id in outputOrder {
            snapshots[id]?.phase = .idle
            snapshots[id]?.nextAttemptAt = nil
        }
        health = CaptureHealth()
        // Dans le même tour que l'état : un appel qui reprendrait entre les deux croirait un
        // arrêt encore en cours, et attendrait une tâche déjà finie au lieu d'agir.
        stopTask = nil
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
        guard !outputsAwaitingRelaunch else {
            // Lancée maintenant, elle s'alimenterait à un tampon sur le point de disparaître.
            guard entries.count < tuning.maximumOutputs else {
                throw Failure.tooManyOutputs(limit: tuning.maximumOutputs)
            }
            entries[request.id] = OutputEntry(request: request, token: makeToken())
            snapshots[request.id] = OutputSnapshot(id: request.id, phase: .connecting)
            if !outputOrder.contains(request.id) { outputOrder.append(request.id) }
            return
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
        // Le tour de pairing est commun à toutes les sorties, comme l'horloge : c'est ce qui empêche
        // deux pair-setups simultanés, vers les deux HomePod d'une paire stéréo par exemple.
        let context = OutputSenderContext(
            ring: fanout.ring(atSlot: slot), captureFormat: fanout.format, clock: clock,
            pairingGate: dependencies.pairingGate
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
        /// Le sender a renoncé. Sa raison, s'il en donne une, est un refus définitif : les vrais
        /// senders ne quittent leur boucle de reconnexion que sur ce type de refus.
        case senderGaveUp(reason: String?)
    }

    /// Fait vivre une sortie : découverte, connexion, surveillance, et nouvel essai si besoin.
    ///
    /// Un sender neuf par tentative : un sender en échec reste `failed`, et son `start` refuse
    /// de repartir de cet état.
    private func runOutput(id: String, token: UInt64, context: OutputSenderContext) async {
        var attempt = 0
        attempts: while !Task.isCancelled {
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
                if request.proto.supportsToneControl {
                    await created.setBassBoost(decibels: request.bassBoostDB)
                    await created.setTrebleCut(decibels: request.trebleCutDB)
                }
                await created.setOutputLevel(request.outputLevel)
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
                switch outcome {
                case .cancelled:
                    break attempts
                case let .senderGaveUp(reason?):
                    // Un sender neuf rencontrerait le même refus, et le dernier message resterait
                    // « session perdue » pendant que la vraie cause disparaît. La sortie s'arrête
                    // là : la décocher puis la recocher est une nouvelle tentative.
                    update(id, token: token) {
                        $0.phase = .failed(reason)
                        $0.lastError = reason
                        $0.nextAttemptAt = nil
                    }
                    return
                case .senderGaveUp(reason: nil):
                    lastError = "session perdue"
                }
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
                        $0.lastError = "\(error)"
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
                $0.lastError = lastError
                $0.nextAttemptAt = retryAt
            }
            do { try await Task.sleep(for: delay) } catch { break }
            update(id, token: token) { $0.nextAttemptAt = nil }
        }
        update(id, token: token) {
            $0.phase = .idle
            $0.lastError = nil
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

    /// Rend le sender joignable par `setVolume`/`setManualDelay`/`setBassBoost`/`setTrebleCut`, et
    /// rattrape les réglages faits pendant la négociation.
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
            $0.lastError = nil
            $0.nextAttemptAt = nil
        }
        guard let latest = entries[id]?.request else { return }
        if latest.proto.supportsToneControl {
            if latest.bassBoostDB != request.bassBoostDB {
                await sender.setBassBoost(decibels: latest.bassBoostDB)
            }
            if latest.trebleCutDB != request.trebleCutDB {
                await sender.setTrebleCut(decibels: latest.trebleCutDB)
            }
        }
        if latest.manualDelaySeconds != request.manualDelaySeconds {
            await sender.setManualDelay(seconds: latest.manualDelaySeconds)
        }
        // Le niveau propre (`setOutputLevel`), rattrapé comme le reste.
        if latest.outputLevel != request.outputLevel {
            await sender.setOutputLevel(latest.outputLevel)
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
            let message = await sender.currentOutputError()
            sender.synchronizer.noteRefusedCaptureFrames(total: ring.droppedFrames)
            let sync = sender.synchronizer.snapshot()
            let refused = ring.droppedFrames
            update(id, token: token) {
                $0.statistics = statistics
                $0.sync = sync
                $0.droppedWhileStreaming = max(0, refused - statistics.droppedBeforeStreaming)
                switch state {
                case .reconnecting:
                    $0.phase = .reconnecting
                    $0.lastError = message
                case .streaming:
                    $0.phase = .streaming
                    $0.lastError = nil
                case .idle, .connecting, .failed:
                    break
                }
            }
            // Un sender réel se rétablit seul d'une perte réseau, mais il renonce sur un refus
            // définitif (mot de passe, appairage). Sans la lecture de sa raison, le moteur le
            // remplaçait sans fin et n'affichait que « session perdue ».
            if state == .failed { return .senderGaveUp(reason: message) }
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

    /// Pousse un gain numérique et un silence à une sortie, sans rupture de flux ni de session.
    ///
    /// Les deux protocoles : c'est ce qui donne à chaque membre d'une paire stéréo son propre niveau,
    /// et ce qui en coupe un sans couper l'autre, leur volume AirPlay étant commun. Comme le volume,
    /// une valeur poussée pendant la négociation est appliquée à la connexion, et le sender suivant
    /// repart de la dernière consigne.
    public func setOutputLevel(_ level: OutputLevel, for id: String) async {
        guard entries[id] != nil else { return }
        entries[id]?.request.outputLevel = level
        guard let sender = entries[id]?.sender else { return }
        await sender.setOutputLevel(level)
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

    /// Pousse un renfort de basses à une sortie, sans rupture de flux.
    ///
    /// Sans effet hors RAOP : le renfort n'est prévu que pour la Geneva (ADR-002, CDC section 2), et
    /// les HomePod doivent recevoir le flux intact. Comme le volume, une valeur poussée pendant la
    /// négociation est appliquée à la connexion.
    public func setBassBoost(_ decibels: Float, for id: String) async {
        guard entries[id]?.request.proto.supportsToneControl == true else { return }
        entries[id]?.request.bassBoostDB = decibels
        guard let sender = entries[id]?.sender else { return }
        await sender.setBassBoost(decibels: decibels)
    }

    /// Pousse une coupe des aigus à une sortie, sans rupture de flux.
    ///
    /// Calqué sur ``setBassBoost(_:for:)`` : sans effet hors RAOP, et une valeur poussée pendant la
    /// négociation est appliquée à la connexion. C'est ce qui laisse les HomePod porter l'image stéréo
    /// et le détail pendant que la Geneva, décalée sur eux, donne le corps sans filtrage en peigne
    /// dans les aigus.
    public func setTrebleCut(_ decibels: Float, for id: String) async {
        guard entries[id]?.request.proto.supportsToneControl == true else { return }
        entries[id]?.request.trebleCutDB = decibels
        guard let sender = entries[id]?.sender else { return }
        await sender.setTrebleCut(decibels: decibels)
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
            await self?.beginRebuildIfNeeded()
        }
    }

    private func beginRebuildIfNeeded() {
        guard rebuildTask == nil else { return }
        rebuildTask = Task { [weak self] in
            await self?.rebuildCaptureIfNeeded()
            await self?.rebuildDidFinish()
        }
    }

    private func rebuildDidFinish() {
        rebuildTask = nil
    }

    /// Reconstruit la capture tant que la route le demande, sans toucher aux senders.
    ///
    /// L'agrégat du tap tient son horloge du périphérique de sortie courant (piège n° 2 de
    /// `CLAUDE.md`) : débrancher un casque lui retire. Les senders n'ont pas à le savoir : pendant
    /// la reconstruction leur tampon reste vide, ils attendent, et le flux reprend.
    ///
    /// Un seul cas impose de les relancer : un changement de **fréquence**, car leur
    /// rééchantillonneur est construit pour la précédente. Les laisser en place ferait jouer tout
    /// le flux à la mauvaise hauteur, sans erreur.
    func rebuildCaptureIfNeeded() async {
        while lifecycle == .running, !Task.isCancelled, let source, source.routeRequiresRebuild() {
            await rebuildCapture(source)
        }
    }

    private func rebuildCapture(_ source: any AudioCaptureSource) async {
        log.info("Reconstruction de la capture")
        let stoppedAt = captureWillStop()
        let compensatedBefore = health.interruptedSeconds
        source.stop()

        var delay = tuning.rebuildRetryInitialDelay
        while lifecycle == .running, !Task.isCancelled {
            do {
                try await reopenCapture(
                    source, stoppedAt: stoppedAt, compensatedBefore: compensatedBefore
                )
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

    /// Repart de la source, déjà arrêtée. Les sorties ne sont touchées que si la fréquence change.
    private func reopenCapture(
        _ source: any AudioCaptureSource, stoppedAt: Date, compensatedBefore: TimeInterval
    ) async throws {
        let nativeFormat = try source.prepare()
        let format = try CaptureBlockAdapter.normalizedFormat(for: nativeFormat)
        if let fanout, format.sampleRate == fanout.format.sampleRate {
            let adapter = try CaptureBlockAdapter(sourceFormat: nativeFormat, fanout: fanout)
            try source.start(deliveringTo: adapter.makeConsumer())
            self.adapter = adapter
            // Le trou de capture ne doit pas entamer la marge de restitution.
            let elapsed = Date().timeIntervalSince(stoppedAt)
            let remaining = elapsed - (health.interruptedSeconds - compensatedBefore)
            if remaining > 0 {
                clock?.shiftOrigin(bySeconds: remaining)
                health.interruptedSeconds += remaining
            }
            // Une relance a pu échouer sur une autre fréquence avant de revenir à celle-ci : les
            // sorties qu'elle a arrêtées resteraient sinon au repos jusqu'à la fin de la diffusion.
            if outputsAwaitingRelaunch { relaunchOutputs() }
        } else {
            try await restartOutputs(source, nativeFormat: nativeFormat)
        }
        resetHealthReferences(frames: fanout?.framesCaptured ?? 0, now: Date())
        health.rebuilds += 1
        health.lastRebuildError = nil
    }

    /// Relance capture et sorties pour une nouvelle fréquence d'échantillonnage.
    ///
    /// L'attente qui suit peut durer jusqu'à `stopTimeout`, et rien n'interdit de décocher une
    /// sortie, d'en cocher une autre ou de bouger un volume pendant ce temps. C'est donc `entries`
    /// **relu après l'attente** qui fait foi, jamais une photographie d'avant.
    private func restartOutputs(
        _ source: any AudioCaptureSource, nativeFormat: AVAudioFormat
    ) async throws {
        log.info("Fréquence de capture changée : relance des sorties")
        outputsAwaitingRelaunch = true
        let running = outputOrder.compactMap { entries[$0]?.task }
        for task in running { task.cancel() }
        _ = await Self.waitForCompletion(of: running, timeout: tuning.stopTimeout)
        guard lifecycle == .running else { return }

        try openCapture(source, nativeFormat: nativeFormat)
        relaunchOutputs()
    }

    /// Relance les sorties qui attendent, dans leur état du moment.
    private func relaunchOutputs() {
        outputsAwaitingRelaunch = false
        for id in outputOrder {
            guard let request = entries[id]?.request else { continue }
            do { try launch(request) } catch {
                // Plus de tampon libre, ceux des sorties en retard n'étant pas encore rendus. Cette
                // sortie seule en pâtit, et la décocher puis la recocher est une nouvelle tentative.
                log.error("Sortie \(id, privacy: .public) non relancée : \(error)")
                snapshots[id]?.phase = .failed("\(error)")
                snapshots[id]?.lastError = "\(error)"
            }
        }
    }

    // MARK: - Changement de source

    /// Remplace ce qui est capté, sans toucher aux sessions des sorties.
    ///
    /// Le moteur sait déjà arrêter une source et en redémarrer l'IO sur le même tampon : c'est ce que
    /// fait une reconstruction. Ici la source qui repart est une autre, et les sorties n'ont pas à le
    /// savoir (invariant section 12). L'ancienne est arrêtée avant que la nouvelle ne démarre : une
    /// seule capture à la fois.
    ///
    /// Rend la main rapidement, sans attendre une capture qui refuserait de repartir : l'appelant est
    /// la file des transitions de l'interface, et un arrêt demandé doit pouvoir y passer.
    ///
    /// Une reconstruction **en échec** cède la place : elle ne finira peut-être jamais, sa source
    /// désignant peut-être des processus disparus, et l'application jouerait devant des enceintes
    /// muettes. Elle reprend si la nouvelle source échoue à son tour.
    ///
    /// - Returns: faux s'il n'a pas eu lieu, à réessayer plus tard : reconstruction en cours qui
    ///   n'a pas encore échoué, nouvelle source qui ne démarre pas, ou qui exigerait une autre
    ///   autorisation. L'ancienne continue alors, reconstruite au besoin en arrière-plan.
    public func replaceCapture(with request: Source) async -> Bool {
        guard lifecycle == .running else { return false }
        if let rebuildTask, health.lastRebuildError != nil {
            rebuildTask.cancel()
            await rebuildTask.value
        }
        // Elle pilote la source : le changement la laisse finir, plutôt que de l'attendre.
        guard lifecycle == .running, rebuildTask == nil else { return false }

        let task = Task { [weak self] in await self?.swapCapture(for: request) ?? .kept }
        rebuildTask = Task { _ = await task.value }
        let outcome = await task.value
        rebuildTask = nil

        switch outcome {
        case .replaced:
            // Une notification de route arrivée entre-temps n'a pas pu lancer sa reconstruction.
            beginRebuildIfNeeded()
            return true
        case .previousStopped:
            if lifecycle == .running { beginCurrentCaptureRebuild() }
            return false
        case .kept:
            return false
        }
    }

    private enum SwapOutcome {
        case replaced
        /// L'ancienne source a été arrêtée pour rien : elle reste à relancer.
        case previousStopped
        case kept
    }

    private func swapCapture(for request: Source) async -> SwapOutcome {
        guard lifecycle == .running, let current = source else { return .kept }
        let replacement = dependencies.makeSource(request, startOptions)
        guard replacement.requiredPermission == current.requiredPermission else { return .kept }

        log.info("Changement de source, sorties conservées")
        let stoppedAt = captureWillStop()
        let compensatedBefore = health.interruptedSeconds
        current.setRouteChangeHandler(nil)
        current.stop()
        do {
            try await reopenCapture(
                replacement, stoppedAt: stoppedAt, compensatedBefore: compensatedBefore
            )
            source = replacement
            watchRoute(of: replacement)
            lastExpectationCheck = nil
            return .replaced
        } catch {
            replacement.stop()
            log.error("Changement de source en échec : \(error)")
            watchRoute(of: current)
            return .previousStopped
        }
    }

    // MARK: - Capture bloquée

    /// Reconstruit une capture dont les blocs ont cessé d'arriver alors qu'une application joue.
    ///
    /// Sans notification de route, rien d'autre ne le fait, et l'application dirait diffuser vers des
    /// enceintes muettes indéfiniment. Seule une capture qui ne livre déjà plus rien est touchée : le
    /// tap ne livrant rien tant que rien ne joue, ce cas-là reste une attente normale.
    ///
    /// Si reconstruire n'y change rien, le délai double à chaque essai : au pire une tentative par
    /// minute, sans effet sur les sessions des sorties, qui attendent leur tampon.
    private func recoverStalledCapture(
        _ source: any AudioCaptureSource, framesMoved: Bool, now: Date
    ) {
        let rebuildJustEnded = rebuildRanAtLastTick && rebuildTask == nil
        rebuildRanAtLastTick = rebuildTask != nil
        noteFlow(framesMoved: framesMoved, now: now)
        guard health.diagnosis == .stalled, silenceExpectation(source, now: now) == true else {
            nextStallRebuild = nil
            health.nextStallRebuild = nil
            return
        }
        let due = nextStallRebuild ?? firstStallDeadline(now: now)
        if now >= due, rebuildJustEnded {
            // Une reconstruction plus longue que le délai : la capture qui vient de repartir a droit
            // à son attente, au lieu d'être détruite avant son premier bloc.
            nextStallRebuild = now.addingTimeInterval(stallRebuildDelay)
        } else if now >= due, rebuildTask == nil {
            log.error("Capture bloquée alors qu'une application joue : reconstruction")
            stallRebuildDelay = min(stallRebuildDelay * 2, tuning.stallRebuildMaximumDelaySeconds)
            nextStallRebuild = now.addingTimeInterval(stallRebuildDelay)
            beginCurrentCaptureRebuild()
        } else {
            nextStallRebuild = due
        }
        health.nextStallRebuild = nextStallRebuild
    }

    /// L'échéance d'un blocage tout juste constaté.
    ///
    /// Elle part du dernier bloc, sauf si ce bloc est trop ancien : après une pause, l'application qui
    /// reprend n'a pas encore livré le sien, et reconstruire tout de suite détruirait le tap au moment
    /// où le son démarre.
    private func firstStallDeadline(now: Date) -> Date {
        let afterLastBlock = lastFlowDate.addingTimeInterval(stallRebuildDelay)
        return afterLastBlock >= now ? afterLastBlock : now.addingTimeInterval(stallRebuildDelay)
    }

    /// Des blocs arrivent : plus rien n'est prévu. Le repli, lui, ne repart de zéro qu'une fois le flux
    /// établi. Un périphérique qui livre un bloc à chaque démarrage, puis plus rien, ferait sinon
    /// reconstruire toutes les 5 s sans jamais espacer.
    private func noteFlow(framesMoved: Bool, now: Date) {
        if framesMoved {
            nextStallRebuild = nil
            health.nextStallRebuild = nil
            let since = flowSince ?? now
            flowSince = since
            if now.timeIntervalSince(since) >= tuning.stallRebuildDelaySeconds {
                stallRebuildDelay = tuning.stallRebuildDelaySeconds
            }
        } else if health.stalledSince != nil {
            flowSince = nil
        }
    }

    private func resetStallRecovery() {
        stallRebuildDelay = tuning.stallRebuildDelaySeconds
        nextStallRebuild = nil
        health.nextStallRebuild = nil
        flowSince = nil
        rebuildRanAtLastTick = false
    }

    /// Reconstruit la capture en cours, même sans changement de route.
    private func beginCurrentCaptureRebuild() {
        rebuildTask = Task { [weak self] in
            await self?.rebuildCurrentCapture()
            await self?.rebuildDidFinish()
        }
    }

    private func rebuildCurrentCapture() async {
        guard let source else { return }
        // Reconstruire ne fait pas revenir les blocs par magie : la capture reste dite bloquée
        // depuis le même instant, tant qu'aucun n'est arrivé.
        let lastFlow = lastFlowDate
        await rebuildCapture(source)
        lastFlowDate = lastFlow
        await rebuildCaptureIfNeeded()
    }

    // MARK: - Santé de la capture

    private func resetHealthReferences(frames: Int, now: Date) {
        lastHealthDate = now
        lastHealthFrames = frames
        lastFlowDate = now
        pendingInterruption = 0
        interruptionConfirmed = false
    }

    /// La capture va s'arrêter pour de bon : ce qui n'était qu'un doute sur un trou n'en est plus
    /// un. Sans cela chaque reconstruction le perdrait, et le retard s'accumulerait d'une capture
    /// bloquée à l'autre jusqu'à manger la marge de restitution.
    private func captureWillStop() -> Date {
        if let clock, pendingInterruption >= tuning.interruptionThresholdSeconds {
            reportInterruption(pendingInterruption, clock: clock)
        }
        pendingInterruption = 0
        return Date()
    }

    private func reportInterruption(_ seconds: TimeInterval, clock: SharedPlaybackClock) {
        clock.shiftOrigin(bySeconds: seconds)
        health.interruptedSeconds += seconds
        log.info("Interruption de capture : \(seconds) s reportées sur l'horloge commune")
    }

    /// Décide si un retard de la graduation sur l'heure est un vrai trou de capture.
    ///
    /// Un vrai trou se reporte sur l'horloge commune (voir `shiftOrigin`) : le tap ne livre rien
    /// tant que rien ne joue, et les instants annoncés prendraient autant de retard sur le réel.
    /// Mais ce report est **définitif**, et la réaction des récepteurs à un instant qui saute reste
    /// inconnue. Il n'a donc pas lieu sur un simple doute :
    ///
    /// - un écart en deçà de `captureJitterTolerance` remet tout à zéro. Un gros bloc d'IO à cheval
    ///   sur deux relevés en produit, et la dérive d'horloge, de plusieurs ordres de grandeur plus
    ///   faible, se trouve écartée du même coup ;
    /// - un retard qui passe le seuil **attend le relevé suivant**. Une rafale tardive le rattrape
    ///   aussitôt, et rien n'a eu lieu ; sinon, qu'il s'aggrave ou que les blocs aient repris sans
    ///   le rattraper, le trou est avéré ;
    /// - tant qu'un trou avéré dure, chaque relevé le reporte sans autre attente.
    private func trackInterruption(deficit: TimeInterval, clock: SharedPlaybackClock) {
        let tolerance = Self.captureJitterTolerance
        if interruptionConfirmed {
            if deficit > tolerance {
                reportInterruption(deficit, clock: clock)
            } else {
                interruptionConfirmed = false
            }
            return
        }
        if pendingInterruption >= tuning.interruptionThresholdSeconds {
            let remaining = pendingInterruption + deficit
            pendingInterruption = 0
            if remaining >= tuning.interruptionThresholdSeconds {
                reportInterruption(remaining, clock: clock)
                interruptionConfirmed = deficit > tolerance
            }
        } else if deficit > tolerance {
            pendingInterruption += deficit
        } else {
            pendingInterruption = 0
        }
    }

    /// Écart entre l'heure et la graduation qu'un relevé tolère sans le compter.
    private static let captureJitterTolerance: TimeInterval = 0.05

    /// Mesure la capture : interruption, silence strict, arrêt des blocs.
    ///
    /// Rien de tout cela n'est calculé dans le callback temps réel, qui se contente de tenir deux
    /// compteurs atomiques (`CaptureFanout`).
    func tickHealth(now: Date = Date()) {
        guard lifecycle == .running, let fanout, let clock, let source else { return }
        let frames = fanout.framesCaptured
        let rate = fanout.format.sampleRate

        // Interruption : la graduation prend du retard sur l'heure.
        let elapsed = now.timeIntervalSince(lastHealthDate)
        let advanced = Double(frames - lastHealthFrames) / rate
        trackInterruption(deficit: elapsed - advanced, clock: clock)

        let framesMoved = frames != lastHealthFrames
        if framesMoved { lastFlowDate = now }
        lastHealthDate = now
        lastHealthFrames = frames

        health.framesCaptured = frames

        let idleSeconds = now.timeIntervalSince(lastFlowDate)
        health.stalledSince =
            frames > 0 && idleSeconds >= tuning.stallThresholdSeconds ? lastFlowDate : nil

        let silentSeconds = Double(fanout.framesSinceLastSignal) / rate
        let isSilent = frames > 0 && silentSeconds >= tuning.silenceThresholdSeconds
        health.silentSince = isSilent ? now.addingTimeInterval(-silentSeconds) : nil

        // L'état de l'autorisation passe par un appel à `tccd` : relu au démarrage, puis seulement
        // quand un silence le rend utile.
        if let kind = source.requiredPermission, health.permission == nil || isSilent {
            health.permission = dependencies.permissions.status(for: kind)
        }

        if frames == 0 {
            health.diagnosis = .waitingForFirstBlock
        } else if health.stalledSince != nil {
            // Le tap ne livre plus rien quand plus rien ne joue : ce n'est pas une panne, sauf si une
            // reconstruction échoue, ce que l'interface doit dire.
            let nothingPlaying =
                silenceExpectation(source, now: now) == false && health.lastRebuildError == nil
            health.diagnosis = nothingPlaying ? .silentNothingPlaying : .stalled
        } else if isSilent {
            switch silenceExpectation(source, now: now) {
            case true?: health.diagnosis = .silentWhilePlaying
            case false?: health.diagnosis = .silentNothingPlaying
            case nil: health.diagnosis = .silentUnknown
            }
        } else {
            health.diagnosis = .healthy
        }

        recoverStalledCapture(source, framesMoved: framesMoved, now: now)
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
