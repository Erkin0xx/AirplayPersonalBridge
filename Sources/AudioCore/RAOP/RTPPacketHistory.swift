import Foundation

/// Une demande de retransmission reçue sur le canal de contrôle (RTCP type `0x55`).
///
/// Format commun à RAOP et à AirPlay 2 : `80 D5 | séquence(2) | premier perdu(2) | nombre(2)`,
/// en big-endian. Le récepteur la réémet tant que son tampon lui en laisse le temps : c'est
/// ce qui rend une perte Wi-Fi inaudible, à condition que quelqu'un réponde.
struct RTPRetransmitRequest: Equatable, Sendable {
    let firstSequence: UInt16
    let count: UInt16

    /// `nil` si le datagramme n'est pas une demande de retransmission bien formée.
    init?(datagram: Data) {
        let bytes = [UInt8](datagram.prefix(8))
        guard bytes.count == 8, bytes[1] & 0x7F == RTPPayloadType.retransmitRequest.rawValue else {
            return nil
        }
        firstSequence = UInt16(bytes[4]) << 8 | UInt16(bytes[5])
        count = UInt16(bytes[6]) << 8 | UInt16(bytes[7])
    }

    /// Les numéros demandés, le passage de 65 535 à 0 compris.
    var sequences: [UInt16] {
        (0..<count).map { firstSequence &+ $0 }
    }
}

/// Les derniers paquets audio émis, tels qu'ils sont partis sur le réseau.
///
/// Une case par numéro de séquence modulo la capacité : écrire et relire sont en temps
/// constant, sans allocation de structure à chaque paquet, et un paquet trop ancien est
/// simplement écrasé par son successeur. Chaque case retient son numéro complet, pour ne
/// jamais rendre un paquet périmé à la place de celui qui est demandé.
struct RTPPacketHistory: Sendable {
    private var slots: [(sequence: UInt16, packet: Data)?]

    /// 512 paquets de 352 trames à 44,1 kHz couvrent environ 4 s, soit davantage que le
    /// tampon de restitution des récepteurs : au-delà, renvoyer ne servirait plus à rien.
    init(capacity: Int = 512) {
        slots = Array(repeating: nil, count: max(capacity, 1))
    }

    mutating func record(sequence: UInt16, packet: Data) {
        slots[Int(sequence) % slots.count] = (sequence, packet)
    }

    func packet(sequence: UInt16) -> Data? {
        guard let slot = slots[Int(sequence) % slots.count], slot.sequence == sequence else {
            return nil
        }
        return slot.packet
    }

    mutating func removeAll() {
        for index in slots.indices { slots[index] = nil }
    }
}
