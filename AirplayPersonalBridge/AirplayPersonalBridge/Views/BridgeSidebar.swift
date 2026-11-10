//
//  BridgeSidebar.swift
//  AirplayPersonalBridge
//

import SwiftUI

/// Le panneau des enceintes de la vue Plan, qui flotte en verre au-dessus du plan : ce qui joue (état,
/// commande Diffuser, volume général), puis une carte par enceinte. Ce qui se règle une fois (délai, tonalité,
/// options du Mac, diagnostic) est un clic plus loin, dans une fenêtre surgissante.
struct BridgeSidebar: View {
    @Bindable var state: BridgeState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let panelWidth: CGFloat = 330

    /// À sa hauteur naturelle quand tout tient, sinon une liste qui défile : un panneau flottant ne doit
    /// pas descendre jusqu'en bas de la fenêtre pour trois enceintes.
    var body: some View {
        ViewThatFits(in: .vertical) {
            content
            ScrollView { content }
                .scrollEdgeEffectStyle(.soft, for: .vertical)
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: WindowMetrics.cardSpacing) {
                hero
                if state.startFailure != nil || state.captureAlert != nil {
                    notices
                }
                outputsHeader
                    .padding(.top, 10)
                    .padding(.horizontal, WindowMetrics.cardPadding)
                outputs
                foot
                    .padding(.top, 4)
                    .padding(.horizontal, WindowMetrics.cardPadding)
        }
        .padding(WindowMetrics.margin)
    }

    /// Le pied du panneau : ce qui est masqué, et la fenêtre des réglages où le réafficher.
    private var foot: some View {
        HStack(spacing: 8) {
            HiddenElementsNote(state: state)
            Spacer(minLength: 0)
            OpenSettingsLink()
        }
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
                        .font(.headline)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    if let detail = status.detail {
                        Text(detail)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                // Le volume général masqué : son bouton de silence monte ici, un son coupé doit se voir.
                if !state.isVisible(.masterVolume) {
                    PanelMuteButton(isMuted: $state.isMuted)
                }
                StreamingRoundButton(state: state, diameter: 40)
            }
            .accessibilityElement(children: .contain)

            if state.isVisible(.masterVolume) {
                master
            }
            awaitedSource
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

    /// Une application choisie qui ne joue pas encore : elle reprendra la main. La source elle-même est dans
    /// la pastille en haut de la fenêtre.
    @ViewBuilder
    private var awaitedSource: some View {
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
                    .tint(.secondary)
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
        } else if state.hidesEverySpeaker {
            AllSpeakersHiddenNotice()
                .padding(WindowMetrics.cardPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
                .windowCard(isRaised: false)
        } else {
            // L'ordre du panneau : celles qui exigent une intervention passent en fin de liste. Les masquées
            // n'ont pas de carte ; le plan, lui, garde leur dessin.
            ForEach(PanelSpeakerOrder.sorted(state.visibleOutputs)) { output in
                SpeakerCard(
                    output: output,
                    effectiveGainDB: state.effectiveGainDB(for: output),
                    listeningCompensationMS: state.listeningCompensationMS(for: output),
                    listeningPlaceName: state.listeningPlaceName,
                    stereoPartnerNames: state.stereoPartners(of: output).map(\.displayName),
                    isAudible: state.captureAlert == nil && !state.isMuted,
                    toggle: { state.toggleEnabled(output) },
                    hide: {
                        withAnimation(PanelMotion.standard(reduceMotion: reduceMotion)) {
                            state.setHidden(true, for: output)
                        }
                    }
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

}

/// Les options du Mac, dans la fenêtre surgissante du pied de la barre latérale : les mêmes que celles du
/// panneau de la barre de menus, sur les mêmes réglages.
struct MacOptions: View {
    @Bindable var state: BridgeState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            WindowLayoutPicker(state: state)
            Divider()
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
