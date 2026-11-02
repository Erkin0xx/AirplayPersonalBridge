import Foundation

/// Tour de pairing : un seul pairing AirPlay 2 à la fois parmi les sorties qui partagent ce tour.
///
/// ## Le défaut qui le justifie
///
/// Deux HomePod en paire stéréo, « Salon » et « Salon (2) », adressés ensemble : leurs deux
/// pair-setups transitoires partaient dans la même milliseconde, et l'un était refusé à M4 (TLV
/// d'erreur « authentification »). Le même essai, une heure plus tôt, avait réussi pour les deux.
/// L'hypothèse — les membres d'une paire partagent l'état SRP du pair-setup, et deux échanges
/// concurrents s'y mélangent — **n'est pas prouvée**. Ce tour retire la concurrence, quelle qu'en
/// soit la cause ; le sender réessaie par ailleurs un refus transitoire (``AirPlay2Sender``).
///
/// ## Pourquoi tous les récepteurs, et pas seulement les membres d'une paire
///
/// Le TXT porte de quoi reconnaître une paire ou un groupe (`tsid`, `gid`), mais le tour ne s'en
/// sert pas, pour trois raisons :
///
/// - la cause n'étant pas établie, rien ne dit que le partage s'arrête à la paire ;
/// - un TXT peut manquer à la découverte (``AirPlay2Device/txt`` vide) : un tour par `tsid` ne
///   protégerait plus, sans le moindre signe, exactement le cas qu'il doit couvrir ;
/// - le coût est faible : seul le pairing est tenu (environ 0,3 s sur un HomePod), ni la connexion,
///   ni les `SETUP`, ni la diffusion. Une sortie de plus attend au pire le pairing des autres.
///
/// Le tour n'est tenu que pendant les échanges de pairing, chacun borné par l'échéance de
/// `RTSPClient` : un récepteur qui ne répond plus ne retient les autres que jusqu'à cette échéance.
///
/// ## Invariant section 12 : chaque sender ignore l'existence de l'autre
///
/// Ce n'est pas un canal entre senders : un verrou asynchrone générique, qui ne transporte rien, ne
/// sait ni qui l'attend ni pour quel récepteur, et ne donne à personne le moyen d'atteindre un autre
/// sender. Un sender sait seulement qu'il doit attendre son tour avant de négocier, comme il attend
/// une réponse réseau. C'est le moteur qui en crée un et le passe à toutes ses sorties, comme
/// l'horloge commune.
public protocol PairingGate: Sendable {
    /// Attend que plus aucun autre pairing ne soit en cours, puis prend le tour.
    ///
    /// - Throws: `CancellationError` si la tâche est annulée pendant l'attente. Le tour n'est alors
    ///   **pas** pris, et il n'y a rien à rendre.
    func acquire() async throws
    /// Rend le tour. Une fois, et une seule, après chaque ``acquire()`` qui a abouti.
    func release()
}

/// Le tour de pairing réel : premier arrivé, premier servi.
///
/// Un verrou et des continuations plutôt qu'un acteur : ``release()`` doit rester synchrone pour
/// pouvoir s'écrire dans un `defer`, seule façon de garantir qu'aucun chemin d'erreur n'oublie de
/// rendre le tour. Aucun code temps réel n'y passe : seuls les senders, depuis leurs tâches de
/// négociation.
public final class SerialPairingGate: PairingGate, @unchecked Sendable {
    private struct Waiter {
        let id: UInt64
        let continuation: CheckedContinuation<Void, Error>
    }

    private let lock = NSLock()
    private var held = false
    private var waiters: [Waiter] = []
    private var nextWaiterID: UInt64 = 0

    public init() {}

    /// Attentes en cours. Interne : seuls les tests le lisent, pour ordonner leurs arrivées.
    var waitingCount: Int { lock.withLock { waiters.count } }

    public func acquire() async throws {
        let id = lock.withLock {
            nextWaiterID &+= 1
            return nextWaiterID
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.lock()
                // Vérifié sous le verrou : une annulation survenue avant ce point ne trouverait pas
                // l'attente à retirer, et celle-ci ne serait jamais reprise.
                if Task.isCancelled {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                } else if !held {
                    held = true
                    lock.unlock()
                    continuation.resume()
                } else {
                    waiters.append(Waiter(id: id, continuation: continuation))
                    lock.unlock()
                }
            }
        } onCancel: {
            lock.lock()
            // Absente : le tour lui a déjà été donné, ou elle n'est pas encore inscrite et verra
            // l'annulation en s'inscrivant. Dans les deux cas, rien à faire ici.
            guard let index = waiters.firstIndex(where: { $0.id == id }) else {
                lock.unlock()
                return
            }
            let waiter = waiters.remove(at: index)
            lock.unlock()
            waiter.continuation.resume(throwing: CancellationError())
        }
    }

    public func release() {
        lock.lock()
        guard !waiters.isEmpty else {
            held = false
            lock.unlock()
            return
        }
        // Le tour passe directement au suivant, `held` restant vrai : personne ne peut s'intercaler
        // entre les deux.
        let next = waiters.removeFirst()
        lock.unlock()
        next.continuation.resume()
    }
}
