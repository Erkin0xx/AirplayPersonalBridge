//
//  BridgeEnvironment.swift
//  AirplayPersonalBridge
//

import AudioCore
import Foundation

/// Ce que renvoie une recherche sur le réseau.
struct OutputDiscoveryResult: Sendable {
    var raop: [RAOPDevice] = []
    var airplay2: [AirPlay2Device] = []
}

/// La découverte, injectée : aucun test ne doit toucher au réseau local, où se trouve le vrai
/// matériel.
protocol OutputDiscovering {
    func discover() async -> OutputDiscoveryResult
}

/// Les deux découvertes réelles, en parallèle. Elles n'échangent rien : une sortie n'apprend
/// jamais l'existence de l'autre (invariant section 12).
struct LiveOutputDiscovery: OutputDiscovering {
    func discover() async -> OutputDiscoveryResult {
        async let raop = RAOPDiscovery().browse()
        async let airplay2 = AirPlay2Discovery().browse()
        return await OutputDiscoveryResult(raop: raop, airplay2: airplay2)
    }
}

/// Empêche macOS d'endormir le processus pendant une diffusion.
///
/// **Indispensable depuis que l'app vit sans fenêtre** : un processus sans fenêtre visible est
/// candidat à App Nap, qui regroupe ses minuteries. Or le cadencement RTP tient à des échéances de
/// `ContinuousClock` (piège n° 3 du jalon 2) : des paquets émis en rafales toutes les quelques
/// secondes, et le récepteur décroche.
protocol StreamingActivityHolding: AnyObject {
    func begin()
    func end()
}

final class LiveStreamingActivity: StreamingActivityHolding {
    private var token: (any NSObjectProtocol)?

    func begin() {
        guard token == nil else { return }
        // Le Mac peut toujours se mettre en veille : Core Audio retient déjà la veille automatique
        // tant qu'un son joue, et il n'y a pas à l'empêcher quand plus rien ne joue.
        token = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
            reason: "Diffusion AirPlay en cours"
        )
    }

    func end() {
        guard let token else { return }
        ProcessInfo.processInfo.endActivity(token)
        self.token = nil
    }
}

final class NoStreamingActivity: StreamingActivityHolding {
    func begin() {}
    func end() {}
}

/// Tout ce que `BridgeState` reçoit de l'extérieur (CDC section 13 : injection par protocole).
struct BridgeEnvironment {
    /// Temporisations, injectables pour que les tests n'aient pas à dormir.
    struct Timing {
        /// Cadence de recopie de l'état du moteur, et de poussée des réglages.
        var pollInterval: Duration = .milliseconds(250)
        /// Cadence de la recherche périodique.
        var discoveryInterval: Duration = .seconds(30)
        /// Une recherche ne se relance pas à l'ouverture du panneau si la dernière est plus récente.
        var panelRefreshMinimumAge: Duration = .seconds(5)
        /// Regroupe les changements de réglages : un curseur en bouge des dizaines par seconde.
        var settingsSaveDelay: Duration = .seconds(1)
        /// Laisse au Wi-Fi le temps de revenir avant de reprendre une diffusion au réveil.
        var wakeResumeDelay: Duration = .seconds(3)
        /// Une enceinte décochée puis une autre cochée juste après ne repaient pas un démarrage
        /// de capture, et la permutation reste un seul geste.
        var emptySelectionGrace: Duration = .seconds(4)
        /// En deçà, un second clic sur Diffuser est le rebond d'un double clic.
        var minimumToggleInterval: Duration = .milliseconds(500)
        /// Cadence de relecture des processus de l'application captée. Le relevé passe par plusieurs
        /// lectures de propriétés Core Audio par processus : pas à chaque tour de 250 ms.
        var sourceCheckInterval: Duration = .seconds(1)
        /// Écart entre deux changements de capture qui suivent ces processus.
        var sourceFollowMinimumSpacing: Duration = .seconds(5)
        var sourceFollowMaximumSpacing: Duration = .seconds(60)
    }

    var engineDependencies: BridgeEngine.Dependencies
    var discovery: any OutputDiscovering
    var settingsStore: any SettingsStoring
    var loadRoomLayout: () -> RoomLayout
    var saveRoomLayout: (RoomLayout) -> Void
    var availableSources: () -> [CaptureSource]
    var streamingActivity: any StreamingActivityHolding
    var timing = Timing()
    var isProcessAlive: (pid_t) -> Bool = CaptureSource.isProcessAlive

    static var live: BridgeEnvironment {
        BridgeEnvironment(
            engineDependencies: .live,
            discovery: LiveOutputDiscovery(),
            settingsStore: FileSettingsStore(url: FileSettingsStore.defaultURL),
            loadRoomLayout: { RoomLayout.load() },
            saveRoomLayout: { $0.save() },
            availableSources: { CaptureSource.available() },
            streamingActivity: LiveStreamingActivity()
        )
    }

    /// Pour les aperçus : ni réseau, ni fichier, ni plan de la machine.
    static var inert: BridgeEnvironment {
        BridgeEnvironment(
            engineDependencies: .live,
            discovery: NoOutputDiscovery(),
            settingsStore: InMemorySettingsStore(),
            loadRoomLayout: { RoomLayout() },
            saveRoomLayout: { _ in },
            availableSources: { [.systemWide, .inputDevice] },
            streamingActivity: NoStreamingActivity()
        )
    }
}

struct NoOutputDiscovery: OutputDiscovering {
    func discover() async -> OutputDiscoveryResult { OutputDiscoveryResult() }
}
