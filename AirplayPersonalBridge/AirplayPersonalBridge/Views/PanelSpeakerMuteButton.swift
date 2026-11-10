//
//  PanelSpeakerMuteButton.swift
//  AirplayPersonalBridge
//

import SwiftUI

/// Le silence d'une seule enceinte, au bout de son curseur.
///
/// Il ne fait que basculer `OutputState.isMuted` : c'est la boucle de `BridgeState` qui en tire le
/// gain numérique de la sortie et le volume de son groupe (`VolumeGroups`). L'enceinte reste cochée et
/// en session, son flux continue de partir : rétablir le son ne repaie aucune connexion. **Jamais par
/// le volume AirPlay** : les deux HomePod d'une paire n'ont qu'un volume, et −144 couperait les deux.
///
/// Comme le silence général (`PanelMuteButton`), l'icône ne change pas d'un état à l'autre : elle dit
/// ce que fait le bouton, et c'est le fond qui dit s'il est enclenché. Au repos, elle reste discrète,
/// pour ne pas faire lire « coupée » à une enceinte qui joue.
struct PanelSpeakerMuteButton: View {
    @Bindable var output: OutputState
    /// La largeur de la colonne où il se loge, au bout de la ligne du curseur.
    var width: CGFloat = 18

    static let symbol = "speaker.slash.fill"
    static let diameter: CGFloat = 18

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    var body: some View {
        Button {
            PanelSpeakerMute.toggle(output)
        } label: {
            Image(systemName: Self.symbol)
                .font(.caption2.weight(.semibold))
                .imageScale(.small)
                .foregroundStyle(foreground)
                .frame(width: Self.diameter, height: Self.diameter)
                .background(background, in: Circle())
                .frame(width: width)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(PanelMotion.quick(reduceMotion: reduceMotion), value: isHovering)
        .animation(PanelMotion.standard(reduceMotion: reduceMotion), value: output.isMuted)
        .help(
            output.isMuted
                ? "Rétablir le son de cette enceinte"
                : "Couper cette enceinte seule, sans la déconnecter"
        )
        .accessibilityLabel(PanelSpeakerMute.accessibilityLabel(for: output))
        .accessibilityValue(PanelSpeakerMute.accessibilityValue(for: output))
        .accessibilityHint("L'enceinte reste connectée, et les autres continuent de jouer.")
        .accessibilityAddTraits(.isToggle)
    }

    private var foreground: Color {
        if output.isMuted { return .white }
        return Color.primary.opacity(isHovering ? 0.75 : 0.45)
    }

    private var background: AnyShapeStyle {
        if output.isMuted { return AnyShapeStyle(BridgeTheme.accent) }
        return AnyShapeStyle(isHovering ? PanelPalette.press : Color.clear)
    }
}

/// Ce que le bouton fait, et ce que le bouton et la rangée disent du silence d'une enceinte : hors des
/// vues pour être testé.
enum PanelSpeakerMute {
    /// L'opacité du curseur d'une enceinte coupée.
    static let mutedSliderOpacity = 0.4

    /// Le geste du bouton. Il n'écrit que dans `OutputState.isMuted` : c'est la boucle de `BridgeState`
    /// qui le fait suivre au moteur, sans jamais décocher l'enceinte.
    static func toggle(_ output: OutputState) {
        output.isMuted.toggle()
    }

    static func accessibilityLabel(for output: OutputState) -> String {
        "Couper le son de \(output.displayName)"
    }

    static func accessibilityValue(for output: OutputState) -> String {
        output.isMuted ? "activé" : "désactivé"
    }

    /// Le complément de l'état de la rangée, pour VoiceOver : `nil` quand le son passe.
    static func rowStateWord(for output: OutputState) -> String? {
        output.isEnabled && output.isMuted ? "son coupé" : nil
    }

    /// L'aide du curseur. Coupé, il reste visible mais grisé : il dit pourquoi.
    static func sliderHelp(for output: OutputState) -> String {
        output.isMuted
            ? "Le son de cette enceinte est coupé : rétablis-le pour régler son volume"
            : "Volume de cette enceinte, en plus du volume master"
    }
}
