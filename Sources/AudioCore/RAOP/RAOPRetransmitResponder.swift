import Foundation

/// Répond aux demandes de retransmission d'un récepteur RAOP (RTCP type `0x55`).
///
/// ## Pourquoi ce n'est pas le sender qui répond
///
/// Le récepteur réclame ce qu'il n'a pas reçu, et une perte Wi-Fi reste inaudible tant que
/// quelqu'un répond à temps. Une perte en rafale donne une rafale de demandes : si chacune
/// passait par l'acteur `RAOPSender`, elles se disputeraient son exécuteur avec la boucle de
/// diffusion, et c'est le flux audio qui prendrait du retard au pire moment.
///
/// Cet objet répond donc **directement, sur la file du canal de contrôle**, sans passer par
/// l'acteur. La boucle de diffusion n'y touche que le temps de déposer un paquet sous un verrou
/// très court. Ce verrou est permis ici : la boucle de diffusion et la file réseau sont toutes
/// deux hors temps réel, l'interdiction de la section 12 ne porte que sur le callback de
/// capture. Audio et contrôle ayant chacun leur socket, une rafale ne retarde pas non plus
/// l'émission au niveau du noyau.
///
/// ## Débit borné
///
/// Une demande peut réclamer jusqu'à 65 535 paquets, et un récepteur en difficulté la répète.
/// Renvoyer sans limite aggraverait la congestion qui a causé la perte, aux dépens du flux
/// courant. Le débit de retransmission est donc plafonné à ``maximumPacketsPerSecond`` : deux
/// fois le flux normal, de quoi rattraper une coupure d'une seconde en une demi-seconde.
final class RAOPRetransmitResponder: @unchecked Sendable {
    /// Deux fois le débit du flux audio (≈ 125 paquets/s à 44,1 kHz).
    static let maximumPacketsPerSecond = 250.0

    struct Counters: Sendable, Equatable {
        var requests = 0
        var packetsResent = 0
        /// Paquets réclamés mais déjà sortis de l'historique, ou jamais émis.
        var packetsMissing = 0
        /// Paquets non renvoyés faute de débit disponible.
        var packetsThrottled = 0
    }

    private let lock = NSLock()
    private var history: RTPPacketHistory
    private var counters = Counters()
    private let capacity: Int
    private var tokens = RAOPRetransmitResponder.maximumPacketsPerSecond
    private var lastRefill = ContinuousClock.now

    init(capacity: Int = 512) {
        self.capacity = capacity
        self.history = RTPPacketHistory(capacity: capacity)
    }

    /// Mémorise un paquet tel qu'il part sur le réseau. Appelé par la boucle de diffusion.
    func record(sequence: UInt16, packet: Data) {
        lock.lock()
        history.record(sequence: sequence, packet: packet)
        lock.unlock()
    }

    /// Oublie tout. À appeler entre deux sessions : la numérotation continue d'une session à la
    /// suivante, et un ancien paquet n'a de sens ni pour le nouveau récepteur ni pour sa clé.
    func clear() {
        lock.lock()
        history.removeAll()
        lock.unlock()
    }

    var snapshot: Counters {
        lock.lock()
        defer { lock.unlock() }
        return counters
    }

    /// Traite un datagramme reçu sur le canal de contrôle.
    ///
    /// Tout autre type de paquet est ignoré, comme le fait pyatv.
    ///
    /// - Parameter reply: émet une réponse vers l'expéditeur. Son échec reste confiné ici : le
    ///   récepteur redemandera si son tampon lui en laisse le temps.
    func handle(datagram: Data, reply: (Data) throws -> Void) {
        guard let request = RTPRetransmitRequest(datagram: datagram) else { return }

        var resent = 0
        var missing = 0
        var throttled = 0
        // Jamais plus que l'historique n'en contient : au-delà, ce serait se laisser demander
        // 65 535 recherches par un seul datagramme de 8 octets.
        let wanted = min(Int(request.count), capacity)
        for offset in 0..<wanted {
            let sequence = request.firstSequence &+ UInt16(truncatingIfNeeded: offset)

            lock.lock()
            let packet = history.packet(sequence: sequence)
            let allowed = packet != nil && takeToken()
            lock.unlock()

            guard let packet else {
                missing += 1
                continue
            }
            guard allowed else {
                throttled += 1
                continue
            }
            guard let response = RTPPacketBuilder.retransmissionResponse(originalPacket: packet)
            else { continue }
            if (try? reply(response)) != nil {
                resent += 1
            }
        }

        lock.lock()
        counters.requests += 1
        counters.packetsResent += resent
        counters.packetsMissing += missing
        counters.packetsThrottled += throttled
        lock.unlock()
    }

    /// À appeler sous le verrou.
    private func takeToken() -> Bool {
        let now = ContinuousClock.now
        let elapsed = now - lastRefill
        lastRefill = now
        let seconds = Double(elapsed.components.seconds)
            + Double(elapsed.components.attoseconds) / 1e18
        tokens = min(Self.maximumPacketsPerSecond, tokens + seconds * Self.maximumPacketsPerSecond)
        guard tokens >= 1 else { return false }
        tokens -= 1
        return true
    }
}
