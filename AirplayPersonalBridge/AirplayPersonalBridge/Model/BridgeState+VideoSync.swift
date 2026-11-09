//
//  BridgeState+VideoSync.swift
//  AirplayPersonalBridge
//

import Foundation

/// L'image des vidéos calée sur le son des enceintes pendant une diffusion (`VideoSyncSwitch`).
/// `BridgeState` n'en tient que les points d'accroche : l'option, la source, le lancement, le début et
/// la fin d'une diffusion.
extension BridgeState {
    /// Au lancement : rend au Mac la sortie d'une diffusion interrompue sans arrêt propre (plantage,
    /// `kill -9`), ou le retire du pilote s'il y est resté. Appelé par `startBackgroundWork`.
    func restoreLeftoverDefaultOutput() {
        videoSync.restoreLeftoverMemory()
    }

    /// Le calage ne vaut qu'avec un tap, son système global ou application. Avec l'entrée physique, les
    /// applications du Mac ne sont pas captées : elles doivent continuer de jouer sur sa sortie.
    var sourceAllowsVideoSync: Bool {
        selectedSource.tapMode != nil
    }

    /// Avec une application pour source, les autres jouent sur le pilote, qui jette le son : elles se
    /// taisent. Le panneau le dit.
    var videoSyncSilencesOtherApplications: Bool {
        if case .application = selectedSource { return true }
        return awaitedSourceName != nil
    }

    /// L'option a basculé.
    ///
    /// Désactivée en pleine diffusion : la sortie d'origine est rendue aussitôt (`isEnabled`), sans
    /// relance ; la capture se reconstruit d'elle-même au changement de sortie. Activée en pleine
    /// diffusion : bascule sur place, par le même chemin qu'au démarrage, et c'est une demande explicite,
    /// qui l'emporte sur une sortie choisie à la main plus tôt. Une page vidéo déjà ouverte ne relit la
    /// latence qu'à l'ouverture de son flux : rien à faire pour elle.
    func videoSyncOptionDidChange() {
        videoSync.isEnabled = syncsVideo
        guard syncsVideo, streamingPhase == .running, !isRestarting, sourceAllowsVideoSync else {
            return
        }
        videoSync.forgetUserChoice()
        // Le lien du volume tient la sortie actuelle et lui a imposé le master : il lui rendra lui-même
        // son volume d'origine en passant au pilote.
        videoSync.beginSession(memorizesLevels: !systemVolume.isActive)
    }
}
