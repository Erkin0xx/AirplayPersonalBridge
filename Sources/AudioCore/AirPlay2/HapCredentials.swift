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

        public var description: String {
            switch self {
            case let .malformed(reason): return "credentials illisibles : \(reason)"
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
        let text = try String(contentsOf: url, encoding: .utf8)
        guard let line = text.split(separator: "\n")
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

    init?(hexEncoded text: String) {
        guard text.count % 2 == 0 else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(text.count / 2)
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(index, offsetBy: 2)
            guard let byte = UInt8(text[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self.init(bytes)
    }
}
