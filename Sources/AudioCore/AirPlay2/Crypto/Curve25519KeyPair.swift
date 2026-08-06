import CCurve25519
import Foundation

/// Échange de clés X25519, adossé à `agl/curve25519-donna`.
///
/// Wrapper de la bibliothèque C vendue dans `Sources/CCrypto/CCurve25519` (CDC 4.4 :
/// la primitive n'est pas retranscrite en Swift). Seul endroit du projet qui appelle
/// `curve25519_donna` (invariant section 12).
///
/// Sert au `pair-verify` d'AirPlay 2 : chaque session génère une paire éphémère, et le
/// secret partagé alimente le HKDF qui produit les clés de chiffrement de session.
///
/// La clé privée est stockée dans un tampon alloué explicitement, remis à zéro dans
/// `deinit` : la laisser dans un `Data` la ferait recopier au gré des copies de valeur,
/// sans garantie d'effacement à la libération.
public final class Curve25519KeyPair {
    /// Toutes les valeurs X25519 font 32 octets : clé privée, clé publique, secret partagé.
    public static let keyLength = 32

    public enum Failure: Error, Equatable {
        case invalidKeyLength(Int)
        /// `curve25519_donna` a renvoyé un code non nul.
        case computationFailed
    }

    /// Clé privée « clampée ». Allouée à l'init, effacée puis libérée dans `deinit`.
    private let privateKeyStorage: UnsafeMutablePointer<UInt8>

    /// Clé publique correspondante, dérivée à l'init. Publique par nature, donc sans
    /// précaution d'effacement.
    public let publicKey: Data

    /// Génère une paire éphémère à partir du générateur aléatoire du système.
    public convenience init() throws {
        var seed = Data(count: Self.keyLength)
        var generator = SystemRandomNumberGenerator()
        for index in 0..<Self.keyLength {
            seed[index] = UInt8.random(in: UInt8.min...UInt8.max, using: &generator)
        }
        try self.init(privateKey: seed)
    }

    /// Reconstruit une paire depuis une clé privée existante.
    ///
    /// Le « clamping » RFC 7748 est appliqué ici plutôt que laissé à l'appelant : donna
    /// l'attend déjà fait, et l'oublier produit un secret partagé faux de façon silencieuse.
    public init(privateKey: Data) throws {
        guard privateKey.count == Self.keyLength else {
            throw Failure.invalidKeyLength(privateKey.count)
        }

        // Variable locale plutôt que la propriété : les closures ci-dessous captureraient
        // `self` avant que toutes ses propriétés soient initialisées.
        let storage = UnsafeMutablePointer<UInt8>.allocate(capacity: Self.keyLength)
        storage.initialize(repeating: 0, count: Self.keyLength)
        privateKey.withUnsafeBytes { bytes in
            guard let base = bytes.bindMemory(to: UInt8.self).baseAddress else { return }
            storage.update(from: base, count: Self.keyLength)
        }
        // Clamping RFC 7748 §5 : efface les 3 bits de poids faible du premier octet,
        // force le bit 254 et efface le bit 255 du dernier.
        storage[0] &= 248
        storage[31] &= 127
        storage[31] |= 64

        var derived = Data(count: Self.keyLength)
        let status = derived.withUnsafeMutableBytes { publicBytes -> Int32 in
            guard let out = publicBytes.bindMemory(to: UInt8.self).baseAddress else { return -1 }
            // Base X25519 : le point {9}, suivi de 31 octets nuls.
            var basePoint = [UInt8](repeating: 0, count: Self.keyLength)
            basePoint[0] = 9
            return curve25519_donna(out, storage, basePoint)
        }
        guard status == 0 else {
            storage.deinitialize(count: Self.keyLength)
            storage.deallocate()
            throw Failure.computationFailed
        }
        privateKeyStorage = storage
        publicKey = derived
    }

    deinit {
        // Effacement avant libération : c'est du matériel de clé.
        privateKeyStorage.update(repeating: 0, count: Self.keyLength)
        privateKeyStorage.deinitialize(count: Self.keyLength)
        privateKeyStorage.deallocate()
    }

    /// Calcule le secret partagé X25519 avec la clé publique du pair.
    ///
    /// Le résultat est le secret brut, sans dérivation : c'est au HKDF appelant de le
    /// transformer en clés de session (`Pair-Verify-Encrypt-Salt` / `-Info` côté AirPlay 2).
    public func sharedSecret(withPublicKey peerPublicKey: Data) throws -> Data {
        guard peerPublicKey.count == Self.keyLength else {
            throw Failure.invalidKeyLength(peerPublicKey.count)
        }

        var shared = Data(count: Self.keyLength)
        let status = shared.withUnsafeMutableBytes { sharedBytes -> Int32 in
            guard let out = sharedBytes.bindMemory(to: UInt8.self).baseAddress else { return -1 }
            return peerPublicKey.withUnsafeBytes { peerBytes -> Int32 in
                guard let peer = peerBytes.bindMemory(to: UInt8.self).baseAddress else { return -1 }
                return curve25519_donna(out, privateKeyStorage, peer)
            }
        }
        guard status == 0 else {
            throw Failure.computationFailed
        }
        return shared
    }
}
