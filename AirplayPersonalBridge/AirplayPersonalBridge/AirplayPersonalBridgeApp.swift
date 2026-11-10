//
//  AirplayPersonalBridgeApp.swift
//  AirplayPersonalBridge
//
//  Created by baptiste on 07/08/2026.
//

import SwiftUI

/// Le point d'entrée, réduit aux scènes : toute la logique vit dans `AppLifecycle`, que `swift build`
/// compile et que `swift test` couvre. Ce fichier n'appartient qu'à la cible Xcode.
@main
struct AirplayPersonalBridgeApp: App {
    @NSApplicationDelegateAdaptor(AppLifecycle.self) private var lifecycle

    init() {
        TerminationSignal.install()
    }

    var body: some Scene {
        Window("AirPlay Personal Bridge", id: MainWindow.id) {
            MainWindowContent(lifecycle: lifecycle)
        }
        .defaultLaunchBehavior(.presented)
        // Pas de barre de titre visible : les vues mettent leurs commandes en verre par-dessus le fond, et
        // les boutons système sont masqués, remplacés par `WindowControls`.
        .windowStyle(.hiddenTitleBar)
        // Assez large pour la barre latérale, le plan et ses outils sans débordement de la barre d'outils.
        .defaultSize(width: 1200, height: 760)
        // La fenêtre s'ouvre selon la façon dont l'app est lancée, pas selon qu'elle l'était au
        // dernier arrêt : sans cela, l'avoir fermée une fois la ferait disparaître au lancement.
        .restorationBehavior(.disabled)

        // Les réglages de l'app (⌘,) : la vue de la fenêtre, et ce qui y est masqué.
        Settings {
            SettingsWindowContent(lifecycle: lifecycle)
        }

        MenuBarExtra {
            MenuBarPanel(lifecycle: lifecycle)
        } label: {
            MenuBarLabel(state: lifecycle.state)
        }
        .menuBarExtraStyle(.window)
    }
}
