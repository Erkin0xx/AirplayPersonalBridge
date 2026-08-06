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

    /// Chiffrement supporté, tel qu'annoncé par `et` (0 = aucun, 1 = RSA-AES).
    public var supportsRSAEncryption: Bool { txtList("et").contains("1") }
    /// Compression supportée, tel qu'annoncé par `cn` (0 = PCM, 1 = ALAC).
    public var supportsALAC: Bool { txtList("cn").contains("1") }
    /// Fréquence d'échantillonnage annoncée (`sr`), 44 100 Hz par défaut en RAOP.
    public var sampleRate: Int { txt["sr"].flatMap(Int.init) ?? 44_100 }
    /// Profondeur annoncée (`ss`), 16 bits par défaut.
    public var bitDepth: Int { txt["ss"].flatMap(Int.init) ?? 16 }
    /// Nombre de canaux annoncé (`ch`).
    public var channelCount: Int { txt["ch"].flatMap(Int.init) ?? 2 }
    /// Le récepteur exige-t-il un mot de passe (`pw`) ?
    public var requiresPassword: Bool { txt["pw"]?.lowercased() == "true" }

    private func txtList(_ key: String) -> [String] {
        (txt[key] ?? "").split(separator: ",").map { String($0) }
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
    private let log = AudioLog.raop

    public init() {}

    /// Parcourt `_raop._tcp` et renvoie tous les récepteurs résolus.
    ///
    /// - Parameter timeout: durée d'écoute du parcours avant de rendre la main.
    public func browse(timeout: Duration = .seconds(5)) async -> [RAOPDevice] {
        let results = await browseRaw(timeout: timeout)
        var devices: [RAOPDevice] = []
        for result in results {
            if let device = await resolve(result) {
                devices.append(device)
            }
        }
        return devices
    }

    /// Cherche un récepteur dont le nom contient `name` (comparaison insensible à la casse).
    ///
    /// La correspondance est volontairement partielle : le nom annoncé porte un préfixe
    /// d'adresse matérielle qu'aucun appelant ne peut connaître à l'avance.
    public func find(named name: String, timeout: Duration = .seconds(5)) async throws -> RAOPDevice {
        let devices = await browse(timeout: timeout)
        let needle = name.lowercased()
        if let match = devices.first(where: { $0.serviceName.lowercased().contains(needle) }) {
            log.info("Récepteur RAOP résolu : \(match.serviceName, privacy: .public) → \(match.host, privacy: .public):\(match.port)")
            return match
        }
        throw RAOPDiscoveryError.notFound(name: name, seen: devices.map(\.serviceName))
    }

    // MARK: - Parcours

    private func browseRaw(timeout: Duration) async -> [NWBrowser.Result] {
        await withCheckedContinuation { continuation in
            let parameters = NWParameters()
            parameters.includePeerToPeer = false
            let browser = NWBrowser(
                for: .bonjourWithTXTRecord(type: "_raop._tcp", domain: nil),
                using: parameters
            )
            // `finish` garde la reprise unique : `browseResultsChangedHandler` peut être
            // appelé plusieurs fois, et le timeout peut se déclencher en parallèle.
            let box = ResumeBox(continuation: continuation)
            browser.browseResultsChangedHandler = { results, _ in
                box.store(Array(results))
            }
            browser.stateUpdateHandler = { state in
                if case let .failed(error) = state {
                    self.log.error("Parcours _raop._tcp en échec : \(String(describing: error), privacy: .public)")
                    box.finish(browser: browser)
                }
            }
            browser.start(queue: .global(qos: .userInitiated))
            Task {
                try? await Task.sleep(for: timeout)
                box.finish(browser: browser)
            }
        }
    }

    /// Résout un service en hôte/port exploitables.
    ///
    /// `NWBrowser` donne l'enregistrement TXT mais jamais l'adresse : celle-ci n'existe
    /// qu'après une connexion effective, d'où la connexion TCP brève réalisée ici.
    private func resolve(_ result: NWBrowser.Result) async -> RAOPDevice? {
        guard case let .service(name, type, domain, _) = result.endpoint else { return nil }
        var txt: [String: String] = [:]
        if case let .bonjour(record) = result.metadata {
            for (key, value) in record.dictionary {
                txt[key.lowercased()] = value
            }
        }

        guard let resolved = await resolveEndpoint(
            NWEndpoint.service(name: name, type: type, domain: domain, interface: nil)
        ) else {
            log.error("Résolution impossible pour \(name, privacy: .public)")
            return nil
        }

        return RAOPDevice(serviceName: name, host: resolved.host, port: resolved.port, txt: txt)
    }

    private func resolveEndpoint(_ endpoint: NWEndpoint) async -> (host: String, port: UInt16)? {
        await withCheckedContinuation { continuation in
            let box = EndpointResumeBox(continuation: continuation)
            let connection = NWConnection(to: endpoint, using: .tcp)
            connection.stateUpdateHandler = { state in
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
            Task {
                try? await Task.sleep(for: .seconds(3))
                box.finish(nil, connection: connection)
            }
        }
    }

    /// Forme littérale d'une adresse, sans le suffixe de zone (`%en0`) qu'ajoute IPv6.
    private static func literal(from host: NWEndpoint.Host) -> String {
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
private final class ResumeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<[NWBrowser.Result], Never>?
    private var results: [NWBrowser.Result] = []

    init(continuation: CheckedContinuation<[NWBrowser.Result], Never>) {
        self.continuation = continuation
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
        lock.unlock()
        guard let pending else { return }
        browser.cancel()
        pending.resume(returning: snapshot)
    }
}

private final class EndpointResumeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<(host: String, port: UInt16)?, Never>?

    init(continuation: CheckedContinuation<(host: String, port: UInt16)?, Never>) {
        self.continuation = continuation
    }

    func finish(_ value: (host: String, port: UInt16)?, connection: NWConnection) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        guard let pending else { return }
        connection.cancel()
        pending.resume(returning: value)
    }
}
