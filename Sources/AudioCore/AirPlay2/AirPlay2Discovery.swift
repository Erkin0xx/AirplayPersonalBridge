import Foundation
import Network
import OSLog

/// Un récepteur AirPlay 2 découvert sur le réseau, avec ses capacités déclarées.
///
/// Le nom d'instance de `_airplay._tcp` n'a **pas** le préfixe d'adresse matérielle qu'on
/// trouve en `_raop._tcp` : le mock s'annonce `ApTV-HomePod-Mock`, sans préfixe. La recherche
/// est insensible à la casse ; elle n'accepte une partie du nom que si on le lui demande
/// (``ReceiverNameMatching``), ce que seule la ligne de commande fait.
public struct AirPlay2Device: Sendable {
    public let serviceName: String
    public let host: String
    public let port: UInt16
    /// Enregistrement TXT, clés en minuscules.
    public let txt: [String: String]

    /// Bits de fonctionnalité (`features`), annoncés en deux mots de 32 bits séparés par
    /// une virgule : `features=0x405f4200,0x1c300`. Le second mot est celui de poids fort, et
    /// il est facultatif : `features=0x445f8a00` est tout aussi valide, sans bit au-delà du 31ᵉ.
    /// Certains récepteurs le publient sous la clé `ft`, que pyatv lit aussi.
    public var features: UInt64 {
        let parts = (txt["features"] ?? txt["ft"] ?? "").split(separator: ",")
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
        guard let hex = txt["pk"], let key = Data(hexEncoded: hex), key.count == 32 else {
            return nil
        }
        return key
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
/// Le parcours est partagé avec `RAOPDiscovery` (méthode `static`), et la résolution passe par
/// le même `BonjourAddressResolver` : seule change la valeur du type de service. Dupliquer
/// `NWBrowser` et sa gestion de reprise unique aurait été du copier-coller sans bénéfice.
public actor AirPlay2Discovery {
    static let serviceType = "_airplay._tcp"

    /// Un service vu au parcours, pas encore résolu.
    struct BrowsedService: Sendable, Equatable {
        let name: String
        let type: String
        let domain: String
    }

    typealias ServiceBrowser = @Sendable (Duration) async -> [BrowsedService]
    typealias ServiceResolver = @Sendable (BrowsedService) async -> AirPlay2Device?

    private let log = AudioLog.airplay2
    private let browser: ServiceBrowser
    private let resolver: ServiceResolver
    private let resolutionBudget: Duration

    public init() {
        self.init(
            browser: { await Self.browseServices(serviceType: Self.serviceType, timeout: $0) },
            resolver: Self.resolve
        )
    }

    /// Injection du parcours et de la résolution : un test ne doit jamais interroger le matériel du
    /// réseau local, et simule ainsi les parcours incomplets qu'on ne sait pas provoquer.
    init(
        browser: @escaping ServiceBrowser,
        resolver: @escaping ServiceResolver,
        resolutionBudget: Duration = BonjourAddressResolver.batchBudget
    ) {
        self.browser = browser
        self.resolver = resolver
        self.resolutionBudget = resolutionBudget
    }

    /// Parcourt `_airplay._tcp` et renvoie tous les récepteurs résolus.
    ///
    /// Le parcours se fait **sans** demander le TXT à Network framework, et le TXT est lu
    /// ensuite par `BonjourTXTQuery`. Ce détour n'est pas gratuit : avec
    /// `bonjourWithTXTRecord`, le mock AirPlay 2 **n'apparaît pas du tout** dans les
    /// résultats, alors que `dns-sd` et un parcours sans TXT le voient tous les deux. Voir
    /// l'explication dans `BonjourTXTQuery`.
    ///
    /// La résolution ne contacte aucun appareil (voir `BonjourAddressResolver`) et se fait en
    /// parallèle : un seul appareil parti sans se désannoncer coûte plusieurs secondes de délais,
    /// que les autres n'ont pas à attendre. Il est simplement absent de ce passage.
    public func browse(timeout: Duration = .seconds(5)) async -> [AirPlay2Device] {
        let services = await browser(timeout)
        return await BonjourAddressResolver.resolveAll(
            services, budget: resolutionBudget, using: resolver
        )
    }

    /// Cherche un récepteur dont le nom correspond à `name`, sans tenir compte de la casse.
    ///
    /// Plusieurs tentatives plutôt qu'un seul parcours plus long : `NWBrowser` peut rendre
    /// une liste vide au premier passage et la bonne au suivant, sans erreur ni état
    /// d'échec — constaté de façon intermittente sur cette machine avec le mock, pourtant
    /// visible en permanence via `dns-sd`. Un récepteur matériel, qui met plus de temps à
    /// répondre qu'un mock local, rend cette marge d'autant plus utile.
    ///
    /// Deux règles en découlent, vu qu'un passage peut être incomplet :
    ///
    /// - **Une correspondance partielle, quand elle est demandée, attend un second passage.**
    ///   « Salon » contenu dans « Salon (2) » serait sinon retenu dès que le vrai « Salon » manque à
    ///   un parcours.
    /// - **Seul le service retenu est résolu.** Inutile d'interroger tout le réseau, ni d'attendre
    ///   ses retardataires.
    public func find(
        named name: String,
        matching: ReceiverNameMatching = .exact,
        timeout: Duration = .seconds(5),
        attempts: Int = 3
    ) async throws -> AirPlay2Device {
        let needle = name.lowercased()
        let passes = max(1, attempts)
        var seen: Set<String> = []
        // Un appareil dont le TXT n'a pas pu être lu vaut mieux que rien, mais moins qu'un autre
        // passage : sans TXT, pas de bits de fonctionnalité.
        var fallback: AirPlay2Device?

        for pass in 1...passes {
            try Task.checkCancellation()
            let services = try await cancellableBrowse(timeout: timeout)
            seen.formUnion(services.map(\.name))

            if let match = Self.bestMatch(
                for: needle, among: services, name: \.name, matching: matching
            ) {
                let isExact = match.name.lowercased() == needle
                if isExact || pass >= min(2, passes),
                    let device = await BonjourAddressResolver.resolveAll(
                        [match], budget: resolutionBudget, using: resolver
                    ).first
                {
                    guard device.txt.isEmpty, pass < passes else {
                        log.info(
                            "Récepteur AirPlay 2 résolu : \(device.serviceName, privacy: .public) → \(device.host, privacy: .public):\(device.port)"
                        )
                        return device
                    }
                    fallback = device
                }
            }
            if pass < passes {
                log.debug("Parcours \(pass) sans résultat définitif pour « \(name, privacy: .public) », nouvelle tentative")
            }
        }
        if let fallback { return fallback }
        throw AirPlay2DiscoveryError.notFound(name: name, seen: seen.sorted())
    }

    /// Un parcours qui s'interrompt à l'annulation : il dure plusieurs secondes, et arrêter une
    /// sortie en recherche de son récepteur ne doit pas l'attendre. Le parcours sous-jacent se
    /// termine de lui-même à son échéance.
    private func cancellableBrowse(timeout: Duration) async throws -> [BrowsedService] {
        let browser = self.browser
        let box = BrowseResumeBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                box.attach(continuation)
                Task {
                    box.finish(.success(await browser(timeout)))
                }
            }
        } onCancel: {
            box.finish(.failure(CancellationError()))
        }
    }

    static func browseServices(serviceType: String, timeout: Duration) async -> [BrowsedService] {
        let results = await RAOPDiscovery.browseRaw(
            serviceType: serviceType,
            timeout: timeout,
            includeTXTRecord: false,
            log: AudioLog.airplay2
        )
        return results.compactMap { result in
            guard case let .service(name, type, domain, _) = result.endpoint else { return nil }
            return BrowsedService(name: name, type: type, domain: domain)
        }
    }

    /// Choisit le récepteur désigné par un nom, **exactitude d'abord**.
    ///
    /// La correspondance partielle seule est un piège dès que deux appareils partagent un
    /// préfixe : « Salon » est contenu dans « Salon (2) », et l'ordre de parcours Bonjour
    /// n'est pas garanti. Deux sorties visaient alors le même récepteur — la première
    /// diffusait, la seconde échouait. Constaté le 2026-08-11 avec deux HomePod.
    static func bestMatch<T>(
        for needle: String, among devices: [T], name: (T) -> String,
        matching: ReceiverNameMatching = .exact
    ) -> T? {
        if let exact = devices.first(where: { name($0).lowercased() == needle }) { return exact }
        guard matching == .partial else { return nil }
        return devices.first { name($0).lowercased().contains(needle) }
    }

    static func resolve(_ service: BrowsedService) async -> AirPlay2Device? {
        let log = AudioLog.airplay2
        let name = service.name

        // Le TXT porte les bits de fonctionnalité (`features`), l'identifiant de pairing
        // (`pi`) et la clé publique (`pk`) : sans lui, impossible de choisir le mode de
        // pairing. Il est lu par une requête DNS dédiée, hors de Network framework.
        //
        // TXT et adresse sont demandés en même temps : un appareil parti coûte ainsi un seul
        // délai, pas la somme des deux.
        let fullName =
            BonjourTXTQuery.fullName(instance: name, type: service.type, domain: service.domain)
        async let address = BonjourAddressResolver.resolveInBackground(
            name: name, type: service.type, domain: service.domain, log: log
        )
        var txt: [String: String] = [:]
        if let fullName {
            txt = await BonjourTXTQuery.lookupInBackground(fullName: fullName)
        }

        guard let resolved = await address else {
            log.error("Résolution impossible pour \(name, privacy: .public)")
            return nil
        }

        // Le service vient de se résoudre : un TXT manquant tient plutôt à une réponse multicast
        // perdue qu'à une absence réelle, et une seconde question ne coûte plus rien à personne.
        if txt.isEmpty, let fullName {
            txt = await BonjourTXTQuery.lookupInBackground(fullName: fullName, timeout: 2)
        }
        if txt.isEmpty {
            log.error("TXT vide pour \(name, privacy: .public) — capacités du récepteur inconnues")
        }

        return AirPlay2Device(serviceName: name, host: resolved.host, port: resolved.port, txt: txt)
    }
}

/// Reprise unique d'un parcours, par son résultat ou par son annulation.
private final class BrowseResumeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<[AirPlay2Discovery.BrowsedService], Error>?
    /// Une annulation peut précéder l'installation de la continuation.
    private var early: Result<[AirPlay2Discovery.BrowsedService], Error>?

    func attach(_ continuation: CheckedContinuation<[AirPlay2Discovery.BrowsedService], Error>) {
        lock.lock()
        guard let early else {
            self.continuation = continuation
            lock.unlock()
            return
        }
        lock.unlock()
        continuation.resume(with: early)
    }

    func finish(_ result: Result<[AirPlay2Discovery.BrowsedService], Error>) {
        lock.lock()
        guard let pending = continuation else {
            if early == nil { early = result }
            lock.unlock()
            return
        }
        continuation = nil
        early = result
        lock.unlock()
        pending.resume(with: result)
    }
}
