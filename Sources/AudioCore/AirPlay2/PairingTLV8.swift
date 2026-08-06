import Foundation

/// Encodage TLV8 des messages de pairing HomeKit/AirPlay 2.
///
/// Format : une suite de triplets `type` (1 octet), `longueur` (1 octet), `valeur`. Une
/// valeur de plus de 255 octets est **fragmentée** en plusieurs éléments consécutifs de même
/// type, que le lecteur doit reconcaténer. C'est le cas courant en pratique : la clé
/// publique SRP fait 384 octets et arrive donc systématiquement en deux fragments.
///
/// Ignorer la fragmentation est le piège classique de ce format : un décodeur naïf lit le
/// premier fragment de 255 octets, croit tenir la valeur complète, et échoue plus loin sur
/// un calcul cryptographique faux sans jamais signaler d'erreur d'analyse.
public enum PairingTLV8 {

    /// Types TLV8 du protocole de pairing (spécification HomeKit, chapitre « Pair Setup »).
    public enum Tag: UInt8 {
        case method = 0x00
        case identifier = 0x01
        case salt = 0x02
        case publicKey = 0x03
        case proof = 0x04
        case encryptedData = 0x05
        case state = 0x06
        case error = 0x07
        case retryDelay = 0x08
        case certificate = 0x09
        case signature = 0x0A
        case permissions = 0x0B
        case fragmentData = 0x0C
        case fragmentLast = 0x0D
        case flags = 0x13
    }

    /// Étapes du dialogue. Chaque requête porte son numéro, chaque réponse le suivant.
    public enum State: UInt8 {
        case m1 = 0x01
        case m2 = 0x02
        case m3 = 0x03
        case m4 = 0x04
        case m5 = 0x05
        case m6 = 0x06
    }

    /// Méthode de pairing demandée dans le M1.
    public enum Method: UInt8 {
        case pairSetup = 0x00
        case pairSetupWithAuth = 0x01
        case pairVerify = 0x02
        case addPairing = 0x03
        case removePairing = 0x04
        case listPairings = 0x05
    }

    /// Drapeaux de pairing. Seul `transient` nous concerne au jalon 3.
    ///
    /// `transient` (bit 4) demande un pair-setup limité à M1–M4, **sans échange de clés
    /// long terme** : la session est chiffrée, mais rien n'est persisté de part et d'autre.
    /// C'est ce que le mock annonce (bit de fonctionnalité 48) et ce que macOS emploie pour
    /// diffuser vers un récepteur qui ne réclame pas de code.
    public enum Flags: UInt32 {
        case transient = 0x0000_0010
        case split = 0x0100_0000
    }

    /// Codes d'erreur renvoyés par le récepteur dans un TLV `error`.
    public enum PairingError: UInt8, Error, CustomStringConvertible {
        case unknown = 0x01
        case authentication = 0x02
        case backoff = 0x03
        case maxPeers = 0x04
        case maxTries = 0x05
        case unavailable = 0x06
        case busy = 0x07

        public var description: String {
            switch self {
            case .unknown: return "erreur inconnue du récepteur"
            case .authentication: return "authentification refusée (code de pairing erroné)"
            case .backoff: return "trop de tentatives, récepteur en attente"
            case .maxPeers: return "nombre maximal d'appairages atteint"
            case .maxTries: return "nombre maximal de tentatives atteint"
            case .unavailable: return "pairing indisponible sur ce récepteur"
            case .busy: return "récepteur occupé par un autre appairage"
            }
        }
    }

    // MARK: - Encodage

    /// Sérialise une suite d'éléments, en fragmentant les valeurs de plus de 255 octets.
    ///
    /// L'ordre est conservé tel que fourni : certains récepteurs sont sensibles à l'ordre
    /// des éléments, et le respecter ne coûte rien.
    public static func encode(_ items: [(tag: Tag, value: Data)]) -> Data {
        var output = Data()
        for item in items {
            if item.value.isEmpty {
                output.append(item.tag.rawValue)
                output.append(0)
                continue
            }
            var remaining = item.value[...]
            while !remaining.isEmpty {
                let chunkLength = min(255, remaining.count)
                output.append(item.tag.rawValue)
                output.append(UInt8(chunkLength))
                output.append(contentsOf: remaining.prefix(chunkLength))
                remaining = remaining.dropFirst(chunkLength)
            }
        }
        return output
    }

    /// Raccourci pour un élément d'un seul octet (`state`, `method`, `error`…).
    public static func byte(_ value: UInt8) -> Data {
        Data([value])
    }

    /// Encode un drapeau de pairing en entier little-endian, sans octets de tête nuls.
    ///
    /// C'est la forme qu'attend le récepteur : `0x10` sur un seul octet pour `transient`,
    /// pas un entier 32 bits complet.
    public static func flagsValue(_ flags: Flags) -> Data {
        var value = flags.rawValue.littleEndian
        var bytes = withUnsafeBytes(of: &value) { Data($0) }
        while bytes.count > 1, bytes.last == 0 {
            bytes.removeLast()
        }
        return bytes
    }

    // MARK: - Décodage

    /// Analyse un message TLV8 et reconcatène les fragments de même type.
    ///
    /// - Returns: les valeurs indexées par type, ou `nil` si le message est tronqué.
    public static func decode(_ data: Data) -> [Tag: Data]? {
        var result: [Tag: Data] = [:]
        var index = data.startIndex

        while index < data.endIndex {
            guard index + 1 < data.endIndex else { return nil }
            let rawTag = data[index]
            let length = Int(data[index + 1])
            let valueStart = index + 2
            guard valueStart + length <= data.endIndex else { return nil }

            let value = data[valueStart..<(valueStart + length)]
            if let tag = Tag(rawValue: rawTag) {
                // Fragments de même type : on concatène plutôt que d'écraser.
                result[tag, default: Data()].append(contentsOf: value)
            }
            // Un type inconnu est ignoré plutôt que rejeté : le protocole autorise
            // l'ajout d'éléments, et un récepteur plus récent peut en émettre.
            index = valueStart + length
        }
        return result
    }

    /// Lit l'état (`state`) d'un message décodé.
    public static func state(in items: [Tag: Data]) -> State? {
        guard let raw = items[.state]?.first else { return nil }
        return State(rawValue: raw)
    }

    /// Lit l'erreur éventuelle d'un message décodé.
    ///
    /// Un TLV `error` présent invalide toujours la réponse, quel que soit son contenu par
    /// ailleurs : c'est le seul moyen dont dispose le récepteur pour refuser une étape.
    public static func error(in items: [Tag: Data]) -> PairingError? {
        guard let raw = items[.error]?.first, raw != 0 else { return nil }
        return PairingError(rawValue: raw) ?? .unknown
    }
}
