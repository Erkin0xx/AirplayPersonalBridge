import CChachaPoly
import Foundation

/// ChaCha20-Poly1305 AEAD (RFC 7539), adossé à `grigorig/chachapoly`.
///
/// Wrapper de la bibliothèque C vendue dans `Sources/CCrypto/CChachaPoly` : le CDC 4.4
/// interdit de retranscrire la primitive elle-même en Swift. Cette classe est le seul
/// endroit du projet qui touche à `chachapoly_ctx` (invariant section 12).
///
/// Le contexte est alloué à l'init et libéré dans `deinit`. Il contient la clé étendue :
/// il est effacé avant d'être rendu, pour ne pas laisser traîner de matériel de clé dans
/// de la mémoire libérée.
///
/// AirPlay 2 s'en sert à deux endroits : le chiffrement des sous-TLV du pairing
/// (nonces `PS-Msg05`, `PV-Msg02`…) et celui des trames audio une fois la session établie.
public final class ChaChaPoly1305 {
    /// Longueur de clé exigée par RFC 7539, et la seule qu'utilise AirPlay 2.
    public static let keyLength = 32
    /// Nonce RFC 7539 : 96 bits.
    public static let nonceLength = 12
    /// Étiquette d'authentification Poly1305.
    public static let tagLength = 16

    public enum Failure: Error, Equatable {
        /// Longueur de clé refusée par `chachapoly_init`.
        case invalidKeyLength(Int)
        /// Nonce de taille autre que 12 octets : la bibliothèque C lit une taille fixe,
        /// un nonce plus court provoquerait une lecture hors limites.
        case invalidNonceLength(Int)
        /// Le déchiffrement a échoué : l'étiquette ne correspond pas. Message forgé,
        /// altéré, ou clé/nonce erronés.
        case authenticationFailed
        /// `chachapoly_init` a renvoyé un code d'erreur.
        case initialisationFailed(Int32)
    }

    /// Alloué une fois, libéré dans `deinit`. Jamais exposé hors de cette classe.
    private let context: UnsafeMutablePointer<chachapoly_ctx>

    /// - Parameter key: 32 octets. Toute autre longueur est refusée.
    public init(key: Data) throws {
        guard key.count == Self.keyLength else {
            throw Failure.invalidKeyLength(key.count)
        }
        context = UnsafeMutablePointer<chachapoly_ctx>.allocate(capacity: 1)
        context.initialize(to: chachapoly_ctx())

        let status = key.withUnsafeBytes { keyBytes in
            chachapoly_init(context, keyBytes.baseAddress, Int32(Self.keyLength * 8))
        }
        guard status == CHACHAPOLY_OK else {
            // L'allocation a réussi mais l'init a échoué : libérer ici, `deinit` ne sera
            // jamais appelé puisque l'initialiseur lève.
            context.deinitialize(count: 1)
            context.deallocate()
            throw Failure.initialisationFailed(status)
        }
    }

    deinit {
        // Effacer le contexte avant de le rendre : il porte la clé étendue.
        context.pointee = chachapoly_ctx()
        context.deinitialize(count: 1)
        context.deallocate()
    }

    /// Chiffre `plaintext` et renvoie le cryptogramme suivi de l'étiquette de 16 octets.
    ///
    /// C'est la convention d'AirPlay 2 (et de HomeKit) : l'étiquette est concaténée au
    /// cryptogramme dans le champ `kTLVType_EncryptedData`, jamais transmise à part.
    public func seal(_ plaintext: Data, nonce: Data, additionalData: Data = Data()) throws -> Data {
        guard nonce.count == Self.nonceLength else {
            throw Failure.invalidNonceLength(nonce.count)
        }

        var ciphertext = Data(count: plaintext.count)
        var tag = Data(count: Self.tagLength)
        // `chachapoly_crypt` écrit dans `input` quand entrée et sortie se recouvrent ;
        // on lui passe une copie propre pour ne jamais modifier l'argument de l'appelant.
        var input = plaintext

        let status = Self.withOptionalBytes(additionalData) { adBytes, adCount in
            input.withUnsafeMutableBytes { inputBytes in
                ciphertext.withUnsafeMutableBytes { outputBytes in
                    tag.withUnsafeMutableBytes { tagBytes in
                        nonce.withUnsafeBytes { nonceBytes in
                            chachapoly_crypt(
                                context,
                                nonceBytes.baseAddress,
                                adBytes, adCount,
                                inputBytes.baseAddress, Int32(plaintext.count),
                                outputBytes.baseAddress,
                                tagBytes.baseAddress, Int32(Self.tagLength),
                                1  // encrypt
                            )
                        }
                    }
                }
            }
        }
        guard status == CHACHAPOLY_OK else {
            throw Failure.initialisationFailed(status)
        }
        return ciphertext + tag
    }

    /// Vérifie puis déchiffre un message produit par ``seal(_:nonce:additionalData:)``.
    ///
    /// - Parameter sealed: cryptogramme **suivi** de l'étiquette de 16 octets.
    /// - Throws: ``Failure/authenticationFailed`` si l'étiquette ne correspond pas. Dans ce
    ///   cas rien n'est renvoyé : un texte clair non authentifié ne doit jamais remonter.
    public func open(_ sealed: Data, nonce: Data, additionalData: Data = Data()) throws -> Data {
        guard nonce.count == Self.nonceLength else {
            throw Failure.invalidNonceLength(nonce.count)
        }
        guard sealed.count >= Self.tagLength else {
            throw Failure.authenticationFailed
        }

        let boundary = sealed.count - Self.tagLength
        // `Data` tranché garde l'indexation de l'original : re-baser pour que
        // `withUnsafeBytes` parte bien de l'octet 0.
        var input = Data(sealed.prefix(boundary))
        var tag = Data(sealed.suffix(Self.tagLength))
        var plaintext = Data(count: boundary)

        let status = Self.withOptionalBytes(additionalData) { adBytes, adCount in
            input.withUnsafeMutableBytes { inputBytes in
                plaintext.withUnsafeMutableBytes { outputBytes in
                    tag.withUnsafeMutableBytes { tagBytes in
                        nonce.withUnsafeBytes { nonceBytes in
                            chachapoly_crypt(
                                context,
                                nonceBytes.baseAddress,
                                adBytes, adCount,
                                inputBytes.baseAddress, Int32(boundary),
                                outputBytes.baseAddress,
                                tagBytes.baseAddress, Int32(Self.tagLength),
                                0  // decrypt
                            )
                        }
                    }
                }
            }
        }
        guard status == CHACHAPOLY_OK else {
            throw Failure.authenticationFailed
        }
        return plaintext
    }

    /// `Data.withUnsafeBytes` sur une valeur vide donne un `baseAddress` nul dont la
    /// bibliothèque C ne se plaint pas, mais l'expliciter évite de dépendre de ce détail.
    private static func withOptionalBytes<R>(
        _ data: Data,
        _ body: (UnsafeRawPointer?, Int32) -> R
    ) -> R {
        guard !data.isEmpty else { return body(nil, 0) }
        return data.withUnsafeBytes { body($0.baseAddress, Int32(data.count)) }
    }
}
