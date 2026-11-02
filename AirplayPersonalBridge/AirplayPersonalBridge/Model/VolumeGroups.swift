//
//  VolumeGroups.swift
//  AirplayPersonalBridge
//

import AudioCore
import Foundation

/// Les groupes de volume : ce que chaque sortie reçoit, quand plusieurs n'ont qu'un seul volume.
///
/// ## Le défaut corrigé
///
/// Les deux HomePod « Salon » et « Salon (2) » forment une **paire stéréo** : même `tsid` dans leur
/// TXT `_airplay._tcp` (`AirPlay2Device.tightSyncIdentifier`). Une paire n'a qu'**un** volume côté
/// HomePod, et le dernier réglé vaut pour les deux : deux `SET_PARAMETER volume` distincts, un par
/// session, finissaient donc au même niveau, celui du dernier trim touché.
///
/// ## La règle
///
/// Un **groupe de volume** est l'ensemble des sorties cochées qui partagent un `tsid`. Une sortie sans
/// `tsid`, comme la Geneva, ou décochée, forme un groupe à elle seule.
///
/// - Toutes les sorties d'un groupe reçoivent **le même volume AirPlay** : celui du plus fort de ses
///   membres audibles, master compris (`BridgeState.receiverVolume(forGainDB:)`).
/// - Chacune reçoit en plus un **gain numérique**, appliqué par son sender sur sa copie du flux
///   (`OutputGainStage`) : l'écart entre le volume qu'elle aurait reçu seule et ce volume commun.
///   Il est donc toujours ≤ 0 dB, sans risque d'écrêtage, et vaut exactement 0 dB pour le plus fort.
/// - Une sortie seule dans son groupe garde le comportement d'avant au bit près : son trim dans le
///   volume AirPlay, un gain de 0 dB, et l'étage contourné.
///
/// **L'écart se compte sur l'échelle du fil, pas sur celle de l'interface.** Le curseur court de −60
/// à 0 dB et le protocole de −30 à 0 : deux décibels d'interface en valent un sur le fil. Pour +0,5 et
/// −11,5 dB de trim, le gain numérique vaut donc −6 dB et non −12. C'est ce qui rend chaque curseur
/// indépendant : chaque HomePod entend exactement ce que son propre volume AirPlay lui aurait donné,
/// et bouger le trim du plus fort ne déplace pas le niveau de l'autre. Compté en décibels d'interface,
/// le gain aurait fait baisser l'autre de la moitié de chaque geste. L'hypothèse est celle du
/// protocole : un décibel de volume AirPlay est un décibel chez le récepteur.
///
/// ## Le silence par enceinte
///
/// Numérique, jamais par le volume AirPlay : −144 envoyé à un membre d'une paire couperait les deux.
/// Une sortie coupée **sort du calcul du plus fort** : couper le HomePod le plus fort ne laisse pas
/// l'autre sous un gain numérique devenu inutile, et son niveau ne bouge pas. Si tout le groupe est
/// coupé, le plus fort de tous sert de référence, pour que le volume commun ne bouge pas.
///
/// ## Le silence général et le master au minimum
///
/// Ils passent toujours par le volume AirPlay (−144), comme avant. Les gains numériques, eux, restent
/// ceux du son rétabli : basculer le silence ne pousse aucun gain, et rétablir le son ne fait pas
/// attendre le gain d'un membre pendant que le volume commun, plus rapide, est déjà revenu.
enum VolumeGroups {
    /// Ce que le calcul a besoin de savoir d'une sortie.
    struct Member: Equatable {
        let id: String
        /// Le `tsid` d'une sortie cochée, ou à défaut une clé qui n'appartient qu'à elle.
        let groupKey: String
        let trimDB: Double
        /// Silence par enceinte, numérique.
        let isMuted: Bool
    }

    /// Ce que reçoit une sortie : le volume AirPlay de son groupe, et son niveau propre.
    struct Setting: Equatable {
        /// Sur l'échelle du protocole : −30 à 0, −144 pour le silence.
        var volumeDB: Float
        var level: OutputLevel
    }

    /// Le réglage de chaque sortie, indexé par identifiant.
    ///
    /// - Parameters:
    ///   - masterVolumeDB: master de l'interface, de −60 à 0 dB. Au minimum, le silence.
    ///   - isMuted: silence général, par le volume AirPlay.
    static func settings(
        for members: [Member], masterVolumeDB: Double, isMuted: Bool
    ) -> [String: Setting] {
        var groups: [String: [Member]] = [:]
        for member in members { groups[member.groupKey, default: []].append(member) }

        var result: [String: Setting] = [:]
        for group in groups.values {
            let audible = group.filter { !$0.isMuted }
            let reference = (audible.isEmpty ? group : audible).map(\.trimDB).max() ?? 0
            let common = wireVolume(trimDB: reference, masterVolumeDB: masterVolumeDB)
            let isSilenced = isMuted || masterVolumeDB <= BridgeState.silenceDB
            for member in group {
                result[member.id] = Setting(
                    volumeDB: isSilenced ? silentVolume : common,
                    level: level(of: member, commonVolume: common, masterVolumeDB: masterVolumeDB)
                )
            }
        }
        return result
    }

    /// Le réglage d'une sortie seule dans son groupe.
    static func soloSetting(
        trimDB: Double, isOutputMuted: Bool, masterVolumeDB: Double, isMuted: Bool
    ) -> Setting {
        let member = Member(id: "", groupKey: "", trimDB: trimDB, isMuted: isOutputMuted)
        return settings(for: [member], masterVolumeDB: masterVolumeDB, isMuted: isMuted)[""]
            ?? Setting(volumeDB: silentVolume, level: OutputLevel(isMuted: isOutputMuted))
    }

    // MARK: - Interne

    private static let silentVolume: Float = BridgeState.receiverVolume(forGainDB: BridgeState.silenceDB)

    /// Le volume du fil que ce trim donnerait seul, master compris, **hors silence général** : c'est la
    /// base des gains, qui ne doivent pas bouger quand le silence se lève.
    private static func wireVolume(trimDB: Double, masterVolumeDB: Double) -> Float {
        let level = min(max(masterVolumeDB + trimDB, BridgeState.silenceDB), 0)
        return BridgeState.receiverVolume(forGainDB: level)
    }

    private static func level(
        of member: Member, commonVolume: Float, masterVolumeDB: Double
    ) -> OutputLevel {
        // Tout le groupe est sous le plancher de l'échelle : le volume commun dit déjà le silence.
        guard commonVolume != silentVolume else { return OutputLevel(isMuted: member.isMuted) }
        let own = wireVolume(trimDB: member.trimDB, masterVolumeDB: masterVolumeDB)
        // Seule sous le plancher : seule, elle aurait reçu −144. Le silence numérique le rend exact.
        guard own != silentVolume else { return OutputLevel(isMuted: true) }
        // Une sortie coupée peut être plus forte que la référence, dont elle est sortie : son gain
        // reste à 0 dB, le silence suffit.
        return OutputLevel(gainDB: min(0, own - commonVolume), isMuted: member.isMuted)
    }
}

extension OutputState {
    /// Sa place dans le calcul des groupes de volume. Décochée, elle ne joue pas et ne pèse donc sur
    /// aucun groupe : elle forme le sien.
    var volumeGroupMember: VolumeGroups.Member {
        let key = isEnabled ? tightSyncIdentifier.map { "tsid/\($0)" } : nil
        return VolumeGroups.Member(
            id: id, groupKey: key ?? "sortie/\(id)", trimDB: trimDB, isMuted: isMuted
        )
    }
}
