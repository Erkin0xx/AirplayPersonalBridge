import Foundation
import Network
import OSLog

/// Un récepteur RAOP découvert sur le réseau, avec ses capacités déclarées.
///
/// Le nom d'instance annoncé en `_raop._tcp` porte un préfixe d'adresse matérielle
/// (`65D15B6D3AC1@Geneva-Mock`). C'est pourquoi la recherche se fait sur une
/// **sous-chaîne** du nom et jamais sur une égalité stricte, et pourquoi l'hôte et le port
/// viennent toujours de la résolution du service, jamais d'une valeur en dur.
public struct RAOPDevice: Sendable {
    /// Nom d'instance complet, préfixe matériel compris.
    public let serviceName: String
    /// Nom lisible, préfixe matériel retiré (`Geneva-Mock`).
    public let displayName: String
    public let host: String
    public let port: UInt16
    /// Enregistrement TXT, clés en minuscules.
    public let txt: [String: String]

    /// Chiffrement supporté, tel qu'annoncé par `et` (0 = aucun, 1 = RSA-AES,
    /// 3 = FairPlay SAPv2, 4 = FairPlay SAPv2.5).
    public var supportsRSAEncryption: Bool { txtList("et").contains("1") }
    /// Le récepteur accepte-t-il le flux **en clair** (`et` contenant 0) ?
    ///
    /// Relevé sur la Geneva AeroSphere Large (2026-08-11) : `et=0,4`. Elle ne propose donc
    /// jamais RSA-AES, seulement le clair ou FairPlay — ce dernier étant hors de portée du
    /// projet. Un récepteur qui n'annonce ni 0 ni 1 est inutilisable ici, et le sender le
    /// signale plutôt que de tenter une session vouée à l'échec.
    ///
    /// Sans `et` du tout (TXT illisible ou incomplet), on tente le clair : c'est ce que fait
    /// pyatv, dont le flux part toujours en clair, et un récepteur qui le refuse le dira.
    public var supportsUnencrypted: Bool {
        let announced = txtList("et")
        return announced.isEmpty || announced.contains("0")
    }
    /// Compression supportée, tel qu'annoncé par `cn` (0 = PCM, 1 = ALAC).
    public var supportsALAC: Bool { txtList("cn").contains("1") }
    /// Le récepteur accepte-t-il le PCM brut (`cn` contenant 0) ?
    ///
    /// Décrit en SDP par `a=rtpmap:96 L16/44100/2`, charge utile en entiers 16 bits
    /// **big-endian** (ordre réseau, conforme à L16 — relevé sur le fil contre la Geneva).
    /// Sans `cn` du tout, même raisonnement que pour ``supportsUnencrypted`` : pyatv envoie du
    /// L16 sans condition.
    public var supportsPCM: Bool {
        let announced = txtList("cn")
        return announced.isEmpty || announced.contains("0")
    }
    /// Fréquence d'échantillonnage annoncée (`sr`), 44 100 Hz par défaut en RAOP.
    ///
    /// Une valeur nulle ou absurde dans un TXT ne doit pas devenir une division par zéro dans
    /// le cadencement : on retombe sur la valeur par défaut du protocole.
    public var sampleRate: Int { positiveTXTValue("sr", in: 8_000...192_000) ?? 44_100 }
    /// Profondeur annoncée (`ss`), 16 bits par défaut.
    public var bitDepth: Int { positiveTXTValue("ss", in: 8...32) ?? 16 }
    /// Nombre de canaux annoncé (`ch`).
    public var channelCount: Int { positiveTXTValue("ch", in: 1...2) ?? 2 }
    /// Le récepteur exige-t-il un mot de passe (`pw`) ?
    public var requiresPassword: Bool { txt["pw"]?.lowercased() == "true" }

    private func txtList(_ key: String) -> [String] {
        (txt[key] ?? "").split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespaces)
        }
    }

    private func positiveTXTValue(_ key: String, in range: ClosedRange<Int>) -> Int? {
        guard let value = txt[key].flatMap({ Int($0.trimmingCharacters(in: .whitespaces)) }),
              range.contains(value)
        else { return nil }
        return value
    }

    public init(serviceName: String, host: String, port: UInt16, txt: [String: String]) {
        self.serviceName = serviceName
        self.host = host
        self.port = port
        self.txt = txt
        // Le préfixe est une adresse matérielle sur 12 caractères hexadécimaux suivie de @.
        if let separator = serviceName.firstIndex(of: "@") {
            self.displayName = String(serviceName[serviceName.index(after: separator)...])
        } else {
            self.displayName = serviceName
        }
    }
}

public enum RAOPDiscoveryError: Error, CustomStringConvertible {
    case notFound(name: String, seen: [String])
    case resolutionFailed(String)

    public var description: String {
        switch self {
        case let .notFound(name, seen):
            let list = seen.isEmpty ? "aucun" : seen.joined(separator: ", ")
            return "aucun récepteur _raop._tcp correspondant à « \(name) » "
                + "(services vus : \(list))"
        case let .resolutionFailed(reason):
            return "résolution du service RAOP impossible : \(reason)"
        }
    }
}

/// Découverte Bonjour des récepteurs RAOP (`_raop._tcp`).
///
/// Invariant section 12 : ce module ne connaît que le protocole RAOP. Il ne dépend ni de la
/// capture, ni d'un autre sender.
public actor RAOPDiscovery {
    /// Type de service Bonjour des récepteurs AirPlay 1. Le sender AirPlay 2 parcourt
    /// `_airplay._tcp` (voir `AirPlay2Discovery`) : ce sont deux annonces distinctes, et un
    /// même appareil peut apparaître dans l'une, l'autre, ou les deux.
    static let serviceType = "_raop._tcp"

    private let log = AudioLog.raop

    public init() {}

    /// Parcourt `_raop._tcp` et renvoie tous les récepteurs résolus.
    ///
    /// La résolution passe par une connexion TCP brève vers **chaque** récepteur vu, d'où le
    /// parallélisme : un appareil éteint mais encore en cache Bonjour coûte plusieurs secondes,
    /// qu'il n'a pas à faire payer aux autres.
    ///
    /// - Parameter timeout: durée d'écoute du parcours avant de rendre la main.
    public func browse(timeout: Duration = .seconds(5)) async -> [RAOPDevice] {
        let results = await browseRaw(timeout: timeout)
        return await withTaskGroup(of: RAOPDevice?.self) { group in
            for result in results {
                group.addTask { await Self.resolve(result, log: AudioLog.raop) }
            }
            var devices: [RAOPDevice] = []
            for await device in group {
                if let device { devices.append(device) }
            }
            return devices
        }
    }

    /// Cherche un récepteur par son nom (comparaison insensible à la casse).
    ///
    /// Seul le récepteur retenu est résolu, donc contacté : parcourir d'abord tous les appareils
    /// du réseau leur ouvrait à chacun une connexion à chaque démarrage, pour n'en garder qu'un.
    ///
    /// Le parcours s'arrête dès qu'un nom correspond exactement : attendre la fin du délai ne
    /// pourrait rien apporter de mieux, et ces secondes-là sont du silence pour l'utilisateur.
    /// Plusieurs tentatives, pour la raison qu'explique `AirPlay2Discovery.find` : `NWBrowser`
    /// peut rendre une liste vide au premier passage et la bonne au suivant, sans erreur.
    public func find(
        named name: String,
        timeout: Duration = .seconds(5),
        attempts: Int = 2
    ) async throws -> RAOPDevice {
        var seen: [String] = []
        for attempt in 1...max(1, attempts) {
            let results = await Self.browseRaw(
                serviceType: Self.serviceType,
                timeout: timeout,
                includeTXTRecord: false,
                log: log,
                stopWhen: { results in
                    results.contains { Self.isExactMatch(Self.serviceName(of: $0), for: name) }
                }
            )
            seen = results.compactMap { Self.serviceName(of: $0) }
            if let match = Self.bestMatch(for: name, among: results, name: { Self.serviceName(of: $0) }) {
                guard let device = await Self.resolve(match, log: log) else {
                    throw RAOPDiscoveryError.resolutionFailed(Self.serviceName(of: match) ?? name)
                }
                log.info("Récepteur RAOP résolu : \(device.serviceName, privacy: .public) → \(device.host, privacy: .public):\(device.port)")
                return device
            }
            if attempt < attempts {
                log.debug("Parcours \(attempt) sans résultat pour « \(name, privacy: .public) », nouvelle tentative")
            }
        }
        throw RAOPDiscoveryError.notFound(name: name, seen: seen)
    }

    /// Choisit le récepteur désigné par un nom, **exactitude d'abord** : nom d'instance, puis
    /// nom affiché (celui que l'interface propose, sans le préfixe matériel), puis contenance.
    ///
    /// La contenance seule est un piège dès que deux appareils partagent un préfixe : « Salon »
    /// est contenu dans « Salon (2) », et l'ordre de parcours Bonjour n'est pas garanti. Quand
    /// plusieurs noms ne correspondent que partiellement, le plus court l'emporte, ce qui rend
    /// au moins le choix reproductible d'un démarrage à l'autre.
    static func bestMatch<T>(
        for name: String, among candidates: [T], name serviceName: (T) -> String?
    ) -> T? {
        let needle = name.lowercased()
        let named = candidates.compactMap { candidate in
            serviceName(candidate).map { (candidate: candidate, name: $0) }
        }
        if let exact = named.first(where: { $0.name.lowercased() == needle }) {
            return exact.candidate
        }
        if let display = named.first(where: { displayName(of: $0.name).lowercased() == needle }) {
            return display.candidate
        }
        return named
            .filter { $0.name.lowercased().contains(needle) }
            .min { $0.name.count < $1.name.count }?
            .candidate
    }

    private static func isExactMatch(_ candidate: String?, for name: String) -> Bool {
        guard let candidate else { return false }
        let needle = name.lowercased()
        return candidate.lowercased() == needle || displayName(of: candidate).lowercased() == needle
    }

    /// Nom lisible d'une instance : sans le préfixe d'adresse matérielle suivi de `@`.
    static func displayName(of serviceName: String) -> String {
        guard let separator = serviceName.firstIndex(of: "@") else { return serviceName }
        return String(serviceName[serviceName.index(after: separator)...])
    }

    private static func serviceName(of result: NWBrowser.Result) -> String? {
        guard case let .service(name, _, _, _) = result.endpoint else { return nil }
        return name
    }

    /// Nom pleinement qualifié d'un service, tel que l'attend une requête DNS.
    ///
    /// Les points et les barres obliques inverses du nom d'instance doivent être échappés :
    /// sans cela « M. Dupont » se lirait comme deux labels DNS, et le TXT reviendrait vide sans
    /// erreur. `NWEndpoint` rend le type **sans** point final et le domaine **avec**.
    static func fullServiceName(name: String, type: String, domain: String) -> String {
        let escaped = name
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: ".", with: "\\.")
        let separator = type.hasSuffix(".") ? "" : "."
        return "\(escaped).\(type)\(separator)\(domain)"
    }

    // MARK: - Parcours

    private func browseRaw(timeout: Duration) async -> [NWBrowser.Result] {
        await Self.browseRaw(
            serviceType: Self.serviceType, timeout: timeout, includeTXTRecord: false, log: log
        )
    }

    /// Parcours Bonjour brut, paramétré par type de service.
    ///
    /// Sorti en `static` au jalon 3 : le sender AirPlay 2 parcourt `_airplay._tcp` avec
    /// exactement la même mécanique (résolution incluse). Seul le type de service change,
    /// il n'y avait donc aucune raison de dupliquer `NWBrowser` et sa gestion de reprise
    /// unique.
    ///
    /// - Parameter stopWhen: rend la main sans attendre le délai dès que ce prédicat est vrai.
    static func browseRaw(
        serviceType: String,
        timeout: Duration,
        includeTXTRecord: Bool = true,
        log: Logger,
        stopWhen: (@Sendable ([NWBrowser.Result]) -> Bool)? = nil
    ) async -> [NWBrowser.Result] {
        await withCheckedContinuation { continuation in
            let parameters = NWParameters()
            parameters.includePeerToPeer = false
            // `bonjourWithTXTRecord` fait analyser l'enregistrement TXT par Network
            // framework, qui **écarte silencieusement tout service dont le TXT lui déplaît**
            // — le service n'apparaît alors pas du tout dans les résultats, sans erreur.
            // C'est le cas du mock AirPlay 2 (voir `AirPlay2Discovery`), d'où le choix
            // laissé à l'appelant.
            let descriptor: NWBrowser.Descriptor =
                includeTXTRecord
                ? .bonjourWithTXTRecord(type: serviceType, domain: nil)
                : .bonjour(type: serviceType, domain: nil)
            let browser = NWBrowser(for: descriptor, using: parameters)
            // `finish` garde la reprise unique : `browseResultsChangedHandler` peut être
            // appelé plusieurs fois, et le timeout peut se déclencher en parallèle.
            let box = ResumeBox(continuation: continuation)
            let timer = Task {
                do {
                    try await Task.sleep(for: timeout)
                } catch {
                    return
                }
                box.finish(browser: browser)
            }
            box.attach(timer: timer)
            browser.browseResultsChangedHandler = { [weak browser] results, _ in
                let snapshot = Array(results)
                box.store(snapshot)
                if let browser, stopWhen?(snapshot) == true {
                    box.finish(browser: browser)
                }
            }
            browser.stateUpdateHandler = { [weak browser] state in
                if case let .failed(error) = state, let browser {
                    log.error(
                        "Parcours \(serviceType, privacy: .public) en échec : \(String(describing: error), privacy: .public)"
                    )
                    box.finish(browser: browser)
                }
            }
            browser.start(queue: .global(qos: .userInitiated))
        }
    }

    /// Résout un service en hôte/port exploitables, et lit ses capacités.
    ///
    /// Le TXT est lu par une requête DNS dédiée et non par `NWBrowser`, qui écarte en silence
    /// tout service dont le TXT lui déplaît : un récepteur au TXT inhabituel doit rester visible
    /// (voir `BonjourTXTQuery`). Un TXT illisible n'est pas fatal : ``RAOPDevice`` retombe alors
    /// sur les valeurs par défaut du protocole, celles que pyatv emploie sans condition.
    ///
    /// L'adresse, elle, n'existe qu'après une connexion effective, d'où la connexion TCP brève
    /// réalisée ici.
    private static func resolve(_ result: NWBrowser.Result, log: Logger) async -> RAOPDevice? {
        guard case let .service(name, type, domain, _) = result.endpoint else { return nil }

        var txt: [String: String] = [:]
        if case let .bonjour(record) = result.metadata {
            for (key, value) in record.dictionary {
                txt[key.lowercased()] = value
            }
        }
        if txt.isEmpty {
            txt = await lookupTXT(
                fullName: fullServiceName(name: name, type: type, domain: domain)
            )
        }
        if txt.isEmpty {
            log.error("TXT vide pour \(name, privacy: .public) : valeurs par défaut du protocole")
        }

        guard let resolved = await resolveEndpoint(
            NWEndpoint.service(name: name, type: type, domain: domain, interface: nil)
        ) else {
            log.error("Résolution impossible pour \(name, privacy: .public)")
            return nil
        }

        return RAOPDevice(serviceName: name, host: resolved.host, port: resolved.port, txt: txt)
    }

    /// `BonjourTXTQuery` attend de façon bloquante, jusqu'à 3 s : hors du pool coopératif, où
    /// elle priverait d'un fil tout le reste de l'application.
    private static func lookupTXT(fullName: String) async -> [String: String] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: BonjourTXTQuery.lookup(fullName: fullName))
            }
        }
    }

    /// Résolution d'un service Bonjour en couple hôte/port.
    ///
    /// `static` et partagée avec `AirPlay2Discovery` depuis le jalon 3 : la mécanique est
    /// strictement la même quel que soit le type de service.
    /// **L'IPv4 est essayée d'abord**, avec repli sur une résolution sans contrainte.
    ///
    /// Motif (constaté le 2026-08-11 contre un HomePod gen 2) : sans contrainte, la résolution
    /// rendait une adresse IPv6 **lien-local**. La session s'établissait, le pairing aboutissait,
    /// mais le récepteur refusait le `SETUP` en `400`, là où pyatv — qui passe en IPv4 — était
    /// accepté avec un plist identique. Le repli garde le chemin ouvert vers un récepteur qui
    /// n'aurait pas d'adresse IPv4.
    static func resolveEndpoint(_ endpoint: NWEndpoint) async -> (host: String, port: UInt16)? {
        if let v4 = await resolveEndpoint(endpoint, ipVersion: .v4) { return v4 }
        return await resolveEndpoint(endpoint, ipVersion: nil)
    }

    private static func resolveEndpoint(
        _ endpoint: NWEndpoint, ipVersion: NWProtocolIP.Options.Version?
    ) async -> (host: String, port: UInt16)? {
        await withCheckedContinuation { continuation in
            let box = EndpointResumeBox(continuation: continuation)
            let parameters = NWParameters.tcp
            if let ipVersion,
                let options = parameters.defaultProtocolStack.internetProtocol
                    as? NWProtocolIP.Options
            {
                options.version = ipVersion
            }
            let connection = NWConnection(to: endpoint, using: parameters)
            let timer = Task {
                do {
                    try await Task.sleep(for: .seconds(3))
                } catch {
                    return
                }
                box.finish(nil, connection: connection)
            }
            box.attach(timer: timer)
            connection.stateUpdateHandler = { [weak connection] state in
                guard let connection else { return }
                switch state {
                case .ready:
                    guard case let .hostPort(host, port) = connection.currentPath?.remoteEndpoint
                    else {
                        box.finish(nil, connection: connection)
                        return
                    }
                    box.finish((Self.literal(from: host), port.rawValue), connection: connection)
                case .failed, .cancelled:
                    box.finish(nil, connection: connection)
                default:
                    break
                }
            }
            connection.start(queue: .global(qos: .userInitiated))
        }
    }

    /// Forme littérale d'une adresse, sans le suffixe de zone (`%en0`) qu'ajoute IPv6.
    static func literal(from host: NWEndpoint.Host) -> String {
        switch host {
        case let .ipv4(address):
            return address.debugDescription.components(separatedBy: "%")[0]
        case let .ipv6(address):
            return address.debugDescription.components(separatedBy: "%")[0]
        case let .name(name, _):
            return name
        @unknown default:
            return String(describing: host)
        }
    }
}

/// Garde qu'une continuation n'est reprise qu'une fois, quel que soit l'ordre des callbacks.
///
/// À la reprise, elle arrête tout ce qui ne servirait plus : le parcours, ses gestionnaires
/// (qui le retiennent, directement ou par cette boîte) et la minuterie du délai.
private final class ResumeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<[NWBrowser.Result], Never>?
    private var results: [NWBrowser.Result] = []
    private var timer: Task<Void, Never>?

    init(continuation: CheckedContinuation<[NWBrowser.Result], Never>) {
        self.continuation = continuation
    }

    func attach(timer: Task<Void, Never>) {
        lock.lock()
        self.timer = timer
        lock.unlock()
    }

    func store(_ new: [NWBrowser.Result]) {
        lock.lock()
        results = new
        lock.unlock()
    }

    func finish(browser: NWBrowser) {
        lock.lock()
        let pending = continuation
        continuation = nil
        let snapshot = results
        let timer = timer
        self.timer = nil
        lock.unlock()
        guard let pending else { return }
        timer?.cancel()
        browser.browseResultsChangedHandler = nil
        browser.stateUpdateHandler = nil
        browser.cancel()
        pending.resume(returning: snapshot)
    }
}

private final class EndpointResumeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<(host: String, port: UInt16)?, Never>?
    private var timer: Task<Void, Never>?

    init(continuation: CheckedContinuation<(host: String, port: UInt16)?, Never>) {
        self.continuation = continuation
    }

    func attach(timer: Task<Void, Never>) {
        lock.lock()
        self.timer = timer
        lock.unlock()
    }

    func finish(_ value: (host: String, port: UInt16)?, connection: NWConnection) {
        lock.lock()
        let pending = continuation
        continuation = nil
        let timer = timer
        self.timer = nil
        lock.unlock()
        guard let pending else { return }
        timer?.cancel()
        connection.stateUpdateHandler = nil
        connection.cancel()
        pending.resume(returning: value)
    }
}
