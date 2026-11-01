//
//  BridgeStatus.swift
//  AirplayPersonalBridge
//

import AudioCore
import Foundation

/// Panneau des Réglages Système à ouvrir pour résoudre un problème.
enum SystemSettingsPane: String, Sendable, Equatable {
    /// « Enregistrement de l'écran et des sons du système » : le Process Tap en dépend, et c'est
    /// une autorisation distincte du micro (`CLAUDE.md`, jalon 1).
    case systemAudioCapture = "Privacy_ScreenCapture"
    case microphone = "Privacy_Microphone"
    case localNetwork = "Privacy_LocalNetwork"

    var url: URL? {
        URL(string: "x-apple.systempreferences:com.apple.preference.security?\(rawValue)")
    }
}

/// Ce que la santé de la capture demande de dire à l'utilisateur.
///
/// Toute la difficulté est de ne pas confondre deux silences : « rien ne joue » n'appelle aucun
/// geste, alors que « autorisation perdue » laisse les enceintes muettes sans la moindre erreur
/// (un rebuild du bundle suffit, `CLAUDE.md`).
struct CaptureAlert: Equatable {
    enum Severity: Equatable {
        /// Rien d'anormal, mais autant le dire : l'utilisateur se demande pourquoi rien ne sort.
        case info
        case warning
        /// Les enceintes ne recevront rien tant que l'utilisateur n'a pas agi.
        case critical
    }

    let severity: Severity
    let title: String
    let detail: String?
    let settingsPane: SystemSettingsPane?

    /// Délai au-delà duquel une capture qui n'a encore rien livré mérite d'être signalée. En deçà,
    /// c'est l'attente normale du premier bloc.
    static let firstBlockPatience: TimeInterval = 5

    static func evaluate(
        health: BridgeEngine.CaptureHealth, source: CaptureSource, runningFor: TimeInterval
    ) -> CaptureAlert? {
        let pane: SystemSettingsPane =
            source == .inputDevice ? .microphone : .systemAudioCapture
        let permissionName =
            source == .inputDevice ? "« Microphone »" : "« sons du système »"

        if health.diagnosis != .notRunning {
            switch health.permission {
            case .denied?, .restricted?, .notDetermined?:
                return CaptureAlert(
                    severity: .critical,
                    title: "Autorisation manquante",
                    detail: "Sans l'autorisation \(permissionName), tes enceintes ne reçoivent "
                        + "que du silence.",
                    settingsPane: pane
                )
            case .authorized?, .unknown?, nil:
                break
            }
        }

        switch health.diagnosis {
        case .notRunning, .healthy:
            return nil
        case .waitingForFirstBlock:
            guard runningFor >= firstBlockPatience else { return nil }
            return CaptureAlert(
                severity: .info,
                title: "Aucun son reçu pour l'instant",
                detail: "Lance une lecture. Si rien ne vient, vérifie la sortie son du Mac.",
                settingsPane: nil
            )
        case .stalled:
            return CaptureAlert(
                severity: .warning,
                title: "La capture ne reçoit plus rien",
                detail: health.lastRebuildError
                    ?? "Le périphérique audio a peut-être changé. Nouvel essai en cours.",
                settingsPane: nil
            )
        case .silentWhilePlaying:
            return CaptureAlert(
                severity: .critical,
                title: "Autorisation manquante",
                detail: "Un son joue, mais la capture reste muette : l'autorisation "
                    + "\(permissionName) a sans doute été perdue. Retire-la puis ajoute-la "
                    + "de nouveau.",
                settingsPane: pane
            )
        case .silentNothingPlaying:
            return CaptureAlert(
                severity: .info,
                title: "Rien ne joue",
                detail: "Le son partira vers les enceintes dès qu'une lecture commencera.",
                settingsPane: nil
            )
        case .silentUnknown:
            if source == .inputDevice {
                return CaptureAlert(
                    severity: .info,
                    title: "Aucun signal sur l'entrée",
                    detail: "Vérifie le branchement et le niveau d'entrée dans Réglages Son.",
                    settingsPane: nil
                )
            }
            return CaptureAlert(
                severity: .warning,
                title: "La capture reste silencieuse",
                detail: "Rien ne joue, ou l'autorisation \(permissionName) manque. "
                    + "Impossible de trancher d'ici.",
                settingsPane: pane
            )
        }
    }
}

/// Un échec de démarrage, tel qu'on l'affiche.
struct StartFailure: Equatable {
    let message: String
    let settingsPane: SystemSettingsPane?
}

/// L'état de l'icône de la barre de menus.
///
/// La barre de menus est monochrome : c'est la **forme** qui porte la différence, jamais une
/// couleur.
enum MenuBarStatus: Equatable, CaseIterable {
    case idle
    case connecting
    case streaming
    case trouble

    var glyph: BridgeGlyph.Variant {
        switch self {
        case .idle: .idle
        case .connecting: .connecting
        case .streaming: .streaming
        case .trouble: .trouble
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .idle: "AirPlay Personal Bridge, au repos"
        case .connecting: "AirPlay Personal Bridge, connexion en cours"
        case .streaming: "AirPlay Personal Bridge, en diffusion"
        case .trouble: "AirPlay Personal Bridge, problème à régler"
        }
    }
}

/// Où en est la diffusion, en mots.
struct BridgeStatusSummary: Equatable {
    var title: String
    var detail: String?
    var menuBar: MenuBarStatus
}

extension BridgeStatusSummary {
    /// Résume la situation pour le panneau et l'icône. Une fonction pure : c'est ce qu'on voit en
    /// premier, et chaque combinaison de pannes doit pouvoir s'y vérifier sans matériel.
    static func make(
        phase: BridgeState.StreamingPhase,
        isRestarting: Bool,
        selection: [(isEnabled: Bool, connection: OutputConnectionState)],
        sourceLabel: String,
        alert: CaptureAlert?,
        startFailure: StartFailure?
    ) -> BridgeStatusSummary {
        if isRestarting {
            return BridgeStatusSummary(
                title: "Relance de la diffusion…", detail: sourceLabel, menuBar: .connecting
            )
        }
        switch phase {
        case .stopping:
            return BridgeStatusSummary(title: "Arrêt…", detail: nil, menuBar: .connecting)
        case .starting:
            return BridgeStatusSummary(
                title: "Démarrage…", detail: sourceLabel, menuBar: .connecting
            )
        case .idle:
            if startFailure != nil {
                return BridgeStatusSummary(
                    title: "Démarrage impossible", detail: nil, menuBar: .trouble
                )
            }
            let checked = selection.count(where: \.isEnabled)
            return BridgeStatusSummary(
                title: "Au repos",
                detail: checked == 0
                    ? "Aucune enceinte cochée"
                    : "\(checked) \(speakers(checked)) \(checked > 1 ? "cochées" : "cochée")",
                menuBar: .idle
            )
        case .running:
            break
        }

        let active = selection.filter(\.isEnabled).map(\.connection)
        guard !active.isEmpty else {
            return BridgeStatusSummary(
                title: "Plus aucune enceinte",
                detail: "La diffusion s'arrête dans un instant.",
                menuBar: .connecting
            )
        }

        let streaming = active.count(where: { $0 == .streaming })
        let failed = active.count(where: \.isFailure)
        let pending = active.count - streaming - failed

        var notes: [String] = []
        if failed > 0 { notes.append("\(failed) en panne") }
        if pending > 0 { notes.append("\(pending) en attente") }
        let needsAttention = failed > 0 || alert?.severity == .critical

        if streaming > 0 {
            return BridgeStatusSummary(
                title: "Diffusion vers \(streaming) \(speakers(streaming))",
                detail: notes.isEmpty ? sourceLabel : notes.joined(separator: ", "),
                menuBar: needsAttention ? .trouble : .streaming
            )
        }
        if pending > 0 {
            return BridgeStatusSummary(
                title: "Connexion…",
                detail: failed > 0 ? "\(failed) en panne" : sourceLabel,
                menuBar: needsAttention ? .trouble : .connecting
            )
        }
        return BridgeStatusSummary(
            title: "En panne",
            detail: failed > 1 ? "Aucune enceinte ne répond." : "L'enceinte ne répond pas.",
            menuBar: .trouble
        )
    }

    private static func speakers(_ count: Int) -> String {
        count > 1 ? "enceintes" : "enceinte"
    }
}
