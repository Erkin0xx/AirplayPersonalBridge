import Foundation
import Network
import OSLog

/// Canal UDP d'une session RAOP, sur port local fixé.
///
/// Les ports locaux doivent être connus **avant** l'envoi du `SETUP` : ils y sont annoncés
/// au récepteur, qui s'en sert comme destination pour ses paquets de contrôle et de timing.
/// D'où l'écoute (`NWListener`) plutôt qu'une simple connexion sortante — un socket
/// purement sortant se verrait attribuer un port éphémère inconnu à l'avance.
///
/// Le canal audio est unidirectionnel, mais control et timing reçoivent tous deux du
/// trafic à l'initiative du récepteur : demandes de retransmission d'un côté, requêtes
/// d'horloge de l'autre.
public final class UDPChannel: @unchecked Sendable {
    /// Port local réellement attribué, à annoncer dans le `SETUP`.
    public let localPort: UInt16
    public let label: String

    private let descriptor: Int32
    private let log = AudioLog.raop
    private var receiveSource: DispatchSourceRead?
    private let receiveQueue: DispatchQueue

    /// Destination courante. Connue seulement après la réponse au `SETUP`, qui donne les
    /// ports réellement ouverts par le récepteur.
    private var destination: sockaddr_storage?
    private var destinationLength: socklen_t = 0
    private let lock = NSLock()

    /// Appelé pour chaque datagramme reçu, sur `receiveQueue`.
    /// Le second paramètre est l'adresse de l'émetteur.
    public var onReceive: ((Data, sockaddr_storage) -> Void)?

    /// Ouvre un socket UDP. Un `preferredPort` nul laisse le système choisir.
    ///
    /// Le socket BSD est ici préféré à `NWConnection` : RAOP exige d'émettre **et** de
    /// recevoir sur le *même* port local, ce que le Network framework n'exprime pas
    /// directement pour UDP sans passer par un listener plus un chemin de connexion séparé.
    /// Toute la manipulation du descripteur est confinée à cette classe, qui le referme dans
    /// son `deinit` (invariant section 12).
    public init(label: String, preferredPort: UInt16 = 0) throws {
        self.label = label
        self.receiveQueue = DispatchQueue(
            label: "fr.baptiste.airplaymultioutput.raop.\(label)", qos: .userInitiated
        )

        let descriptor = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard descriptor >= 0 else {
            throw UDPChannelError.socketCreationFailed(label: label, errno: errno)
        }

        var reuse: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = INADDR_ANY
        address.sin_port = preferredPort.bigEndian
        let bindStatus = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindStatus == 0 else {
            let failure = errno
            close(descriptor)
            throw UDPChannelError.bindFailed(label: label, port: preferredPort, errno: failure)
        }

        // Relire le port effectif : avec preferredPort = 0, c'est le noyau qui l'a choisi.
        var bound = sockaddr_in()
        var boundLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameStatus = withUnsafeMutablePointer(to: &bound) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(descriptor, $0, &boundLength)
            }
        }
        guard nameStatus == 0 else {
            let failure = errno
            close(descriptor)
            throw UDPChannelError.bindFailed(label: label, port: preferredPort, errno: failure)
        }

        self.descriptor = descriptor
        self.localPort = UInt16(bigEndian: bound.sin_port)
        log.debug("Canal UDP « \(label, privacy: .public) » ouvert sur le port \(self.localPort)")
    }

    deinit {
        receiveSource?.cancel()
        close(descriptor)
    }

    /// Fixe la destination des envois, d'après les ports renvoyés par le `SETUP`.
    public func setDestination(host: String, port: UInt16) throws {
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        guard inet_pton(AF_INET, host, &address.sin_addr) == 1 else {
            throw UDPChannelError.invalidDestination(host: host)
        }
        var storage = sockaddr_storage()
        withUnsafeMutableBytes(of: &storage) { raw in
            withUnsafeBytes(of: address) { source in
                raw.copyMemory(from: source)
            }
        }
        lock.lock()
        destination = storage
        destinationLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        lock.unlock()
    }

    /// Émet un datagramme vers la destination courante.
    ///
    /// Non bloquant côté appelant sur un réseau local : `sendto` sur UDP place le paquet
    /// dans le tampon de sortie du noyau et rend la main immédiatement.
    public func send(_ data: Data) throws {
        lock.lock()
        guard var target = destination else {
            lock.unlock()
            throw UDPChannelError.destinationNotSet(label: label)
        }
        let length = destinationLength
        lock.unlock()

        let sent = data.withUnsafeBytes { payload -> Int in
            withUnsafePointer(to: &target) { storagePointer in
                storagePointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { addressPointer in
                    sendto(descriptor, payload.baseAddress, payload.count, 0, addressPointer, length)
                }
            }
        }
        guard sent >= 0 else {
            throw UDPChannelError.sendFailed(label: label, errno: errno)
        }
    }

    /// Émet un datagramme vers une adresse précise, sans toucher à la destination courante.
    ///
    /// Nécessaire pour répondre à une requête d'horloge sur un canal qui n'a pas de
    /// destination fixée : en AirPlay 2, le récepteur interroge notre port de timing avant que
    /// le `SETUP` n'ait rendu la moindre adresse. On répond donc à l'expéditeur.
    public func send(_ data: Data, to address: sockaddr_storage) throws {
        var target = address
        let length = socklen_t(
            target.ss_family == sa_family_t(AF_INET6)
                ? MemoryLayout<sockaddr_in6>.size
                : MemoryLayout<sockaddr_in>.size
        )
        let sent = data.withUnsafeBytes { payload -> Int in
            withUnsafePointer(to: &target) { storagePointer in
                storagePointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { addressPointer in
                    sendto(descriptor, payload.baseAddress, payload.count, 0, addressPointer, length)
                }
            }
        }
        guard sent >= 0 else {
            throw UDPChannelError.sendFailed(label: label, errno: errno)
        }
    }

    /// Démarre la réception. Chaque datagramme est passé à `onReceive`.
    public func startReceiving() {
        guard receiveSource == nil else { return }
        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: receiveQueue)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            // 2048 octets : au-delà de tout paquet RAOP de contrôle ou de timing, dont les
            // plus gros font quelques dizaines d'octets.
            var buffer = [UInt8](repeating: 0, count: 2_048)
            var sender = sockaddr_storage()
            var senderLength = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let received = withUnsafeMutablePointer(to: &sender) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { addressPointer in
                    recvfrom(self.descriptor, &buffer, buffer.count, 0, addressPointer, &senderLength)
                }
            }
            guard received > 0 else { return }
            self.onReceive?(Data(buffer[0..<received]), sender)
        }
        source.resume()
        receiveSource = source
    }

    public func stop() {
        receiveSource?.cancel()
        receiveSource = nil
    }
}

public enum UDPChannelError: Error, CustomStringConvertible {
    case socketCreationFailed(label: String, errno: Int32)
    case bindFailed(label: String, port: UInt16, errno: Int32)
    case invalidDestination(host: String)
    case destinationNotSet(label: String)
    case sendFailed(label: String, errno: Int32)

    public var description: String {
        switch self {
        case let .socketCreationFailed(label, code):
            return "création du socket UDP « \(label) » impossible (errno \(code))"
        case let .bindFailed(label, port, code):
            return "attachement du canal « \(label) » au port \(port) impossible (errno \(code))"
        case let .invalidDestination(host):
            return "adresse de destination invalide : \(host)"
        case let .destinationNotSet(label):
            return "envoi sur le canal « \(label) » avant que sa destination soit connue"
        case let .sendFailed(label, code):
            return "envoi sur le canal « \(label) » en échec (errno \(code))"
        }
    }
}
