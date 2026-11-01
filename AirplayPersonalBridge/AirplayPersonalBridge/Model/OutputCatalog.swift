//
//  OutputCatalog.swift
//  AirplayPersonalBridge
//

import AudioCore
import Foundation

/// Pourquoi une sortie visible sur le réseau ne jouera pas sans intervention.
///
/// Elle reste affichée : la masquer ferait chercher une enceinte qu'on voit pourtant dans le menu
/// AirPlay de macOS. Elle n'est simplement pas cochée d'office, et la raison se lit sur sa ligne.
enum OutputUnavailability: String, Sendable, Equatable {
    case pairingRequired = "Appairage requis"
    case passwordRequired = "Mot de passe requis"
    case unsupportedEncryption = "Chiffrement non pris en charge"
    case unsupportedFormat = "Format audio non pris en charge"
}

/// Une sortie telle que les découvertes la rapportent, avant toute considération d'interface.
struct DiscoveredOutput: Sendable, Equatable {
    let id: String
    let displayName: String
    let host: String
    let port: UInt16
    let proto: OutputProtocol
    var unavailability: OutputUnavailability?
    /// Cette annonce porte le bit 48 : ce n'est pas une ligne AirPlay 2 par défaut d'autre chose.
    var confirmsTransientPairing = false
}

/// Présence d'une sortie sur le réseau, distincte de son état de connexion.
enum OutputPresence: Sendable, Equatable {
    /// Restaurée des réglages, pas encore revue par une découverte.
    case unknown
    case online
    case offline
}

/// Dédoublonnage et réconciliation, en fonctions pures : c'est ici que se décide ce que la liste
/// montre, et ces règles se testent sans réseau ni interface.
enum OutputCatalog {
    /// Une recherche manquée ne prouve rien : `NWBrowser` peut rendre une liste vide au premier
    /// passage et la bonne au suivant (`AirPlay2Discovery.find`). C'est donc au second passage
    /// consécutif sans la voir qu'une sortie est déclarée absente, ce qui évite de faire clignoter
    /// la liste toutes les 30 s.
    static let missedRoundsBeforeOffline = 2

    // MARK: - Dédoublonnage

    /// Une ligne par appareil, à partir des deux découvertes.
    ///
    /// Un même appareil s'annonce sur les DEUX services : les HomePod et l'Apple TV en `_raop._tcp`
    /// et `_airplay._tcp`, la Geneva également. Les lister tels quels donne deux lignes par
    /// enceinte, dont une injouable. On n'en garde qu'une par appareil, identifié par son adresse.
    ///
    /// **Pas par son nom** : deux HomePod baptisés « Salon » s'annoncent `Salon` et `Salon (2)` en
    /// `_airplay._tcp`, le suffixe venant du conflit Bonjour, mais tous les deux `<MAC>@Salon` en
    /// `_raop._tcp`, où l'adresse matérielle évite le conflit.
    ///
    /// Critère de choix : l'AirPlay 2 l'emporte **seulement si l'appareil annonce le pairing
    /// transitoire** (bit 48), qui est le chemin que ce projet sait emprunter sans credentials. La
    /// Geneva s'annonce bien en `_airplay._tcp` mais avec `features=0x444c0a00`, sans aucun bit de
    /// pairing : c'est un récepteur AirPlay 1, il repasse en RAOP.
    static func merge(raop: [RAOPDevice], airplay2: [AirPlay2Device]) -> [DiscoveredOutput] {
        let pairingHosts = Set(airplay2.filter(requiresPairing).map(\.host))

        var byHost: [String: DiscoveredOutput] = [:]
        for device in raop {
            byHost[device.host] = DiscoveredOutput(
                id: "raop/\(device.serviceName)", displayName: device.displayName,
                host: device.host, port: device.port, proto: .raop,
                unavailability: pairingHosts.contains(device.host)
                    ? .pairingRequired : unavailability(of: device)
            )
        }
        for device in airplay2 {
            let needsPairing = requiresPairing(device)
            // Un TXT illisible laisse les capacités inconnues, pas absentes : sans annonce RAOP
            // pour la représenter, l'appareil reste proposé, et le récepteur tranchera lui-même.
            let isOnlyAnnouncement =
                byHost[device.host] == nil && (needsPairing || device.txt.isEmpty)
            guard device.supportsTransientPairing || isOnlyAnnouncement else { continue }
            byHost[device.host] = DiscoveredOutput(
                id: "airplay2/\(device.serviceName)", displayName: device.serviceName,
                host: device.host, port: device.port, proto: .airplay2,
                unavailability: needsPairing ? .pairingRequired : nil,
                confirmsTransientPairing: device.supportsTransientPairing
            )
        }
        return byHost.values.sorted(by: isOrderedBefore)
    }

    /// Le récepteur exige-t-il un appairage que le projet ne sait pas encore présenter ?
    ///
    /// Le bit 43 seul ne suffit pas : il dit que l'appairage système est **proposé**, ce qui
    /// n'empêche pas un récepteur d'accepter aussi le transitoire. C'est donc l'absence du bit 48
    /// qui décide, avec un bit de pairing pour distinguer ce récepteur de la Geneva, qui n'arme
    /// ni l'un ni l'autre.
    ///
    /// Le modèle couvre le cas restant : un Apple TV peut annoncer le bit 48 et le refuser quand
    /// même en `470` (mesuré, commit 4d1fb75). Sans credentials, il ne jouera pas. Si un réglage
    /// d'accès le rendait jouable, rien n'est perdu : la sortie reste cochable, et la mention
    /// s'efface dès qu'elle diffuse.
    static func requiresPairing(_ device: AirPlay2Device) -> Bool {
        if device.txt["model"]?.hasPrefix("AppleTV") == true { return true }
        guard !device.supportsTransientPairing else { return false }
        return device.requiresSystemPairing || device.supportsHomeKitPairing
    }

    private static func unavailability(of device: RAOPDevice) -> OutputUnavailability? {
        if device.requiresPassword { return .passwordRequired }
        if !device.supportsUnencrypted && !device.supportsRSAEncryption {
            return .unsupportedEncryption
        }
        if !device.supportsPCM && !device.supportsALAC { return .unsupportedFormat }
        return nil
    }

    /// Ordre stable : alphabétique, l'identifiant départageant deux noms égaux. Une sortie garde
    /// donc sa place d'une recherche à l'autre, en ligne comme hors ligne.
    private static func isOrderedBefore(_ a: DiscoveredOutput, _ b: DiscoveredOutput) -> Bool {
        isOrdered((a.displayName, a.id), (b.displayName, b.id))
    }

    private static func isOrdered(
        _ a: (name: String, id: String), _ b: (name: String, id: String)
    ) -> Bool {
        switch a.name.localizedCaseInsensitiveCompare(b.name) {
        case .orderedAscending: true
        case .orderedDescending: false
        case .orderedSame: a.id < b.id
        }
    }

    // MARK: - Réconciliation

    /// Ce que la réconciliation a besoin de savoir d'une sortie affichée.
    struct Entry: Equatable {
        let id: String
        let displayName: String
        let host: String
        let proto: OutputProtocol
        var presence: OutputPresence
        var missedRounds: Int
        /// Cochée ou en diffusion : elle ne disparaît pas de la liste.
        var isRetained: Bool
        /// Le moteur la fait vivre en ce moment.
        var isInSession: Bool
        /// Vue au moins une fois avec le bit 48 : c'est bien un récepteur AirPlay 2.
        var confirmsTransientPairing = false
    }

    struct Reconciliation: Equatable {
        /// Identifiants de la liste finale, dans l'ordre.
        var order: [String] = []
        /// Sorties jamais vues jusqu'ici.
        var added: [DiscoveredOutput] = []
        /// Sorties déjà affichées et revues : adresse et signalement peuvent avoir changé.
        var seen: [DiscoveredOutput] = []
        /// Présence de chaque sortie conservée.
        var presence: [String: OutputPresence] = [:]
        var missedRounds: [String: Int] = [:]
        var removed: [String] = []
        /// Sous-ensemble de `removed` : l'appareil est désormais représenté par une autre ligne.
        /// Garder ses réglages la ferait renaître au prochain lancement, en double.
        var superseded: [String] = []
    }

    /// Réconcilie la liste affichée avec le résultat d'une découverte, **sans recréer ce qui
    /// existe** : l'interface et le moteur tiennent des références aux sorties conservées.
    ///
    /// Une même adresse peut répondre sur les deux services, et une ligne peut alors en remplacer
    /// une autre. **Seul le bit 48 en donne le droit** : effacer une ligne RAOP efface aussi sa coche
    /// et ses réglages, et une annonce sans TXT ne prouve rien. Une seule recherche où la Geneva
    /// manquait en RAOP et perdait son TXT suffisait sinon à la remplacer par une ligne AirPlay 2
    /// injouable, qui absorbait ensuite la vraie annonce à chaque recherche.
    static func reconcile(
        current: [Entry], discovered: [DiscoveredOutput],
        missedRoundsBeforeOffline: Int = OutputCatalog.missedRoundsBeforeOffline
    ) -> Reconciliation {
        var result = Reconciliation()
        var candidates = discovered
        let discoveredIDs = Set(discovered.map(\.id))

        // Un TXT perdu le temps d'une recherche fait repasser un HomePod en RAOP, faute de bit 48.
        // Sans cette règle, une seconde ligne apparaîtrait pendant que la vraie passerait hors
        // ligne. L'adresse dit qu'il s'agit du même appareil : il est donc bien là.
        var stillPresent: Set<String> = []
        for entry in current where entry.proto == .airplay2 && !discoveredIDs.contains(entry.id) {
            guard entry.confirmsTransientPairing, !entry.host.isEmpty,
                let index = candidates.firstIndex(where: {
                    $0.proto == .raop && $0.host == entry.host
                })
            else { continue }
            candidates.remove(at: index)
            stillPresent.insert(entry.id)
        }

        // L'inverse : la ligne RAOP manque à cette recherche, mais la même adresse s'annonce en
        // AirPlay 2 sans le bit 48. C'est un TXT perdu ou un appareil AirPlay 1 : il est bien là, et
        // cette annonce n'a pas à devenir une seconde ligne.
        let currentIDs = Set(current.map(\.id))
        for entry in current where entry.proto == .raop && !discoveredIDs.contains(entry.id) {
            guard !entry.host.isEmpty,
                candidates.contains(where: { isUnconfirmedAnnouncement($0, at: entry.host) })
            else { continue }
            candidates.removeAll {
                isUnconfirmedAnnouncement($0, at: entry.host) && !currentIDs.contains($0.id)
            }
            stillPresent.insert(entry.id)
        }

        result.added = candidates.filter { !currentIDs.contains($0.id) }
        result.seen = candidates.filter { currentIDs.contains($0.id) }
        let candidateIDs = Set(candidates.map(\.id))

        var kept: [(name: String, id: String)] = result.added.map { ($0.displayName, $0.id) }
        for entry in current {
            if candidateIDs.contains(entry.id) || stillPresent.contains(entry.id) {
                result.presence[entry.id] = .online
                result.missedRounds[entry.id] = 0
                kept.append((entry.displayName, entry.id))
                continue
            }

            // La même adresse répond désormais en AirPlay 2, bit 48 à l'appui : la ligne RAOP n'a
            // plus lieu d'être. Sauf si le moteur la fait vivre : le retrait se décidera quand elle
            // sera décochée, pas sous ses pieds.
            let isSuperseded =
                entry.proto == .raop && !entry.host.isEmpty
                && candidates.contains {
                    $0.proto == .airplay2 && $0.confirmsTransientPairing && $0.host == entry.host
                }
            if isSuperseded && !entry.isInSession {
                result.removed.append(entry.id)
                result.superseded.append(entry.id)
                continue
            }

            let missed = entry.missedRounds + 1
            if missed < missedRoundsBeforeOffline {
                result.presence[entry.id] = entry.presence
                result.missedRounds[entry.id] = missed
                kept.append((entry.displayName, entry.id))
            } else if entry.isRetained {
                result.presence[entry.id] = .offline
                result.missedRounds[entry.id] = missed
                kept.append((entry.displayName, entry.id))
            } else {
                result.removed.append(entry.id)
            }
        }

        result.order = kept.sorted(by: isOrdered).map(\.id)
        return result
    }

    private static func isUnconfirmedAnnouncement(
        _ candidate: DiscoveredOutput, at host: String
    ) -> Bool {
        candidate.proto == .airplay2 && !candidate.confirmsTransientPairing && candidate.host == host
    }
}
