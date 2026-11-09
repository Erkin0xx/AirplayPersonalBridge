import Foundation

/// Ce qu'un récepteur ajoute de lui-même à la latence annoncée dans un paquet de synchro, en trames.
///
/// Un récepteur RAOP ne joue pas l'estampille courante `latence annoncée` après l'instant NTP du
/// paquet, mais `latence annoncée + 11 025 trames` (0,25 s à 44,1 kHz) : c'est la valeur historique
/// d'iTunes, que décrivent shairport-sync et OwnTone, et qu'Airfoil compense en annonçant 1,75 s
/// pour obtenir 2,0 s (analyse statique, `airfoil-analyse.md` du vault, Q3). Mesuré au micro le
/// 2026-11-02 sans compensation : la Geneva et les HomePod jouent 290 à 307 ms après l'instant visé.
///
/// **Réglé par protocole**, parce que rien ne prouve que la voie AirPlay 2 ajoute la même constante
/// que RAOP : c'est la mesure au micro, enceinte par enceinte, qui le dit.
public struct ReceiverAddedLatency: Sendable, Equatable {
    /// La constante historique : 0,25 s à 44,1 kHz.
    public static let historicalFrames: UInt32 = 11_025

    public var raopFrames: UInt32
    public var airPlay2Frames: UInt32

    public init(raopFrames: UInt32, airPlay2Frames: UInt32) {
        self.raopFrames = raopFrames
        self.airPlay2Frames = airPlay2Frames
    }

    /// Ce que l'app et le CLI emploient sans réglage : la constante historique pour les deux
    /// familles.
    ///
    /// Mesuré au micro le 2026-11-09, enceinte par enceinte, son direct à table, sans puis avec :
    /// Geneva +292,4 → +43 ms, HomePod « Salon » +289,7 → +40,1 ms, « Salon (2) » +295,9 → +46,5 ms.
    /// Les trois avancent de 0,25 s et gardent leurs écarts (6,2 ms avant, 6,4 ms après). **Les deux
    /// familles vont ensemble** : n'en compenser qu'une les mettrait à 0,25 s l'une de l'autre.
    public static let `default` = ReceiverAddedLatency(
        raopFrames: historicalFrames, airPlay2Frames: historicalFrames
    )
}

/// Les deux latences d'une sortie : celle qu'on vise, et celle qu'on écrit dans le paquet de synchro.
///
/// **Le seul endroit où le délai de restitution devient des trames.** Les senders n'ont plus de
/// constante à eux : ils reçoivent le délai de l'horloge commune, et la latence annoncée en découle.
/// Changer le délai de l'horloge déplace donc ensemble l'instant visé et ce que dit le fil.
///
/// ## Le calcul
///
/// Le paquet dit : « l'estampille `courante − annoncée` correspond à l'instant NTP que voici ». Le
/// récepteur joue l'estampille courante à `NTP + (annoncée + ajout du récepteur) / fréquence`. Pour
/// qu'elle sorte à l'instant visé, il faut :
///
/// - annoncer `visée − ajout` (``announcedFrames``) ;
/// - donner pour NTP l'instant visé moins la latence **visée** entière (``playoutFrames``), et non
///   la seule latence annoncée : sinon toutes les enceintes reculeraient de l'ajout qu'on vient de
///   retirer.
public struct SyncLatency: Sendable, Equatable {
    /// Latence visée, de l'instant NTP annoncé à la restitution de l'estampille courante.
    public let playoutFrames: UInt32
    /// Ce que le récepteur ajoute à la latence annoncée.
    public let receiverAddedFrames: UInt32

    /// Latence à écrire dans le paquet de synchro.
    public var announcedFrames: UInt32 { playoutFrames - receiverAddedFrames }

    /// - Parameters:
    ///   - playoutDelaySeconds: délai de restitution de l'horloge commune.
    ///   - sampleRate: fréquence du flux émis.
    ///   - receiverAddedFrames: ajout du récepteur, borné à la latence visée (une latence annoncée
    ///     ne peut pas être négative).
    public init(playoutDelaySeconds: Double, sampleRate: Double, receiverAddedFrames: UInt32) {
        let frames = (max(0, playoutDelaySeconds) * sampleRate).rounded()
        let playout = UInt32(min(frames, Double(UInt32.max)))
        self.playoutFrames = playout
        self.receiverAddedFrames = min(receiverAddedFrames, playout)
    }
}
