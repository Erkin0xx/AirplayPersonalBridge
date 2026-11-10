//
//  BridgeSidebar.swift
//  AirplayPersonalBridge
//

import SwiftUI

/// La barre latérale de la fenêtre : ce qui joue, puis les enceintes, une carte chacune.
///
/// Elle flotte en verre au-dessus du plan, et ne montre que ce qu'on règle en écoutant : l'état, la
/// source, le volume général, puis le volume de chaque enceinte. Tout ce qui se règle une fois (délai,
/// tonalité, options du Mac, diagnostic) est un clic plus loin, dans une fenêtre surgissante : une barre
/// latérale qui montre tout ne montre plus rien.
struct BridgeSidebar: View {
    @Bindable var state: BridgeState
    /// La feuille de diagnostic, ouverte depuis le pied de la barre.
    var showDiagnostics: () -> Void = {}
    @State private var showsMacOptions = false

    var body: some View {
        // Le pied sous la liste, pas dessus : une carte qui défile ne passe jamais derrière ses boutons.
        VStack(spacing: 0) {
            cards
            footer
        }
    }

    private var cards: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: WindowMetrics.cardSpacing) {
                hero
                if state.startFailure != nil || state.captureAlert != nil {
                    notices
                }
                outputsHeader
                    .padding(.top, 10)
                    .padding(.horizontal, WindowMetrics.cardPadding)
                outputs
            }
            .padding(.horizontal, WindowMetrics.margin)
            .padding(.top, 4)
            .padding(.bottom, 12)
        }
        .scrollEdgeEffectStyle(.soft, for: .vertical)
    }

    // MARK: - En-tête

    /// Ce qui joue, d'où, et à quel volume : la carte qu'on lit en premier, et la seule qu'on lit si tout
    /// va bien. La commande Diffuser est dans la barre d'outils, où rien ne la fait déborder.
    private var hero: some View {
        let status = state.status
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: WindowMetrics.columnGap) {
                PanelStatusChip(
                    status: status.menuBar, isAudible: state.captureAlert == nil && !state.isMuted,
                    diameter: WindowMetrics.heroPastille
                )
                VStack(alignment: .leading, spacing: 1) {
                    Text(status.title)
                        .font(.title3.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                    if let detail = status.detail {
                        Text(detail)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)

            master
            Divider()
            source
        }
        .padding(WindowMetrics.cardPadding)
        .windowCard()
    }

    // MARK: - Alertes

    /// Les alertes portent leur propre fond teinté : pas de carte autour, qui ferait une boîte dans une
    /// boîte.
    private var notices: some View {
        VStack(alignment: .leading, spacing: 8) { noticeRows }
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var noticeRows: some View {
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
            Text("Source")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize()
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
                Text("Passera sur \(awaited) dès que cette application jouera.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
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

    /// Le grand curseur du panneau, et la même grammaire : le niveau se lit à la longueur du remplissage,
    /// la valeur en dB reste discrète au-dessus.
    private var master: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Volume général")
                Spacer()
                Text(state.isMuted ? "Son coupé" : PanelFormat.decibels(state.masterVolumeDB))
                    .monospacedDigit()
                    .accessibilityHidden(true)
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                PanelVolumeSlider(
                    decibels: masterBinding, isMuted: $state.isMuted, range: BridgeSettings.Limits.masterDB
                )
                // Le double-clic du bouton rotatif d'avant : le menu le garde.
                .contextMenu {
                    Button("Revenir à \(PanelFormat.decibels(BridgeState.defaultMasterVolumeDB))") {
                        state.masterVolumeDB = BridgeState.defaultMasterVolumeDB
                    }
                }
                .help("Volume de toutes les enceintes. Clic droit : revenir au niveau de départ.")
                PanelMuteButton(isMuted: $state.isMuted)
            }
        }
    }

    // MARK: - Sorties

    private var outputsHeader: some View {
        HStack(spacing: 6) {
            Text("Enceintes")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
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
                .windowCard(isRaised: false)
        } else {
            // L'ordre du panneau : celles qui exigent une intervention passent en fin de liste.
            ForEach(PanelSpeakerOrder.sorted(state.outputs)) { output in
                SpeakerCard(
                    output: output,
                    effectiveGainDB: state.effectiveGainDB(for: output),
                    listeningCompensationMS: state.listeningCompensationMS(for: output),
                    listeningPlaceName: state.listeningPlaceName,
                    stereoPartnerNames: state.stereoPartners(of: output).map(\.displayName),
                    isAudible: state.captureAlert == nil && !state.isMuted,
                    toggle: { state.toggleEnabled(output) }
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

    // MARK: - Pied

    /// Ce qui se règle une fois : les options du Mac, et le diagnostic qui détaille l'état.
    private var footer: some View {
        HStack(spacing: 4) {
            Button {
                showsMacOptions.toggle()
            } label: {
                Label("Options", systemImage: "gearshape")
            }
            .help("Options du Mac : son du Mac, touches de volume, calage des vidéos")
            .popover(isPresented: $showsMacOptions, arrowEdge: .top) {
                MacOptions(state: state)
            }
            Spacer()
            Button(action: showDiagnostics) {
                Label("Diagnostic", systemImage: "waveform.path.ecg")
            }
            .help("Diagnostic : compteurs de la capture et de chaque enceinte")
        }
        .buttonStyle(.borderless)
        .labelStyle(.titleAndIcon)
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .padding(.horizontal, WindowMetrics.margin + WindowMetrics.cardPadding)
        .padding(.vertical, 10)
    }
}

/// Les options du Mac, dans la fenêtre surgissante du pied de la barre latérale : les mêmes que celles du
/// panneau de la barre de menus, sur les mêmes réglages.
struct MacOptions: View {
    @Bindable var state: BridgeState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Ce Mac")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            // À ne pas confondre avec le silence des enceintes, à côté du volume général : celle-ci éteint
            // la sortie du Mac, et les enceintes continuent de jouer.
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
        .padding(16)
        .frame(width: 340)
    }
}
