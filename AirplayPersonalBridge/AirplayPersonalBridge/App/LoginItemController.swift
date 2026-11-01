//
//  LoginItemController.swift
//  AirplayPersonalBridge
//

import AudioCore
import Foundation
import OSLog
import ServiceManagement

private let loginItemLog = Logger(subsystem: AudioLog.subsystem, category: "login-item")

enum LoginItemStatus: Equatable {
    case disabled
    case enabled
    /// Inscrit, mais l'utilisateur doit encore l'autoriser dans Réglages Système.
    case requiresApproval
}

/// L'inscription au démarrage de session. Injecté : un test n'a pas à inscrire quoi que ce soit.
protocol LoginItemService {
    var status: LoginItemStatus { get }
    func register() throws
    func unregister() throws
    func openSystemSettings()
}

struct SMAppLoginItemService: LoginItemService {
    var status: LoginItemStatus {
        switch SMAppService.mainApp.status {
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        // `notFound` : macOS ne connaît pas (encore) cette app comme élément d'ouverture, ce qui
        // n'est une erreur que si l'inscription échoue, et elle le dira alors.
        case .notRegistered, .notFound: .disabled
        @unknown default: .disabled
        }
    }

    func register() throws { try SMAppService.mainApp.register() }
    func unregister() throws { try SMAppService.mainApp.unregister() }
    func openSystemSettings() { SMAppService.openSystemSettingsLoginItems() }
}

/// « Démarrer à l'ouverture de session ».
///
/// Le bouton reflète ce que le système dit, jamais ce qu'on lui a demandé : macOS peut retenir
/// l'inscription en attente d'approbation, et l'utilisateur peut la retirer dans ses Réglages.
@Observable
final class LoginItemController {
    @ObservationIgnored private let service: any LoginItemService
    private(set) var status: LoginItemStatus
    /// Pourquoi la dernière demande a échoué.
    private(set) var failureMessage: String?

    init(service: any LoginItemService = SMAppLoginItemService()) {
        self.service = service
        self.status = service.status
    }

    /// Le bouton est coché dès que l'inscription existe, même en attente d'approbation : le
    /// message d'approbation dit alors ce qu'il reste à faire.
    var isOn: Bool { status != .disabled }

    var message: String? {
        if let failureMessage { return failureMessage }
        if status == .requiresApproval {
            return "À autoriser dans Réglages Système, section Ouverture."
        }
        return nil
    }

    var needsApproval: Bool { status == .requiresApproval }

    /// À appeler à l'ouverture du panneau : l'approbation se donne hors de l'app.
    func refresh() {
        let current = service.status
        if current != status { status = current }
    }

    func setEnabled(_ enabled: Bool) {
        failureMessage = nil
        do {
            if enabled {
                try service.register()
            } else {
                try service.unregister()
            }
        } catch {
            loginItemLog.error(
                "Démarrage à l'ouverture de session : \(error.localizedDescription, privacy: .public)"
            )
            status = service.status
            // Une inscription retenue pour approbation lève aussi une erreur : ce n'est pas un
            // échec, le message d'approbation dit mieux ce qu'il reste à faire.
            if status != .requiresApproval {
                failureMessage = "Réglage refusé par macOS : \(error.localizedDescription)"
            }
            return
        }
        status = service.status
    }

    func openSystemSettings() {
        service.openSystemSettings()
    }
}
