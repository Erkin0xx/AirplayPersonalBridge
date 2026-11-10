//
//  HiddenElementsViews.swift
//  AirplayPersonalBridge
//

import AppKit
import SwiftUI

/// Ce que les trois vues de la fenêtre partagent pour le masquage (`HiddenElements`) : la commande
/// « Masquer » d'une enceinte, la ligne discrète qui dit ce qui est masqué, et l'ouverture des Réglages.

extension EnvironmentValues {
    /// Les rendus hors écran le posent pour montrer les commandes qui n'apparaissent qu'au survol ; l'app,
    /// jamais.
    @Entry var revealsHoverControls = false
}

/// La fenêtre Réglages de l'app (scène `Settings`, ⌘,).
enum AppSettingsWindow {
    /// L'app d'abord : sans activation, la fenêtre des réglages s'ouvre derrière celle de l'application en
    /// cours. `SettingsWindowContent` la repasse devant une fois rattachée, et montre l'icône du Dock.
    static func open(_ openSettings: OpenSettingsAction) {
        NSApplication.shared.activate()
        openSettings()
    }
}

// MARK: - Masquer une enceinte

/// Le bouton « Masquer » d'une enceinte, qui n'apparaît qu'au survol : un œil barré, gris, jamais rose.
struct HideSpeakerButton: View {
    let name: String
    var partners: [String] = []
    var isEnabled = false
    var diameter: CGFloat = 22
    /// Un fond sous l'œil, pour le bouton posé dans le coin d'une tuile ; sans, pour celui d'une rangée.
    var isFilled = false
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "eye.slash")
                .font(.system(size: diameter * 0.5, weight: .medium))
                .foregroundStyle(Color.white.opacity(isHovering ? 0.9 : 0.6))
                .frame(width: diameter, height: diameter)
                .background(
                    Color.white.opacity(isFilled ? (isHovering ? 0.2 : 0.12) : (isHovering ? 0.12 : 0)),
                    in: Circle()
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(HiddenElementsCopy.hideHelp(name: name, partners: partners, isEnabled: isEnabled))
        .accessibilityLabel(HiddenElementsCopy.hideTitle(partners: partners))
        .accessibilityHint("À réafficher dans les Réglages.")
    }
}

extension View {
    /// Le menu contextuel d'une enceinte : « Masquer », avec sa paire stéréo s'il y en a une. Sans action,
    /// pas de menu.
    @ViewBuilder
    func hideSpeakerMenu(partners: [String], action: (() -> Void)?) -> some View {
        if let action {
            contextMenu {
                Button(action: action) {
                    Label(HiddenElementsCopy.hideTitle(partners: partners), systemImage: "eye.slash")
                }
            }
            // Le survol n'existe pas pour VoiceOver : la même commande, dans les actions de l'élément.
            .accessibilityAction(named: Text(HiddenElementsCopy.hideTitle(partners: partners)), action)
        } else {
            self
        }
    }
}

// MARK: - Ce qui est masqué

/// La ligne discrète d'une vue : « 1 enceinte masquée », qui ouvre les Réglages. Rien quand la vue montre
/// tout.
struct HiddenElementsNote: View {
    let state: BridgeState
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        if let summary = state.hiddenSummary {
            Button {
                AppSettingsWindow.open(openSettings)
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "eye.slash")
                        .accessibilityHidden(true)
                    Text(summary)
                }
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Color.primary.opacity(0.5))
                .lineLimit(1)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Ouvrir les Réglages pour réafficher ce qui est masqué (⌘,)")
            .accessibilityHint("Ouvre les Réglages.")
        }
    }
}

/// Ce qu'une vue dit à la place de ses enceintes quand elles sont toutes masquées : pas « aucune
/// enceinte », qui serait faux.
struct AllSpeakersHiddenNotice: View {
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "eye.slash")
                .font(.title3)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Toutes les enceintes sont masquées")
                    .font(.headline)
                Text("Celles qui sont cochées continuent de jouer.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
            Button("Réglages…") { AppSettingsWindow.open(openSettings) }
                .controlSize(.small)
        }
        .accessibilityElement(children: .contain)
    }
}

/// « Réglages… », en ligne discrète : au pied du panneau des enceintes de la vue Plan.
struct OpenSettingsLink: View {
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Button {
            AppSettingsWindow.open(openSettings)
        } label: {
            Label("Réglages…", systemImage: "gearshape")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Color.primary.opacity(0.6))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Réglages de l'affichage : vue, enceintes et éléments masqués (⌘,)")
    }
}
