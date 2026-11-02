//
//  MenuBarPanel.swift
//  AirplayPersonalBridge
//

import AppKit
import AudioCore
import SwiftUI

/// L'icône de la barre de menus. La barre est monochrome : seule la forme dit où on en est.
struct MenuBarLabel: View {
    let state: BridgeState

    var body: some View {
        let status = state.status.menuBar
        Image(nsImage: MenuBarGlyphImage.image(for: status.glyph))
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

/// Ce que le rendu hors écran force, faute de souris : le panneau réel ne s'en sert jamais.
struct PanelPreviewOptions {
    var expandsOptions = false
    var hoveredSpeakerID: String?
    var showsVolumeValue = false
    /// L'enceinte dont le tiroir est déplié.
    var openDrawerSpeakerID: String?
}

/// Le contenu du panneau : d'un coup d'œil, ce qui joue et où ; d'un clic, jouer ailleurs.
///
/// Le modèle est le module Son du Centre de contrôle et le sélecteur de sortie audio de macOS, pas un
/// tableau de bord. D'où trois partis pris : **aucun fond maison**, le panneau hérite du matériau de
/// `MenuBarExtra` et tout s'y pose en couleurs sémantiques ; des **rangées plutôt que des cases**, où
/// c'est la pastille qui dit qu'une enceinte est retenue ; et **le reste en retrait**, derrière une
/// section repliable. Les réglages fins (délai, plan) restent dans la fenêtre ; les basses de la Geneva
/// ont leur tiroir sous sa rangée, parce qu'elles se retouchent en écoutant.
///
/// Ce qui est propre au widget vit dans ses fichiers (`PanelControls`, `PanelSpeakerRow`,
/// `MenuBarGlyph`) : le thème de `DesignSystem` sert à la fenêtre principale.
struct MenuBarPanelContent: View {
    @Bindable var state: BridgeState
    let loginItem: LoginItemController
    var actions: MenuBarPanelActions

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isOptionsExpanded: Bool
    /// Un seul tiroir ouvert à la fois : le panneau reste court.
    @State private var openDrawerSpeakerID: String?
    private let previewOptions: PanelPreviewOptions

    /// Au-delà, la liste défile plutôt que de pousser le panneau hors de l'écran.
    private let maximumRowsWithoutScrolling = 6

    init(
        state: BridgeState, loginItem: LoginItemController,
        actions: MenuBarPanelActions = MenuBarPanelActions(),
        preview: PanelPreviewOptions = PanelPreviewOptions()
    ) {
        self.state = state
        self.loginItem = loginItem
        self.actions = actions
        self.previewOptions = preview
        // Un message de l'ouverture de session demande une action : il ne doit pas rester caché.
        _isOptionsExpanded = State(initialValue: preview.expandsOptions || loginItem.message != nil)
        _openDrawerSpeakerID = State(initialValue: preview.openDrawerSpeakerID)
    }

    /// Un son passe vraiment vers les enceintes : la capture ne signale rien, et le silence n'est pas
    /// mis. Sinon, rien dans le panneau ne bouge comme si un son passait.
    private var isAudible: Bool {
        state.captureAlert == nil && !state.isMuted
    }

    var body: some View {
        GlassEffectContainer(spacing: 8) {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 12) {
                    header
                    notices
                    master
                }
                .padding(.horizontal, PanelMetrics.margin)
                .padding(.top, PanelMetrics.margin)
                .padding(.bottom, 10)

                speakers
                listeningPlace
                PanelSeparator()
                options
                PanelSeparator()
                footer
            }
        }
        .frame(width: PanelMetrics.width)
        .background(alignment: .top) { streamingWash }
    }

    /// La diffusion se sent dans tout le panneau, sans rien y ajouter : une lueur de la couleur
    /// d'accent qui descend du haut et s'éteint avant les enceintes.
    private var streamingWash: some View {
        LinearGradient(
            colors: [Color.accentColor.opacity(0.2), Color.accentColor.opacity(0)],
            startPoint: .top, endPoint: .bottom
        )
        .frame(height: 120)
        .opacity(state.status.menuBar == .streaming ? 1 : 0)
        .animation(PanelMotion.standard(reduceMotion: reduceMotion), value: state.status.menuBar)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    // MARK: - En-tête : l'état et la commande

    private var header: some View {
        let status = state.status
        return HStack(spacing: PanelMetrics.columnGap) {
            PanelStatusChip(status: status.menuBar, isAudible: isAudible)
            VStack(alignment: .leading, spacing: 0) {
                Text(status.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.9)
                if let detail = status.detail {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            // Pas de `Spacer` ici : il compterait deux fois l'espacement de la pile, soit les 20 pt
            // qui manquent pour écrire « Diffusion vers 3 enceintes » en entier.
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            command
        }
    }

    /// Pendant une transition, la commande garde son nom et sa largeur : un témoin remplace son icône.
    /// C'est le titre de l'en-tête qui dit « Démarrage… », pas la peine de le répéter à côté.
    private var command: some View {
        let isStopSide = state.streamingPhase == .running || state.streamingPhase == .stopping
        let isTransition = state.streamingPhase == .starting || state.streamingPhase == .stopping
        return Button {
            state.toggleStreaming()
        } label: {
            HStack(spacing: 5) {
                Group {
                    if isTransition {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: isStopSide ? "stop.fill" : "play.fill")
                            .font(.system(size: 10, weight: .semibold))
                    }
                }
                .frame(width: 12, height: 12)
                Text(isStopSide ? "Arrêter" : "Diffuser")
            }
            // La largeur du mot le plus long : le titre à côté ne se décale pas au changement d'état.
            .frame(minWidth: 64)
        }
        .buttonStyle(PanelCommandButtonStyle(tint: isStopSide ? nil : .accentColor))
        .disabled(!state.canToggleStreaming)
        .fixedSize()
        .accessibilityLabel(isStopSide ? "Arrêter la diffusion" : "Lancer la diffusion")
    }

    @ViewBuilder
    private var notices: some View {
        if let failure = state.startFailure {
            // Le titre de l'en-tête dit déjà « Démarrage impossible » : l'alerte dit pourquoi.
            PanelNotice(
                severity: .critical, title: failure.message,
                actionTitle: failure.settingsPane == nil ? nil : "Ouvrir les Réglages…",
                action: { failure.settingsPane?.open() }
            )
        }
        if let alert = state.captureAlert {
            PanelNotice(
                severity: alert.severity, title: alert.title, detail: alert.detail,
                actionTitle: alert.settingsPane == nil ? nil : "Ouvrir les Réglages…",
                action: { alert.settingsPane?.open() }
            )
        }
    }

    // MARK: - Volume master et silence

    /// Le bouton de silence au bout du curseur, sur le bord droit commun au bouton Diffuser et aux
    /// chevrons des rangées. Coupé, le curseur reste en place et dit « Son coupé » ; le pousser
    /// rétablit le son.
    private var master: some View {
        HStack(spacing: 8) {
            PanelVolumeSlider(
                decibels: $state.masterVolumeDB, isMuted: $state.isMuted,
                range: BridgeSettings.Limits.masterDB,
                showsValue: previewOptions.showsVolumeValue
            )
            PanelMuteButton(isMuted: $state.isMuted)
        }
    }

    // MARK: - Les enceintes

    private var speakers: some View {
        VStack(alignment: .leading, spacing: 2) {
            speakersTitle
            if state.outputs.isEmpty {
                emptySpeakers
            } else if state.outputs.count > maximumRowsWithoutScrolling {
                ScrollView { speakerRows }.frame(height: 256)
            } else {
                speakerRows
            }
        }
        .padding(.bottom, 8)
    }

    private var speakersTitle: some View {
        HStack(spacing: 6) {
            PanelSectionTitle(title: "Enceintes")
            Spacer()
            // Le même cadre avec ou sans le témoin : la recherche revient régulièrement, et la ligne
            // ne doit pas tressauter à chaque fois. Liste vide, c'est elle qui dit qu'on cherche.
            Group {
                if state.isBrowsing {
                    if !state.outputs.isEmpty { ProgressView().controlSize(.mini) }
                } else {
                    Button {
                        Task { await state.refreshOutputs() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(width: 20, height: 20)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Rechercher sur le réseau local")
                    .accessibilityLabel("Rechercher les enceintes")
                }
            }
            .frame(width: 20, height: 20)
        }
        .padding(.horizontal, PanelMetrics.margin)
    }

    private var speakerRows: some View {
        let reservesDrawerColumn = state.outputs.contains(where: \.supportsBassBoost)
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(PanelSpeakerOrder.sorted(state.outputs)) { output in
                PanelSpeakerRow(
                    output: output, isAudible: isAudible,
                    reservesDrawerColumn: reservesDrawerColumn,
                    isDrawerOpen: drawerBinding(for: output.id),
                    previewHovering: previewOptions.hoveredSpeakerID == output.id
                )
            }
        }
        .padding(.horizontal, PanelMetrics.rowInset)
    }

    private func drawerBinding(for id: String) -> Binding<Bool> {
        Binding(
            get: { openDrawerSpeakerID == id },
            set: { isOpen in
                if isOpen {
                    openDrawerSpeakerID = id
                } else if openDrawerSpeakerID == id {
                    openDrawerSpeakerID = nil
                }
            }
        )
    }

    private var emptySpeakers: some View {
        VStack(spacing: 4) {
            if state.isBrowsing || !state.hasCompletedDiscovery {
                ProgressView()
                    .controlSize(.small)
                    .padding(.bottom, 6)
                Text("Recherche des enceintes…")
                    .font(.system(size: 13, weight: .medium))
                Text("Elles apparaîtront ici dès qu'elles répondront.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            } else {
                // `hifispeaker.slash` n'existe pas : un nom inconnu n'affiche rien, sans la moindre erreur.
                Image(systemName: "hifispeaker")
                    .font(.system(size: 20, weight: .light))
                    .foregroundStyle(.tertiary)
                    .padding(.bottom, 4)
                Text("Aucune enceinte trouvée")
                    .font(.system(size: 13, weight: .medium))
                if let notice = state.discoveryNotice {
                    Text(notice)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 12) {
                    Button("Rechercher") { Task { await state.refreshOutputs() } }
                    Button("Réseau local…") { SystemSettingsPane.localNetwork.open() }
                }
                .buttonStyle(.link)
                .font(.system(size: 11, weight: .medium))
                .padding(.top, 6)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, PanelMetrics.margin + 8)
        .padding(.vertical, 12)
    }

    // MARK: - Écoute

    /// Visible à partir de deux lieux : avec un seul, il n'y aurait rien à choisir.
    @ViewBuilder
    private var listeningPlace: some View {
        let places = state.roomLayout.listeners
        if places.count >= 2, let active = state.roomLayout.listener {
            PanelSeparator()
            HStack(spacing: 8) {
                Text("Écoute").font(.system(size: 13))
                Spacer(minLength: 4)
                Picker(
                    "Lieu d'écoute",
                    selection: Binding(
                        get: { active.id },
                        set: { state.selectListeningPlace(id: $0) }
                    )
                ) {
                    ForEach(places) { place in
                        Text(place.name.isEmpty ? place.kind.label : place.name).tag(place.id)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            .padding(.horizontal, PanelMetrics.margin)
            .padding(.vertical, 8)
            .help("Recale les enceintes pour ce lieu, sans couper le son.")
        }
    }

    // MARK: - Options, en retrait

    private var options: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(PanelMotion.standard(reduceMotion: reduceMotion)) {
                    isOptionsExpanded.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Text("Options")
                    Spacer(minLength: 4)
                    if !isOptionsExpanded {
                        Text(state.selectedSource.label)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isOptionsExpanded ? 90 : 0))
                }
            }
            .buttonStyle(PanelMenuRowStyle())
            .accessibilityLabel("Options")
            .accessibilityValue(isOptionsExpanded ? "dépliées" : "repliées")
            .padding(.horizontal, PanelMetrics.rowInset)

            if isOptionsExpanded {
                optionRows
                    .padding(.horizontal, PanelMetrics.margin)
                    .padding(.vertical, 4)
                    .transition(.opacity)
            }
        }
        .padding(.vertical, 4)
    }

    private var optionRows: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Source").font(.system(size: 12))
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
                        .font(.system(size: 12))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Pendant une diffusion, changer de source la relance.")
            }

            // À ne pas confondre avec le bouton de silence, en haut, qui coupe les enceintes : celle-ci
            // éteint la sortie du Mac, et les enceintes continuent de jouer.
            PanelOptionToggle(
                title: "Couper le son du Mac",
                detail: "Les enceintes continuent de jouer.",
                isOn: $state.muteLocalOutput
            )
            .disabled(state.selectedSource.tapMode == nil)
            .help(
                "Éteint la sortie de ce Mac pendant la capture du son système ou d'une application. "
                    + "Pendant une diffusion, le changer la relance."
            )

            PanelOptionToggle(
                title: "Démarrer à l'ouverture de session",
                isOn: Binding(
                    get: { loginItem.isOn },
                    set: { loginItem.setEnabled($0) }
                )
            )

            if let message = loginItem.message {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(message)
                        .font(.system(size: 11))
                        .foregroundStyle(PanelPalette.warningText)
                        .fixedSize(horizontal: false, vertical: true)
                    if loginItem.needsApproval {
                        Spacer(minLength: 0)
                        Button("Ouvrir…") { loginItem.openSystemSettings() }
                            .buttonStyle(.link)
                            .font(.system(size: 11, weight: .medium))
                    }
                }
            }
        }
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
        VStack(alignment: .leading, spacing: 0) {
            Button("Plan et réglages…", action: actions.openMainWindow)
            Button("Quitter", action: actions.quit)
        }
        .buttonStyle(PanelMenuRowStyle())
        .padding(.horizontal, PanelMetrics.rowInset)
        .padding(.vertical, 4)
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
