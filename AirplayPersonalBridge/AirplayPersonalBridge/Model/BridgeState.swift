//
//  BridgeState.swift
//  AirplayPersonalBridge
//

import AudioCore
import Foundation
import OSLog

private let stateLog = Logger(subsystem: AudioLog.subsystem, category: "state")

/// Protocole d'une sortie. L'interface s'en sert pour le rendu, jamais pour du routage :
/// c'est le cœur qui sait quel sender employer.
enum OutputProtocol: String, Sendable {
    case raop = "AirPlay 1"
    case airplay2 = "AirPlay 2"

    /// Lu dans l'identifiant d'une sortie restaurée, avant que la découverte l'ait revue.
    init?(outputID: String) {
        if outputID.hasPrefix("raop/") {
            self = .raop
        } else if outputID.hasPrefix("airplay2/") {
            self = .airplay2
        } else {
            return nil
        }
    }
}

/// État de connexion d'une sortie, tel que l'interface le montre. Reflet de `BridgeEngine.Phase` :
/// aucun état n'est inventé ici, et les messages sont ceux du moteur, faits pour être affichés.
enum OutputConnectionState: Sendable, Equatable {
    case idle
    case connecting
    /// Récepteur introuvable ou injoignable : le moteur réessaie en tâche de fond.
    case waiting(attempt: Int, message: String, nextAttemptAt: Date?)
    case streaming
    /// Session perdue, repli exponentiel en cours (CDC section 8).
    case reconnecting(message: String?)
    case failed(String)

    init(phase: BridgeEngine.Phase, lastError: String?, nextAttemptAt: Date?) {
        switch phase {
        case .idle: self = .idle
        case .connecting: self = .connecting
        case let .waitingForReceiver(attempt, message):
            self = .waiting(attempt: attempt, message: message, nextAttemptAt: nextAttemptAt)
        case .streaming: self = .streaming
        case .reconnecting: self = .reconnecting(message: lastError)
        case let .failed(message): self = .failed(message)
        }
    }

    var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }
}

/// Le ton d'une ligne de message : c'est ce qui dit si elle demande un geste.
enum OutputStatusTone: Sendable, Equatable {
    case muted
    case warning
    case critical
}

/// Une sortie découverte et ses réglages.
///
/// Les réglages vivent ici et non dans le cœur : un sender ne connaît que la valeur qu'on
/// lui pousse (`setVolume`, `setManualDelay`, `setBassBoost`), jamais l'intention de l'utilisateur.
///
/// **L'identité d'un objet compte** : la liste est réconciliée en place à chaque recherche, et une
/// sortie conservée garde son objet. Une vue qui la tient n'a pas à savoir qu'une recherche a eu
/// lieu.
@Observable
final class OutputState: Identifiable {
    let id: String
    let displayName: String
    let proto: OutputProtocol

    /// Adresse vue à la dernière découverte. Vide tant qu'une sortie restaurée n'a pas été revue.
    fileprivate(set) var host: String
    fileprivate(set) var port: UInt16

    /// Sortie retenue pour la diffusion. La cocher ou la décocher pendant une diffusion ne doit
    /// jamais perturber les autres — c'est l'invariant §12, et il vaut aussi pour une action
    /// volontaire.
    var isEnabled = true {
        didSet { if oldValue != isEnabled { onSettingsChange?() } }
    }

    /// Correction par sortie, en dB, appliquée en plus du master (décision du jalon 5).
    var trimDB: Double = 0 {
        didSet { if oldValue != trimDB { onSettingsChange?() } }
    }

    /// Décalage manuel de restitution, en millisecondes. Agit sur l'ancrage annoncé, pas
    /// sur les échantillons : instantané, sans rupture de flux (jalon 4). S'ajoute à la
    /// compensation du lieu d'écoute (`BridgeState.effectiveDelayMS`).
    var delayMS: Double = 0 {
        didSet { if oldValue != delayMS { onSettingsChange?() } }
    }

    /// Renfort de basse, en dB (ADR-002 : low shelf ~80 Hz, Q 0,7).
    var bassBoostDB: Double = 0 {
        didSet { if oldValue != bassBoostDB { onSettingsChange?() } }
    }

    var connection: OutputConnectionState = .idle
    fileprivate(set) var presence: OutputPresence
    /// Pourquoi elle ne jouera pas sans intervention, d'après ce qu'elle annonce.
    fileprivate(set) var unavailability: OutputUnavailability?

    /// Compteurs du sender, reflet fidèle. Une grandeur qu'un protocole ne mesure pas reste `nil`.
    var statistics = OutputStatistics()
    /// Alignement et dérive. `nil` tant que le sender n'est pas connecté.
    var sync: SyncSnapshot?
    /// Trames refusées depuis le début de la diffusion, reconnexions comprises.
    var droppedWhileStreaming = 0

    /// Le renfort de basse ne concerne que la Geneva (CDC section 2) : les HomePod gardent une
    /// stéréo pleine bande intacte. On le rattache au protocole plutôt qu'au nom de
    /// l'appareil — la Geneva est l'unique sortie AirPlay 1 de cette installation, et se
    /// fier au nom casserait dès le premier renommage.
    var supportsBassBoost: Bool { proto == .raop }

    /// Recherches consécutives qui ne l'ont pas vue.
    @ObservationIgnored fileprivate var missedRounds = 0
    /// Vue au moins une fois avec le bit 48 : voir `OutputCatalog.reconcile`.
    @ObservationIgnored fileprivate var confirmsTransientPairing = false
    @ObservationIgnored fileprivate var onSettingsChange: (() -> Void)?

    init(
        id: String, displayName: String, host: String, port: UInt16, proto: OutputProtocol,
        presence: OutputPresence = .online, unavailability: OutputUnavailability? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.host = host
        self.port = port
        self.proto = proto
        self.presence = presence
        self.unavailability = unavailability
    }

    /// Le nom sous lequel le moteur doit chercher ce récepteur : l'instance Bonjour complète, tirée
    /// de l'identifiant.
    ///
    /// Pas `displayName` : deux HomePod baptisés « Salon » sont `<MAC>@Salon` tous les deux en
    /// `_raop._tcp`, et seul le préfixe matériel les distingue.
    var serviceInstanceName: String {
        id.split(separator: "/", maxSplits: 1).last.map(String.init) ?? id
    }

    /// La ligne de message sous le nom, ou `nil` s'il n'y a rien à dire.
    ///
    /// L'état du moteur prime : ce qu'il dit d'une sortie qu'il fait vivre est plus précis que ce
    /// qu'annonce le réseau. Une sortie qui diffuse n'a rien à signaler, même marquée « appairage
    /// requis » — c'est que le signalement était trop prudent.
    var statusLine: (text: String, tone: OutputStatusTone)? {
        switch connection {
        case let .failed(message):
            return (message, .critical)
        case let .waiting(_, message, _):
            return (message, .warning)
        case let .reconnecting(message):
            return (message.map { "Reconnexion… \($0)" } ?? "Reconnexion…", .warning)
        case .connecting:
            return ("Connexion…", .muted)
        case .streaming:
            return nil
        case .idle:
            break
        }
        switch presence {
        case .offline: return ("Hors ligne", .warning)
        case .unknown: return ("Recherche sur le réseau…", .muted)
        case .online: break
        }
        return unavailability.map { ($0.rawValue, .warning) }
    }
}

/// L'état complet de l'interface, partagé entre la fenêtre et le panneau de la barre de menus.
///
/// Découverte et diffusion sont réelles : `BridgeEngine` détient la capture et les senders,
/// cette classe lui passe des intentions et recopie l'état qu'il publie. Elle n'invente aucun
/// état et ne manipule jamais un ring buffer ni un sender directement.
@Observable
final class BridgeState {
    /// Où en est la capture, du point de vue de l'interface.
    enum StreamingPhase: Equatable {
        case idle
        case starting
        case running
        case stopping
    }

    /// Ce qu'une sortie a reçu en dernier, pour ne pousser que sur changement.
    private struct PushedSettings {
        var volume: Float
        var delay: TimeInterval
        var bass: Float
    }

    static let silenceDB: Double = -60

    /// Niveau de départ du master. −24 dB d'interface valent −12 dB sur le fil
    /// (`receiverVolume(forGainDB:)`), le niveau validé à l'oreille sur le matériel.
    static let defaultMasterVolumeDB: Double = -24

    @ObservationIgnored private let environment: BridgeEnvironment
    @ObservationIgnored private let engine: BridgeEngine

    // MARK: - Source

    private(set) var sources: [CaptureSource] = [.systemWide, .inputDevice]
    private(set) var selectedSource: CaptureSource = .systemWide
    /// Le dernier choix de l'utilisateur. Une application ne figure dans la liste que quand elle
    /// joue : ce choix attend son retour, et ne se confond pas avec le repli sur le mode global.
    @ObservationIgnored private var preferredSourceID = CaptureSource.systemWide.id

    /// Coupe le son du Mac pendant la capture (Process Tap seulement). Option de démarrage du
    /// moteur : la changer pendant une diffusion demande donc de la relancer.
    var muteLocalOutput = false {
        didSet {
            guard oldValue != muteLocalOutput else { return }
            scheduleSettingsSave()
            if selectedSource.tapMode != nil { restartIfLive() }
        }
    }

    // MARK: - Sorties

    private(set) var outputs: [OutputState] = []
    private(set) var isBrowsing = false
    private(set) var discoveryNotice: String?
    /// Une recherche au moins a abouti depuis le lancement.
    private(set) var hasCompletedDiscovery = false

    // MARK: - Volume

    /// Master logiciel, en dB (décision du jalon 5 : gain appliqué au signal, plus un trim
    /// par sortie). `-60` fait office de silence.
    var masterVolumeDB: Double = BridgeState.defaultMasterVolumeDB {
        didSet { if oldValue != masterVolumeDB { scheduleSettingsSave() } }
    }

    var isMuted = false {
        didSet { if oldValue != isMuted { scheduleSettingsSave() } }
    }

    /// Gain effectif d'une sortie, master et trim confondus. C'est cette valeur, et elle
    /// seule, que le moteur appliquera — la vue n'en calcule aucune autre.
    ///
    /// Un master au minimum vaut silence, quel que soit le trim : un trim positif le ferait repartir
    /// au-dessus du seuil, et −29 dB sur le fil pour un bouton tourné à fond vers la gauche.
    func effectiveGainDB(for output: OutputState) -> Double {
        guard !isMuted, masterVolumeDB > Self.silenceDB else { return Self.silenceDB }
        return min(max(masterVolumeDB + output.trimDB, Self.silenceDB), 0)
    }

    // MARK: - Diffusion

    private(set) var streamingPhase = StreamingPhase.idle
    /// Vrai quand la capture tourne : ni pendant son démarrage, ni pendant son arrêt.
    var isStreaming: Bool { streamingPhase == .running }
    /// Un échec de démarrage, jusqu'au démarrage suivant.
    private(set) var startFailure: StartFailure?
    /// Santé de la capture, reflet du moteur. Rafraîchie à chaque tour : à ne pas lire depuis une
    /// vue qui n'en a pas besoin, le panneau s'en tient à `captureAlert`.
    private(set) var captureHealth = BridgeEngine.CaptureHealth()
    /// Ce que cette santé demande de dire. Ne change que lorsque le message change.
    private(set) var captureAlert: CaptureAlert?
    /// Un changement de source ou d'option relance la diffusion.
    private(set) var isRestarting = false

    /// Les sorties dont le plan trace le trait vers le lieu d'écoute : celles qui sont cochées. Le
    /// plan montre ainsi ce qui va réellement jouer, et non tout ce qui est visible sur le réseau.
    var outputIDsDrawnOnPlan: [String] { outputs.filter(\.isEnabled).map(\.id) }

    /// Le bouton Diffuser/Arrêter répond-il ? Pas en pleine transition : il n'y a rien à annuler
    /// de plus, et un second clic ne doit rien démarrer en double.
    var canToggleStreaming: Bool {
        switch streamingPhase {
        case .idle: outputs.contains(where: \.isEnabled)
        case .running: !isRestarting
        case .starting, .stopping: false
        }
    }

    /// L'état en mots, et l'icône de la barre de menus.
    var status: BridgeStatusSummary {
        BridgeStatusSummary.make(
            phase: streamingPhase,
            isRestarting: isRestarting,
            selection: outputs.map { ($0.isEnabled, $0.connection) },
            sourceLabel: selectedSource.label,
            alert: captureAlert,
            startFailure: startFailure
        )
    }

    /// Une session live : la capture tourne ou va tourner.
    private var isLive: Bool { streamingPhase == .running || streamingPhase == .starting }

    @ObservationIgnored private var pollTask: Task<Void, Never>?
    /// Toutes les transitions de la capture passent par cette file : démarrer, arrêter et relancer
    /// s'exécutent l'un après l'autre, quelle que soit la cadence des clics.
    @ObservationIgnored private var lifecycleTail: Task<Void, Never>?
    /// Numéro de la session courante : ce qu'une tâche en retard constate pour se taire.
    @ObservationIgnored private var sessionGeneration = 0
    @ObservationIgnored private var streamingSince: ContinuousClock.Instant?
    @ObservationIgnored private var lastToggle: ContinuousClock.Instant?
    /// Sorties confiées au moteur. C'est de l'écart avec ce qui est coché que naissent
    /// `addOutput` et `removeOutput`.
    @ObservationIgnored private var activeOutputIDs: Set<String> = []
    @ObservationIgnored private var pushed: [String: PushedSettings] = [:]
    /// Une tâche à la fois par sortie : un retrait attend le `TEARDOWN` avant qu'un nouvel ajout
    /// parte, et un récepteur lent ne retarde jamais les réglages des autres.
    @ObservationIgnored private var outputWork: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var emptySelectionTask: Task<Void, Never>?

    // MARK: - Veille

    @ObservationIgnored private var sleepPolicy = SleepResumePolicy()
    @ObservationIgnored private var resumeTask: Task<Void, Never>?
    @ObservationIgnored private var isSystemAsleep = false

    // MARK: - Découverte

    @ObservationIgnored private var discoveryTask: Task<Void, Never>?
    @ObservationIgnored private var discoveryLoop: Task<Void, Never>?
    @ObservationIgnored private var lastDiscovery: ContinuousClock.Instant?

    // MARK: - Réglages

    /// Dernier état connu des réglages, y compris ceux des sorties absentes du réseau.
    @ObservationIgnored private var settings: BridgeSettings
    @ObservationIgnored private var lastSavedSettings: BridgeSettings
    @ObservationIgnored private var settingsSaveTask: Task<Void, Never>?

    // MARK: - Plan de la pièce

    var roomLayout: RoomLayout

    func persistRoomLayout() { environment.saveRoomLayout(roomLayout) }

    /// Compensation du lieu d'écoute en vigueur, en millisecondes, ou `nil` si le plan ne permet
    /// pas de la calculer (enceinte non posée, pas de position d'écoute).
    ///
    /// Appliquée, et plus seulement suggérée : un sélecteur de lieu n'aurait sinon aucun effet.
    /// Elle reste une estimation : les distances sont relevées à la main, les enceintes ne sont
    /// pas des sources ponctuelles et les réflexions de la pièce dominent souvent le trajet
    /// direct. C'est pourquoi le réglage manuel (`delayMS`) s'y ajoute, et ne la remplace pas.
    func listeningCompensationMS(for output: OutputState) -> Double? {
        listeningCompensations[output.id]
    }

    /// Calculée sur **les sorties rattachées dans le plan**, et sur elles seules : la référence
    /// est l'enceinte la plus lointaine, et la prendre parmi les sorties découvertes ou cochées
    /// ferait bouger le calage des autres en pleine écoute, dès qu'on coche une enceinte ou que la
    /// Geneva s'allume. Le plan, lui, ne change que si on le modifie.
    ///
    /// Sans doublons : une paire stéréo pose deux enceintes sur une même sortie.
    private var listeningCompensations: [String: Double] {
        let bound = Set(
            roomLayout.objects.compactMap { object -> String? in
                guard case let .speaker(outputID) = object.kind else { return nil }
                return outputID
            }
        )
        return roomLayout.suggestedDelaysMS(for: Array(bound))
    }

    /// Délai envoyé au moteur : le réglage manuel, plus la compensation du lieu d'écoute. Une
    /// sortie sans enceinte sur le plan n'a que son réglage manuel.
    ///
    /// C'est cette valeur, et elle seule, que le moteur reçoit. Elle agit sur l'ancrage annoncé et
    /// non sur les échantillons : changer de lieu en pleine diffusion ne rompt pas le flux.
    func effectiveDelayMS(for output: OutputState) -> Double {
        output.delayMS + (listeningCompensationMS(for: output) ?? 0)
    }

    /// Nom du lieu d'écoute en vigueur, s'il en a un.
    var listeningPlaceName: String? {
        guard let name = roomLayout.listener?.name, !name.isEmpty else { return nil }
        return name
    }

    /// Choisit le lieu d'écoute. En pleine diffusion, le tour suivant pousse les nouveaux délais
    /// aux sorties concernées (`pushChanges`), sans rupture de flux.
    func selectListeningPlace(id: UUID) {
        guard id != roomLayout.listener?.id, roomLayout.listeners.contains(where: { $0.id == id })
        else { return }
        roomLayout.selectListener(id: id)
        persistRoomLayout()
    }

    // MARK: - Création

    init(environment: BridgeEnvironment = .inert) {
        self.environment = environment
        self.engine = BridgeEngine(dependencies: environment.engineDependencies)
        let settings = environment.settingsStore.load()
        self.settings = settings
        self.lastSavedSettings = settings
        self.roomLayout = environment.loadRoomLayout()
        self.masterVolumeDB = settings.masterVolumeDB
        self.isMuted = settings.isMuted
        self.muteLocalOutput = settings.muteLocalOutput
        self.preferredSourceID = settings.sourceID
        if settings.sourceID == CaptureSource.inputDevice.id { selectedSource = .inputDevice }

        // Une enceinte cochée reste visible avant d'être revue : elle n'a pas à attendre la fin de
        // la première recherche, et le moteur saura la trouver par son nom si elle est là.
        outputs = settings.outputs
            .filter(\.value.isEnabled)
            .compactMap { id, record in
                guard let proto = OutputProtocol(outputID: id) else { return nil }
                let output = OutputState(
                    id: id,
                    displayName: record.displayName ?? Self.displayName(fromOutputID: id),
                    host: "", port: 0, proto: proto, presence: .unknown
                )
                restore(record, on: output)
                return output
            }
            .sorted {
                $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
            }
    }

    private static func displayName(fromOutputID id: String) -> String {
        let name = id.split(separator: "/", maxSplits: 1).last.map(String.init) ?? id
        return RAOPDevice(serviceName: name, host: "", port: 0, txt: [:]).displayName
    }

    private func restore(_ record: BridgeSettings.Output, on output: OutputState) {
        output.isEnabled = record.isEnabled
        output.trimDB = record.trimDB
        output.delayMS = record.delayMS
        output.bassBoostDB = record.bassBoostDB
        output.onSettingsChange = { [weak self] in self?.scheduleSettingsSave() }
    }

    /// Lance ce qui doit tourner dès l'ouverture, avec ou sans fenêtre : le rafraîchissement des
    /// sources et la recherche périodique. Idempotent.
    func startBackgroundWork() {
        guard discoveryLoop == nil else { return }
        refreshSources()
        let interval = environment.timing.discoveryInterval
        discoveryLoop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.periodicDiscoveryRound()
                do { try await Task.sleep(for: interval) } catch { return }
            }
        }
    }

    /// Le panneau vient de s'ouvrir : il doit dire ce qui est vrai maintenant.
    func panelDidOpen() {
        refreshSources()
        if let lastDiscovery,
            lastDiscovery.duration(to: .now) < environment.timing.panelRefreshMinimumAge
        {
            return
        }
        Task { await refreshOutputs() }
    }

    // MARK: - Découverte

    /// Une recherche automatique. Elle continue pendant une diffusion : la découverte ne fait que
    /// des requêtes DNS, sans connexion vers les appareils, et une enceinte trouvée à ce moment
    /// reste décochée. Rien pendant la veille, où le réseau n'est pas là pour répondre.
    private func periodicDiscoveryRound() async {
        guard !isSystemAsleep else { return }
        await refreshOutputs()
    }

    /// Recherche sur le réseau et réconcilie la liste. Une recherche déjà en cours n'en lance pas
    /// une seconde : on attend simplement son résultat.
    func refreshOutputs() async {
        if let discoveryTask {
            await discoveryTask.value
            return
        }
        let task = Task { [weak self] in
            await self?.performDiscovery()
            self?.discoveryTask = nil
        }
        discoveryTask = task
        await task.value
    }

    private func performDiscovery() async {
        isBrowsing = true
        defer { isBrowsing = false }
        let result = await environment.discovery.discover()
        lastDiscovery = .now
        hasCompletedDiscovery = true
        apply(OutputCatalog.merge(raop: result.raop, airplay2: result.airplay2))
    }

    /// Réconcilie en place : une sortie conservée garde son objet.
    private func apply(_ discovered: [DiscoveredOutput]) {
        let reconciliation = OutputCatalog.reconcile(
            current: outputs.map { output in
                OutputCatalog.Entry(
                    id: output.id, displayName: output.displayName, host: output.host,
                    proto: output.proto, presence: output.presence,
                    missedRounds: output.missedRounds,
                    isRetained: output.isEnabled || activeOutputIDs.contains(output.id),
                    isInSession: activeOutputIDs.contains(output.id),
                    confirmsTransientPairing: output.confirmsTransientPairing
                )
            },
            discovered: discovered
        )

        var byID = Dictionary(uniqueKeysWithValues: outputs.map { ($0.id, $0) })
        settings = currentSettings()
        let isFirstEverDiscovery = settings.outputs.isEmpty
        for id in reconciliation.removed { byID[id] = nil }
        for id in reconciliation.superseded { settings.outputs[id] = nil }
        for found in reconciliation.added {
            byID[found.id] = makeOutput(from: found, isFirstEverDiscovery: isFirstEverDiscovery)
        }
        for found in reconciliation.seen {
            guard let output = byID[found.id] else { continue }
            if output.host != found.host { output.host = found.host }
            if output.port != found.port { output.port = found.port }
            if output.unavailability != found.unavailability {
                output.unavailability = found.unavailability
            }
            if found.confirmsTransientPairing { output.confirmsTransientPairing = true }
        }
        for (id, presence) in reconciliation.presence {
            guard let output = byID[id], output.presence != presence else { continue }
            output.presence = presence
        }
        for (id, missed) in reconciliation.missedRounds { byID[id]?.missedRounds = missed }

        let reconciled = reconciliation.order.compactMap { byID[$0] }
        if reconciled.map(\.id) != outputs.map(\.id) { outputs = reconciled }
        if !reconciliation.added.isEmpty || !reconciliation.superseded.isEmpty {
            scheduleSettingsSave()
        }

        // Une liste vide n'est pas une erreur : c'est aussi ce qu'on obtient quand
        // l'autorisation « réseau local » vient d'être refusée. Distinguer les deux
        // demanderait une API que macOS n'expose pas ; on le dit sans trancher.
        discoveryNotice =
            outputs.isEmpty
            ? "Vérifie qu'elles sont allumées et sur le même réseau, et que l'autorisation "
                + "« Réseau local » est accordée."
            : nil

        // Une enceinte posée avant que sa sortie soit visible (la Geneva éteinte, typiquement)
        // se rattache ici, par son nom, dès que celle-ci apparaît sur le réseau.
        let bound = roomLayout.bindingSpeakers(
            toOutputs: outputs.map { (id: $0.id, name: $0.displayName) }
        )
        if bound != roomLayout {
            roomLayout = bound
            persistRoomLayout()
        }
    }

    /// Une sortie qu'on n'avait pas à l'écran : elle retrouve ses réglages si elle en a.
    ///
    /// Sinon, elle n'est cochée d'office qu'à la toute première découverte, pour qu'installer l'app
    /// et cliquer sur Diffuser suffise. Pas après : cocher, c'est jouer, et la recherche tourne
    /// désormais toute seule, sans que personne regarde. Un appareil de passage sur le réseau ne
    /// doit pas se mettre à chanter parce qu'il s'est allumé hier. Ni, à aucun moment, une enceinte
    /// qui ne jouera pas : l'afficher en rouge d'office n'apprend rien à personne.
    private func makeOutput(
        from found: DiscoveredOutput, isFirstEverDiscovery: Bool
    ) -> OutputState {
        let output = OutputState(
            id: found.id, displayName: found.displayName, host: found.host, port: found.port,
            proto: found.proto, unavailability: found.unavailability
        )
        let fallback = BridgeSettings.Output(
            isEnabled: isFirstEverDiscovery && found.unavailability == nil && !isLive
        )
        restore(settings.outputs[found.id] ?? fallback, on: output)
        output.confirmsTransientPairing = found.confirmsTransientPairing
        return output
    }

    func refreshSources() {
        updateSources(isCaptureLive: isLive)
    }

    private func updateSources(isCaptureLive: Bool) {
        let resolved = CaptureSource.resolve(
            preferredID: preferredSourceID, current: selectedSource,
            available: environment.availableSources(), isLive: isCaptureLive
        )
        if resolved.sources != sources { sources = resolved.sources }
        if resolved.selected != selectedSource { selectedSource = resolved.selected }
    }

    /// Choix explicite d'une source. Pendant une diffusion, la relance : un sélecteur sans effet
    /// serait un mensonge, et la capture ne se change pas à chaud (une seule capture à la fois).
    func selectSource(id: String) {
        guard id != selectedSource.id, let source = sources.first(where: { $0.id == id }) else {
            return
        }
        preferredSourceID = id
        selectedSource = source
        scheduleSettingsSave()
        restartIfLive()
    }

    // MARK: - Diffusion

    /// Démarre ou arrête la diffusion via `BridgeEngine`.
    ///
    /// Le moteur ne connaît ni les vues ni les réglages : on lui passe une capture et une
    /// liste de sorties, il publie un état qu'on recopie ici. C'est ce sens unique qui
    /// permet à une panne de sortie de rester confinée à sa ligne.
    func toggleStreaming() {
        let now = ContinuousClock.now
        if let lastToggle, lastToggle.duration(to: now) < environment.timing.minimumToggleInterval {
            return
        }
        guard canToggleStreaming else { return }
        lastToggle = now

        // Le geste de l'utilisateur prime sur une reprise programmée au réveil.
        sleepPolicy.userTookOver()
        resumeTask?.cancel()
        resumeTask = nil

        if isStreaming {
            streamingPhase = .stopping
            enqueueLifecycle { [weak self] in await self?.performStop() }
        } else {
            streamingPhase = .starting
            enqueueLifecycle { [weak self] in await self?.performStart() }
        }
    }

    @discardableResult
    private func enqueueLifecycle(
        _ operation: @escaping @MainActor () async -> Void
    ) -> Task<Void, Never> {
        let previous = lifecycleTail
        let task = Task {
            await previous?.value
            await operation()
        }
        lifecycleTail = task
        return task
    }

    private func restartIfLive() {
        guard isLive, !isRestarting else { return }
        isRestarting = true
        enqueueLifecycle { [weak self] in
            await self?.performStop()
            // Levé avant de repartir : un nouveau changement de source arrivé maintenant ne serait
            // pas vu par ce démarrage, il doit donc pouvoir demander le sien.
            self?.isRestarting = false
            await self?.performStart()
        }
    }

    private func performStart() async {
        guard streamingPhase == .idle || streamingPhase == .starting else { return }
        streamingPhase = .starting
        // Les PID d'une application valent à l'instant du relevé : un navigateur crée ses
        // processus de rendu à la demande, et la capture doit tous les prendre.
        updateSources(isCaptureLive: false)

        let selected = outputs.filter(\.isEnabled)
        guard !selected.isEmpty else {
            streamingPhase = .idle
            startFailure = StartFailure(message: "Aucune enceinte cochée.", settingsPane: nil)
            return
        }
        startFailure = nil

        sessionGeneration += 1
        let requests = selected.map(makeRequest)
        activeOutputIDs = Set(selected.map(\.id))
        pushed = Dictionary(
            uniqueKeysWithValues: requests.map { ($0.id, Self.pushedSettings(for: $0)) }
        )
        for output in selected { output.connection = .connecting }

        let source: BridgeEngine.Source =
            selectedSource.tapMode.map { .processTap($0) } ?? .inputDevice
        do {
            try await engine.start(
                source: source, outputs: requests,
                options: BridgeEngine.StartOptions(muteLocalOutput: muteLocalOutput)
            )
        } catch {
            resetAfterSession()
            if case BridgeEngine.Failure.stoppedDuringStart = error { return }
            startFailure = Self.startFailure(for: error, source: selectedSource)
            stateLog.error("Démarrage impossible : \(String(describing: error), privacy: .public)")
            return
        }

        environment.streamingActivity.begin()
        streamingSince = .now
        streamingPhase = .running
        startPollingEngine()
    }

    private static func startFailure(for error: Error, source: CaptureSource) -> StartFailure {
        if case BridgeEngine.Failure.permissionDenied = error {
            return source == .inputDevice
                ? StartFailure(
                    message: "Autorise le micro dans Réglages Système pour capter l'entrée.",
                    settingsPane: .microphone
                )
                : StartFailure(
                    message: "Autorise l'enregistrement des sons du système dans Réglages Système.",
                    settingsPane: .systemAudioCapture
                )
        }
        return StartFailure(message: "\(error)", settingsPane: nil)
    }

    private func performStop() async {
        guard streamingPhase != .idle else { return }
        streamingPhase = .stopping
        pollTask?.cancel()
        pollTask = nil
        await engine.stop()
        resetAfterSession()
    }

    /// Remet tout au repos. La suite de la session ne peut plus rien écrire : `sessionGeneration`
    /// change, et les tâches en retard le constateront.
    private func resetAfterSession() {
        sessionGeneration += 1
        emptySelectionTask?.cancel()
        emptySelectionTask = nil
        outputWork = [:]
        activeOutputIDs = []
        pushed = [:]
        streamingSince = nil
        captureHealth = BridgeEngine.CaptureHealth()
        captureAlert = nil
        for output in outputs where output.connection != .idle { output.connection = .idle }
        environment.streamingActivity.end()
        streamingPhase = .idle
    }

    private func makeRequest(for output: OutputState) -> BridgeEngine.OutputRequest {
        BridgeEngine.OutputRequest(
            id: output.id,
            proto: output.proto == .raop ? .raop : .airplay2,
            deviceName: output.serviceInstanceName,
            nameMatching: .exact,
            volumeDB: Self.receiverVolume(forGainDB: effectiveGainDB(for: output)),
            manualDelaySeconds: effectiveDelayMS(for: output) / 1000,
            bassBoostDB: Float(output.supportsBassBoost ? output.bassBoostDB : 0)
        )
    }

    private static func pushedSettings(for request: BridgeEngine.OutputRequest) -> PushedSettings {
        PushedSettings(
            volume: request.volumeDB, delay: request.manualDelaySeconds, bass: request.bassBoostDB
        )
    }

    /// Recopie l'état du moteur dans les sorties, et lui pousse ce qui a changé.
    ///
    /// Le moteur est la source de vérité : la vue n'invente aucun état, elle reflète. Une
    /// sortie que le moteur déclare en échec le reste ici, même si les autres diffusent.
    private func startPollingEngine() {
        let interval = environment.timing.pollInterval
        let generation = sessionGeneration
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollEngine(generation: generation)
                do { try await Task.sleep(for: interval) } catch { return }
            }
        }
    }

    private func pollEngine(generation: Int) async {
        let isRunning = await engine.isRunning
        let snapshots = await engine.outputs
        let health = await engine.captureHealth
        // L'arrêt a pu passer pendant ces lectures : ce qu'elles rapportent n'a plus cours.
        guard generation == sessionGeneration, streamingPhase == .running else { return }

        // `isStreaming` dit la vérité : si le moteur ne tourne plus, l'interface ne prétend pas
        // le contraire.
        guard isRunning else {
            stateLog.error("Le moteur ne tourne plus : remise au repos de l'interface")
            enqueueLifecycle { [weak self] in await self?.performStop() }
            return
        }

        for snapshot in snapshots where activeOutputIDs.contains(snapshot.id) {
            guard let output = outputs.first(where: { $0.id == snapshot.id }) else { continue }
            let connection = OutputConnectionState(
                phase: snapshot.phase, lastError: snapshot.lastError,
                nextAttemptAt: snapshot.nextAttemptAt
            )
            if output.connection != connection { output.connection = connection }
            if output.statistics != snapshot.statistics { output.statistics = snapshot.statistics }
            output.sync = snapshot.sync
            if output.droppedWhileStreaming != snapshot.droppedWhileStreaming {
                output.droppedWhileStreaming = snapshot.droppedWhileStreaming
            }
        }

        if captureHealth != health { captureHealth = health }
        let alert = CaptureAlert.evaluate(
            health: health, source: selectedSource,
            runningFor: streamingSince.map { Self.seconds($0.duration(to: .now)) } ?? 0
        )
        if captureAlert != alert { captureAlert = alert }

        syncOutputsWithEngine()
    }

    /// Fait suivre au moteur ce que l'utilisateur a changé depuis le dernier tour.
    ///
    /// Détecter le changement plutôt que réagir à chaque frappe du curseur évite d'envoyer un
    /// `SET_PARAMETER` par pixel déplacé, tout en couvrant tous les chemins qui modifient une
    /// consigne — fenêtre, panneau, master, trim, silence, plan.
    private func syncOutputsWithEngine() {
        guard streamingPhase == .running else { return }
        for output in outputs where outputWork[output.id] == nil {
            let isActive = activeOutputIDs.contains(output.id)
            if output.isEnabled, !isActive {
                addToSession(output)
            } else if !output.isEnabled, isActive {
                removeFromSession(output)
            } else if isActive {
                pushChanges(of: output)
            }
        }
        updateEmptySelectionStop()
    }

    private func addToSession(_ output: OutputState) {
        let request = makeRequest(for: output)
        activeOutputIDs.insert(output.id)
        pushed[output.id] = Self.pushedSettings(for: request)
        output.connection = .connecting
        let engine = self.engine
        let generation = sessionGeneration
        runOutputWork(id: output.id) { [weak self, weak output] in
            do {
                try await engine.addOutput(request)
            } catch {
                // L'arrêt a pu passer entre-temps : l'ajout échoue alors pour rien, et cette ligne
                // est déjà au repos.
                guard generation == self?.sessionGeneration else { return }
                // Laissée dans la session : le prochain tour ne retente pas toutes les 250 ms ce
                // qui vient d'échouer. La décocher puis la recocher est une nouvelle tentative.
                output?.connection = .failed("\(error)")
            }
        }
    }

    private func removeFromSession(_ output: OutputState) {
        activeOutputIDs.remove(output.id)
        pushed[output.id] = nil
        output.connection = .idle
        let engine = self.engine
        let id = output.id
        runOutputWork(id: id) { await engine.removeOutput(id: id) }
    }

    private func pushChanges(of output: OutputState) {
        guard let last = pushed[output.id] else { return }
        let target = Self.pushedSettings(for: makeRequest(for: output))
        let volume = target.volume != last.volume ? target.volume : nil
        let delay = target.delay != last.delay ? target.delay : nil
        let bass = target.bass != last.bass ? target.bass : nil
        guard volume != nil || delay != nil || bass != nil else { return }

        pushed[output.id] = target
        let engine = self.engine
        let id = output.id
        runOutputWork(id: id) {
            if let volume { await engine.setVolume(volume, for: id) }
            if let delay { await engine.setManualDelay(delay, for: id) }
            if let bass { await engine.setBassBoost(bass, for: id) }
        }
    }

    private func runOutputWork(id: String, _ work: @escaping @MainActor () async -> Void) {
        let generation = sessionGeneration
        outputWork[id] = Task { [weak self] in
            await work()
            guard let self, generation == self.sessionGeneration else { return }
            self.outputWork[id] = nil
        }
    }

    /// Plus aucune enceinte cochée : la capture ne sert plus à rien, et avec « Couper le son du
    /// Mac » le son serait perdu pour tout le monde. On attend un instant, pour qu'une permutation
    /// d'une enceinte à l'autre reste un seul geste, sans repayer un démarrage de capture.
    private func updateEmptySelectionStop() {
        guard !outputs.contains(where: \.isEnabled) else {
            emptySelectionTask?.cancel()
            emptySelectionTask = nil
            return
        }
        guard emptySelectionTask == nil else { return }
        let grace = environment.timing.emptySelectionGrace
        emptySelectionTask = Task { [weak self] in
            do { try await Task.sleep(for: grace) } catch { return }
            guard let self, !self.outputs.contains(where: \.isEnabled) else { return }
            self.emptySelectionTask = nil
            self.enqueueLifecycle { [weak self] in await self?.performStop() }
        }
    }

    /// Traduit le gain de l'interface vers l'échelle de volume AirPlay.
    ///
    /// Deux échelles distinctes : l'interface court de `-60` à `0` dB, le protocole n'accepte
    /// que `-30…0`, plus `-144` pour le silence. Écrêter revenait à rendre **toute la moitié
    /// basse du bouton inopérante** — le volume ne bougeait plus en dessous de -30 dB, ce qui
    /// donnait un réglage à moitié mort. La course est donc remise à l'échelle, pour que
    /// chaque degré de rotation agisse.
    ///
    /// Conséquence assumée : un même nombre affiché ne correspond plus à la même atténuation
    /// chez le récepteur. C'est le prix d'un bouton dont toute la course sert, et l'affichage
    /// reste monotone — ce que l'oreille demande d'un volume.
    static func receiverVolume(forGainDB gain: Double) -> Float {
        guard gain > silenceDB else { return -144 }
        let clamped = min(max(gain, silenceDB), 0)
        return Float(clamped / silenceDB * -30)
    }

    private static func seconds(_ duration: Duration) -> TimeInterval {
        let (seconds, attoseconds) = duration.components
        return Double(seconds) + Double(attoseconds) / 1e18
    }

    // MARK: - Veille et arrêt de l'application

    /// Le Mac s'endort : la session ne survivrait pas, et un récepteur resterait bloqué sans
    /// `TEARDOWN`. Mieux vaut l'arrêter pendant que le réseau répond encore.
    func systemWillSleep() {
        isSystemAsleep = true
        resumeTask?.cancel()
        resumeTask = nil
        // Une relance en cours compte : elle est entre son arrêt et son redémarrage.
        if sleepPolicy.systemWillSleep(isStreaming: isLive || isRestarting) {
            enqueueLifecycle { [weak self] in await self?.performStop() }
        }
        flushSettings()
    }

    /// Le Mac se réveille : reprise si la veille a interrompu une diffusion, après un court délai
    /// pour laisser revenir le réseau. Une enceinte encore injoignable passera par l'attente du
    /// moteur, sans empêcher les autres de repartir.
    func systemDidWake() {
        isSystemAsleep = false
        guard sleepPolicy.shouldResumeAfterWake else { return }
        let delay = environment.timing.wakeResumeDelay
        resumeTask = Task { [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            guard let self, self.sleepPolicy.shouldResumeAfterWake else { return }
            self.sleepPolicy.resumeDidStart()
            self.resumeTask = nil
            self.enqueueLifecycle { [weak self] in await self?.performStart() }
        }
    }

    /// Faut-il attendre un arrêt propre avant de quitter ?
    var needsOrderlyShutdown: Bool { streamingPhase != .idle }

    /// Arrête tout avant de quitter, sans dépasser `timeout` : un récepteur muet ne doit pas
    /// empêcher l'app de se fermer, mais un récepteur sain doit recevoir son `TEARDOWN`.
    func shutdown(timeout: Duration) async {
        discoveryLoop?.cancel()
        discoveryLoop = nil
        resumeTask?.cancel()
        resumeTask = nil
        flushSettings()
        persistRoomLayout()
        guard needsOrderlyShutdown else { return }
        // Un démarrage peut attendre un dialogue d'autorisation : `stop` le rend caduc, sans quoi
        // la file resterait bloquée derrière lui.
        if streamingPhase == .starting { await engine.stop() }
        let stopping = enqueueLifecycle { [weak self] in await self?.performStop() }
        await Self.wait(for: stopping, atMost: timeout)
    }

    /// Attend une tâche, sans dépasser un délai.
    ///
    /// Ni groupe de tâches ni `async let` : ils attendent tous leurs enfants à la sortie, et
    /// `await task.value` ne s'interrompt pas sur annulation. Le délai ne vaudrait rien.
    private static func wait(for task: Task<Void, Never>, atMost limit: Duration) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let once = OnceContinuation(continuation)
            Task {
                await task.value
                once.resume()
            }
            Task {
                try? await Task.sleep(for: limit)
                once.resume()
            }
        }
    }

    // MARK: - Persistance

    /// Différée : un curseur change des dizaines de fois par seconde, et le fichier n'a besoin que
    /// de la valeur où il s'arrête.
    private func scheduleSettingsSave() {
        settingsSaveTask?.cancel()
        let delay = environment.timing.settingsSaveDelay
        settingsSaveTask = Task { [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            self?.flushSettings()
        }
    }

    /// Écrit tout de suite ce qui ne l'est pas encore. N'écrit rien si rien n'a changé.
    func flushSettings() {
        settingsSaveTask?.cancel()
        settingsSaveTask = nil
        let current = currentSettings()
        settings = current
        guard current != lastSavedSettings else { return }
        if environment.settingsStore.save(current) { lastSavedSettings = current }
    }

    private func currentSettings() -> BridgeSettings {
        var result = settings
        result.masterVolumeDB = masterVolumeDB
        result.isMuted = isMuted
        result.sourceID = preferredSourceID
        result.muteLocalOutput = muteLocalOutput
        for output in outputs {
            result.outputs[output.id] = BridgeSettings.Output(
                isEnabled: output.isEnabled, trimDB: output.trimDB, delayMS: output.delayMS,
                bassBoostDB: output.bassBoostDB, displayName: output.displayName
            )
        }
        return result
    }
}

/// Reprise unique d'une attente, par celui qui arrive le premier.
private final class OnceContinuation {
    private var continuation: CheckedContinuation<Void, Never>?

    init(_ continuation: CheckedContinuation<Void, Never>) {
        self.continuation = continuation
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }
}

// MARK: - Données de démonstration

extension BridgeState {
    /// Peuple l'état avec l'installation cible du CDC, pour les Previews.
    ///
    /// Les Previews n'ont ni réseau local autorisé ni audio : sans ce jeu de données, elles
    /// ne montreraient qu'une liste vide et ne serviraient à rien pour la mise en page.
    static func preview() -> BridgeState {
        let state = BridgeState(environment: .inert)
        let geneva = OutputState(
            id: "raop/Geneva", displayName: "Geneva", host: "192.168.1.42", port: 7000,
            proto: .raop
        )
        geneva.trimDB = -2
        geneva.bassBoostDB = 6
        geneva.connection = .streaming
        geneva.statistics = previewStatistics(
            packets: 454_621, frames: 174_197_760, sync: 3_661, removed: 10, reconnections: 90,
            dropped: 113_536
        )
        geneva.statistics.reportedLatencyFrames = 11_025
        geneva.statistics.timingResponsesSent = 14

        let appleTV = OutputState(
            id: "airplay2/ApTV", displayName: "Apple TV + HomePod", host: "192.168.1.51",
            port: 7000, proto: .airplay2
        )
        appleTV.delayMS = 25
        appleTV.connection = .streaming
        appleTV.statistics = previewStatistics(
            packets: 466_088, frames: 178_572_800, sync: 3_700, removed: 14, reconnections: 0,
            dropped: 0
        )
        appleTV.statistics.eventChannelConnected = true

        state.outputs = [geneva, appleTV]
        state.streamingPhase = .running
        state.sources = [
            .systemWide,
            .application(pids: [501], name: "Music", bundleID: "com.apple.Music"),
            .inputDevice,
        ]
        state.captureHealth.diagnosis = .healthy
        state.captureHealth.framesCaptured = 188_000_000
        state.captureHealth.permission = .authorized
        return state
    }

    private static func previewStatistics(
        packets: Int, frames: Int, sync: Int, removed: Int, reconnections: Int, dropped: Int
    ) -> OutputStatistics {
        var statistics = OutputStatistics()
        statistics.packetsSent = packets
        statistics.framesRead = frames
        statistics.anchoredSyncPackets = sync
        statistics.syncPacketsSent = sync
        statistics.framesRemoved = removed
        statistics.reconnections = reconnections
        statistics.reconnectionAttempts = reconnections
        statistics.droppedBeforeStreaming = dropped
        return statistics
    }

    /// Les situations du panneau de la barre de menus, pour les Previews et le rendu hors écran.
    enum PanelScene: String, CaseIterable {
        case idle = "repos"
        case streaming = "diffusion"
        case trouble = "panne"
        case nothingPlaying = "rien-ne-joue"
        case offline = "hors-ligne"
        case startFailed = "echec-demarrage"
        case starting = "demarrage"
        case searching = "recherche"
        case empty = "vide"
        case inputSource = "entree-physique"
        case listeningPlaces = "lieux-ecoute"
    }

    static func preview(_ scene: PanelScene) -> BridgeState {
        let state = BridgeState(environment: .inert)
        state.hasCompletedDiscovery = true
        state.masterVolumeDB = defaultMasterVolumeDB
        state.sources = [
            .systemWide,
            .application(pids: [501], name: "Music", bundleID: "com.apple.Music"),
            .inputDevice,
        ]

        let geneva = OutputState(
            id: "raop/AABBCCDDEEFF@Geneva", displayName: "Geneva", host: "192.168.1.42",
            port: 7000, proto: .raop
        )
        geneva.trimDB = -2
        geneva.bassBoostDB = 6
        let left = OutputState(
            id: "airplay2/Salon", displayName: "Salon", host: "192.168.1.158", port: 7000,
            proto: .airplay2
        )
        let right = OutputState(
            id: "airplay2/Salon (2)", displayName: "Salon (2)", host: "192.168.1.88", port: 7000,
            proto: .airplay2
        )
        right.trimDB = 1.5
        let appleTV = OutputState(
            id: "raop/001122334455@Apple TV Salon", displayName: "Apple TV Salon",
            host: "192.168.1.51", port: 7000, proto: .raop, unavailability: .pairingRequired
        )
        appleTV.isEnabled = false
        let speakers = [appleTV, geneva, left, right]

        switch scene {
        case .idle:
            state.outputs = speakers
        case .streaming:
            state.outputs = speakers
            state.streamingPhase = .running
            for output in [geneva, left, right] { output.connection = .streaming }
        case .trouble:
            state.outputs = speakers
            state.streamingPhase = .running
            left.connection = .streaming
            geneva.connection = .waiting(
                attempt: 3,
                message: "Impossible de joindre « Geneva » (192.168.1.42). Vérifiez qu'il est "
                    + "allumé et sur le même réseau que ce Mac.",
                nextAttemptAt: nil
            )
            right.connection = .failed(
                "« Salon (2) » a refusé la requête SETUP (réponse 400). Cette version de l'appareil "
                    + "attend peut-être un autre format ; redémarrer l'appareil peut aussi lever "
                    + "un blocage."
            )
            state.captureAlert = CaptureAlert.evaluate(
                health: previewHealth(.silentWhilePlaying), source: .systemWide, runningFor: 60
            )
        case .nothingPlaying:
            state.outputs = speakers
            state.streamingPhase = .running
            for output in [geneva, left, right] { output.connection = .streaming }
            state.captureAlert = CaptureAlert.evaluate(
                health: previewHealth(.silentNothingPlaying), source: .systemWide, runningFor: 60
            )
        case .offline:
            geneva.presence = .offline
            state.outputs = speakers
        case .startFailed:
            state.outputs = speakers
            state.startFailure = StartFailure(
                message: "Autorise l'enregistrement des sons du système dans Réglages Système.",
                settingsPane: .systemAudioCapture
            )
        case .starting:
            state.outputs = speakers
            state.streamingPhase = .starting
            for output in [geneva, left, right] { output.connection = .connecting }
        case .listeningPlaces:
            state.outputs = speakers
            state.streamingPhase = .running
            for output in [geneva, left, right] { output.connection = .streaming }
            state.roomLayout = RoomLayout.salon.bindingSpeakers(
                toOutputs: speakers.map { (id: $0.id, name: $0.displayName) }
            )
        case .inputSource:
            state.outputs = speakers
            state.selectedSource = .inputDevice
            state.sources = [.systemWide, .inputDevice]
        case .searching:
            state.isBrowsing = true
            state.hasCompletedDiscovery = false
        case .empty:
            state.discoveryNotice =
                "Vérifie qu'elles sont allumées et sur le même réseau, et que l'autorisation "
                + "« Réseau local » est accordée."
        }
        return state
    }

    private static func previewHealth(
        _ diagnosis: BridgeEngine.CaptureHealth.Diagnosis
    ) -> BridgeEngine.CaptureHealth {
        var health = BridgeEngine.CaptureHealth()
        health.diagnosis = diagnosis
        health.permission = .authorized
        return health
    }

    /// Comme `preview()`, plus une pièce meublée — sans quoi l'éditeur de plan ne montre
    /// qu'une grille vide et ne dit rien de sa mise en page.
    static func previewWithRoom() -> BridgeState {
        let state = preview()
        state.roomLayout = RoomLayout(
            walls: [
                RoomLayout.WallSegment(a: CGPoint(x: 0, y: 0), b: CGPoint(x: 5.2, y: 0)),
                RoomLayout.WallSegment(a: CGPoint(x: 5.2, y: 0), b: CGPoint(x: 5.2, y: 3.8)),
                RoomLayout.WallSegment(a: CGPoint(x: 5.2, y: 3.8), b: CGPoint(x: 0, y: 3.8)),
                RoomLayout.WallSegment(a: CGPoint(x: 0, y: 3.8), b: CGPoint(x: 0, y: 0)),
            ],
            objects: [
                RoomObject(
                    kind: .tv, position: CGPoint(x: 2.6, y: 0.15),
                    size: CGSize(width: 1.20, height: 0.08), elevation: 1.05
                ),
                RoomObject(
                    kind: .tvStand, position: CGPoint(x: 2.6, y: 0.35),
                    size: CGSize(width: 1.40, height: 0.40), elevation: 0.50
                ),
                RoomObject(
                    kind: .sofa, position: CGPoint(x: 2.6, y: 3.0),
                    size: CGSize(width: 2.00, height: 0.90), elevation: 0.45
                ),
                RoomObject(
                    kind: .coffeeTable, position: CGPoint(x: 2.6, y: 1.9),
                    size: CGSize(width: 0.90, height: 0.90), elevation: 0.40,
                    shape: .ellipse
                ),
                RoomObject(
                    kind: .speaker(outputID: "raop/Geneva"), position: CGPoint(x: 0.6, y: 0.5),
                    size: CGSize(width: 0.45, height: 0.45), elevation: 1.80, name: "Geneva",
                    shape: .ellipse
                ),
                // Les deux HomePod portent la **même** sortie : ils ne forment qu'une seule
                // destination AirPlay 2, mais bien deux points dans la pièce.
                RoomObject(
                    kind: .speaker(outputID: "airplay2/ApTV"), position: CGPoint(x: 1.5, y: 0.4),
                    size: CGSize(width: 0.15, height: 0.15), elevation: 0.55, name: "HomePod G",
                    shape: .ellipse
                ),
                RoomObject(
                    kind: .speaker(outputID: "airplay2/ApTV"), position: CGPoint(x: 3.7, y: 0.4),
                    size: CGSize(width: 0.15, height: 0.15), elevation: 0.55, name: "HomePod D",
                    shape: .ellipse
                ),
                RoomObject(
                    kind: .device, position: CGPoint(x: 2.6, y: 0.35),
                    size: CGSize(width: 0.10, height: 0.10), elevation: 0.55, name: "Apple TV"
                ),
                RoomObject(
                    kind: .listener, position: CGPoint(x: 2.6, y: 2.9),
                    size: CGSize(width: 0.45, height: 0.40), elevation: 1.10
                ),
            ]
        )
        return state
    }
}
