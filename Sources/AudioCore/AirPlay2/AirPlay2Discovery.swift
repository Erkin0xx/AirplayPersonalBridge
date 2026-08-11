import Foundation
import Network
import OSLog

/// Un récepteur AirPlay 2 découvert sur le réseau, avec ses capacités déclarées.
///
/// Le nom d'instance de `_airplay._tcp` n'a **pas** le préfixe d'adresse matérielle qu'on
/// trouve en `_raop._tcp` : le mock s'annonce `ApTV-HomePod-Mock`, sans préfixe. La
/// recherche reste néanmoins partielle et insensible à la casse, par cohérence avec le
/// sender RAOP et parce qu'un Apple TV réel peut porter un nom composé.
public struct AirPlay2Device: Sendable {
    public let serviceName: String
    public let host: String
    public let port: UInt16
    /// Enregistrement TXT, clés en minuscules.
    public let txt: [String: String]

    /// Bits de fonctionnalité (`features`), annoncés en deux mots de 32 bits séparés par
    /// une virgule : `features=0x405f4200,0x1c300`. Le second mot est celui de poids fort.
    public var features: UInt64 {
        let parts = (txt["features"] ?? "").split(separator: ",")
        func parse(_ value: Substring?) -> UInt64 {
            guard let value else { return 0 }
            let trimmed = value.trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: "0x", with: "", options: .caseInsensitive)
            return UInt64(trimmed, radix: 16) ?? 0
        }
        let low = parse(parts.first)
        let high = parts.count > 1 ? parse(parts[1]) : 0
        return (high << 32) | low
    }

    /// Bit 48 : le récepteur accepte le pair-setup **transitoire** (M1–M4, sans clés long
    /// terme ni code à saisir). C'est le mode que le jalon 3 emploie.
    public var supportsTransientPairing: Bool { features >> 48 & 1 == 1 }
    /// Bit 43 : le récepteur exige un appairage système persistant.
    public var requiresSystemPairing: Bool { features >> 43 & 1 == 1 }
    /// Bit 46 : appairage HomeKit.
    public var supportsHomeKitPairing: Bool { features >> 46 & 1 == 1 }
    /// Bit 27 : appairage « legacy » façon AirPlay 1.
    public var supportsLegacyPairing: Bool { features >> 27 & 1 == 1 }

    /// Identifiant de pairing du récepteur (`pi`), un UUID.
    public var pairingIdentifier: String { txt["pi"] ?? "" }
    /// Clé publique Ed25519 long terme du récepteur (`pk`), en hexadécimal.
    ///
    /// Sert à vérifier la signature du récepteur pendant le `pair-verify`. Absente du TXT
    /// sur certains récepteurs, d'où l'`Optional`.
    public var publicKey: Data? {
        guard let hex = txt["pk"], hex.count == 64 else { return nil }
        var bytes = [UInt8]()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return Data(bytes)
    }

    /// Identifiant matériel (`deviceid`), au format d'une adresse MAC.
    public var deviceIdentifier: String { txt["deviceid"] ?? "" }

    public init(serviceName: String, host: String, port: UInt16, txt: [String: String]) {
        self.serviceName = serviceName
        self.host = host
        self.port = port
        self.txt = txt
    }
}

public enum AirPlay2DiscoveryError: Error, CustomStringConvertible {
    case notFound(name: String, seen: [String])

    public var description: String {
        switch self {
        case let .notFound(name, seen):
            let list = seen.isEmpty ? "aucun" : seen.joined(separator: ", ")
            return "aucun récepteur _airplay._tcp correspondant à « \(name) » "
                + "(services vus : \(list))"
        }
    }
}

/// Découverte Bonjour des récepteurs AirPlay 2 (`_airplay._tcp`).
///
/// Invariant section 12 : ce module ne connaît que le protocole AirPlay 2. Il ignore la
/// capture, et ignore l'existence du sender RAOP.
///
/// Le parcours et la résolution sont partagés avec `RAOPDiscovery` (méthodes `static`) :
/// seule change la valeur du type de service. Dupliquer `NWBrowser` et sa gestion de
/// reprise unique aurait été du copier-coller sans bénéfice.
public actor AirPlay2Discovery {
    static let serviceType = "_airplay._tcp"

    private let log = AudioLog.airplay2

    public init() {}

    /// Parcourt `_airplay._tcp` et renvoie tous les récepteurs résolus.
    ///
    /// Le parcours se fait **sans** demander le TXT à Network framework, et le TXT est lu
    /// ensuite par `BonjourTXTQuery`. Ce détour n'est pas gratuit : avec
    /// `bonjourWithTXTRecord`, le mock AirPlay 2 **n'apparaît pas du tout** dans les
    /// résultats, alors que `dns-sd` et un parcours sans TXT le voient tous les deux. Voir
    /// l'explication dans `BonjourTXTQuery`.
    public func browse(timeout: Duration = .seconds(5)) async -> [AirPlay2Device] {
        let results = await RAOPDiscovery.browseRaw(
            serviceType: Self.serviceType,
            timeout: timeout,
            includeTXTRecord: false,
            log: log
        )
        var devices: [AirPlay2Device] = []
        for result in results {
            if let device = await resolve(result) {
                devices.append(device)
            }
        }
        return devices
    }

    /// Cherche un récepteur dont le nom contient `name` (comparaison insensible à la casse).
    ///
    /// Plusieurs tentatives plutôt qu'un seul parcours plus long : `NWBrowser` peut rendre
    /// une liste vide au premier passage et la bonne au suivant, sans erreur ni état
    /// d'échec — constaté de façon intermittente sur cette machine avec le mock, pourtant
    /// visible en permanence via `dns-sd`. Un récepteur matériel, qui met plus de temps à
    /// répondre qu'un mock local, rend cette marge d'autant plus utile.
    public func find(
        named name: String,
        timeout: Duration = .seconds(5),
        attempts: Int = 3
    ) async throws -> AirPlay2Device {
        let needle = name.lowercased()
        var seen: [String] = []

        for attempt in 1...max(1, attempts) {
            let devices = await browse(timeout: timeout)
            if let match = Self.bestMatch(for: needle, among: devices, name: \.serviceName) {
                log.info(
                    "Récepteur AirPlay 2 résolu : \(match.serviceName, privacy: .public) → \(match.host, privacy: .public):\(match.port)"
                )
                return match
            }
            seen = devices.map(\.serviceName)
            if attempt < attempts {
                log.debug("Parcours \(attempt) sans résultat pour « \(name, privacy: .public) », nouvelle tentative")
            }
        }
        throw AirPlay2DiscoveryError.notFound(name: name, seen: seen)
    }

    /// Choisit le récepteur désigné par un nom, **exactitude d'abord**.
    ///
    /// La correspondance partielle seule est un piège dès que deux appareils partagent un
    /// préfixe : « Salon » est contenu dans « Salon (2) », et l'ordre de parcours Bonjour
    /// n'est pas garanti. Deux sorties visaient alors le même récepteur — la première
    /// diffusait, la seconde échouait. Constaté le 2026-08-11 avec deux HomePod.
    static func bestMatch<T>(
        for needle: String, among devices: [T], name: (T) -> String
    ) -> T? {
        devices.first { name($0).lowercased() == needle }
            ?? devices.first { name($0).lowercased().contains(needle) }
    }

    private func resolve(_ result: NWBrowser.Result) async -> AirPlay2Device? {
        guard case let .service(name, type, domain, _) = result.endpoint else { return nil }

        // Le TXT porte les bits de fonctionnalité (`features`), l'identifiant de pairing
        // (`pi`) et la clé publique (`pk`) : sans lui, impossible de choisir le mode de
        // pairing. Il est lu par une requête DNS dédiée, hors de Network framework.
        // Nom pleinement qualifié : `instance._service._tcp.domaine.`, chaque composant
        // séparé par un point. `NWEndpoint` rend le type **sans** point final (`_airplay._tcp`)
        // et le domaine **avec** (`local.`) : les concaténer tels quels produit
        // `_airplay._tcplocal.`, que le résolveur ne trouve jamais — et le TXT revient vide
        // sans erreur.
        let fullName = "\(name).\(type).\(domain)"
        let txt = BonjourTXTQuery.lookup(fullName: fullName)
        if txt.isEmpty {
            log.error("TXT vide pour \(name, privacy: .public) — capacités du récepteur inconnues")
        }

        guard let resolved = await RAOPDiscovery.resolveEndpoint(
            NWEndpoint.service(name: name, type: type, domain: domain, interface: nil)
        ) else {
            log.error("Résolution impossible pour \(name, privacy: .public)")
            return nil
        }

        return AirPlay2Device(serviceName: name, host: resolved.host, port: resolved.port, txt: txt)
    }
}
