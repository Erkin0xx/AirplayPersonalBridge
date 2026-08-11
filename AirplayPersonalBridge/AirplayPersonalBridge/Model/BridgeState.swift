//
//  BridgeState.swift
//  AirplayPersonalBridge
//

import AudioCore
import Foundation

/// Protocole d'une sortie. L'interface s'en sert pour le rendu, jamais pour du routage :
/// c'est le cœur qui sait quel sender employer.
enum OutputProtocol: String, Sendable {
    case raop = "AirPlay 1"
    case airplay2 = "AirPlay 2"
}

/// Compteurs remontés par une sortie.
///
/// Reflet fidèle des `Statistics` des deux senders (jalon 4). Les champs absents d'un
/// protocole restent à zéro plutôt que d'être rendus optionnels : le panneau de
/// diagnostic les affiche alors comme « — », ce qui dit la même chose sans compliquer
/// l'affichage. La réserve du jalon 4 vaut toujours — un compteur qu'on ne sait pas
/// mesurer doit rester absent, jamais devenir un nombre inventé.
struct OutputDiagnostics: Sendable, Equatable {
    var packetsSent = 0
    var framesRead = 0
    var errors = 0
    var resyncs = 0
    var anchoredSyncPackets = 0
    var syncPacketsSent = 0
    var framesInserted = 0
    var framesRemoved = 0
    var reconnections = 0
    var reconnectionAttempts = 0
    var droppedBeforeStreaming = 0
    /// Latence annoncée par le récepteur, en trames. Zéro = non annoncée (le cas d'AirPlay 2
    /// contre le mock), pas « aucune latence ».
    var reportedLatencyFrames = 0
    var eventChannelConnected = false

    static let empty = OutputDiagnostics()
}

/// État de connexion d'une sortie, tel que l'interface le montre.
enum OutputConnectionState: Sendable {
    case idle
    case connecting
    case streaming
    /// Session perdue, repli exponentiel en cours (CDC section 8).
    case reconnecting
    case failed(String)
}

/// Une sortie découverte et ses réglages.
///
/// Les réglages vivent ici et non dans le cœur : un sender ne connaît que la valeur qu'on
/// lui pousse (`setVolume`, `setManualDelay`), jamais l'intention de l'utilisateur.
@Observable
final class OutputState: Identifiable {
    let id: String
    let displayName: String
    let host: String
    let port: UInt16
    let proto: OutputProtocol

    /// Sortie retenue pour la diffusion. Décocher une sortie ne doit jamais perturber
    /// l'autre — c'est l'invariant §12, et il vaut aussi pour une action volontaire.
    var isEnabled = true

    /// Correction par sortie, en dB, appliquée en plus du master (décision du jalon 5).
    var trimDB: Double = 0

    /// Décalage manuel de restitution, en millisecondes. Agit sur l'ancrage annoncé, pas
    /// sur les échantillons : instantané, sans rupture de flux (jalon 4).
    var delayMS: Double = 0

    /// Renfort de basse, en dB (ADR-002 : low shelf ~80 Hz, Q 0,7).
    var bassBoostDB: Double = 0

    var connection: OutputConnectionState = .idle
    var diagnostics: OutputDiagnostics = .empty

    /// Le renfort de basse ne concerne que la Geneva (CDC section 2) : les HomePod gardent
    /// une stéréo pleine bande intacte. On le rattache au protocole plutôt qu'au nom de
    /// l'appareil — la Geneva est l'unique sortie AirPlay 1 de cette installation, et se
    /// fier au nom casserait dès le premier renommage.
    var supportsBassBoost: Bool { proto == .raop }

    init(
        id: String, displayName: String, host: String, port: UInt16, proto: OutputProtocol
    ) {
        self.id = id
        self.displayName = displayName
        self.host = host
        self.port = port
        self.proto = proto
    }
}

/// L'état complet de l'interface.
///
/// Découverte et diffusion sont réelles : `BridgeEngine` détient la capture et les senders,
/// cette classe lui passe des intentions et recopie l'état qu'il publie. Elle n'invente aucun
/// état et ne manipule jamais un ring buffer ni un sender directement.
///
/// Limite connue : l'entrée physique (ligne/micro) n'est pas encore diffusable — le moteur ne
/// gère que les modes Process Tap, et le bouton le dit plutôt que de rester sans effet.
@Observable
final class BridgeState {
    // MARK: - Source

    var sources: [CaptureSource] = [.systemWide, .inputDevice]
    var selectedSource: CaptureSource = .systemWide

    // MARK: - Sorties

    private(set) var outputs: [OutputState] = []
    private(set) var isBrowsing = false
    private(set) var discoveryNotice: String?

    // MARK: - Volume

    /// Master logiciel, en dB (décision du jalon 5 : gain appliqué au signal, plus un trim
    /// par sortie). `-60` fait office de silence.
    var masterVolumeDB: Double = -12
    var isMuted = false

    /// Gain effectif d'une sortie, master et trim confondus. C'est cette valeur, et elle
    /// seule, que le moteur appliquera — la vue n'en calcule aucune autre.
    func effectiveGainDB(for output: OutputState) -> Double {
        isMuted ? Self.silenceDB : min(max(masterVolumeDB + output.trimDB, Self.silenceDB), 0)
    }

    static let silenceDB: Double = -60

    // MARK: - Diffusion

    private(set) var isStreaming = false

    /// Le moteur, seul détenteur de la capture et des senders. `BridgeState` ne manipule
    /// jamais un ring buffer ni un sender directement — il demande et il reflète.
    private let engine = BridgeEngine()
    private var pollTask: Task<Void, Never>?
    /// Dernier volume réellement envoyé à chaque sortie, pour n'émettre que sur changement.
    private var lastPushedVolume: [String: Float] = [:]

    // MARK: - Plan de la pièce

    var roomLayout = RoomLayout.load()

    func persistRoomLayout() { roomLayout.save() }

    /// Délai suggéré par le plan, en millisecondes, ou `nil` si le plan ne permet pas de
    /// le calculer (enceinte non posée, pas de position d'écoute).
    ///
    /// Suggéré, et pas appliqué : les distances sont relevées à la main, les enceintes ne
    /// sont pas des sources ponctuelles et les réflexions de la pièce dominent souvent le
    /// trajet direct. C'est un point de départ pour le réglage manuel, pas une mesure.
    func suggestedDelayMS(for output: OutputState) -> Double? {
        suggestedDelays[output.id]
    }

    private var suggestedDelays: [String: Double] {
        roomLayout.suggestedDelaysMS(for: outputs.map(\.id))
    }

    func applySuggestedDelay(to output: OutputState) {
        guard let suggested = suggestedDelayMS(for: output) else { return }
        output.delayMS = suggested
    }

    func applyAllSuggestedDelays() {
        for output in outputs { applySuggestedDelay(to: output) }
    }

    // MARK: - Découverte

    /// Les deux découvertes tournent en parallèle et n'échangent rien : une sortie
    /// n'apprend jamais l'existence de l'autre (invariant §12).
    func refreshOutputs() async {
        isBrowsing = true
        discoveryNotice = nil
        defer { isBrowsing = false }

        async let raop = RAOPDiscovery().browse()
        async let airplay2 = AirPlay2Discovery().browse()
        let (raopDevices, airplay2Devices) = await (raop, airplay2)

        // Un même appareil s'annonce sur les DEUX services : les HomePod et l'Apple TV en
        // `_raop._tcp` et `_airplay._tcp`, la Geneva également. Les lister tels quels donne
        // deux lignes par enceinte, dont une injouable. On n'en garde qu'une par appareil,
        // identifié par son adresse.
        //
        // Critère de choix : l'AirPlay 2 l'emporte **seulement si l'appareil annonce le
        // pairing transitoire** (bit 48), qui est le chemin que ce projet sait emprunter. La
        // Geneva s'annonce bien en `_airplay._tcp` mais avec `features=0x444c0a00`, sans
        // aucun bit de pairing : c'est un récepteur AirPlay 1, il repasse en RAOP.
        var byHost: [String: OutputState] = [:]
        for device in raopDevices {
            byHost[device.host] = OutputState(
                id: "raop/\(device.serviceName)", displayName: device.displayName,
                host: device.host, port: device.port, proto: .raop
            )
        }
        for device in airplay2Devices where device.supportsTransientPairing {
            byHost[device.host] = OutputState(
                id: "airplay2/\(device.serviceName)", displayName: device.serviceName,
                host: device.host, port: device.port, proto: .airplay2
            )
        }
        let discovered = byHost.values.sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }

        // Les réglages déjà faits survivent à un rafraîchissement : une sortie qui
        // réapparaît sous la même identité Bonjour retrouve son trim, son délai et son
        // renfort de basse. Sans cela, chaque recherche remettrait l'installation à plat.
        let previous = Dictionary(uniqueKeysWithValues: outputs.map { ($0.id, $0) })
        outputs = discovered.map { fresh in
            guard let old = previous[fresh.id] else { return fresh }
            fresh.isEnabled = old.isEnabled
            fresh.trimDB = old.trimDB
            fresh.delayMS = old.delayMS
            fresh.bassBoostDB = old.bassBoostDB
            fresh.connection = old.connection
            fresh.diagnostics = old.diagnostics
            return fresh
        }

        // Une liste vide n'est pas une erreur : c'est aussi ce qu'on obtient quand
        // l'autorisation « réseau local » vient d'être refusée. Distinguer les deux
        // demanderait une API que macOS n'expose pas ; on le dit sans trancher.
        if outputs.isEmpty {
            discoveryNotice =
                "Aucune sortie trouvée. Vérifier les mocks (./run-mocks.sh) et l'autorisation "
                + "« Réseau local » dans Réglages Système."
        }
    }

    func refreshSources() {
        let available = CaptureSource.available()
        sources = available
        // Une application qui cesse de jouer disparaît de la liste ; la sélection retombe
        // alors sur le mode global plutôt que de désigner un process mort.
        if !available.contains(selectedSource) { selectedSource = .systemWide }
    }

    // MARK: - Diffusion

    /// Démarre ou arrête la diffusion via `BridgeEngine`.
    ///
    /// Le moteur ne connaît ni les vues ni les réglages : on lui passe une capture et une
    /// liste de sorties, il publie un état qu'on recopie ici. C'est ce sens unique qui
    /// permet à une panne de sortie de rester confinée à sa ligne.
    func toggleStreaming() {
        if isStreaming {
            Task { await stopStreaming() }
        } else {
            Task { await startStreaming() }
        }
    }

    private func startStreaming() async {
        guard let mode = selectedSource.tapMode else {
            // L'entrée physique ne passe pas par un Process Tap : le moteur ne la gère pas
            // encore, et le dire vaut mieux qu'un bouton qui ne fait rien.
            discoveryNotice = "L'entrée physique n'est pas encore diffusable depuis l'interface."
            return
        }
        let selected = outputs.filter(\.isEnabled)
        guard !selected.isEmpty else {
            discoveryNotice = "Aucune sortie sélectionnée."
            return
        }

        let requests = selected.map { output in
            BridgeEngine.OutputRequest(
                id: output.id,
                proto: output.proto == .raop ? .raop : .airplay2,
                deviceName: output.displayName,
                volumeDB: Float(effectiveGainDB(for: output)),
                manualDelaySeconds: output.delayMS / 1000
            )
        }

        for output in selected { output.connection = .connecting }
        do {
            try await engine.start(mode: mode, outputs: requests)
            isStreaming = true
            discoveryNotice = nil
            startPollingEngine()
        } catch {
            discoveryNotice = "Démarrage impossible : \(error)"
            for output in selected { output.connection = .idle }
        }
    }

    private func stopStreaming() async {
        pollTask?.cancel()
        pollTask = nil
        await engine.stop()
        isStreaming = false
        for output in outputs { output.connection = .idle }
    }

    /// Recopie l'état du moteur dans les sorties, une fois par seconde.
    ///
    /// Le moteur est la source de vérité : la vue n'invente aucun état, elle reflète. Une
    /// sortie que le moteur déclare en échec le reste ici, même si les autres diffusent.
    private func startPollingEngine() {
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let snapshots = await engine.outputs
                await MainActor.run {
                    for snapshot in snapshots {
                        guard let output = self.outputs.first(where: { $0.id == snapshot.id })
                        else { continue }
                        switch snapshot.phase {
                        case .idle: output.connection = .idle
                        case .connecting: output.connection = .connecting
                        case .streaming: output.connection = .streaming
                        case let .failed(message): output.connection = .failed(message)
                        }
                        output.diagnostics.packetsSent = snapshot.packetsSent
                        output.diagnostics.errors = snapshot.errors
                        output.diagnostics.framesInserted = snapshot.driftCorrections
                    }
                }
                // Les volumes sont calculés sur le fil principal, avec le reste de l'état,
                // puis poussés hors de lui : le moteur est un acteur, il n'a pas à y être.
                let pending = await MainActor.run { self.pendingVolumeChanges() }
                for (id, volume) in pending {
                    await self.engine.setVolume(volume, for: id)
                }
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            }
        }
    }

    /// Pousse aux senders les volumes qui ont changé depuis le dernier tour.
    ///
    /// Détecter le changement plutôt que réagir à chaque frappe du curseur évite d'envoyer un
    /// `SET_PARAMETER` par pixel déplacé, tout en couvrant les trois chemins qui modifient le
    /// gain — master, trim par sortie, et silence.
    private func pendingVolumeChanges() -> [(String, Float)] {
        var changes: [(String, Float)] = []
        for output in outputs {
            let target = Self.receiverVolume(forGainDB: effectiveGainDB(for: output))
            guard lastPushedVolume[output.id] != target else { continue }
            lastPushedVolume[output.id] = target
            changes.append((output.id, target))
        }
        return changes
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
}

// MARK: - Données de démonstration

extension BridgeState {
    /// Peuple l'état avec l'installation cible du CDC, pour les Previews.
    ///
    /// Les Previews n'ont ni réseau local autorisé ni audio : sans ce jeu de données, elles
    /// ne montreraient qu'une liste vide et ne serviraient à rien pour la mise en page.
    static func preview() -> BridgeState {
        let state = BridgeState()
        let geneva = OutputState(
            id: "raop/Geneva", displayName: "Geneva", host: "192.168.1.42", port: 7000,
            proto: .raop
        )
        geneva.trimDB = -2
        geneva.bassBoostDB = 6
        geneva.connection = .streaming
        geneva.diagnostics = OutputDiagnostics(
            packetsSent: 454_621, framesRead: 174_197_760, errors: 0, resyncs: 0,
            anchoredSyncPackets: 3_661, syncPacketsSent: 3_661, framesInserted: 0,
            framesRemoved: 10, reconnections: 90, reconnectionAttempts: 90,
            droppedBeforeStreaming: 113_536, reportedLatencyFrames: 11_025
        )

        let appleTV = OutputState(
            id: "airplay2/ApTV", displayName: "Apple TV + HomePod", host: "192.168.1.51",
            port: 7000, proto: .airplay2
        )
        appleTV.delayMS = 25
        appleTV.connection = .streaming
        appleTV.diagnostics = OutputDiagnostics(
            packetsSent: 466_088, framesRead: 178_572_800, errors: 0, resyncs: 0,
            anchoredSyncPackets: 3_700, syncPacketsSent: 3_700, framesInserted: 0,
            framesRemoved: 14, reconnections: 0, reconnectionAttempts: 0,
            droppedBeforeStreaming: 0, eventChannelConnected: true
        )

        state.outputs = [geneva, appleTV]
        state.isStreaming = true
        state.sources = [
            .systemWide,
            .application(pids: [501], name: "Music", bundleID: "com.apple.Music"),
            .inputDevice,
        ]
        return state
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
