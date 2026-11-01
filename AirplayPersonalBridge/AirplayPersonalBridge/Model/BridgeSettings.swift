//
//  BridgeSettings.swift
//  AirplayPersonalBridge
//

import AudioCore
import CryptoKit
import Foundation
import OSLog

private let settingsLog = Logger(subsystem: AudioLog.subsystem, category: "settings")

/// Ce qui doit survivre à un redémarrage : la sélection et les réglages faits à l'oreille.
///
/// Rien de l'état de connexion ici : une sortie repart toujours au repos, et c'est le moteur qui
/// dit où elle en est. Les réglages d'une sortie absente du réseau sont conservés, indexés sur son
/// identifiant Bonjour : une Geneva éteinte pendant une semaine retrouve son trim à son retour.
struct BridgeSettings: Codable, Equatable {
    /// Bornes des réglages, partagées avec les curseurs : un fichier retouché à la main ne doit
    /// pas produire une valeur qu'aucun geste de l'interface ne permettrait.
    enum Limits {
        static let masterDB: ClosedRange<Double> = -60...0
        static let trimDB: ClosedRange<Double> = -12...12
        static let delayMS: ClosedRange<Double> = -200...200
        static let bassBoostDB = LowShelfFilter.gainRangeDecibels
    }

    struct Output: Codable, Equatable {
        var isEnabled = true
        var trimDB = 0.0
        var delayMS = 0.0
        var bassBoostDB = 0.0
        /// Pour montrer une sortie cochée avant que la découverte l'ait revue. Facultatif : à
        /// défaut, le nom se lit dans l'identifiant.
        var displayName: String?

        private enum CodingKeys: String, CodingKey {
            case isEnabled, trimDB, delayMS, bassBoostDB, displayName
        }

        init(
            isEnabled: Bool = true, trimDB: Double = 0, delayMS: Double = 0,
            bassBoostDB: Double = 0, displayName: String? = nil
        ) {
            self.isEnabled = isEnabled
            self.trimDB = trimDB
            self.delayMS = delayMS
            self.bassBoostDB = bassBoostDB
            self.displayName = displayName
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let fields = TolerantFields(container: container, recorder: decoder.lossRecorder)
            isEnabled = fields.value(.isEnabled, default: true)
            trimDB = fields.value(.trimDB, default: 0).clamped(to: Limits.trimDB)
            delayMS = fields.value(.delayMS, default: 0).clamped(to: Limits.delayMS)
            bassBoostDB = fields.value(.bassBoostDB, default: 0).clamped(to: Limits.bassBoostDB)
            displayName = fields.value(.displayName, default: nil)
        }
    }

    var masterVolumeDB = BridgeState.defaultMasterVolumeDB
    var isMuted = false
    /// Identifiant de `CaptureSource`. Une application précise reste désignée par son bundle : ses
    /// PID ne valent que le temps d'un lancement.
    var sourceID = CaptureSource.systemWide.id
    /// Option « Couper le son du Mac ». Désactivée par défaut, comme le veut le moteur : le son
    /// local reste un filet si les enceintes ne répondent pas.
    var muteLocalOutput = false
    var outputs: [String: Output] = [:]

    private enum CodingKeys: String, CodingKey {
        case masterVolumeDB, isMuted, sourceID, muteLocalOutput, outputs
    }

    init() {}

    /// Décodage tolérant : un champ absent prend sa valeur par défaut, un champ illisible aussi.
    /// Un format qui gagne un champ doit se relire, pas se perdre — la leçon vient du plan de la
    /// pièce (`RoomLayout.storageURL`).
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fields = TolerantFields(container: container, recorder: decoder.lossRecorder)
        masterVolumeDB = fields.value(.masterVolumeDB, default: BridgeState.defaultMasterVolumeDB)
            .clamped(to: Limits.masterDB)
        isMuted = fields.value(.isMuted, default: false)
        sourceID = fields.value(.sourceID, default: CaptureSource.systemWide.id)
        muteLocalOutput = fields.value(.muteLocalOutput, default: false)
        // Entrée par entrée : une sortie abîmée ne doit pas coûter les réglages des autres.
        let entries = fields.value(.outputs, default: [String: TolerantOutput]())
        outputs = entries.compactMapValues(\.output)
        if outputs.count != entries.count { decoder.lossRecorder?.recordLoss() }
    }
}

extension Double {
    fileprivate func clamped(to range: ClosedRange<Double>) -> Double {
        guard isFinite else { return Swift.min(Swift.max(0, range.lowerBound), range.upperBound) }
        return Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}

/// Une entrée de sortie qui, illisible, ne fait pas échouer le dictionnaire entier.
private struct TolerantOutput: Decodable {
    let output: BridgeSettings.Output?

    init(from decoder: Decoder) throws {
        output = try? BridgeSettings.Output(from: decoder)
    }
}

/// Lit des champs sans jamais échouer, en notant ceux qu'il a fallu écarter.
private struct TolerantFields<Key: CodingKey> {
    let container: KeyedDecodingContainer<Key>
    let recorder: SettingsLossRecorder?

    func value<T: Decodable>(_ key: Key, default fallback: T) -> T {
        guard container.contains(key) else { return fallback }
        if (try? container.decodeNil(forKey: key)) == true { return fallback }
        if let decoded = try? container.decode(T.self, forKey: key) { return decoded }
        recorder?.recordLoss()
        return fallback
    }
}

/// Note qu'un décodage tolérant a écarté quelque chose : c'est le cas le plus traître, les réglages
/// se chargent et rien n'indique qu'il en manque.
final class SettingsLossRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var lost = false

    func recordLoss() {
        lock.lock()
        lost = true
        lock.unlock()
    }

    var hasLoss: Bool {
        lock.lock()
        defer { lock.unlock() }
        return lost
    }

    static let userInfoKey = CodingUserInfoKey(rawValue: "fr.baptiste.settings-loss")
}

extension Decoder {
    fileprivate var lossRecorder: SettingsLossRecorder? {
        SettingsLossRecorder.userInfoKey.flatMap { userInfo[$0] as? SettingsLossRecorder }
    }
}

// MARK: - Stockage

/// Injecté : aucun test ne doit lire ni écraser les réglages de la machine.
protocol SettingsStoring {
    func load() -> BridgeSettings
    @discardableResult func save(_ settings: BridgeSettings) -> Bool
}

/// `settings.json`, dans le même dossier que le plan de la pièce.
///
/// Mêmes principes que `RoomLayout` : écriture atomique, et un fichier qu'on n'a pas su lire n'est
/// jamais écrasé par la sauvegarde suivante sans en avoir gardé une copie à côté.
struct FileSettingsStore: SettingsStoring {
    let url: URL

    static var defaultURL: URL {
        URL.applicationSupportDirectory
            .appending(path: "AirplayPersonalBridge")
            .appending(path: "settings.json")
    }

    func load() -> BridgeSettings {
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
            return BridgeSettings()
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            // Illisible au sens du système de fichiers : on ne peut pas le recopier, mais on peut
            // encore l'écarter du chemin de la prochaine sauvegarde.
            settingsLog.error(
                "Lecture des réglages impossible : \(error.localizedDescription, privacy: .public)"
            )
            moveAside()
            return BridgeSettings()
        }

        let recorder = SettingsLossRecorder()
        let decoder = JSONDecoder()
        if let key = SettingsLossRecorder.userInfoKey { decoder.userInfo[key] = recorder }
        guard let settings = try? decoder.decode(BridgeSettings.self, from: data) else {
            settingsLog.error("Réglages illisibles : \(url.path, privacy: .public)")
            preserveCopy(of: data)
            return BridgeSettings()
        }
        if recorder.hasLoss {
            settingsLog.error("Réglages relus en partie seulement : \(url.path, privacy: .public)")
            preserveCopy(of: data)
        }
        return settings
    }

    @discardableResult
    func save(_ settings: BridgeSettings) -> Bool {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(settings)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            settingsLog.error(
                "Réglages non sauvegardés : \(error.localizedDescription, privacy: .public)"
            )
            return false
        }
    }

    /// Le nom dérive du contenu : relancer l'app sur le même fichier abîmé ne multiplie pas les
    /// copies, et deux fichiers abîmés différents ne s'écrasent pas.
    private func preserveCopy(of data: Data) {
        let digest = SHA256.hash(data: data).prefix(6).map { String(format: "%02x", $0) }.joined()
        let copy = sibling("illisible-\(digest)")
        guard !FileManager.default.fileExists(atPath: copy.path(percentEncoded: false)) else {
            return
        }
        do {
            try data.write(to: copy, options: .atomic)
            settingsLog.notice("Original des réglages préservé : \(copy.path, privacy: .public)")
        } catch {
            settingsLog.error(
                "Impossible de préserver l'original : \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func moveAside() {
        do {
            try FileManager.default.moveItem(
                at: url, to: sibling("illisible-\(Int(Date().timeIntervalSince1970))")
            )
        } catch {
            settingsLog.error(
                "Impossible d'écarter les réglages : \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func sibling(_ suffix: String) -> URL {
        url.deletingPathExtension()
            .appendingPathExtension(suffix)
            .appendingPathExtension(url.pathExtension)
    }
}

/// Pour les aperçus et les tests : ne touche à aucun fichier.
final class InMemorySettingsStore: SettingsStoring {
    var stored: BridgeSettings
    private(set) var saveCount = 0

    init(_ stored: BridgeSettings = BridgeSettings()) {
        self.stored = stored
    }

    func load() -> BridgeSettings { stored }

    @discardableResult
    func save(_ settings: BridgeSettings) -> Bool {
        stored = settings
        saveCount += 1
        return true
    }
}
