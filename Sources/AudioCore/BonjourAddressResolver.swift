import Foundation
import Network
import OSLog
import dnssd

/// Adresse et port d'un service Bonjour, obtenus **sans ouvrir de connexion vers l'appareil**.
///
/// ## Pourquoi pas `NWConnection`
///
/// Network framework ne livre l'adresse d'un service qu'une fois connecté. L'app vivant en
/// permanence dans la barre de menus et relançant sa recherche toutes les 30 s environ, chaque
/// enceinte de la maison recevait des connexions TCP vides en continu, pour une simple liste.
/// Ici tout passe par `mDNSResponder` : l'enregistrement SRV donne la cible et le port, puis
/// A/AAAA donnent l'adresse. Ce ne sont que des questions mDNS, que le démon sert le plus souvent
/// depuis son cache ; aucun port de l'appareil n'est jamais sollicité.
///
/// ## Ce qu'on y perd
///
/// Une connexion réussie prouvait que l'appareil répondait, plus rien ici ne le prouve : un
/// appareil éteint sans s'être désannoncé reste résolu tant que ses enregistrements vivent dans le
/// cache (120 s pour SRV et adresses selon la RFC 6762, durée non mesurée). C'est au moment de
/// diffuser que le sender le découvrira.
///
/// ## Échappement
///
/// `DNSServiceResolve` attend le nom d'instance **brut**, tel que le rend le parcours :
/// `AA7CB1CFC6E7@Salon (2)` ou `St. Louis` se passent tels quels, et les échapper chercherait un
/// autre service. C'est l'inverse de `DNSServiceQueryRecord`, qui veut un nom complet échappé (voir
/// `BonjourTXTQuery.fullName`). La cible rendue par la résolution est au contraire déjà sous forme
/// échappée, celle qu'attend `DNSServiceGetAddrInfo`.
///
/// ## Gestion mémoire
///
/// Invariant section 12 : chaque `DNSServiceRef` est créé ici et libéré dans tous les chemins de
/// sortie, y compris en cas d'échec ou de délai dépassé. Aucun pointeur C ne sort de ce type.
enum BonjourAddressResolver {

    /// Délai d'une résolution complète, cible et adresse comprises.
    static let defaultTimeout: TimeInterval = 3

    /// Échéance commune d'un lot de résolutions, voir ``resolveAll(_:budget:using:)``.
    ///
    /// Au-dessus de ce que coûte normalement un appareil dans le pire des cas (3 s pour le TXT, 2 s
    /// pour sa seconde chance côté AirPlay 2) : elle ne doit couper que ce qui ne répond plus du
    /// tout, jamais un TXT lent sur un appareil bien présent.
    static let batchBudget: Duration = .seconds(6)

    // MARK: - Lot

    /// Résout des services en parallèle, sous une seule échéance, dans l'ordre reçu.
    ///
    /// Un service qui échoue ou n'a pas répondu à temps est simplement absent du résultat : le
    /// passage suivant lui redonnera sa chance, et les autres n'ont pas à l'attendre.
    ///
    /// Les résolutions portent déjà leurs propres délais : celle-ci couvre ce qu'ils ne maîtrisent
    /// pas. Ouvrir une requête est un échange synchrone avec `mDNSResponder`, que rien ne borne si
    /// le démon ne répond plus. Un groupe de tâches attendrait ses enfants même annulés, d'où des
    /// tâches indépendantes : une résolution bloquée finit seule, et son résultat est perdu.
    static func resolveAll<Service: Sendable, Device: Sendable>(
        _ services: [Service],
        budget: Duration = batchBudget,
        using resolver: @escaping @Sendable (Service) async -> Device?
    ) async -> [Device] {
        guard !services.isEmpty else { return [] }
        let gathering = ResolutionGathering<Device>(slotCount: services.count)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard gathering.begin(continuation) else { return }
                for (index, service) in services.enumerated() {
                    gathering.track(
                        Task { gathering.deliver(await resolver(service), at: index) }
                    )
                }
                gathering.track(
                    Task {
                        try? await Task.sleep(for: budget)
                        gathering.finish()
                    }
                )
            }
        } onCancel: {
            gathering.finish()
        }
    }

    // MARK: - Un service

    /// ``resolve(name:type:domain:timeout:log:)`` sur un fil à part, sans bloquer l'appelant.
    ///
    /// L'attente sur le socket bloque son fil : elle n'a rien à faire sur le pool coopératif de
    /// Swift Concurrency, où quelques appareils muets suffiraient à immobiliser tous les acteurs
    /// du processus, dont les senders.
    static func resolveInBackground(
        name: String,
        type: String,
        domain: String,
        timeout: TimeInterval = defaultTimeout,
        log: Logger = AudioLog.raop
    ) async -> (host: String, port: UInt16)? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(
                    returning: resolve(
                        name: name, type: type, domain: domain, timeout: timeout, log: log
                    )
                )
            }
        }
    }

    /// Résout un service en adresse littérale et port. Bloque le fil appelant, jusqu'à `timeout`.
    ///
    /// - Parameters:
    ///   - name: nom d'instance **brut**, tel que le rend le parcours.
    ///   - type: `_raop._tcp`, avec ou sans point final.
    ///   - domain: `local.`, avec ou sans point final.
    /// - Returns: `nil` si le service ou son adresse n'a pas répondu dans le délai.
    static func resolve(
        name: String,
        type: String,
        domain: String,
        timeout: TimeInterval = defaultTimeout,
        log: Logger = AudioLog.raop
    ) -> (host: String, port: UInt16)? {
        let deadline = ContinuousClock.now + .seconds(timeout)
        guard
            let target = queryTarget(
                name: name, type: type, domain: domain, deadline: deadline, log: log
            )
        else {
            log.debug("\(name, privacy: .public) : pas de cible résolue")
            return nil
        }
        let addresses = queryAddresses(of: target, deadline: deadline, log: log)
        guard let host = preferredAddress(among: addresses) else {
            log.debug(
                "\(name, privacy: .public) : aucune adresse pour \(target.hostName, privacy: .public)"
            )
            return nil
        }
        log.debug(
            "\(name, privacy: .public) → \(host, privacy: .public):\(target.port) parmi \(addresses.joined(separator: ", "), privacy: .public)"
        )
        return (host, target.port)
    }

    /// Choisit l'adresse à viser : **l'IPv4 d'abord, l'IPv6 seulement en repli.**
    ///
    /// Motif (constaté le 2026-08-11 contre un HomePod gen 2) : par une adresse IPv6 **lien-local**,
    /// la session s'établissait, le pairing aboutissait, mais le récepteur refusait le `SETUP` en
    /// `400`, là où pyatv, qui passe en IPv4, était accepté avec un plist identique. Le repli garde
    /// le chemin ouvert vers un récepteur qui n'aurait pas d'adresse IPv4.
    ///
    /// Dans chaque famille, une adresse lien-local n'est retenue qu'à défaut d'une autre : un
    /// appareil peut garder en cache un 169.254.x.x d'avant son bail DHCP. Le plus petit littéral
    /// départage ensuite les ex æquo plutôt que l'ordre d'arrivée, qui varie d'une question à
    /// l'autre : l'interface identifie un appareil à son adresse pour fusionner ses annonces
    /// `_raop._tcp` et `_airplay._tcp`, qui doivent donc donner la même.
    static func preferredAddress(among addresses: [String]) -> String? {
        addresses
            .compactMap { address in preference(of: address).map { (rank: $0, address: address) } }
            .min { ($0.rank, $0.address) < ($1.rank, $1.address) }?
            .address
    }

    /// Rang d'une adresse littérale, `nil` si elle est illisible. `0` est le meilleur.
    private static func preference(of literal: String) -> Int? {
        if let address = IPv4Address(literal) { return address.isLinkLocal ? 1 : 0 }
        if let address = IPv6Address(literal) { return address.isLinkLocal ? 3 : 2 }
        return nil
    }

    // MARK: - Étape 1 : la cible et le port (SRV)

    private struct ServiceTarget {
        let hostName: String
        let port: UInt16
        let interfaceIndex: UInt32
    }

    private static func queryTarget(
        name: String,
        type: String,
        domain: String,
        deadline: ContinuousClock.Instant,
        log: Logger
    ) -> ServiceTarget? {
        let collector = TargetCollector()

        var serviceRef: DNSServiceRef?
        let status = DNSServiceResolve(
            &serviceRef,
            0,
            0,  // toutes les interfaces, sans le pair-à-pair : comme le parcours
            name,
            type,
            domain,
            { _, _, interfaceIndex, errorCode, _, hostTarget, port, _, _, context in
                guard let context else { return }
                let collector = Unmanaged<TargetCollector>.fromOpaque(context).takeUnretainedValue()
                guard errorCode == kDNSServiceErr_NoError else {
                    collector.markFailed(errorCode)
                    return
                }
                // Le port arrive dans l'ordre réseau.
                guard let hostTarget, port != 0 else { return }
                collector.absorb(
                    ServiceTarget(
                        hostName: String(cString: hostTarget),
                        port: UInt16(bigEndian: port),
                        interfaceIndex: interfaceIndex
                    )
                )
            },
            Unmanaged.passUnretained(collector).toOpaque()
        )
        guard status == kDNSServiceErr_NoError, let serviceRef else {
            log.error("DNSServiceResolve refusé pour \(name, privacy: .public) : \(status)")
            return nil
        }
        // Libération garantie quel que soit le chemin de sortie. Une résolution laissée ouverte
        // continuerait d'interroger le réseau.
        defer { DNSServiceRefDeallocate(serviceRef) }

        wait(on: serviceRef, until: deadline) { collector.target != nil || collector.failure != nil }
        if let failure = collector.failure {
            log.error("Résolution de \(name, privacy: .public) en échec : \(failure)")
        }
        return collector.target
    }

    /// Accumule le résultat du callback C. `final class` : le callback reçoit un pointeur
    /// opaque, il lui faut une référence stable.
    private final class TargetCollector {
        private(set) var target: ServiceTarget?
        private(set) var failure: DNSServiceErrorType?

        func absorb(_ target: ServiceTarget) { self.target = target }
        func markFailed(_ error: DNSServiceErrorType) { failure = error }
    }

    // MARK: - Étape 2 : l'adresse (A et AAAA)

    /// Rend toutes les adresses connues de la cible à l'issue de l'attente.
    ///
    /// **La première réponse ne suffit pas** : A et AAAA arrivent séparément et dans n'importe quel
    /// ordre, et `mDNSResponder` rend volontiers l'IPv6 d'abord. S'arrêter là viserait l'adresse
    /// que le HomePod refuse (voir ``preferredAddress(among:)``). L'attente ne s'arrête donc qu'avec
    /// une IPv4 ordinaire en main, et un récepteur sans IPv4 consomme tout le délai avant le repli.
    private static func queryAddresses(
        of target: ServiceTarget,
        deadline: ContinuousClock.Instant,
        log: Logger
    ) -> [String] {
        let collector = AddressCollector()

        var serviceRef: DNSServiceRef?
        let status = DNSServiceGetAddrInfo(
            &serviceRef,
            0,
            // L'interface sur laquelle le service a été vu : une autre pourrait rendre, pour le même
            // nom, une adresse sans rapport avec ce réseau.
            target.interfaceIndex,
            // Les deux explicitement : `0` laisserait le démon écarter l'IPv6 sans route, or une
            // lien-local n'a justement pas de route, et c'est le repli.
            DNSServiceProtocol(kDNSServiceProtocol_IPv4 | kDNSServiceProtocol_IPv6),
            target.hostName,
            { _, flags, _, errorCode, _, address, _, context in
                guard let context else { return }
                let collector = Unmanaged<AddressCollector>.fromOpaque(context).takeUnretainedValue()
                guard errorCode == kDNSServiceErr_NoError else {
                    collector.markFailed(errorCode)
                    return
                }
                let moreComing = flags & kDNSServiceFlagsMoreComing != 0
                let isAddition = flags & kDNSServiceFlagsAdd != 0
                collector.absorb(
                    address.flatMap(BonjourAddressResolver.literal(from:)),
                    isAddition: isAddition,
                    moreComing: moreComing
                )
            },
            Unmanaged.passUnretained(collector).toOpaque()
        )
        guard status == kDNSServiceErr_NoError, let serviceRef else {
            log.error(
                "DNSServiceGetAddrInfo refusé pour \(target.hostName, privacy: .public) : \(status)"
            )
            return []
        }
        defer { DNSServiceRefDeallocate(serviceRef) }

        wait(on: serviceRef, until: deadline) { collector.isSettled || collector.failure != nil }
        if let failure = collector.failure {
            log.error("Adresse de \(target.hostName, privacy: .public) en échec : \(failure)")
        }
        return collector.addresses
    }

    private final class AddressCollector {
        private(set) var addresses: [String] = []
        private(set) var failure: DNSServiceErrorType?
        private var moreComing = false

        /// Vrai quand attendre davantage ne peut plus changer le choix : une IPv4 ordinaire est
        /// en main, et le démon n'a pas annoncé d'autres réponses à la suite.
        var isSettled: Bool {
            guard !moreComing, let best = BonjourAddressResolver.preferredAddress(among: addresses)
            else { return false }
            return BonjourAddressResolver.preference(of: best) == 0
        }

        func absorb(_ address: String?, isAddition: Bool, moreComing: Bool) {
            self.moreComing = moreComing
            guard let address else { return }
            if !isAddition {
                // Sans ce drapeau, le callback annonce la disparition de l'adresse.
                addresses.removeAll { $0 == address }
            } else if !addresses.contains(address) {
                addresses.append(address)
            }
        }

        func markFailed(_ error: DNSServiceErrorType) { failure = error }
    }

    /// Forme littérale d'une adresse, **sans suffixe de zone** (`%en0`) : c'est ce que rendait la
    /// résolution par connexion, et ce que voient `RTSPClient` et les canaux UDP.
    private static func literal(from address: UnsafePointer<sockaddr>) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        let family = Int32(address.pointee.sa_family)
        let written: Bool
        switch family {
        case AF_INET:
            var raw = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                $0.pointee.sin_addr
            }
            written = inet_ntop(family, &raw, &buffer, socklen_t(buffer.count)) != nil
        case AF_INET6:
            var raw = address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) {
                $0.pointee.sin6_addr
            }
            written = inet_ntop(family, &raw, &buffer, socklen_t(buffer.count)) != nil
        default:
            written = false
        }
        guard written else { return nil }
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    // MARK: - Attente

    /// Traite les réponses de `serviceRef` jusqu'à `isDone` ou l'échéance.
    ///
    /// `poll` plutôt que `select`, pour les raisons données dans `BonjourTXTQuery` : échéance en
    /// millisecondes, et pas de limite `FD_SETSIZE`.
    private static func wait(
        on serviceRef: DNSServiceRef,
        until deadline: ContinuousClock.Instant,
        isDone: () -> Bool
    ) {
        let socket = DNSServiceRefSockFD(serviceRef)
        guard socket >= 0 else { return }

        var descriptor = pollfd(fd: socket, events: Int16(POLLIN), revents: 0)
        while !isDone() {
            let remaining = ContinuousClock.now.duration(to: deadline)
            guard remaining > .zero else { return }
            let milliseconds = (remaining / .milliseconds(1)).rounded(.up)
            let ready = poll(&descriptor, 1, Int32(clamping: Int(milliseconds)))
            if ready < 0, errno == EINTR { continue }
            guard ready > 0 else { return }
            guard DNSServiceProcessResult(serviceRef) == kDNSServiceErr_NoError else { return }
        }
    }
}

/// Le résultat d'un lot en cours, livré une seule fois : quand tout le monde a répondu, à
/// l'échéance ou à l'annulation, selon ce qui arrive en premier.
private final class ResolutionGathering<Device: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<[Device], Never>?
    private var slots: [Device?]
    private var outstanding: Int
    private var tasks: [Task<Void, Never>] = []
    private var isFinished = false

    init(slotCount: Int) {
        slots = Array(repeating: nil, count: slotCount)
        outstanding = slotCount
    }

    /// - Returns: faux si le lot était déjà terminé (annulation immédiate) : rien à lancer.
    func begin(_ continuation: CheckedContinuation<[Device], Never>) -> Bool {
        lock.lock()
        guard !isFinished else {
            let collected = slots.compactMap { $0 }
            lock.unlock()
            continuation.resume(returning: collected)
            return false
        }
        self.continuation = continuation
        lock.unlock()
        return true
    }

    func track(_ task: Task<Void, Never>) {
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            task.cancel()
            return
        }
        tasks.append(task)
        lock.unlock()
    }

    func deliver(_ device: Device?, at index: Int) {
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }
        slots[index] = device
        outstanding -= 1
        let isComplete = outstanding == 0
        lock.unlock()
        if isComplete { finish() }
    }

    func finish() {
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }
        isFinished = true
        let pending = continuation
        continuation = nil
        let collected = slots.compactMap { $0 }
        let running = tasks
        tasks = []
        lock.unlock()
        for task in running { task.cancel() }
        pending?.resume(returning: collected)
    }
}
