//
//  TransportBar.swift
//  AirplayPersonalBridge
//

import SwiftUI

/// La barre de lecture : ce qui joue, le volume général, et la commande Diffuser/Arrêter, dans une seule
/// capsule de verre. Le curseur et le bouton de silence sont ceux du panneau, dans la matière de la console
/// (`ControlLook.darkshell`) : la prise reste ronde, le niveau est un voile. Sous les curseurs de la vue Console, comme sur la maquette « Scène » qu'a choisie
/// Baptiste (2026-11-10).
/// La barre de lecture selon sa largeur : hors de la vue pour être testé.
///
/// Elle ne perd jamais son état, son silence ni Diffuser/Arrêter. Quand la largeur manque, le curseur du
/// volume cède le premier, jusqu'à sa longueur utile ; puis le texte d'état se tronque ; puis la valeur en
/// dB s'en va, et rend sa place au texte.
struct TransportLayout: Equatable {
    /// La largeur de la colonne du titre et de la source.
    var textWidth: CGFloat
    var showsDecibels: Bool
    /// Le curseur est là mais sa valeur n'a plus sa colonne : elle prend la place de la source, sous le
    /// titre. Le niveau reste lisible à toutes les largeurs.
    var showsLevelInText = false
    var sliderMinWidth: CGFloat
    /// Une fenêtre basse : la barre s'amincit.
    var isCompact: Bool

    static let fullTextWidth: CGFloat = 190
    static let minimumTextWidth: CGFloat = 96
    /// Tant que les dB ont leur colonne, le texte ne descend pas sous cette largeur : « Diffusion vers
    /// 3 enceintes » s'y lit encore. En deçà, mieux vaut rendre la colonne au texte.
    static let readableTextWidth: CGFloat = 150
    static let minimumSliderWidth: CGFloat = 96
    static let decibelsWidth: CGFloat = 52
    static let muteWidth: CGFloat = 28

    var height: CGFloat { isCompact ? 60 : TransportBar.height }
    var chipDiameter: CGFloat { isCompact ? 36 : 48 }
    var commandDiameter: CGFloat { isCompact ? 44 : 52 }
    var spacing: CGFloat { isCompact ? 10 : 14 }
    var chipSpacing: CGFloat { isCompact ? 10 : 12 }
    var leadingPadding: CGFloat { isCompact ? 10 : 14 }
    var trailingPadding: CGFloat { isCompact ? 8 : 12 }
    var titleSize: CGFloat { isCompact ? 14 : 15 }

    static func make(width: CGFloat, isCompact: Bool, showsMaster: Bool = true) -> TransportLayout {
        var layout = TransportLayout(
            textWidth: fullTextWidth, showsDecibels: showsMaster, sliderMinWidth: minimumSliderWidth,
            isCompact: isCompact
        )
        // Ce qui ne cède jamais : les marges, la pastille d'état, le silence et la commande.
        let fixed = layout.leadingPadding + layout.trailingPadding + layout.chipDiameter + layout.chipSpacing
            + muteWidth + layout.commandDiameter + 3 * layout.spacing
        let room = width - fixed
        guard showsMaster else {
            layout.textWidth = min(max(room, minimumTextWidth), fullTextWidth)
            return layout
        }
        let decibels = decibelsWidth + layout.spacing
        layout.showsDecibels = room >= minimumSliderWidth + readableTextWidth + decibels
        layout.showsLevelInText = !layout.showsDecibels
        let forText = room - minimumSliderWidth - (layout.showsDecibels ? decibels : 0)
        layout.textWidth = min(max(forText, minimumTextWidth), fullTextWidth)
        return layout
    }
}

struct TransportBar: View {
    @Bindable var state: BridgeState
    /// La largeur offerte à la barre, et la fenêtre basse : ce qui décide de ce qu'elle garde
    /// (`TransportLayout`).
    var width: CGFloat = ConsoleLayout.minimumColumnWidth
    var isCompact = false

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

    /// La ligne sous le titre : la source, ou le niveau quand la barre n'a plus la place de sa colonne.
    static func secondLine(for state: BridgeState, showsLevel: Bool) -> String {
        guard showsLevel else { return state.selectedSource.label }
        return state.isMuted ? "Son coupé" : "Volume \(PanelFormat.decibels(state.masterVolumeDB))"
    }

    var body: some View {
        let status = state.status
        let layout = TransportLayout.make(
            width: width, isCompact: isCompact, showsMaster: state.isVisible(.masterVolume)
        )
        HStack(spacing: layout.spacing) {
            HStack(spacing: layout.chipSpacing) {
                PanelStatusChip(
                    status: status.menuBar, isAudible: state.captureAlert == nil && !state.isMuted,
                    diameter: layout.chipDiameter
                )
                VStack(alignment: .leading, spacing: 1) {
                    Text(status.title)
                        .font(.system(size: layout.titleSize, weight: .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    // Sans la colonne des dB, le niveau se lit ici : la source est déjà en haut de la fenêtre.
                    Text(Self.secondLine(for: state, showsLevel: layout.showsLevelInText))
                        .font(.system(size: 13).monospacedDigit())
                        .foregroundStyle(Color.white.opacity(0.62))
                        .lineLimit(1)
                }
                .frame(width: layout.textWidth, alignment: .leading)
            }
            .accessibilityElement(children: .combine)

            // Le volume général masqué (`WindowBlock.masterVolume`) : la barre garde sa largeur, l'état à
            // gauche, le silence et la commande à droite.
            if state.isVisible(.masterVolume) {
                PanelVolumeSlider(
                    decibels: Self.master(of: state), isMuted: $state.isMuted,
                    range: BridgeSettings.Limits.masterDB, look: .darkshell
                )
                .frame(minWidth: layout.sliderMinWidth)
                .contextMenu {
                    Button("Revenir à \(PanelFormat.decibels(BridgeState.defaultMasterVolumeDB))") {
                        state.masterVolumeDB = BridgeState.defaultMasterVolumeDB
                    }
                }
                .help("Volume de toutes les enceintes. Clic droit : revenir au niveau de départ.")

                if layout.showsDecibels {
                    Text(state.isMuted ? "Coupé" : PanelFormat.decibels(state.masterVolumeDB))
                        .font(.system(size: 13).monospacedDigit())
                        .foregroundStyle(Color.white.opacity(0.62))
                        .frame(width: TransportLayout.decibelsWidth, alignment: .trailing)
                        .accessibilityHidden(true)
                }
            } else {
                Spacer(minLength: 0)
                if state.isMuted {
                    Text("Son coupé")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.white.opacity(0.62))
                        .lineLimit(1)
                        .accessibilityHidden(true)
                }
            }

            PanelMuteButton(isMuted: $state.isMuted, look: .darkshell)

            StreamingRoundButton(state: state, diameter: layout.commandDiameter)
        }
        .padding(.leading, layout.leadingPadding)
        .padding(.trailing, layout.trailingPadding)
        .frame(height: layout.height)
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
