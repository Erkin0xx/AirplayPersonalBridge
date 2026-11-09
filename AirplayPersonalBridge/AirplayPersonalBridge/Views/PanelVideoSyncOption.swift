//
//  PanelVideoSyncOption.swift
//  AirplayPersonalBridge
//

import SwiftUI

/// L'option « Caler l'image des vidéos », dans la section Options du panneau, sous celle des touches de
/// volume.
///
/// Activée, pendant une diffusion par tap, le Mac joue sur la sortie virtuelle du pilote, qui ne fait
/// aucun son et annonce aux lecteurs vidéo le retard des enceintes ; la sortie d'origine revient à
/// l'arrêt (`VideoSyncSwitch`). Grisée sans pilote, avec de quoi l'installer. Le détail dit quand elle
/// sera sans effet, ou ce qu'elle coûte : avec une application pour source, les autres se taisent.
struct PanelVideoSyncOption: View {
    @Bindable var state: BridgeState

    static let title = "Caler l'image des vidéos"
    /// Une vidéo déjà ouverte ne relit la latence qu'à l'ouverture de son flux : ne pas promettre plus.
    static let detail = "Pour les vidéos ouvertes ou rechargées pendant la diffusion."
    static let missingDriverDetail =
        "Pilote absent : Drivers/APBOutput/build.sh, puis sudo scripts/install-driver.sh."
    static let inputSourceDetail = "Avec le son système ou une application seulement."
    static let otherApplicationsDetail = "Les autres applications se taisent pendant la diffusion."
    static let help =
        "Pendant une diffusion, le Mac joue sur la sortie « AirPlay Personal Bridge », qui ne fait aucun "
        + "son et annonce aux lecteurs vidéo le retard des enceintes : l'image attend le son. Une vidéo "
        + "déjà ouverte doit être rechargée. Avec une application pour source, les autres applications "
        + "se taisent. La sortie du Mac est rendue à l'arrêt."

    static func userChoiceDetail(_ name: String) -> String {
        "Suspendu : « \(name) » choisie comme sortie du Mac."
    }

    var body: some View {
        PanelOptionToggle(title: Self.title, detail: Self.detail(for: state), isOn: $state.syncsVideo)
            .disabled(!state.videoSync.isDriverInstalled)
            .help(Self.help)
    }

    static func detail(for state: BridgeState) -> String {
        guard state.videoSync.isDriverInstalled else { return Self.missingDriverDetail }
        if state.syncsVideo {
            if !state.sourceAllowsVideoSync { return Self.inputSourceDetail }
            if let name = state.videoSync.userChosenOutputName { return Self.userChoiceDetail(name) }
            if state.videoSyncSilencesOtherApplications { return Self.otherApplicationsDetail }
        }
        return Self.detail
    }
}
