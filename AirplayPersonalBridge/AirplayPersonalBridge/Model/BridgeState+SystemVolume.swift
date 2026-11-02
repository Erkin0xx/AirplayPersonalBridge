//
//  BridgeState+SystemVolume.swift
//  AirplayPersonalBridge
//

import Foundation

/// Le volume général des enceintes relié aux touches de volume et de silence du Mac pendant une
/// diffusion (`SystemVolumeLink`). `BridgeState` n'en tient que les points d'accroche : l'option, le
/// signal de ses propres changements de master et de silence, le début et la fin d'une diffusion.
extension BridgeState {
    /// Au lancement : rend au Mac le volume d'une diffusion interrompue sans arrêt propre (plantage,
    /// `kill -9`). Appelé par `startBackgroundWork`. Hors de ce cas, rien n'est lu ni écrit.
    func restoreLeftoverSystemVolume() {
        systemVolume.restoreLeftoverMemory()
    }

    /// Ce que le Mac impose pendant une diffusion : le master et le silence des enceintes, sans
    /// déconnexion ni relance.
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

    /// L'option a basculé.
    ///
    /// Désactivée en pleine diffusion : le Mac retrouve aussitôt son volume, **sans relance** ; le tap,
    /// décidé au démarrage, garde le son local coupé jusqu'à l'arrêt. Activée en pleine diffusion : si le
    /// tap coupe déjà le son local, le lien démarre sur place ; sinon la capture est relancée **une
    /// fois**, comme pour « Couper le son du Mac », car le Mac jouerait au volume du master.
    func systemVolumeOptionDidChange() {
        systemVolume.isEnabled = followsSystemVolume
        guard followsSystemVolume, streamingPhase == .running, !isRestarting,
            sourceAllowsSystemVolumeLink, systemVolume.canLink()
        else { return }
        if sessionMutesLocalOutput {
            systemVolume.beginSession(masterDB: masterVolumeDB, isMuted: isMuted)
        } else {
            restartIfLive()
        }
    }
}
