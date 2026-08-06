import CryptoKit
import Foundation

/// HKDF-SHA512 (RFC 5869), tel qu'AirPlay 2 l'emploie dans le pairing.
///
/// Contrairement aux quatre autres primitives, celle-ci **n'est pas** wrappée depuis une
/// bibliothèque C : CryptoKit la fournit nativement et de façon testée. Le CDC 4.4 proscrit
/// de *retranscrire à la main* une primitive, pas d'utiliser une implémentation système
/// éprouvée — et faire entrer une cinquième bibliothèque C juste pour un HMAC serait un
/// surcoût sans bénéfice de sûreté.
///
/// Chaque étape du pairing dérive sa clé avec son propre couple sel/info. Les valeurs sont
/// des littéraux du protocole : elles doivent correspondre **octet pour octet** à celles du
/// récepteur, sans quoi le déchiffrement échoue sur une étiquette Poly1305 invalide, sans
/// autre indice. Les valeurs ci-dessous ont été relevées dans `ap2/pairing/hap.py` du mock
/// (les mêmes que celles de la spécification HomeKit).
public enum HKDF512 {
    /// Sels et infos du pairing AirPlay 2, regroupés pour éviter les littéraux dispersés.
    public enum Label {
        /// Chiffrement du sous-TLV de `pair-setup` M5/M6.
        public static let setupEncryptSalt = "Pair-Setup-Encrypt-Salt"
        public static let setupEncryptInfo = "Pair-Setup-Encrypt-Info"
        /// Dérivation de `iOSDeviceX`, qui entre dans la signature du contrôleur.
        public static let controllerSignSalt = "Pair-Setup-Controller-Sign-Salt"
        public static let controllerSignInfo = "Pair-Setup-Controller-Sign-Info"
        /// Dérivation d'`AccessoryX`, côté récepteur.
        public static let accessorySignSalt = "Pair-Setup-Accessory-Sign-Salt"
        public static let accessorySignInfo = "Pair-Setup-Accessory-Sign-Info"
        /// Chiffrement du sous-TLV de `pair-verify` M2/M3.
        public static let verifyEncryptSalt = "Pair-Verify-Encrypt-Salt"
        public static let verifyEncryptInfo = "Pair-Verify-Encrypt-Info"
    }

    /// Dérive `outputLength` octets depuis `secret`, avec le sel et l'info donnés.
    ///
    /// - Parameter outputLength: 32 pour toutes les clés du pairing AirPlay 2.
    public static func derive(
        secret: Data,
        salt: String,
        info: String,
        outputLength: Int = 32
    ) -> Data {
        let derived = CryptoKit.HKDF<SHA512>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: secret),
            salt: Data(salt.utf8),
            info: Data(info.utf8),
            outputByteCount: outputLength
        )
        return derived.withUnsafeBytes { Data($0) }
    }
}
