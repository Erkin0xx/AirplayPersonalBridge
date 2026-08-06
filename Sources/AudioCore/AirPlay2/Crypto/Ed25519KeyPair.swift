import CEd25519
import Foundation

/// Signatures Ed25519, adossées à `orlp/ed25519` (portage SUPERCOP ref10).
///
/// Wrapper de la bibliothèque C vendue dans `Sources/CCrypto/CEd25519` (CDC 4.4).
/// Seul endroit du projet qui appelle `ed25519_*` (invariant section 12).
///
/// Rôle dans AirPlay 2 : la clé long terme (LTSK/LTPK) du contrôleur. Elle est créée une
/// fois au pairing, conservée dans les credentials, et resservie à chaque `pair-verify`
/// pour prouver notre identité au récepteur.
///
/// Attention à la terminologie d'`orlp/ed25519` : sa « clé privée » fait **64 octets**
/// (graine étendue + clé publique), pas 32. La graine de 32 octets est ce que pyatv et
/// AirPlay appellent la clé privée ; ``seed`` la restitue.
public final class Ed25519KeyPair {
    public static let seedLength = 32
    public static let publicKeyLength = 32
    /// Format interne d'orlp/ed25519 : 64 octets.
    public static let privateKeyLength = 64
    public static let signatureLength = 64

    public enum Failure: Error, Equatable {
        case invalidSeedLength(Int)
        case invalidKeyLength(Int)
        case invalidSignatureLength(Int)
    }

    /// Clé privée étendue (64 octets). Allouée à l'init, effacée puis libérée dans `deinit`.
    private let privateKeyStorage: UnsafeMutablePointer<UInt8>

    public let publicKey: Data

    /// La graine de 32 octets dont dérive la paire — c'est elle qu'on persiste dans les
    /// credentials, jamais la forme étendue de 64 octets.
    public let seed: Data

    /// Génère une paire long terme depuis le générateur aléatoire du système.
    ///
    /// `seed.c` de la bibliothèque amont est volontairement écarté (voir
    /// `Sources/CCrypto/README.md`) : l'entropie vient de Swift, pas d'un `/dev/urandom`
    /// ouvert en C.
    public convenience init() throws {
        var generated = Data(count: Self.seedLength)
        var generator = SystemRandomNumberGenerator()
        for index in 0..<Self.seedLength {
            generated[index] = UInt8.random(in: UInt8.min...UInt8.max, using: &generator)
        }
        try self.init(seed: generated)
    }

    /// Reconstruit la paire depuis une graine de 32 octets (cas des credentials relus).
    public init(seed: Data) throws {
        guard seed.count == Self.seedLength else {
            throw Failure.invalidSeedLength(seed.count)
        }
        self.seed = seed

        // Variable locale : les closures ci-dessous captureraient `self` avant que toutes
        // ses propriétés soient initialisées.
        let storage = UnsafeMutablePointer<UInt8>.allocate(capacity: Self.privateKeyLength)
        storage.initialize(repeating: 0, count: Self.privateKeyLength)

        var derivedPublic = Data(count: Self.publicKeyLength)
        derivedPublic.withUnsafeMutableBytes { publicBytes in
            guard let publicBase = publicBytes.bindMemory(to: UInt8.self).baseAddress else { return }
            seed.withUnsafeBytes { seedBytes in
                guard let seedBase = seedBytes.bindMemory(to: UInt8.self).baseAddress else { return }
                ed25519_create_keypair(publicBase, storage, seedBase)
            }
        }
        privateKeyStorage = storage
        publicKey = derivedPublic
    }

    deinit {
        privateKeyStorage.update(repeating: 0, count: Self.privateKeyLength)
        privateKeyStorage.deinitialize(count: Self.privateKeyLength)
        privateKeyStorage.deallocate()
    }

    /// Signe `message` avec la clé long terme. Signature de 64 octets.
    public func sign(_ message: Data) -> Data {
        var signature = Data(count: Self.signatureLength)
        signature.withUnsafeMutableBytes { signatureBytes in
            guard let signatureBase = signatureBytes.bindMemory(to: UInt8.self).baseAddress else { return }
            publicKey.withUnsafeBytes { publicBytes in
                guard let publicBase = publicBytes.bindMemory(to: UInt8.self).baseAddress else { return }
                Self.withMessageBytes(message) { messageBase, messageCount in
                    ed25519_sign(
                        signatureBase,
                        messageBase, messageCount,
                        publicBase, privateKeyStorage
                    )
                }
            }
        }
        return signature
    }

    /// Vérifie une signature contre une clé publique arbitraire.
    ///
    /// Statique : on vérifie la signature **du récepteur**, pour laquelle on n'a qu'une clé
    /// publique et aucune paire.
    public static func verify(
        signature: Data,
        message: Data,
        publicKey: Data
    ) throws -> Bool {
        guard signature.count == signatureLength else {
            throw Failure.invalidSignatureLength(signature.count)
        }
        guard publicKey.count == publicKeyLength else {
            throw Failure.invalidKeyLength(publicKey.count)
        }

        return signature.withUnsafeBytes { signatureBytes -> Bool in
            guard let signatureBase = signatureBytes.bindMemory(to: UInt8.self).baseAddress else {
                return false
            }
            return publicKey.withUnsafeBytes { publicBytes -> Bool in
                guard let publicBase = publicBytes.bindMemory(to: UInt8.self).baseAddress else {
                    return false
                }
                return withMessageBytes(message) { messageBase, messageCount in
                    ed25519_verify(signatureBase, messageBase, messageCount, publicBase) == 1
                }
            }
        }
    }

    /// Ed25519 accepte un message vide ; `Data` vide donnerait un `baseAddress` nul, que la
    /// bibliothèque C déréférencerait. On lui passe alors un tampon d'un octet, de longueur 0.
    private static func withMessageBytes<R>(
        _ message: Data,
        _ body: (UnsafePointer<UInt8>, Int) -> R
    ) -> R {
        guard !message.isEmpty else {
            let placeholder: [UInt8] = [0]
            return placeholder.withUnsafeBufferPointer { buffer in
                // baseAddress non nul, longueur 0 : la bibliothèque ne lira rien.
                guard let base = buffer.baseAddress else { fatalError("tampon vide impossible") }
                return body(base, 0)
            }
        }
        return message.withUnsafeBytes { bytes in
            guard let base = bytes.bindMemory(to: UInt8.self).baseAddress else {
                fatalError("Data non vide sans adresse de base")
            }
            return body(base, message.count)
        }
    }
}
