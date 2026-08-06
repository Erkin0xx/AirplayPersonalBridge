import CoreAudio
import Foundation
import OSLog

/// Erreurs de la couche capture.
///
/// `fatalError` est réservé aux erreurs de programmation non récupérables (CDC section 13) :
/// tout échec runtime de Core Audio remonte ici sous forme d'erreur typée.
public enum AudioCaptureError: Error, CustomStringConvertible {
    case coreAudio(status: OSStatus, operation: String)
    case processNotFound(String)
    case tapFormatUnavailable
    case noInputDevice
    case unsupportedFormat(String)

    public var description: String {
        switch self {
        case let .coreAudio(status, operation):
            return "\(operation) a échoué (OSStatus \(status)\(Self.fourCC(status)))"
        case let .processNotFound(hint):
            return "Aucun process audio trouvé pour « \(hint) »"
        case .tapFormatUnavailable:
            return "Format du tap illisible (kAudioTapPropertyFormat)"
        case .noInputDevice:
            return "Aucun périphérique d'entrée audio sélectionné dans Réglages Son > Entrée"
        case let .unsupportedFormat(detail):
            return "Format audio non pris en charge : \(detail)"
        }
    }

    /// Les OSStatus de Core Audio sont souvent des codes à 4 caractères ('!obj', 'who?'…),
    /// nettement plus lisibles que leur valeur entière.
    private static func fourCC(_ status: OSStatus) -> String {
        let value = UInt32(bitPattern: status)
        let bytes = [
            UInt8((value >> 24) & 0xFF), UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF),
        ]
        guard bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) else { return "" }
        return " '\(String(decoding: bytes, as: UTF8.self))'"
    }
}

/// Vérifie un OSStatus et le convertit en erreur Swift typée.
@inlinable
func check(_ status: OSStatus, _ operation: String) throws {
    guard status == noErr else {
        throw AudioCaptureError.coreAudio(status: status, operation: operation)
    }
}

public enum AudioLog {
    public static let subsystem = "fr.baptiste.airplaymultioutput"
    public static let capture = Logger(subsystem: subsystem, category: "capture")
    public static let cli = Logger(subsystem: subsystem, category: "cli")
    /// Sender AirPlay 1 / RAOP (CDC 4.3) : découverte, RTSP, RTP.
    public static let raop = Logger(subsystem: subsystem, category: "raop")
    /// Sender AirPlay 2 (CDC 4.4) : découverte, pairing, RTSP, canal d'événements.
    /// Catégorie distincte de `raop` : les deux sorties tournent en parallèle, et les
    /// mélanger rendrait un journal illisible en cas de panne d'une seule des deux.
    public static let airplay2 = Logger(subsystem: subsystem, category: "airplay2")
}

/// Accès typé aux propriétés d'objets Core Audio (`AudioObjectGetPropertyData`).
///
/// Ces appels sont répétitifs et manipulent des pointeurs ; les centraliser ici évite de
/// disperser du code pointeur dans les modules de capture.
enum AudioObject {
    static func address(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    /// Lit une propriété de taille fixe.
    static func value<T>(
        _ objectID: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain,
        defaultValue: T,
        operation: String
    ) throws -> T {
        var addr = address(selector, scope: scope, element: element)
        var size = UInt32(MemoryLayout<T>.size)
        var result = defaultValue
        // `withUnsafeMutableBytes` plutôt que `&result` : passer `&` sur une valeur
        // générique fait supposer au compilateur qu'elle peut contenir une référence
        // objet. Ici les T utilisés sont des types POD Core Audio.
        try withUnsafeMutableBytes(of: &result) { raw in
            guard let base = raw.baseAddress else {
                throw AudioCaptureError.coreAudio(status: kAudio_ParamError, operation: operation)
            }
            try check(
                AudioObjectGetPropertyData(objectID, &addr, 0, nil, &size, base),
                operation
            )
        }
        return result
    }

    /// Lit une propriété de taille variable sous forme de tableau.
    static func array<T>(
        _ objectID: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain,
        of type: T.Type,
        operation: String
    ) throws -> [T] {
        var addr = address(selector, scope: scope, element: element)
        var dataSize: UInt32 = 0
        try check(
            AudioObjectGetPropertyDataSize(objectID, &addr, 0, nil, &dataSize),
            "\(operation) (taille)"
        )
        let count = Int(dataSize) / MemoryLayout<T>.size
        guard count > 0 else { return [] }
        return try [T](unsafeUninitializedCapacity: count) { buffer, initialized in
            var size = dataSize
            try check(
                AudioObjectGetPropertyData(objectID, &addr, 0, nil, &size, buffer.baseAddress!),
                operation
            )
            initialized = count
        }
    }

    /// Lit une propriété chaîne (CFString transférée au appelant).
    static func string(
        _ objectID: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        operation: String
    ) throws -> String {
        var addr = address(selector, scope: scope)
        var size = UInt32(MemoryLayout<UnsafeRawPointer?>.size)
        // Core Audio écrit ici une CFStringRef dont il transfère la propriété à l'appelant
        // (règle « Get » avec valeur retournée par paramètre de sortie sur ces sélecteurs).
        // On la récupère en Unmanaged pour rendre ce transfert explicite plutôt que de
        // laisser le pont Swift/CF le deviner.
        var raw: UnsafeMutableRawPointer? = nil
        try withUnsafeMutableBytes(of: &raw) { buffer in
            guard let base = buffer.baseAddress else {
                throw AudioCaptureError.coreAudio(status: kAudio_ParamError, operation: operation)
            }
            try check(
                AudioObjectGetPropertyData(objectID, &addr, 0, nil, &size, base),
                operation
            )
        }
        guard let raw else { return "" }
        return Unmanaged<CFString>.fromOpaque(raw).takeRetainedValue() as String
    }
}
