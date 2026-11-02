import Foundation
import Network
import Testing
import dnssd

@testable import AudioCore

/// Le choix de l'adresse, règle validée sur le vrai matériel (voir `preferredAddress`).
@Suite("Résolution Bonjour — choix de l'adresse")
struct BonjourAddressChoiceTests {

    private func choice(_ addresses: String...) -> String? {
        BonjourAddressResolver.preferredAddress(among: addresses)
    }

    /// Le HomePod refuse le `SETUP` en 400 par son IPv6 lien-local. `mDNSResponder` rend
    /// volontiers l'AAAA en premier : l'ordre d'arrivée ne doit donc rien décider.
    @Test("L'IPv4 l'emporte, quel que soit l'ordre d'arrivée")
    func ipv4DAbord() {
        #expect(choice("fe80::1c2:3ff:fe04:506", "192.168.1.30") == "192.168.1.30")
        #expect(choice("192.168.1.30", "fe80::1c2:3ff:fe04:506") == "192.168.1.30")
        #expect(choice("2a01:cb00::1", "192.168.1.30") == "192.168.1.30")
    }

    @Test("Sans IPv4, l'IPv6 sert de repli")
    func repliIPv6() {
        #expect(choice("fe80::1") == "fe80::1")
        #expect(choice("fe80::1", "2a01:cb00::1") == "2a01:cb00::1")
    }

    @Test("Une adresse lien-local ne passe qu'à défaut d'une autre de sa famille")
    func lienLocalEnDernier() {
        #expect(choice("169.254.3.4", "192.168.1.30") == "192.168.1.30")
        #expect(choice("169.254.3.4", "2a01:cb00::1") == "169.254.3.4")
    }

    /// `BridgeState` reconnaît un appareil à son adresse pour fusionner ses deux annonces, qui
    /// sont résolues séparément et dont les réponses n'arrivent pas dans le même ordre.
    @Test("Le choix entre deux adresses équivalentes ne dépend pas de l'ordre")
    func choixReproductible() {
        #expect(choice("192.168.1.31", "192.168.1.30") == choice("192.168.1.30", "192.168.1.31"))
    }

    @Test("Ce qui n'est pas une adresse est ignoré")
    func illisible() {
        #expect(choice() == nil)
        #expect(choice("Salon.local.") == nil)
        #expect(choice("n'importe quoi", "192.168.1.30") == "192.168.1.30")
    }
}

/// De bout en bout contre `mDNSResponder`, sur un service **que cette machine seule voit**.
///
/// Enregistré sur l'interface locale et sous un type propre, il ne part jamais sur le réseau et
/// n'apparaît nulle part comme une enceinte. Sa cible est alors `localhost.`, ce qui donne au
/// passage le cas le plus piégeux : `::1` est rendu **avant** `127.0.0.1`.
@Suite("Résolution Bonjour — sans connexion", .serialized)
struct BonjourResolutionWithoutConnectionTests {

    private static let type = "_apbresolve._tcp"
    private static let domain = "local."
    /// Le temps qu'une connexion ouverte par la résolution remonte jusqu'à l'écoute.
    private static let settling: Duration = .milliseconds(500)

    private func unique(_ name: String) -> String {
        "\(name) \(UInt16.random(in: 0...UInt16.max))"
    }

    /// Le compteur reste à zéro, et ce zéro signifie quelque chose : une connexion ouverte à
    /// l'adresse rendue, elle, est bien comptée.
    private func expectNoConnection(
        to listener: CountingListener, thenReachableAt host: String?,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        try await Task.sleep(for: Self.settling)
        #expect(listener.accepted == 0, "la résolution a contacté l'appareil", sourceLocation: sourceLocation)

        let host = try #require(host, sourceLocation: sourceLocation)
        let before = listener.accepted
        await listener.connectOnce(host: host)
        #expect(listener.accepted == before + 1, "témoin : l'écoute ne compte rien", sourceLocation: sourceLocation)
    }

    /// Le nom part brut vers `DNSServiceResolve` : l'échapper chercherait un autre service.
    @Test(
        "Le bon port, une adresse locale et aucune connexion, quel que soit le nom",
        arguments: [
            "AA7CB1CFC6E7@Salon (2)", "Apple TV Salon", "St. Louis", "barre\\oblique", "Été à l'Œil",
        ]
    )
    func resolution(name: String) async throws {
        let listener = try await CountingListener()
        defer { listener.shutdown() }
        let instance = unique(name)
        let service = try LocalTestService(name: instance, type: Self.type, port: listener.port)
        defer { service.stop() }

        let resolved = await BonjourAddressResolver.resolveInBackground(
            name: instance, type: Self.type, domain: Self.domain
        )

        #expect(resolved?.port == listener.port)
        #expect(resolved?.host == "127.0.0.1", "::1 arrive d'abord, l'IPv4 doit gagner quand même")
        try await expectNoConnection(to: listener, thenReachableAt: resolved?.host)
    }

    /// Le chemin de chaque découverte, TXT compris : le nom complet du TXT n'est pas construit de
    /// la même façon des deux côtés, et il suit d'autres règles d'échappement que la résolution.
    @Test("RAOP : hôte, port et TXT sans connexion")
    func cheminRAOP() async throws {
        let listener = try await CountingListener()
        defer { listener.shutdown() }
        let instance = unique("AA7CB1CFC6E7@Salon (2) St. Louis")
        let service = try LocalTestService(
            name: instance, type: Self.type, port: listener.port, txt: ["et=0,4", "cn=0"]
        )
        defer { service.stop() }

        let device = await RAOPDiscovery.resolve(
            name: instance, type: Self.type, domain: Self.domain
        )

        #expect(device?.serviceName == instance)
        #expect(device?.displayName == RAOPDiscovery.displayName(of: instance))
        #expect(device?.host == "127.0.0.1")
        #expect(device?.port == listener.port)
        #expect(device?.txt["et"] == "0,4")
        try await expectNoConnection(to: listener, thenReachableAt: device?.host)
    }

    @Test("AirPlay 2 : hôte, port et TXT sans connexion")
    func cheminAirPlay2() async throws {
        let listener = try await CountingListener()
        defer { listener.shutdown() }
        let instance = unique("Salon (2) St. Louis")
        let service = try LocalTestService(
            name: instance, type: Self.type, port: listener.port, txt: ["features=0x0,0x10000"]
        )
        defer { service.stop() }

        let device = await AirPlay2Discovery.resolve(
            .init(name: instance, type: Self.type, domain: Self.domain)
        )

        #expect(device?.serviceName == instance)
        #expect(device?.host == "127.0.0.1")
        #expect(device?.port == listener.port)
        #expect(device?.supportsTransientPairing == true)
        try await expectNoConnection(to: listener, thenReachableAt: device?.host)
    }

    /// `browse` et `find` entiers, parcours `NWBrowser` compris : ce qui fournit le nom, le type et
    /// le domaine sous la forme exacte que reçoit la résolution. Seul le type de service change, ce
    /// qui garde ces parcours loin des vraies enceintes.
    @Test("browse et find de RAOP ne contactent pas le service qu'ils listent")
    func parcoursRAOP() async throws {
        let listener = try await CountingListener()
        defer { listener.shutdown() }
        let instance = unique("AA7CB1CFC6E7@Salon (2)")
        let service = try LocalTestService(name: instance, type: Self.type, port: listener.port)
        defer { service.stop() }
        let discovery = RAOPDiscovery(serviceType: Self.type)

        let listed = await discovery.browse(timeout: .seconds(2))
        let seen = listed.first { $0.serviceName == instance }
        #expect(seen?.host == "127.0.0.1")
        #expect(seen?.port == listener.port)

        let found = try await discovery.find(named: instance, timeout: .seconds(2), attempts: 1)
        #expect(found.port == listener.port)

        try await expectNoConnection(to: listener, thenReachableAt: found.host)
    }

    @Test("browse et find d'AirPlay 2 ne contactent pas le service qu'ils listent")
    func parcoursAirPlay2() async throws {
        let listener = try await CountingListener()
        defer { listener.shutdown() }
        let instance = unique("Salon (2)")
        let service = try LocalTestService(name: instance, type: Self.type, port: listener.port)
        defer { service.stop() }
        let discovery = AirPlay2Discovery(
            browser: { timeout in
                await AirPlay2Discovery.browseServices(serviceType: Self.type, timeout: timeout)
            },
            resolver: AirPlay2Discovery.resolve
        )

        let listed = await discovery.browse(timeout: .seconds(2))
        let seen = listed.first { $0.serviceName == instance }
        #expect(seen?.host == "127.0.0.1")
        #expect(seen?.port == listener.port)

        let found = try await discovery.find(named: instance, timeout: .seconds(2), attempts: 1)
        #expect(found.port == listener.port)

        try await expectNoConnection(to: listener, thenReachableAt: found.host)
    }

    @Test("Un service absent rend la main à l'échéance, sans résultat")
    func serviceAbsent() {
        let start = ContinuousClock.now
        let resolved = BonjourAddressResolver.resolve(
            name: unique("absent"), type: Self.type, domain: Self.domain, timeout: 0.4
        )
        #expect(resolved == nil)
        #expect(ContinuousClock.now - start < .seconds(2))
    }

    @Test("Une cible sans aucune adresse rend la main à l'échéance, sans résultat")
    func cibleSansAdresse() throws {
        let instance = unique("sans adresse")
        let service = try LocalTestService(
            name: instance, type: Self.type, port: 49_997,
            host: "apbresolve-\(UInt32.random(in: 0...UInt32.max)).local."
        )
        defer { service.stop() }

        let start = ContinuousClock.now
        let resolved = BonjourAddressResolver.resolve(
            name: instance, type: Self.type, domain: Self.domain, timeout: 0.5
        )
        #expect(resolved == nil)
        #expect(ContinuousClock.now - start < .seconds(2))
    }

    /// A et AAAA sont deux questions séparées. Sur `localhost.` les deux réponses tiennent dans la
    /// même lecture du socket, ce qui masquerait un arrêt à la première : ici, elles ne le peuvent
    /// pas. L'attente s'arrête aussi dès que l'IPv4 est là, sans aller jusqu'à l'échéance.
    @Test("Une IPv4 arrivée après l'IPv6 l'emporte, et met fin à l'attente")
    func ipv4Tardive() async throws {
        let host = "apbresolve-\(UInt32.random(in: 0...UInt32.max)).local."
        let ipv6 = try LocalAddressRecord(host: host, address: "::1")
        defer { ipv6.stop() }
        let instance = unique("ipv4 tardive")
        let service = try LocalTestService(name: instance, type: Self.type, port: 49_995, host: host)
        defer { service.stop() }

        let start = ContinuousClock.now
        async let resolution = BonjourAddressResolver.resolveInBackground(
            name: instance, type: Self.type, domain: Self.domain, timeout: 5
        )
        try await Task.sleep(for: .milliseconds(300))
        let ipv4 = try LocalAddressRecord(host: host, address: "127.0.0.1")
        defer { ipv4.stop() }

        let resolved = await resolution
        #expect(resolved?.host == "127.0.0.1")
        #expect(resolved?.port == 49_995)
        #expect(ContinuousClock.now - start < .seconds(3))
    }

    /// Le repli n'arrive qu'à l'échéance : avant, une IPv4 peut encore se présenter. Le littéral ne
    /// porte pas de zone, et l'interface reconnaît un appareil à cette chaîne.
    @Test("Sans IPv4, l'IPv6 est rendue à l'échéance et sans zone", arguments: ["::1", "fe80::abcd"])
    func repliIPv6(address: String) throws {
        let host = "apbresolve-\(UInt32.random(in: 0...UInt32.max)).local."
        let record = try LocalAddressRecord(host: host, address: address)
        defer { record.stop() }
        let instance = unique("ipv6 seule")
        let service = try LocalTestService(name: instance, type: Self.type, port: 49_996, host: host)
        defer { service.stop() }

        let start = ContinuousClock.now
        let resolved = BonjourAddressResolver.resolve(
            name: instance, type: Self.type, domain: Self.domain, timeout: 0.6
        )
        #expect(resolved?.host == address)
        #expect(resolved?.port == 49_996)
        #expect(ContinuousClock.now - start >= .milliseconds(500), "le repli n'a pas attendu l'IPv4")
    }
}

@Suite("Résolution Bonjour — lot sous échéance")
struct BonjourResolutionBatchTests {

    @Test("Un lot garde l'ordre et n'attend pas les plus lents pour rien")
    func ordreConserve() async {
        let resolved = await BonjourAddressResolver.resolveAll(["a", "b", "c", "d"]) { name -> String? in
            // Le premier est le plus lent, et « c » ne rend rien.
            if name == "a" { try? await Task.sleep(for: .milliseconds(50)) }
            return name == "c" ? nil : name
        }
        #expect(resolved == ["a", "b", "d"])
    }

    @Test("Un lot vide ne lance rien")
    func loteVide() async {
        let resolved = await BonjourAddressResolver.resolveAll([String]()) { $0 }
        #expect(resolved.isEmpty)
    }

    /// Le cas qu'un groupe de tâches ne couvrirait pas : le résolveur bloqué n'écoute pas
    /// l'annulation, comme un appel à un démon qui ne répond plus.
    @Test("Un appareil bloqué n'empêche ni les autres, ni la fin du lot")
    func appareilBloque() async {
        let release = OneShotRelease()
        defer { release.fire() }

        let start = ContinuousClock.now
        let resolved = await BonjourAddressResolver.resolveAll(
            ["a", "bloqué", "c"], budget: .milliseconds(200)
        ) { name -> String? in
            if name == "bloqué" { await release.wait() }
            return name
        }

        #expect(resolved == ["a", "c"])
        #expect(ContinuousClock.now - start < .seconds(3))
    }

    @Test("Annuler un lot rend la main sans attendre son échéance")
    func annulation() async throws {
        let release = OneShotRelease()
        defer { release.fire() }

        let task = Task {
            await BonjourAddressResolver.resolveAll(["bloqué"], budget: .seconds(60)) { name -> String? in
                await release.wait()
                return name
            }
        }
        try await Task.sleep(for: .milliseconds(50))

        let start = ContinuousClock.now
        task.cancel()
        let resolved = await task.value
        #expect(resolved.isEmpty)
        #expect(ContinuousClock.now - start < .seconds(3))
    }

    private func discovery(
        services: [String], release: OneShotRelease
    ) -> AirPlay2Discovery {
        AirPlay2Discovery(
            browser: { _ in
                services.map { .init(name: $0, type: "_airplay._tcp", domain: "local.") }
            },
            resolver: { service in
                if service.name == "bloqué" { await release.wait() }
                return AirPlay2Device(
                    serviceName: service.name, host: "192.0.2.1", port: 7000, txt: ["pi": "x"]
                )
            },
            resolutionBudget: .milliseconds(200)
        )
    }

    @Test("La découverte AirPlay 2 liste sans l'appareil bloqué")
    func browseSansAppareilBloque() async {
        let release = OneShotRelease()
        defer { release.fire() }
        let finder = discovery(services: ["Salon", "bloqué", "Cuisine"], release: release)

        let start = ContinuousClock.now
        let devices = await finder.browse(timeout: .milliseconds(1))

        #expect(devices.map(\.serviceName) == ["Salon", "Cuisine"])
        #expect(ContinuousClock.now - start < .seconds(3))
    }

    @Test("Chercher un appareil bloqué échoue dans le délai au lieu de rester suspendu")
    func findAppareilBloque() async {
        let release = OneShotRelease()
        defer { release.fire() }
        let finder = discovery(services: ["bloqué"], release: release)

        let start = ContinuousClock.now
        await #expect(throws: AirPlay2DiscoveryError.self) {
            _ = try await finder.find(named: "bloqué", timeout: .milliseconds(1), attempts: 1)
        }
        #expect(ContinuousClock.now - start < .seconds(3))
    }
}

// MARK: - Outils

/// Ce que lit le code de production en l'absence de sortie réelle : un service que cette machine
/// seule voit, sous un type que rien d'autre n'utilise.
private final class LocalTestService: @unchecked Sendable {
    private let lock = NSLock()
    private var reference: DNSServiceRef?

    init(name: String, type: String, port: UInt16, host: String? = nil, txt: [String] = []) throws {
        var record = Data()
        for entry in txt {
            record.append(UInt8(entry.utf8.count))
            record.append(contentsOf: entry.utf8)
        }
        var registration: DNSServiceRef?
        let status = record.withUnsafeBytes { bytes in
            DNSServiceRegister(
                &registration, 0, UInt32(kDNSServiceInterfaceIndexLocalOnly),
                name, type, nil, host, port.bigEndian,
                UInt16(record.count), bytes.baseAddress, nil, nil
            )
        }
        try #require(status == kDNSServiceErr_NoError, "enregistrement refusé : \(status)")
        reference = registration
    }

    func stop() {
        lock.withLock {
            if let reference { DNSServiceRefDeallocate(reference) }
            reference = nil
        }
    }
}

/// Une adresse attachée à un nom d'hôte, sur l'interface locale seule : de quoi décrire un
/// appareil sans IPv4, ou dont l'IPv4 tarde, qu'on ne saurait pas obtenir autrement.
private final class LocalAddressRecord: @unchecked Sendable {
    private let lock = NSLock()
    private var connection: DNSServiceRef?

    init(host: String, address: String) throws {
        let (type, rawAddress): (Int, Data)
        if let ipv4 = IPv4Address(address) {
            (type, rawAddress) = (kDNSServiceType_A, ipv4.rawValue)
        } else {
            let ipv6 = try #require(IPv6Address(address), "adresse de test invalide")
            (type, rawAddress) = (kDNSServiceType_AAAA, ipv6.rawValue)
        }
        var connection: DNSServiceRef?
        try #require(DNSServiceCreateConnection(&connection) == kDNSServiceErr_NoError)
        let established = try #require(connection)
        var record: DNSRecordRef?
        let status = rawAddress.withUnsafeBytes { bytes in
            DNSServiceRegisterRecord(
                established, &record, DNSServiceFlags(kDNSServiceFlagsUnique),
                UInt32(kDNSServiceInterfaceIndexLocalOnly), host,
                UInt16(type), UInt16(kDNSServiceClass_IN),
                UInt16(bytes.count), bytes.baseAddress, 120,
                { _, _, _, _, _ in }, nil
            )
        }
        guard status == kDNSServiceErr_NoError else {
            DNSServiceRefDeallocate(established)
            throw LocalRecordRefused(status: status)
        }
        self.connection = established
    }

    func stop() {
        lock.withLock {
            if let connection { DNSServiceRefDeallocate(connection) }
            connection = nil
        }
    }
}

private struct LocalRecordRefused: Error {
    let status: DNSServiceErrorType
}

/// Une écoute TCP sur la boucle locale, qui ne fait que compter ce qu'elle accepte.
private final class CountingListener: @unchecked Sendable {
    private let lock = NSLock()
    private let listener: NWListener
    private var count = 0
    private(set) var port: UInt16 = 0

    var accepted: Int { lock.withLock { count } }

    /// Son port est hors de la plage éphémère : sur un numéro quelconque, le témoin pouvait être
    /// refusé sur `EADDRINUSE` (voir `LateTCPPort`).
    init() async throws {
        listener = try NWListener(using: loopbackListenerParameters())
        listener.newConnectionHandler = { [weak self] connection in
            self?.lock.withLock { self?.count += 1 }
            connection.cancel()
        }
        let queue = DispatchQueue(label: "test.counting-listener")
        port = await withCheckedContinuation { continuation in
            let once = OneShotRelease()
            listener.stateUpdateHandler = { [listener] state in
                switch state {
                case .ready:
                    if once.fire() { continuation.resume(returning: listener.port?.rawValue ?? 0) }
                case .failed:
                    // Un port pris entre-temps : 0 fait échouer le test, là où il resterait bloqué.
                    if once.fire() { continuation.resume(returning: 0) }
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    /// Le témoin : une vraie connexion, attendue jusqu'à ce que l'écoute l'ait comptée.
    func connectOnce(host: String) async {
        let before = accepted
        let connection = NWConnection(
            host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port) ?? .any, using: .tcp
        )
        connection.start(queue: .global())
        defer { connection.cancel() }
        let deadline = ContinuousClock.now + .seconds(3)
        while accepted == before, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    func shutdown() {
        listener.newConnectionHandler = nil
        listener.stateUpdateHandler = nil
        listener.cancel()
    }
}

/// Une attente qu'aucune annulation n'interrompt, libérée une fois pour toutes.
private final class OneShotRelease: @unchecked Sendable {
    private let lock = NSLock()
    private var isFired = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// - Returns: vrai si c'est cet appel qui a libéré.
    @discardableResult
    func fire() -> Bool {
        let (first, pending) = lock.withLock {
            defer {
                isFired = true
                waiters = []
            }
            return (!isFired, waiters)
        }
        for waiter in pending { waiter.resume() }
        return first
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            let alreadyFired = lock.withLock {
                if !isFired { waiters.append(continuation) }
                return isFired
            }
            if alreadyFired { continuation.resume() }
        }
    }
}
