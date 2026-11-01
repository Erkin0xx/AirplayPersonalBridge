import Foundation

/// Répond aux demandes de retransmission du récepteur, sur le chemin AirPlay 2.
///
/// C'est ce qui rend une perte Wi-Fi inaudible : le récepteur réclame les paquets manquants sur
/// le canal de contrôle (`0x55`) tant que son tampon lui en laisse le temps. pyatv y répond de la
/// même façon en AirPlay 1 et 2 (`ControlClient._retransmit_lost_packets` de `stream_client.py`,
/// qui sert les deux protocoles), en renvoyant le paquet **tel qu'il est parti** : son nonce le
/// suit, il reste donc déchiffrable sans rien recalculer.
///
/// ## Pourquoi pas dans l'acteur du sender
///
/// Une rafale de demandes ne doit pas retarder le flux. Ce type est donc partagé entre deux
/// fils : le sender y dépose chaque paquet émis, et le canal de contrôle sert les demandes depuis
/// sa propre file, sans jamais repasser par l'acteur. Le verrou ne protège qu'un rangement en
/// mémoire ; il est repris à chaque paquet servi plutôt que tenu pendant toute une rafale. On est
/// ici entre deux fils réseau : l'invariant section 12 interdit un verrou sur le callback de
/// capture temps réel, qui n'est pas concerné.
final class AirPlay2Retransmitter: @unchecked Sendable {
    /// Paquets retenus : ~4 s de son, soit le double de la latence maximale négociée au `SETUP`
    /// (`latencyMax` = 88 200 trames). Au-delà, un paquet renvoyé arriverait de toute façon trop
    /// tard pour être joué.
    static let capacity = 512

    private let lock = NSLock()
    private var history = RTPPacketHistory(capacity: AirPlay2Retransmitter.capacity)

    func record(sequence: UInt16, packet: Data) {
        lock.lock()
        history.record(sequence: sequence, packet: packet)
        lock.unlock()
    }

    /// Oublie tout. Indispensable à la reconnexion : la session suivante chiffre avec une autre
    /// clé, un paquet de la précédente serait indéchiffrable.
    func reset() {
        lock.lock()
        history.removeAll()
        lock.unlock()
    }

    /// Les réponses à émettre pour une demande, et le nombre de paquets qu'on n'a plus.
    ///
    /// Le `count` vient du réseau et peut valoir 65 535 : il est borné à ce que l'historique peut
    /// contenir, plutôt que d'énumérer des numéros qu'on sait absents.
    func responses(for request: RTPRetransmitRequest) -> (responses: [Data], missing: Int) {
        let requested = min(Int(request.count), Self.capacity)
        var responses: [Data] = []
        responses.reserveCapacity(requested)
        for offset in 0..<requested {
            lock.lock()
            let packet = history.packet(sequence: request.firstSequence &+ UInt16(offset))
            lock.unlock()
            if let packet { responses.append(Self.response(wrapping: packet)) }
        }
        return (responses, Int(request.count) - responses.count)
    }

    /// Enveloppe un paquet audio : `80 D6 | séquence d'origine (2) | paquet complet`.
    ///
    /// La séquence d'origine est recopiée depuis le paquet lui-même, comme chez pyatv.
    static func response(wrapping packet: Data) -> Data {
        var response = Data(capacity: packet.count + 4)
        response.append(0x80)
        response.append(RTPPayloadType.audioResend.rawValue | 0x80)
        response.append(contentsOf: packet.dropFirst(2).prefix(2))
        response.append(packet)
        return response
    }
}
