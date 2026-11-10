//
//  TransportBar.swift
//  AirplayPersonalBridge
//

import SwiftUI

/// La barre de lecture : ce qui joue, le volume général, et la commande Diffuser/Arrêter, dans une seule
/// capsule de verre. Sous les curseurs de la vue Console, comme sur la maquette « Scène » qu'a choisie
/// Baptiste (2026-11-10).
struct TransportBar: View {
    @Bindable var state: BridgeState

    static let height: CGFloat = 76

    /// Saisir le curseur, c'est vouloir entendre : un son coupé se rétablit, comme dans le panneau. Hors de la
    /// vue pour être testé.
    static func master(of state: BridgeState) -> Binding<Double> {
        Binding(
            get: { state.masterVolumeDB },
            set: { value in
                if state.isMuted { state.isMuted = false }
                state.masterVolumeDB = value
            }
        )
    }

    var body: some View {
        let status = state.status
        HStack(spacing: 14) {
            HStack(spacing: 12) {
                PanelStatusChip(
                    status: status.menuBar, isAudible: state.captureAlert == nil && !state.isMuted, diameter: 48
                )
                VStack(alignment: .leading, spacing: 1) {
                    Text(status.title)
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Text(state.selectedSource.label)
                        .font(.system(size: 13))
                        .foregroundStyle(Color.white.opacity(0.62))
                        .lineLimit(1)
                }
                .frame(width: 190, alignment: .leading)
            }
            .accessibilityElement(children: .combine)

            PanelVolumeSlider(
                decibels: Self.master(of: state), isMuted: $state.isMuted, range: BridgeSettings.Limits.masterDB
            )
            .frame(minWidth: 160)
            .contextMenu {
                Button("Revenir à \(PanelFormat.decibels(BridgeState.defaultMasterVolumeDB))") {
                    state.masterVolumeDB = BridgeState.defaultMasterVolumeDB
                }
            }
            .help("Volume de toutes les enceintes. Clic droit : revenir au niveau de départ.")

            Text(state.isMuted ? "Coupé" : PanelFormat.decibels(state.masterVolumeDB))
                .font(.system(size: 13).monospacedDigit())
                .foregroundStyle(Color.white.opacity(0.62))
                .frame(width: 52, alignment: .trailing)
                .accessibilityHidden(true)

            PanelMuteButton(isMuted: $state.isMuted)

            StreamingRoundButton(state: state, diameter: 52)
        }
        .padding(.leading, 14)
        .padding(.trailing, 12)
        .frame(height: Self.height)
        .floatingGlass(in: Capsule())
        .environment(\.colorScheme, .dark)
    }
}

/// Diffuser ou arrêter, en bouton rond : rouge avec un carré quand ça joue, blanc avec un triangle sinon.
/// Pas de rose : c'est une commande, et le rose est réservé à l'état (demande de Baptiste).
struct StreamingRoundButton: View {
    let state: BridgeState
    var diameter: CGFloat = 52

    var body: some View {
        let isStopSide = state.streamingPhase == .running || state.streamingPhase == .stopping
        let isTransition = state.streamingPhase == .starting || state.streamingPhase == .stopping
        Button {
            state.toggleStreaming()
        } label: {
            ZStack {
                Circle().fill(isStopSide ? Color(red: 0.85, green: 0.18, blue: 0.13) : Color.white)
                if isTransition {
                    ProgressView()
                        .controlSize(.small)
                        .tint(isStopSide ? .white : .black)
                } else {
                    Image(systemName: isStopSide ? "stop.fill" : "play.fill")
                        .font(.system(size: diameter * 0.36, weight: .bold))
                        .foregroundStyle(isStopSide ? Color.white : Color.black.opacity(0.85))
                        // Le triangle a son poids à gauche : on le recentre à l'œil.
                        .offset(x: isStopSide ? 0 : diameter * 0.03)
                }
            }
            .frame(width: diameter, height: diameter)
            .shadow(color: .black.opacity(0.3), radius: 8, y: 3)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        // ⌘↩ et non `.defaultAction` : Retour valide un champ, et ne doit pas faire partir le son.
        .keyboardShortcut(.return, modifiers: .command)
        .disabled(!state.canToggleStreaming)
        .opacity(state.canToggleStreaming ? 1 : 0.45)
        .help(isStopSide ? "Arrêter la diffusion (⌘↩)" : "Diffuser vers les enceintes cochées (⌘↩)")
        .accessibilityLabel(isStopSide ? "Arrêter la diffusion" : "Lancer la diffusion")
    }
}
