//
//  BridgeSidebar.swift
//  AirplayPersonalBridge
//

import SwiftUI

/// La barre latérale de la fenêtre : tout ce qui règle le son, de la source aux sorties.
///
/// Une liste de barre latérale, qui flotte en verre au-dessus du plan : ses rangées n'ont aucun fond
/// propre, et les sections ont les titres discrets des barres latérales de macOS. Les options du Mac,
/// que le panneau range dans ses options repliées, ferment la liste.
struct BridgeSidebar: View {
    @Bindable var state: BridgeState
    /// La feuille de diagnostic, ouverte depuis l'en-tête d'état : c'est l'état qu'elle détaille.
    var showDiagnostics: () -> Void = {}

    var body: some View {
        List {
            Section { status }
            if state.startFailure != nil || state.captureAlert != nil {
                Section { notices }
            }
            Section("Source") { source }
            Section { master } header: { masterHeader }
            Section { outputs } header: { outputsHeader }
            Section("Ce Mac") { macOptions }
        }
        .listStyle(.sidebar)
        .scrollEdgeEffectStyle(.soft, for: .vertical)
    }

    // MARK: - État

    /// L'en-tête du panneau, sans sa commande : la pastille et l'état en mots, puis le diagnostic qui le
    /// détaille. La commande Diffuser est dans la barre d'outils, où rien ne la fait déborder.
    private var status: some View {
        let status = state.status
        return HStack(spacing: 10) {
            HStack(spacing: 10) {
                PanelStatusChip(status: status.menuBar, isAudible: state.captureAlert == nil && !state.isMuted)
                VStack(alignment: .leading, spacing: 1) {
                    Text(status.title)
                        .font(.headline)
                        .lineLimit(1)
                    if let detail = status.detail {
                        Text(detail)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 4)
            Button(action: showDiagnostics) {
                Label("Diagnostic", systemImage: "waveform.path.ecg").labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .help("Diagnostic : compteurs de la capture et de chaque sortie")
        }
        .padding(.vertical, 4)
    }

    // MARK: - Alertes

    @ViewBuilder
    private var notices: some View {
        if let failure = state.startFailure {
            PanelNotice(
                severity: .critical, title: "Démarrage impossible", detail: failure.message,
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

    // MARK: - Source

    /// Le sélecteur porte des identifiants : les PID d'une application varient d'un relevé à
    /// l'autre, et une valeur complète ne correspondrait plus à aucune entrée de la liste.
    private var sourceSelection: Binding<String> {
        Binding(
            get: { state.selectedSource.id },
            set: { state.selectSource(id: $0) }
        )
    }

    @ViewBuilder
    private var source: some View {
        HStack(spacing: 6) {
            Picker("Source", selection: sourceSelection) {
                ForEach(state.sources) { source in
                    Text(source.label).tag(source.id)
                }
            }
            .labelsHidden()
            .help("Pendant une diffusion, changer de source la relance.")

            Button {
                state.refreshSources()
            } label: {
                Label("Rafraîchir les sources", systemImage: "arrow.clockwise")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .help("Rafraîchir la liste des applications qui jouent du son")
        }

        if let awaited = state.awaitedSourceName {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                // La barre latérale limite ses rangées à une ligne : les textes qui en font plusieurs
                // le disent.
                Text("Passera sur \(awaited) dès que cette application jouera.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("Annuler", action: state.forgetAwaitedSource)
                    .controlSize(.small)
            }
        }
    }

    // MARK: - Volume master et silence

    /// Saisir le curseur, c'est vouloir entendre : un son coupé se rétablit, comme dans le panneau.
    private var masterBinding: Binding<Double> {
        Binding(
            get: { state.masterVolumeDB },
            set: { value in
                if state.isMuted { state.isMuted = false }
                state.masterVolumeDB = value
            }
        )
    }

    /// La valeur dans le titre de la section : la rangée garde toute sa largeur au curseur.
    private var masterHeader: some View {
        HStack {
            Text("Volume master")
            Spacer()
            Text(state.isMuted ? "Son coupé" : PanelFormat.decibels(state.masterVolumeDB))
                .monospacedDigit()
                .accessibilityHidden(true)
        }
    }

    private var master: some View {
        HStack(spacing: 8) {
            Image(systemName: "speaker.fill")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Slider(value: masterBinding, in: BridgeSettings.Limits.masterDB) {
                Text("Volume master")
            }
            .labelsHidden()
            // Coupé, le curseur reste où il était, éteint : c'est ce niveau que le rétablissement rendra.
            .opacity(state.isMuted ? 0.45 : 1)
            .accessibilityValue(state.isMuted ? "son coupé" : PanelFormat.decibels(state.masterVolumeDB))
            // Le double-clic du bouton rotatif d'avant : un curseur système n'en a pas, le menu le garde.
            .contextMenu {
                Button("Revenir à \(PanelFormat.decibels(BridgeState.defaultMasterVolumeDB))") {
                    state.masterVolumeDB = BridgeState.defaultMasterVolumeDB
                }
            }
            .help("Volume de toutes les enceintes. Clic droit : revenir au niveau de départ.")
            Image(systemName: "speaker.wave.3.fill")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            PanelMuteButton(isMuted: $state.isMuted)
        }
        .padding(.vertical, 2)
    }

    // MARK: - Sorties

    private var outputsHeader: some View {
        HStack(spacing: 6) {
            Text("Sorties")
            Spacer()
            // Le même cadre avec ou sans le témoin : la recherche revient régulièrement, et la ligne
            // ne doit pas tressauter à chaque fois.
            Group {
                if state.isBrowsing {
                    ProgressView().controlSize(.mini)
                        .accessibilityLabel("Recherche en cours")
                } else {
                    Button {
                        Task { await state.refreshOutputs() }
                    } label: {
                        Label("Rechercher", systemImage: "arrow.clockwise").labelStyle(.iconOnly)
                    }
                    .buttonStyle(.borderless)
                    .help("Rechercher les enceintes sur le réseau local")
                }
            }
            .frame(width: 18, height: 18)
        }
    }

    @ViewBuilder
    private var outputs: some View {
        if state.outputs.isEmpty {
            emptyOutputs
        } else {
            ForEach(state.outputs) { output in
                OutputRow(
                    output: output,
                    effectiveGainDB: state.effectiveGainDB(for: output),
                    listeningCompensationMS: state.listeningCompensationMS(for: output),
                    listeningPlaceName: state.listeningPlaceName,
                    stereoPartnerNames: state.stereoPartners(of: output).map(\.displayName),
                    isAudible: state.captureAlert == nil && !state.isMuted,
                    setEnabled: { state.setEnabled($0, for: output) }
                )
            }
        }
    }

    private var emptyOutputs: some View {
        VStack(spacing: 6) {
            if state.isBrowsing || !state.hasCompletedDiscovery {
                ProgressView().controlSize(.small).padding(.bottom, 2)
                Text("Recherche des enceintes…").font(.headline)
                Text("Elles apparaîtront ici dès qu'elles répondront.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Image(systemName: "hifispeaker")
                    .font(.title2)
                    .foregroundStyle(.tertiary)
                Text("Aucune sortie").font(.headline)
                Text(state.discoveryNotice ?? "Lance une recherche sur le réseau local.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity)
                HStack(spacing: 8) {
                    Button("Rechercher") { Task { await state.refreshOutputs() } }
                    if state.discoveryNotice != nil {
                        Button("Réseau local…") { SystemSettingsPane.localNetwork.open() }
                            .help("Ouvrir les réglages « Réseau local »")
                    }
                }
                .controlSize(.small)
                .padding(.top, 4)
            }
        }
        .multilineTextAlignment(.center)
        .lineLimit(nil)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
    }

    // MARK: - Ce Mac

    @ViewBuilder
    private var macOptions: some View {
        // À ne pas confondre avec le silence des enceintes, à côté du master : celle-ci éteint la sortie
        // du Mac, et les enceintes continuent de jouer.
        PanelOptionToggle(
            title: "Couper le son du Mac",
            detail: "Les enceintes continuent de jouer.",
            isOn: $state.muteLocalOutput
        )
        .disabled(state.selectedSource.tapMode == nil)
        .help(
            "Éteint la sortie de ce Mac, les enceintes continuent de jouer. Ne s'applique "
                + "qu'à la capture du son système ou d'une application. Pendant une "
                + "diffusion, le changer la relance."
        )
        PanelSystemVolumeOption(state: state)
        PanelVideoSyncOption(state: state)
    }
}
