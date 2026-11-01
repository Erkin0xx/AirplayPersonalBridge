//
//  MenuBarPanel.swift
//  AirplayPersonalBridge
//

import AppKit
import AudioCore
import SwiftUI

/// L'icône de la barre de menus. La barre est monochrome : seul le symbole dit où on en est.
struct MenuBarLabel: View {
    let state: BridgeState

    var body: some View {
        let status = state.status.menuBar
        Image(systemName: status.symbolName)
            .accessibilityLabel(status.accessibilityLabel)
    }
}

extension SystemSettingsPane {
    func open() {
        guard let url else { return }
        NSWorkspace.shared.open(url)
    }
}

/// Le panneau tel que la scène l'affiche : le contenu, plus ce qui dépend d'une vraie fenêtre.
struct MenuBarPanel: View {
    let lifecycle: AppLifecycle
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        MenuBarPanelContent(
            state: lifecycle.state,
            loginItem: lifecycle.loginItem,
            actions: MenuBarPanelActions(
                openMainWindow: {
                    lifecycle.showMainWindow { openWindow(id: MainWindow.id) }
                },
                quit: { NSApplication.shared.terminate(nil) }
            )
        )
        .background(PanelOpenObserver { lifecycle.panelDidOpen() })
    }
}

/// Signale chaque ouverture du panneau.
///
/// Par la clé de la fenêtre plutôt que par `onAppear` : le contenu d'un `MenuBarExtra` peut rester
/// en vie d'une ouverture à l'autre, et `onAppear` ne se rejouerait alors pas.
private struct PanelOpenObserver: NSViewRepresentable {
    let onOpen: () -> Void

    func makeNSView(context: Context) -> ObserverView {
        ObserverView(onOpen: onOpen)
    }

    func updateNSView(_ view: ObserverView, context: Context) {
        view.onOpen = onOpen
    }

    final class ObserverView: NSView {
        var onOpen: () -> Void
        private var observer: (any NSObjectProtocol)?

        init(onOpen: @escaping () -> Void) {
            self.onOpen = onOpen
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("Cette vue n'est créée que par SwiftUI")
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            guard let window else { return }
            observer = NotificationCenter.default.addObserver(
                forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.onOpen() }
            }
            // Au tour suivant : on est ici en pleine mise à jour des vues, où changer l'état
            // qu'elles observent n'est pas permis.
            Task { [weak self] in self?.onOpen() }
        }
    }
}

/// Ce que le panneau demande à l'app. Injecté pour le rendre hors de toute scène.
struct MenuBarPanelActions {
    var openMainWindow: () -> Void = {}
    var quit: () -> Void = {}
}

/// Le contenu du panneau : d'un coup d'œil, ce qui joue et où ; d'un clic, jouer ailleurs.
///
/// Le geste principal est celui du menu AirPlay de macOS : cocher une enceinte, et ça joue dessus.
/// Tout le reste s'efface devant lui. Les réglages fins (délai, basses, plan) restent dans la
/// fenêtre, à laquelle le pied du panneau donne accès.
struct MenuBarPanelContent: View {
    @Bindable var state: BridgeState
    let loginItem: LoginItemController
    var actions = MenuBarPanelActions()

    /// Au-delà, la liste défile plutôt que de pousser le panneau hors de l'écran.
    private let maximumRowsWithoutScrolling = 6
    private let contentPadding: CGFloat = 12

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ShadSeparator()
            speakers
            ShadSeparator()
            controls
            ShadSeparator()
            footer
        }
        .frame(width: 320)
        .background(Theme.background)
    }

    // MARK: - En-tête : l'état, et le grand bouton

    private var header: some View {
        let status = state.status
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 9) {
                Image(systemName: status.menuBar.symbolName)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(tint(for: status.menuBar))
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(status.title)
                        .font(Theme.Font.title)
                        .foregroundStyle(Theme.foreground)
                    if let detail = status.detail {
                        Text(detail).shadMuted().lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }

            Button {
                state.toggleStreaming()
            } label: {
                Label(primaryActionTitle, systemImage: state.isStreaming ? "stop.fill" : "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .shadButton(state.isStreaming ? .destructive : .primary, size: .large)
            .disabled(!state.canToggleStreaming)

            if let failure = state.startFailure {
                // Le titre de l'en-tête dit déjà « Démarrage impossible » : le bandeau dit pourquoi.
                NoticeBanner(
                    severity: .critical, title: failure.message, detail: nil,
                    actionTitle: failure.settingsPane == nil ? nil : "Ouvrir les Réglages",
                    action: { failure.settingsPane?.open() }
                )
            }
            if let alert = state.captureAlert {
                NoticeBanner(
                    severity: alert.severity, title: alert.title, detail: alert.detail,
                    actionTitle: alert.settingsPane == nil ? nil : "Ouvrir les Réglages",
                    action: { alert.settingsPane?.open() }
                )
            }
        }
        .padding(contentPadding)
    }

    private var primaryActionTitle: String {
        switch state.streamingPhase {
        case .idle: "Diffuser"
        case .starting: "Démarrage…"
        case .running: "Arrêter"
        case .stopping: "Arrêt…"
        }
    }

    private func tint(for status: MenuBarStatus) -> Color {
        switch status {
        case .idle: Theme.mutedForeground
        case .connecting: Theme.warning
        case .streaming: Theme.success
        case .trouble: Theme.destructive
        }
    }

    // MARK: - Les enceintes

    private var speakers: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("Enceintes").shadLabel()
                Spacer()
                Button {
                    Task { await state.refreshOutputs() }
                } label: {
                    if state.isBrowsing {
                        Text("Recherche…")
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .accessibilityLabel("Rechercher")
                    }
                }
                .buttonStyle(.plain)
                .font(Theme.Font.tiny)
                .foregroundStyle(Theme.mutedForeground)
                .disabled(state.isBrowsing)
                .help("Rechercher sur le réseau local")
            }

            if state.outputs.isEmpty {
                emptySpeakers
            } else if state.outputs.count > maximumRowsWithoutScrolling {
                ScrollView { speakerRows }.frame(height: 280)
            } else {
                speakerRows
            }
        }
        .padding(contentPadding)
    }

    private var speakerRows: some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach(state.outputs) { output in
                SpeakerRow(output: output)
            }
        }
    }

    private var emptySpeakers: some View {
        VStack(spacing: 7) {
            // `hifispeaker.slash` n'existe pas : un nom inconnu n'affiche rien, sans la moindre erreur.
            Image(systemName: state.isBrowsing ? "antenna.radiowaves.left.and.right" : "hifispeaker")
                .font(.system(size: 22))
                .foregroundStyle(Theme.mutedForeground)
            if state.isBrowsing || !state.hasCompletedDiscovery {
                Text("Recherche des enceintes…").font(Theme.Font.medium)
                Text("Elles apparaîtront ici dès qu'elles répondront.")
                    .shadMuted()
                    .multilineTextAlignment(.center)
            } else {
                Text("Aucune enceinte trouvée").font(Theme.Font.medium)
                if let notice = state.discoveryNotice {
                    Text(notice)
                        .shadMuted()
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 6) {
                    Button("Rechercher") { Task { await state.refreshOutputs() } }
                        .shadButton(.outline, size: .small)
                    Button("Réseau local") { SystemSettingsPane.localNetwork.open() }
                        .shadButton(.ghost, size: .small)
                }
                .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }

    // MARK: - Volume et source

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Button {
                    state.isMuted.toggle()
                } label: {
                    Image(systemName: state.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .font(.system(size: 13))
                        .frame(width: 20, alignment: .leading)
                        .foregroundStyle(state.isMuted ? Theme.destructive : Theme.foreground)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(state.isMuted ? "Rétablir le son" : "Silence")
                .accessibilityLabel("Silence")
                .accessibilityValue(state.isMuted ? "activé" : "désactivé")

                ShadSlider(value: $state.masterVolumeDB, range: BridgeSettings.Limits.masterDB)
                    .opacity(state.isMuted ? 0.4 : 1)
                    .accessibilityLabel("Volume master")

                Text(state.isMuted ? "silence" : String(format: "%.0f dB", state.masterVolumeDB))
                    .font(Theme.Font.small.monospacedDigit())
                    .foregroundStyle(Theme.foreground)
                    .frame(width: 48, alignment: .trailing)
            }

            HStack(spacing: 8) {
                Text("Source").shadMuted()
                Spacer(minLength: 4)
                Menu {
                    Picker("Source", selection: sourceSelection) {
                        ForEach(state.sources) { source in
                            Text(source.label).tag(source.id)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                } label: {
                    Text(state.selectedSource.label)
                        .font(Theme.Font.small)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Pendant une diffusion, changer de source la relance.")
            }

            HStack(spacing: 8) {
                Text("Couper le son du Mac").shadMuted()
                Spacer(minLength: 4)
                ShadSwitch(isOn: $state.muteLocalOutput)
                    .accessibilityLabel("Couper le son du Mac")
            }
            .disabled(state.selectedSource.tapMode == nil)
            .opacity(state.selectedSource.tapMode == nil ? 0.5 : 1)
            .help(
                "Ne s'applique qu'à la capture du son système ou d'une application. "
                    + "Pendant une diffusion, le changer la relance."
            )
        }
        .padding(contentPadding)
    }

    /// Le sélecteur porte des identifiants : les PID d'une application varient d'un relevé à
    /// l'autre, et une valeur complète ne correspondrait plus à aucune entrée de la liste.
    private var sourceSelection: Binding<String> {
        Binding(
            get: { state.selectedSource.id },
            set: { state.selectSource(id: $0) }
        )
    }

    // MARK: - Pied

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Démarrer à l'ouverture de session").shadMuted()
                Spacer(minLength: 4)
                ShadSwitch(
                    isOn: Binding(
                        get: { loginItem.isOn },
                        set: { loginItem.setEnabled($0) }
                    )
                )
                .accessibilityLabel("Démarrer à l'ouverture de session")
            }
            if let message = loginItem.message {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(message)
                        .font(Theme.Font.tiny)
                        .foregroundStyle(Theme.warning)
                        .fixedSize(horizontal: false, vertical: true)
                    if loginItem.needsApproval {
                        Spacer(minLength: 0)
                        Button("Ouvrir") { loginItem.openSystemSettings() }
                            .buttonStyle(.plain)
                            .font(Theme.Font.tiny.weight(.medium))
                            .foregroundStyle(Theme.info)
                    }
                }
            }
            HStack(spacing: 8) {
                Button {
                    actions.openMainWindow()
                } label: {
                    Label("Plan et réglages", systemImage: "macwindow")
                }
                .shadButton(.outline, size: .small)
                Spacer()
                Button("Quitter", action: actions.quit)
                    .shadButton(.ghost, size: .small)
            }
        }
        .padding(contentPadding)
    }
}

/// Une enceinte dans le panneau : on coche, et ça joue dessus.
private struct SpeakerRow: View {
    @Bindable var output: OutputState

    /// Aligne messages et curseur sur le nom, sous la case et la pastille.
    private let textInset: CGFloat = 31

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Button {
                output.isEnabled.toggle()
            } label: {
                HStack(spacing: 8) {
                    ShadCheckboxMark(isOn: output.isEnabled)
                    OutputStatusDot(state: output.connection)
                    Text(output.displayName)
                        .font(Theme.Font.medium)
                        .foregroundStyle(output.isEnabled ? Theme.foreground : Theme.mutedForeground)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Diffuser vers \(output.displayName)")
            .accessibilityValue(output.isEnabled ? "cochée" : "décochée")

            if let line = output.statusLine {
                OutputStatusMessage(text: line.text, tone: line.tone)
                    .padding(.leading, textInset)
            }

            if output.isEnabled {
                HStack(spacing: 8) {
                    ShadSlider(
                        value: $output.trimDB, range: BridgeSettings.Limits.trimDB, step: 0.5,
                        isCompact: true
                    )
                    .accessibilityLabel("Volume de \(output.displayName)")
                    Text(String(format: "%+.1f dB", output.trimDB))
                        .font(Theme.Font.tiny.monospacedDigit())
                        .foregroundStyle(Theme.mutedForeground)
                        .frame(width: 48, alignment: .trailing)
                }
                .padding(.leading, textInset)
                .help("Correction de volume de cette enceinte, en plus du volume master")
            }
        }
    }
}

#Preview("Diffusion") {
    MenuBarPanelContent(
        state: .preview(.streaming),
        loginItem: LoginItemController(service: PreviewLoginItemService())
    )
}

#Preview("Panne") {
    MenuBarPanelContent(
        state: .preview(.trouble),
        loginItem: LoginItemController(service: PreviewLoginItemService())
    )
}

/// Pour les aperçus et le rendu hors écran : aucune inscription réelle.
struct PreviewLoginItemService: LoginItemService {
    var status: LoginItemStatus = .disabled
    func register() throws {}
    func unregister() throws {}
    func openSystemSettings() {}
}
