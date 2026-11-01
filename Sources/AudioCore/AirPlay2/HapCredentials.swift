import Foundation

/// Credentials long terme d'un appairage système AirPlay 2 (HomeKit).
///
/// Obtenus une fois par un `pair-setup` avec code à l'écran, puis rejoués à chaque session
/// par `pair-verify` — c'est ce qui évite de ressaisir un code. Le format sérialisé est celui
/// de pyatv, quatre champs hexadécimaux séparés par `:` :
///
///     ltpk:ltsk:identifiant-récepteur:identifiant-client
///
/// Les deux identifiants sont eux-mêmes des chaînes ASCII encodées en hexadécimal — un UUID
/// pour le récepteur, un autre pour le client. Conserver ce format permet de réutiliser tels
/// quels les credentials produits par `atvremote pair`, et inversement.
///
/// **Ce sont des secrets.** `ltsk` est une clé privée : le fichier qui les porte ne doit
/// jamais être versionné (`credentials/` est gitignoré).
public struct HapCredentials: Sendable, Equatable {
    /// Clé publique Ed25519 du **récepteur**, qui sert à vérifier sa signature.
    public let receiverPublicKey: Data
    /// Graine Ed25519 **du client**, 32 octets, avec laquelle nous signons.
    public let clientSecretSeed: Data
    /// Identifiant du récepteur, tel qu'il le renvoie en `pair-verify`.
    public let receiverIdentifier: Data
    /// Identifiant du client, celui sous lequel le récepteur nous connaît.
    public let clientIdentifier: Data

    public init(
        receiverPublicKey: Data,
        clientSecretSeed: Data,
        receiverIdentifier: Data,
        clientIdentifier: Data
    ) {
        self.receiverPublicKey = receiverPublicKey
        self.clientSecretSeed = clientSecretSeed
        self.receiverIdentifier = receiverIdentifier
        self.clientIdentifier = clientIdentifier
    }

    public enum Failure: Error, CustomStringConvertible {
        case malformed(String)
        /// Fichier absent ou illisible. Le chemin figure dans le message, jamais le contenu.
        case unreadable(path: String)

        public var description: String {
            switch self {
            case let .malformed(reason): return "credentials illisibles : \(reason)"
            case let .unreadable(path):
                return "fichier de credentials introuvable ou illisible : \(path)"
            }
        }
    }

    /// Analyse la forme `ltpk:ltsk:atv_id:client_id`, chaque champ en hexadécimal.
    public init(serialized text: String) throws {
        let fields = text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ":")
        guard fields.count == 4 else {
            throw Failure.malformed("4 champs attendus, \(fields.count) trouvés")
        }
        let decoded = try fields.map { field -> Data in
            guard let data = Data(hexEncoded: String(field)) else {
                throw Failure.malformed("champ non hexadécimal")
            }
            return data
        }
        guard decoded[0].count == 32 else {
            throw Failure.malformed("clé publique du récepteur de \(decoded[0].count) o, 32 attendus")
        }
        guard decoded[1].count == 32 else {
            throw Failure.malformed("graine du client de \(decoded[1].count) o, 32 attendus")
        }
        self.init(
            receiverPublicKey: decoded[0],
            clientSecretSeed: decoded[1],
            receiverIdentifier: decoded[2],
            clientIdentifier: decoded[3]
        )
    }

    public var serialized: String {
        [receiverPublicKey, clientSecretSeed, receiverIdentifier, clientIdentifier]
            .map(\.hexEncoded)
            .joined(separator: ":")
    }

    /// Charge les credentials d'un récepteur depuis un fichier.
    ///
    /// Les lignes commençant par `#` sont des commentaires : le fichier reste lisible et
    /// annotable à la main, ce qui compte pour un secret qu'on manipule rarement.
    public static func load(contentsOf url: URL) throws -> HapCredentials {
        let text: String
        do {
            text = try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw Failure.unreadable(path: url.path)
        }
        // `\.isNewline` et non `"\n"` : en Swift `\r\n` est un seul caractère, qu'un découpage sur
        // `"\n"` ne verrait pas — un fichier aux fins de ligne Windows passerait pour une seule
        // ligne, commentaires compris.
        guard let line = text.split(whereSeparator: \.isNewline)
            .map({ $0.trimmingCharacters(in: .whitespaces) })
            .last(where: { !$0.isEmpty && !$0.hasPrefix("#") })
        else {
            throw Failure.malformed("fichier sans ligne exploitable")
        }
        return try HapCredentials(serialized: line)
    }
}

extension Data {
    var hexEncoded: String { map { String(format: "%02x", $0) }.joined() }

    /// Décode de l'hexadécimal strict, sans préfixe ni signe.
    ///
    /// Par octets UTF-8 et non par caractères : `UInt8(_:radix:)` accepte `+a` comme un octet
    /// valide, et un caractère composé fausserait le décompte.
    init?(hexEncoded text: String) {
        let digits = Array(text.utf8)
        guard digits.count % 2 == 0 else { return nil }
        func value(_ digit: UInt8) -> UInt8? {
            switch digit {
            case UInt8(ascii: "0")...UInt8(ascii: "9"): return digit - UInt8(ascii: "0")
            case UInt8(ascii: "a")...UInt8(ascii: "f"): return digit - UInt8(ascii: "a") + 10
            case UInt8(ascii: "A")...UInt8(ascii: "F"): return digit - UInt8(ascii: "A") + 10
            default: return nil
            }
        }
        var bytes = [UInt8]()
        bytes.reserveCapacity(digits.count / 2)
        var index = 0
        while index < digits.count {
            guard let high = value(digits[index]), let low = value(digits[index + 1]) else {
                return nil
            }
            bytes.append(high << 4 | low)
            index += 2
        }
        self.init(bytes)
    }
}
