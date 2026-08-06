import CommonCrypto
import Foundation
import Security

/// Chiffrement de la session RAOP (`et=1`, RSA-AES).
///
/// ## Le schéma
///
/// RAOP tire une clé AES-128 et un IV aléatoires par session. La clé est transmise dans
/// l'`ANNOUNCE`, chiffrée en RSA-OAEP-SHA1 sous la clé publique RAOP historique des bornes
/// AirPort ; l'IV est transmis en clair. Le flux audio est ensuite chiffré en AES-128-CBC.
///
/// Particularité du protocole, contre-intuitive et à ne pas « corriger » : **chaque paquet
/// audio repart du même IV de session** — le CBC n'est pas chaîné d'un paquet à l'autre.
/// C'est ce qui permet au récepteur de décoder un paquet retransmis isolément, sans avoir
/// reçu les précédents. Et **le reliquat de moins de 16 octets en fin de paquet est laissé
/// en clair**, sans bourrage : le récepteur le recopie tel quel.
///
/// ## Sur la clé publique en dur
///
/// Ce n'est pas un secret ni un contournement : c'est la clé **publique** que tout récepteur
/// RAOP annonce implicitement via `et=1`, publiée depuis 2011 et présente à l'identique dans
/// shairport-sync, OwnTone et pyatv. Sans elle, aucun sender ne peut parler à un récepteur
/// RAOP classique. Elle ne donne accès à rien : elle sert uniquement à chiffrer une clé de
/// session vers le récepteur.
///
/// Toute la manipulation de pointeurs C (Security, CommonCrypto) est confinée dans cette
/// classe, qui gère elle-même l'allocation et la libération (invariant section 12).
public final class RAOPCrypto {
    /// Clé publique RAOP des bornes AirPort, en DER (RSAPublicKey, PKCS#1).
    ///
    /// Modulus de 2048 bits, exposant 65537. Reconstruite ici depuis ses deux composants
    /// plutôt que collée en base64 : le DER est vérifiable à la lecture.
    private static let modulus: [UInt8] = [
        0xe7, 0xd7, 0x44, 0xf2, 0xa2, 0xe2, 0x78, 0x8b, 0x6c, 0x1f, 0x55, 0xa0, 0x8e, 0xb7,
        0x05, 0x44, 0xa8, 0xfa, 0x79, 0x45, 0xaa, 0x8b, 0xe6, 0xc6, 0x2c, 0xe5, 0xf5, 0x1c,
        0xbd, 0xd4, 0xdc, 0x68, 0x42, 0xfe, 0x3d, 0x10, 0x83, 0xdd, 0x2e, 0xde, 0xc1, 0xbf,
        0xd4, 0x25, 0x2d, 0xc0, 0x2e, 0x6f, 0x39, 0x8b, 0xdf, 0x0e, 0x61, 0x48, 0xea, 0x84,
        0x85, 0x5e, 0x2e, 0x44, 0x2d, 0xa6, 0xd6, 0x26, 0x64, 0xf6, 0x74, 0xa1, 0xf3, 0x04,
        0x92, 0x9a, 0xde, 0x4f, 0x68, 0x93, 0xef, 0x2d, 0xf6, 0xe7, 0x11, 0xa8, 0xc7, 0x7a,
        0x0d, 0x91, 0xc9, 0xd9, 0x80, 0x82, 0x2e, 0x50, 0xd1, 0x29, 0x22, 0xaf, 0xea, 0x40,
        0xea, 0x9f, 0x0e, 0x14, 0xc0, 0xf7, 0x69, 0x38, 0xc5, 0xf3, 0x88, 0x2f, 0xc0, 0x32,
        0x3d, 0xd9, 0xfe, 0x55, 0x15, 0x5f, 0x51, 0xbb, 0x59, 0x21, 0xc2, 0x01, 0x62, 0x9f,
        0xd7, 0x33, 0x52, 0xd5, 0xe2, 0xef, 0xaa, 0xbf, 0x9b, 0xa0, 0x48, 0xd7, 0xb8, 0x13,
        0xa2, 0xb6, 0x76, 0x7f, 0x6c, 0x3c, 0xcf, 0x1e, 0xb4, 0xce, 0x67, 0x3d, 0x03, 0x7b,
        0x0d, 0x2e, 0xa3, 0x0c, 0x5f, 0xff, 0xeb, 0x06, 0xf8, 0xd0, 0x8a, 0xdd, 0xe4, 0x09,
        0x57, 0x1a, 0x9c, 0x68, 0x9f, 0xef, 0x10, 0x72, 0x88, 0x55, 0xdd, 0x8c, 0xfb, 0x9a,
        0x8b, 0xef, 0x5c, 0x89, 0x43, 0xef, 0x3b, 0x5a, 0xa1, 0x5d, 0xfa, 0xf6, 0xb8, 0xf5,
        0x9f, 0xa9, 0x1f, 0xed, 0x91, 0x11, 0xa2, 0x18, 0x67, 0x1c, 0x39, 0x2d, 0x3d, 0xc0,
        0x14, 0x7d, 0x4a, 0x8f, 0x0d, 0x8d, 0x40, 0x2a, 0xb4, 0x2b, 0xf5, 0x0e, 0x6c, 0xa3,
        0x8e, 0xef, 0x8c, 0x2f, 0x0a, 0x2b, 0x1f, 0x9a, 0x1e, 0xd6, 0x37, 0x35, 0x1e, 0xf2,
        0x8e, 0xb4, 0x25, 0x35, 0x83, 0x35, 0xf1, 0x21, 0x93, 0x36, 0xf1, 0x8a, 0x39, 0x8f,
        0x1e, 0x54, 0x2e, 0x2b,
    ]
    private static let publicExponent: [UInt8] = [0x01, 0x00, 0x01]

    /// Clé AES-128 de session, en clair. Transmise chiffrée dans l'`ANNOUNCE`.
    public let aesKey: [UInt8]
    /// IV de session, transmis en clair dans le SDP.
    public let aesIV: [UInt8]

    private let secKey: SecKey

    public init() throws {
        self.aesKey = try Self.randomBytes(16)
        self.aesIV = try Self.randomBytes(16)
        self.secKey = try Self.makePublicKey()
    }

    // MARK: - Clé de session

    /// Clé AES chiffrée en RSA-OAEP-SHA1, prête pour le champ `rsaaeskey` du SDP.
    ///
    /// OAEP fait intervenir un aléa : deux appels produisent deux valeurs différentes pour
    /// la même clé. C'est attendu, et cela interdit tout test par vecteur figé.
    public func encryptedSessionKey() throws -> [UInt8] {
        var error: Unmanaged<CFError>?
        guard let encrypted = SecKeyCreateEncryptedData(
            secKey,
            .rsaEncryptionOAEPSHA1,
            Data(aesKey) as CFData,
            &error
        ) else {
            let reason = error?.takeRetainedValue().localizedDescription ?? "raison inconnue"
            throw RAOPCryptoError.keyEncryptionFailed(reason)
        }
        return [UInt8](encrypted as Data)
    }

    // MARK: - Chiffrement du flux

    /// Chiffre un paquet audio en AES-128-CBC, sur place.
    ///
    /// Repart de l'IV de session à chaque appel et laisse le reliquat final de moins de
    /// 16 octets en clair : les deux sont exigés par le protocole, voir la note de classe.
    ///
    /// Appelé depuis la tâche du sender, jamais depuis le callback de capture.
    public func encryptAudioInPlace(_ payload: inout [UInt8]) throws {
        let blockCount = payload.count / kCCBlockSizeAES128
        guard blockCount > 0 else { return }
        let encryptedLength = blockCount * kCCBlockSizeAES128

        var produced = 0
        let status = payload.withUnsafeMutableBytes { raw -> CCCryptorStatus in
            guard let base = raw.baseAddress else { return CCCryptorStatus(kCCParamError) }
            return aesKey.withUnsafeBytes { keyBytes in
                aesIV.withUnsafeBytes { ivBytes in
                    CCCrypt(
                        CCOperation(kCCEncrypt),
                        CCAlgorithm(kCCAlgorithmAES),
                        // Pas d'option de bourrage : la longueur est déjà un multiple de 16
                        // et le protocole interdit d'ajouter du remplissage.
                        CCOptions(0),
                        keyBytes.baseAddress, kCCKeySizeAES128,
                        ivBytes.baseAddress,
                        base, encryptedLength,
                        base, encryptedLength,
                        &produced
                    )
                }
            }
        }
        guard status == CCCryptorStatus(kCCSuccess) else {
            throw RAOPCryptoError.audioEncryptionFailed(Int(status))
        }
    }

    // MARK: - Utilitaires

    /// Encodage base64 sans le bourrage `=`, forme exigée par le SDP de RAOP.
    ///
    /// Un `=` laissé en place fait rejeter l'`ANNOUNCE` par certains récepteurs.
    public static func base64Unpadded(_ bytes: [UInt8]) -> String {
        Data(bytes).base64EncodedString().replacingOccurrences(of: "=", with: "")
    }

    public static func randomBytes(_ count: Int) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = bytes.withUnsafeMutableBytes { raw -> Int32 in
            guard let base = raw.baseAddress else { return errSecParam }
            return SecRandomCopyBytes(kSecRandomDefault, count, base)
        }
        guard status == errSecSuccess else {
            throw RAOPCryptoError.randomGenerationFailed(Int(status))
        }
        return bytes
    }

    /// Construit la `SecKey` publique depuis le modulus et l'exposant, via un DER
    /// `RSAPublicKey` (PKCS#1) assemblé à la main.
    private static func makePublicKey() throws -> SecKey {
        var der: [UInt8] = [0x30]  // SEQUENCE
        var body = derInteger(modulus)
        body.append(contentsOf: derInteger(publicExponent))
        der.append(contentsOf: derLength(body.count))
        der.append(contentsOf: body)

        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPublic,
            kSecAttrKeySizeInBits as String: modulus.count * 8,
        ]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(
            Data(der) as CFData, attributes as CFDictionary, &error
        ) else {
            let reason = error?.takeRetainedValue().localizedDescription ?? "raison inconnue"
            throw RAOPCryptoError.publicKeyUnavailable(reason)
        }
        return key
    }

    /// Encode un entier DER. Un octet nul est préfixé si le bit de poids fort est à 1,
    /// sans quoi la valeur serait lue comme négative.
    private static func derInteger(_ value: [UInt8]) -> [UInt8] {
        var content = value
        if let first = content.first, first & 0x80 != 0 {
            content.insert(0x00, at: 0)
        }
        var encoded: [UInt8] = [0x02]  // INTEGER
        encoded.append(contentsOf: derLength(content.count))
        encoded.append(contentsOf: content)
        return encoded
    }

    /// Longueur DER, forme courte sous 128, forme longue au-delà.
    private static func derLength(_ length: Int) -> [UInt8] {
        if length < 0x80 { return [UInt8(length)] }
        var bytes: [UInt8] = []
        var remaining = length
        while remaining > 0 {
            bytes.insert(UInt8(remaining & 0xFF), at: 0)
            remaining >>= 8
        }
        return [UInt8(0x80 | bytes.count)] + bytes
    }
}

public enum RAOPCryptoError: Error, CustomStringConvertible {
    case publicKeyUnavailable(String)
    case keyEncryptionFailed(String)
    case audioEncryptionFailed(Int)
    case randomGenerationFailed(Int)

    public var description: String {
        switch self {
        case let .publicKeyUnavailable(reason):
            return "clé publique RAOP inutilisable : \(reason)"
        case let .keyEncryptionFailed(reason):
            return "chiffrement RSA de la clé de session en échec : \(reason)"
        case let .audioEncryptionFailed(status):
            return "chiffrement AES du flux audio en échec (CCCryptorStatus \(status))"
        case let .randomGenerationFailed(status):
            return "génération d'aléa en échec (OSStatus \(status))"
        }
    }
}
