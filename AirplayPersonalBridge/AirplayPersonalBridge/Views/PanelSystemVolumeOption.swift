//
//  PanelSystemVolumeOption.swift
//  AirplayPersonalBridge
//

import SwiftUI

/// L'option « Touches de volume du Mac → enceintes », dans la section Options du panneau.
///
/// Activée, les touches de volume et de silence du Mac et le curseur du Centre de contrôle règlent le
/// master des enceintes, et le master règle le volume du Mac (`SystemVolumeLink`). Le détail dit quand
/// la sortie du Mac n'a pas de volume réglable : l'option est alors sans effet, et il vaut mieux le
/// lire que de presser les touches pour rien.
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
            "Les touches de volume et de silence du Mac, et le Centre de contrôle, règlent les "
                + "enceintes ; le volume et le silence du panneau règlent le Mac. Avec « Couper le son "
                + "du Mac », les touches ne règlent plus que les enceintes."
        )
    }

    private var detail: String {
        if state.followsSystemVolume, let device = state.systemVolume.inoperativeDeviceName {
            return "Sans effet : « \(device) » n'a pas de volume réglable."
        }
        // Sur une ligne, comme celui de « Couper le son du Mac » : le titre dit déjà l'essentiel.
        return "Silence compris, dans les deux sens."
    }
}
