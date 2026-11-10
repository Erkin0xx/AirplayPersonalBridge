//
//  MenuBarPanel.swift
//  AirplayPersonalBridge
//

import AppKit
import AudioCore
import SwiftUI

/// L'icône de la barre de menus. La barre est monochrome : seule la forme dit où on en est, et la
/// vague qu'un son passe.
struct MenuBarLabel: View {
    let state: BridgeState

    var body: some View {
        let status = state.status.menuBar
        MenuBarGlyphLabel(status: status, isAudible: Self.isAudible(state))
            .accessibilityLabel(status.accessibilityLabel)
    }

    /// La règle de `MenuBarPanelContent.isAudible` : l'icône s'immobilise avec le panneau.
    static func isAudible(_ state: BridgeState) -> Bool {
        state.captureAlert == nil && !state.isMuted
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
    @Environment(\.openSettings) private var openSettings
    @State private var openings = 0

    var body: some View {
        MenuBarPanelContent(
            state: lifecycle.state,
            loginItem: lifecycle.loginItem,
            actions: MenuBarPanelActions(
                openMainWindow: {
                    lifecycle.showMainWindow { openWindow(id: MainWindow.id) }
                },
                openSettings: {
                    lifecycle.showSettingsWindow { openSettings() }
                },
                quit: { NSApplication.shared.terminate(nil) }
            ),
            panelOpenings: openings
        )
        .background(
            PanelOpenObserver {
                lifecycle.panelDidOpen()
                openings += 1
            }
        )
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
    /// La fenêtre Réglages de l'app : là où se réaffiche ce qui est masqué.
    var openSettings: () -> Void = {}
    var quit: () -> Void = {}
}

/// Ce que le rendu hors écran force, faute de souris : le panneau réel ne s'en sert jamais.
struct PanelPreviewOptions {
    /// La fenêtre surgissante des options, ouverte.
    var presentsOptions = false
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
/// c'est la pastille qui dit qu'une enceinte est retenue ; et **le reste en retrait**, dans une
/// fenêtre surgissante (`PanelPopup`) : le panneau ne grandit pas pour montrer ses options. Les
/// réglages fins (délai, plan) restent dans la fenêtre principale ; les basses et les aigus de la
/// Geneva ont leur tiroir sous sa rangée, parce qu'ils se retouchent en écoutant.
///
/// Ce qui est propre au widget vit dans ses fichiers (`PanelControls`, `PanelSpeakerRow`,
/// `MenuBarGlyph`). La fenêtre principale en reprend une partie, pour que les deux se ressemblent : la
/// pastille d'état, les alertes, le bouton de silence, les options, et le message d'une enceinte
/// (`OutputStatusMessage`). Tout s'écrit en styles de texte du système.
struct MenuBarPanelContent: View {
    @Bindable var state: BridgeState
    let loginItem: LoginItemController
    var actions: MenuBarPanelActions
    /// Le nombre d'ouvertures du panneau : à chacune, il se présente sans sa fenêtre surgissante,
    /// comme un popover du système ne survit pas à la fermeture de sa fenêtre.
    var panelOpenings = 0

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isOptionsPresented: Bool
    /// Un seul tiroir ouvert à la fois : le panneau reste court.
    @State private var openDrawerSpeakerID: String?
    private let previewOptions: PanelPreviewOptions

    /// Au-delà, la liste défile plutôt que de pousser le panneau hors de l'écran.
    private let maximumRowsWithoutScrolling = 6

    init(
        state: BridgeState, loginItem: LoginItemController,
        actions: MenuBarPanelActions = MenuBarPanelActions(),
        panelOpenings: Int = 0,
        preview: PanelPreviewOptions = PanelPreviewOptions()
    ) {
        self.state = state
        self.loginItem = loginItem
        self.actions = actions
        self.panelOpenings = panelOpenings
        self.previewOptions = preview
        _isOptionsPresented = State(initialValue: preview.presentsOptions)
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
        // Hors du conteneur de verre : la carte ne doit pas se fondre dans le bouton de l'en-tête.
        .panelPopup("Options", isPresented: $isOptionsPresented) { optionRows }
        .onChange(of: panelOpenings) { isOptionsPresented = false }
        // L'accent de l'app, pour les contrôles du système aussi (interrupteurs, menus).
        .tint(BridgeTheme.accent)
        .containerShape(.rect(cornerRadius: PanelMetrics.panelRadius))
        .background(alignment: .top) { streamingWash }
    }

    /// La diffusion se sent dans tout le panneau, sans rien y ajouter : une lueur de la couleur
    /// d'accent qui descend du haut et s'éteint avant les enceintes.
    private var streamingWash: some View {
        LinearGradient(
            colors: [BridgeTheme.accent.opacity(0.2), BridgeTheme.accent.opacity(0)],
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
                    .font(.headline)
                    .lineLimit(1)
                    .minimumScaleFactor(0.9)
                if let detail = status.detail {
                    Text(detail)
                        .font(.subheadline)
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
                            .font(.caption.weight(.semibold))
                    }
                }
                .frame(width: 12, height: 12)
                Text(isStopSide ? "Arrêter" : "Diffuser")
            }
            // La largeur du mot le plus long : le titre à côté ne se décale pas au changement d'état.
            .frame(minWidth: 64)
        }
        .buttonStyle(PanelCommandButtonStyle(tint: isStopSide ? nil : BridgeTheme.accent))
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
            } else if state.hidesEverySpeaker {
                allSpeakersHidden
            } else if state.visibleOutputs.count > maximumRowsWithoutScrolling {
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
                            .font(.subheadline.weight(.medium))
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
        // Une enceinte masquée dans la fenêtre l'est ici aussi : elle joue toujours si elle est cochée.
        let visible = state.visibleOutputs
        let reservesDrawerColumn = visible.contains(where: \.supportsToneControl)
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(PanelSpeakerOrder.sorted(visible)) { output in
                PanelSpeakerRow(
                    output: output, isAudible: isAudible,
                    reservesDrawerColumn: reservesDrawerColumn,
                    stereoPartnerNames: state.stereoPartners(of: output).map(\.displayName),
                    isDrawerOpen: drawerBinding(for: output.id),
                    previewHovering: previewOptions.hoveredSpeakerID == output.id
                ) { state.toggleEnabled(output) }
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

    /// Des enceintes sont là, toutes masquées : « aucune enceinte trouvée » serait faux.
    private var allSpeakersHidden: some View {
        VStack(spacing: 4) {
            Text("Toutes les enceintes sont masquées")
                .font(.body.weight(.medium))
            Text("Celles qui sont cochées continuent de jouer.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button("Réglages…", action: actions.openSettings)
                .buttonStyle(.link)
                .font(.subheadline.weight(.medium))
                .padding(.top, 6)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, PanelMetrics.margin + 8)
        .padding(.vertical, 12)
    }

    private var emptySpeakers: some View {
        VStack(spacing: 4) {
            if state.isBrowsing || !state.hasCompletedDiscovery {
                ProgressView()
                    .controlSize(.small)
                    .padding(.bottom, 6)
                Text("Recherche des enceintes…")
                    .font(.body.weight(.medium))
                Text("Elles apparaîtront ici dès qu'elles répondront.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            } else {
                // `hifispeaker.slash` n'existe pas : un nom inconnu n'affiche rien, sans la moindre erreur.
                Image(systemName: "hifispeaker")
                    .font(.title2.weight(.light))
                    .foregroundStyle(.tertiary)
                    .padding(.bottom, 4)
                Text("Aucune enceinte trouvée")
                    .font(.body.weight(.medium))
                if let notice = state.discoveryNotice {
                    Text(notice)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 12) {
                    Button("Rechercher") { Task { await state.refreshOutputs() } }
                    Button("Réseau local…") { SystemSettingsPane.localNetwork.open() }
                }
                .buttonStyle(.link)
                .font(.subheadline.weight(.medium))
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
                Text("Écoute").font(.body)
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

    /// La rangée ouvre les options dans une fenêtre surgissante, au-dessus d'elle : le panneau garde sa
    /// taille. Elle rappelle la source en cours, et signale un message qui attend dans les options.
    private var options: some View {
        Button {
            withAnimation(PanelMotion.popup(reduceMotion: reduceMotion)) {
                isOptionsPresented.toggle()
            }
        } label: {
            HStack(spacing: 6) {
                Text("Options")
                Spacer(minLength: 4)
                // Un message de l'ouverture de session demande une action : il ne doit pas rester caché
                // derrière la rangée.
                if loginItem.message != nil {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
                Text(state.selectedSource.label)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                // Fixe : la rangée ouvre une fenêtre, elle ne se déplie pas.
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(PanelMenuRowStyle(isActive: isOptionsPresented))
        .panelPopupAnchor()
        .accessibilityLabel("Options")
        .accessibilityValue(optionsAccessibilityValue)
        .accessibilityHint("Ouvre les options dans une fenêtre surgissante.")
        .padding(.horizontal, PanelMetrics.rowInset)
        .padding(.vertical, 4)
    }

    private var optionsAccessibilityValue: String {
        let source = "Source : \(state.selectedSource.label)"
        guard let message = loginItem.message else { return source }
        return "\(source). \(message)"
    }

    private var optionRows: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Source").font(.callout)
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
                        .font(.callout)
                }
                .menuStyle(.borderlessButton)
                // Blanc : le rose de l'app est réservé à l'état, pas aux commandes.
                .tint(.primary)
                .fixedSize()
                .help("Pendant une diffusion, changer de source la relance.")
            }

            if let awaited = state.awaitedSourceName {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("Passera sur \(awaited) dès que cette application jouera.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    Button("Annuler", action: state.forgetAwaitedSource)
                        .buttonStyle(.borderless)
                        .font(.subheadline)
                }
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

            PanelSystemVolumeOption(state: state)

            PanelVideoSyncOption(state: state)

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
                        .font(.subheadline)
                        .foregroundStyle(PanelPalette.warningText)
                        .fixedSize(horizontal: false, vertical: true)
                    if loginItem.needsApproval {
                        Spacer(minLength: 0)
                        Button("Ouvrir…") { loginItem.openSystemSettings() }
                            .buttonStyle(.link)
                            .font(.subheadline.weight(.medium))
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
            Button("Ouvrir la fenêtre…", action: actions.openMainWindow)
            // La fenêtre Réglages de l'app (⌘,) : la vue, et ce qui est masqué.
            Button(action: actions.openSettings) {
                HStack(spacing: 6) {
                    Text("Réglages…")
                    Spacer(minLength: 4)
                    if let summary = HiddenElementsCopy.summary(speakers: state.hiddenOutputCount, blocks: 0) {
                        Text(summary)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
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
