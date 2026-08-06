import Foundation
import Network
import OSLog

/// Canal d'événements AirPlay 2.
///
/// Le premier `SETUP` (celui **sans** clé `streams`) rend un `eventPort` : une écoute TCP
/// côté récepteur, sur laquelle il pousse ses changements d'état — volume modifié depuis
/// l'appareil, arrêt décidé par le récepteur, changement de groupe. Le jalon 3 récupérait ce
/// port sans jamais s'y connecter ; c'est fait ici.
///
/// ## Ce qu'il apporte au jalon 4
///
/// Moins l'exploitation des événements eux-mêmes — l'interface qui les afficherait est
/// l'objet du jalon 5 — que la **détection de perte de session**. Le canal audio étant en
/// UDP, un récepteur qui disparaît ne provoque aucune erreur d'émission : les datagrammes
/// partent dans le vide indéfiniment. La rupture de cette connexion TCP, elle, est immédiate
/// et sans ambiguïté. C'est le signal de vie qui manque à AirPlay 2, là où RAOP dispose du
/// flux de requêtes d'horloge.
///
/// ## Réserve de validation
///
/// Sur du matériel réel, le contenu de ce canal est **chiffré** avec les clés du pairing et
/// encadré comme le canal de contrôle. Le mock, lui, se contente d'accepter la connexion et
/// de lire les octets sans jamais rien émettre (`EventGeneric` dans `ap2/connections/event.py`) :
/// **la connexion est donc validée, le décodage des événements ne l'est pas**, faute de
/// récepteur qui en émette. Les octets reçus sont journalisés et comptés, pas interprétés.
///
/// ## Invariant section 12
///
/// Une panne ici est confinée : l'échec de connexion est journalisé et signalé, jamais
/// propagé au point d'interrompre la diffusion. Ce canal est un observateur, pas un maillon
/// du chemin audio.
public final class AirPlay2EventChannel: @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "fr.baptiste.airplaymultioutput.airplay2.events")
    private let log = AudioLog.airplay2
    private let lock = NSLock()

    private var bytesReceived = 0
    private var connected = false
    private var closed = false
    /// Appelé si la connexion tombe alors qu'elle avait été établie.
    private var onDisconnect: (@Sendable () -> Void)?

    public init(host: String, port: UInt16) {
        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port) ?? .any
        )
        self.connection = NWConnection(to: endpoint, using: .tcp)
    }

    /// Ouvre la connexion. Rend `true` si le récepteur l'a acceptée avant l'échéance.
    ///
    /// Ne lève jamais : un canal d'événements indisponible ne doit pas empêcher de diffuser.
    @discardableResult
    public func connect(
        timeout: Duration = .seconds(3),
        onDisconnect: (@Sendable () -> Void)? = nil
    ) async -> Bool {
        // `withLock` et non `lock()`/`unlock()` : ces derniers sont interdits en contexte
        // asynchrone, un verrou ne devant jamais chevaucher un point de suspension.
        lock.withLock { self.onDisconnect = onDisconnect }

        let established = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            // Reprise unique garantie : une `CheckedContinuation` reprise deux fois est
            // fatale, et le piège relevé au jalon 3 (échéance et état concurrents) s'applique
            // ici mot pour mot.
            let resumed = ManagedFlag()
            connection.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    if resumed.claim() { continuation.resume(returning: true) }
                case let .failed(error):
                    self.log.error(
                        "Canal d'événements indisponible : \(String(describing: error), privacy: .public)"
                    )
                    if resumed.claim() { continuation.resume(returning: false) }
                    else { self.reportDisconnect() }
                case .cancelled:
                    if resumed.claim() { continuation.resume(returning: false) }
                    else { self.reportDisconnect() }
                default:
                    break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout.timeIntervalValue) {
                if resumed.claim() { continuation.resume(returning: false) }
            }
        }

        lock.withLock { connected = established }
        if established {
            log.info("Canal d'événements AirPlay 2 ouvert")
            receiveLoop()
        }
        return established
    }

    /// Lecture continue. Le mock n'émet rien ; le but est de voir la connexion tomber.
    private func receiveLoop() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4_096) {
            [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.lock.lock()
                self.bytesReceived += data.count
                self.lock.unlock()
                // Non interprété : le contenu réel est chiffré et encadré, et aucun récepteur
                // disponible ici n'en émet. L'interpréter à l'aveugle serait de la fiction.
                self.log.debug("Canal d'événements : \(data.count) octets reçus (non décodés)")
            }
            if isComplete || error != nil {
                self.reportDisconnect()
                return
            }
            self.receiveLoop()
        }
    }

    private func reportDisconnect() {
        lock.lock()
        let shouldReport = connected && !closed
        connected = false
        let handler = onDisconnect
        lock.unlock()
        guard shouldReport else { return }
        log.error("Canal d'événements AirPlay 2 rompu")
        handler?()
    }

    public var isConnected: Bool {
        lock.lock(); defer { lock.unlock() }; return connected
    }

    public var eventBytesReceived: Int {
        lock.lock(); defer { lock.unlock() }; return bytesReceived
    }

    public func close() {
        lock.lock()
        closed = true
        connected = false
        onDisconnect = nil
        lock.unlock()
        connection.cancel()
    }

    deinit {
        connection.cancel()
    }
}

/// Drapeau à usage unique, pour garantir qu'une continuation n'est reprise qu'une fois.
private final class ManagedFlag: @unchecked Sendable {
    private var taken = false
    private let lock = NSLock()
    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if taken { return false }
        taken = true
        return true
    }
}

extension Duration {
    /// Conversion vers `TimeInterval`, pour les API GCD qui ne connaissent pas `Duration`.
    var timeIntervalValue: TimeInterval {
        let (seconds, attoseconds) = components
        return Double(seconds) + Double(attoseconds) * 1e-18
    }
}
