//
//  PanelSystemVolumeOption.swift
//  AirplayPersonalBridge
//

import SwiftUI

/// L'option « Touches de volume du Mac → enceintes », dans la section Options du panneau.
///
/// Activée, pendant une diffusion, les touches de volume et de silence du Mac et le curseur du Centre de
/// contrôle règlent le master des enceintes, et le master règle le volume du Mac ; le Mac se tait, et
/// retrouve son volume à l'arrêt (`SystemVolumeLink`). Le détail dit quand l'option sera sans effet —
/// une sortie du Mac sans volume réglable, une source autre que le son système global : il vaut mieux
/// le lire que de presser les touches pour rien.
struct PanelSystemVolumeOption: View {
    @Bindable var state: BridgeState

    static let title = "Touches de volume du Mac → enceintes"
    /// La flèche se lit mal à VoiceOver.
    static let accessibilityTitle = "Touches de volume du Mac vers les enceintes"

    var body: some View {
        PanelOptionToggle(
            title: Self.title, detail: detail, accessibilityTitle: Self.accessibilityTitle,
            isOn: $state.followsSystemVolume
        )
        .help(
            "Pendant une diffusion du son système global, les touches de volume et de silence du Mac "
                + "et le Centre de contrôle règlent les enceintes, et le volume du panneau règle le "
                + "Mac. Le Mac ne joue rien, et retrouve son volume à l'arrêt."
        )
    }

    private var detail: String {
        if state.followsSystemVolume {
            if let device = state.systemVolume.inoperativeDeviceName {
                return "Sans effet : « \(device) » n'a pas de volume réglable."
            }
            if !state.sourceAllowsSystemVolumeLink {
                return "Avec le son système global seulement."
            }
        }
        return Self.detail
    }

    static let detail = "Pendant la diffusion. Le Mac se tait et retrouve son volume à l'arrêt."
}
