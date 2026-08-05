import CoreAudio
import Foundation

/// Un process audio visible par Core Audio.
public struct AudioProcessInfo: Sendable, Identifiable {
    public let id: AudioObjectID
    public let pid: pid_t
    public let bundleID: String
    public let isPlaying: Bool

    /// Nom lisible, déduit du bundle ID ou à défaut du pid.
    public var displayName: String {
        guard !bundleID.isEmpty else { return "pid \(pid)" }
        return bundleID.split(separator: ".").last.map(String.init) ?? bundleID
    }
}

/// Énumération des process audio du système, pour le mode « application spécifique ».
public enum AudioProcessList {
    /// Tous les process audio connus de Core Audio.
    public static func all() throws -> [AudioProcessInfo] {
        let objectIDs = try AudioObject.array(
            AudioObjectID(kAudioObjectSystemObject),
            kAudioHardwarePropertyProcessObjectList,
            of: AudioObjectID.self,
            operation: "lecture de la liste des process audio"
        )

        return objectIDs.compactMap { objectID in
            let pid = (try? AudioObject.value(
                objectID, kAudioProcessPropertyPID,
                defaultValue: pid_t(-1), operation: "lecture du pid"
            )) ?? -1
            let bundleID = (try? AudioObject.string(
                objectID, kAudioProcessPropertyBundleID, operation: "lecture du bundle ID"
            )) ?? ""
            let running = (try? AudioObject.value(
                objectID, kAudioProcessPropertyIsRunningOutput,
                defaultValue: UInt32(0), operation: "lecture de l'état de lecture"
            )) ?? 0
            guard pid > 0 else { return nil }
            return AudioProcessInfo(
                id: objectID, pid: pid, bundleID: bundleID, isPlaying: running != 0
            )
        }
    }

    /// Process en train d'émettre du son.
    public static func playing() throws -> [AudioProcessInfo] {
        try all().filter(\.isPlaying)
    }

    /// Recherche un process par fragment de bundle ID ou par pid, insensible à la casse.
    ///
    /// - Parameter hint: « Music », « com.apple.Music », ou un pid sous forme de texte.
    public static func find(matching hint: String) throws -> AudioProcessInfo {
        let processes = try all()

        if let pid = pid_t(hint), let match = processes.first(where: { $0.pid == pid }) {
            return match
        }

        let needle = hint.lowercased()
        // Un process qui joue déjà est un meilleur candidat qu'un process silencieux
        // portant un nom voisin.
        let candidates = processes.filter { $0.bundleID.lowercased().contains(needle) }
        if let playing = candidates.first(where: \.isPlaying) { return playing }
        if let first = candidates.first { return first }

        throw AudioCaptureError.processNotFound(hint)
    }
}
