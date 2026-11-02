//
//  BridgeState+SystemVolume.swift
//  AirplayPersonalBridge
//

import Foundation

/// Le volume général des enceintes relié aux touches de volume et de silence du Mac
/// (`SystemVolumeLink`). `BridgeState` n'en tient que les points d'accroche : l'option, et le signal
/// de ses propres changements de master et de silence.
extension BridgeState {
    /// Lance le suivi du volume du Mac, si l'option le veut : le premier relevé est adopté.
    /// Appelé par `startBackgroundWork`, pour qu'il tourne avec ou sans fenêtre. Idempotent.
    func startFollowingSystemVolume() {
        systemVolume.start()
    }

    /// Ce que le Mac impose : le master et le silence des enceintes, sans déconnexion ni relance.
    ///
    /// Ce ne sont que les deux réglages qu'un geste dans le panneau changerait : la boucle de 250 ms
    /// les pousse aux sorties (`pushChanges`), et la sauvegarde différée les garde.
    func applySystemVolume(_ update: SystemVolumeLink.Update) {
        if let master = update.masterDB {
            let range = BridgeSettings.Limits.masterDB
            let clamped = min(max(master, range.lowerBound), range.upperBound)
            if clamped != masterVolumeDB { masterVolumeDB = clamped }
        }
        if let muted = update.isMuted, muted != isMuted { isMuted = muted }
    }
}
