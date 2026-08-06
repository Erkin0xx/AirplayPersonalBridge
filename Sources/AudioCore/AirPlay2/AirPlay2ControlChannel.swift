import Foundation

/// Chiffrement du canal de contrôle AirPlay 2, une fois le pair-setup abouti.
///
/// Après le pairing, la connexion RTSP ne transporte plus de texte clair : chaque envoi est
/// découpé en blocs de 1024 octets au plus, et chaque bloc est encadré ainsi :
///
/// ```
/// [ longueur : 2 octets, little-endian ][ cryptogramme ][ étiquette Poly1305 : 16 octets ]
/// ```
///
/// Trois détails font échouer l'ensemble si on les manque, tous vérifiés dans `hap.py` du
/// mock (classe `HAPSocket`) :
///
/// 1. **Les deux octets de longueur servent de données associées** à l'AEAD. Les omettre
///    donne une étiquette invalide alors que le déchiffrement « fonctionne » par ailleurs.
/// 2. **Le nonce est un compteur de blocs sur 64 bits little-endian, précédé de 4 octets
///    nuls** (12 octets au total). Il s'incrémente à chaque bloc et **jamais** ne repart de
///    zéro tant que la connexion vit — un compteur remis à zéro réutiliserait un nonce, ce
///    qui casse la sécurité de ChaCha20-Poly1305.
/// 3. **Les deux sens ont des compteurs et des clés distincts.**
///
/// Ce type ne gère que la transformation ; l'entrée/sortie reste au `RTSPClient`.
///
/// `@unchecked Sendable` : `Direction` porte un compteur de blocs mutable, donc non
/// `Sendable` au sens du compilateur. La sûreté vient du confinement — l'unique instance
/// vit dans l'acteur `RTSPClient`, qui sérialise tous les accès. Aucun autre type ne
/// détient de référence vers un `Direction`.
public struct AirPlay2ControlChannel: @unchecked Sendable {

    /// Sel et infos HKDF du canal de contrôle (relevés dans `HAPSocket` du mock).
    static let cipherSalt = "Control-Salt"
    /// Clé dont **nous** nous servons pour écrire ; le récepteur la nomme « write ».
    static let writeKeyInfo = "Control-Write-Encryption-Key"
    /// Clé dont **nous** nous servons pour lire ; le récepteur la nomme « read ».
    static let readKeyInfo = "Control-Read-Encryption-Key"

    /// Taille maximale d'un bloc en clair.
    public static let maxBlockLength = 0x400
    /// Préfixe de longueur, en octets.
    public static let lengthPrefixLength = 2

    public enum Failure: Error, CustomStringConvertible {
        case encryptionFailed(String)
        case decryptionFailed(String)

        public var description: String {
            switch self {
            case let .encryptionFailed(reason): return "chiffrement du canal de contrôle : \(reason)"
            case let .decryptionFailed(reason): return "déchiffrement du canal de contrôle : \(reason)"
            }
        }
    }

    /// Compteur de blocs d'un sens, et son chiffre.
    ///
    /// `final class` volontairement : le compteur doit être partagé entre les appels
    /// successifs d'un même sens. Une `struct` copiée réinitialiserait silencieusement le
    /// nonce, avec la faille que cela implique.
    public final class Direction {
        private let cipher: ChaChaPoly1305
        private var blockCounter: UInt64 = 0

        public init(key: Data) throws {
            cipher = try ChaChaPoly1305(key: key)
        }

        /// Nonce du bloc courant : 4 octets nuls, puis le compteur en little-endian.
        private func nextNonce() -> Data {
            var nonce = Data(repeating: 0, count: 4)
            withUnsafeBytes(of: blockCounter.littleEndian) { nonce.append(contentsOf: $0) }
            blockCounter &+= 1
            return nonce
        }

        /// Chiffre un message complet, découpé en blocs de 1024 octets au plus.
        func seal(_ plaintext: Data) throws -> Data {
            var output = Data()
            var remaining = plaintext[...]

            repeat {
                let chunkLength = min(AirPlay2ControlChannel.maxBlockLength, remaining.count)
                let chunk = Data(remaining.prefix(chunkLength))
                remaining = remaining.dropFirst(chunkLength)

                // Le préfixe de longueur est à la fois émis en clair et utilisé comme
                // données associées : c'est ce qui empêche un tiers de le modifier.
                var lengthPrefix = Data()
                withUnsafeBytes(of: UInt16(chunkLength).littleEndian) {
                    lengthPrefix.append(contentsOf: $0)
                }

                let sealed = try cipher.seal(chunk, nonce: nextNonce(), additionalData: lengthPrefix)
                output.append(lengthPrefix)
                output.append(sealed)
            } while !remaining.isEmpty

            return output
        }

        /// Déchiffre autant de blocs complets que `buffer` en contient.
        ///
        /// - Returns: le texte clair, et le nombre d'octets consommés. Un bloc partiel est
        ///   laissé dans le tampon de l'appelant : c'est le cas normal en TCP, où un message
        ///   arrive en plusieurs morceaux.
        func open(_ buffer: Data) throws -> (plaintext: Data, consumed: Int) {
            var plaintext = Data()
            var offset = buffer.startIndex

            while true {
                guard offset + AirPlay2ControlChannel.lengthPrefixLength <= buffer.endIndex else {
                    break
                }
                let lengthPrefix = Data(
                    buffer[offset..<(offset + AirPlay2ControlChannel.lengthPrefixLength)])
                let blockLength = Int(
                    lengthPrefix.withUnsafeBytes { $0.load(as: UInt16.self).littleEndian })

                let bodyStart = offset + AirPlay2ControlChannel.lengthPrefixLength
                let bodyEnd = bodyStart + blockLength + ChaChaPoly1305.tagLength
                // Bloc incomplet : on s'arrête sans consommer, l'appelant rappellera.
                guard bodyEnd <= buffer.endIndex else { break }

                let sealed = Data(buffer[bodyStart..<bodyEnd])
                do {
                    plaintext.append(
                        try cipher.open(sealed, nonce: nextNonce(), additionalData: lengthPrefix))
                } catch {
                    throw Failure.decryptionFailed(String(describing: error))
                }
                offset = bodyEnd
            }

            return (plaintext, offset - buffer.startIndex)
        }
    }

    public let outbound: Direction
    public let inbound: Direction

    public init(keys: AirPlay2PairingSession.SessionKeys) throws {
        outbound = try Direction(key: keys.outgoing)
        inbound = try Direction(key: keys.incoming)
    }
}
