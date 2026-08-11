//
//  CaptureSource.swift
//  AirplayPersonalBridge
//

import AudioCore
import Foundation

/// Source de capture proposée dans le sélecteur (CDC 4.2, trois modes).
///
/// Ce type existe pour l'affichage, mais sa forme est calquée sur ce que le cœur sait
/// consommer : `ProcessTapCapture.Mode` pour les deux premiers cas, `InputDeviceCapture`
/// pour le troisième. La conversion est donc une simple traduction, sans décision — c'est
/// ce qui rendra le branchement sur le moteur mécanique plutôt que réinterprétatif.
enum CaptureSource: Hashable, Identifiable, Sendable {
    /// Son système global, tout capté.
    case systemWide
    /// Mixdown d'une application précise.
    case application(pid: pid_t, name: String)
    /// Entrée physique (ligne/micro) — le mode le mieux documenté des trois (CDC 11).
    case inputDevice

    var id: String {
        switch self {
        case .systemWide: "system"
        case let .application(pid, _): "app-\(pid)"
        case .inputDevice: "input"
        }
    }

    var label: String {
        switch self {
        case .systemWide: "Son système global"
        case let .application(_, name): name
        case .inputDevice: "Entrée physique (ligne/micro)"
        }
    }

    /// Traduction vers le cœur. `nil` pour l'entrée physique, qui ne passe pas par un tap.
    var tapMode: ProcessTapCapture.Mode? {
        switch self {
        case .systemWide: .globalExcluding(pids: [])
        case let .application(pid, _): .processes(pids: [pid])
        case .inputDevice: nil
        }
    }
}

extension CaptureSource {
    /// Les applications qui produisent du son en ce moment, plus les deux modes fixes.
    ///
    /// Le nom affiché vient du bundle ID faute de mieux : `AudioProcessInfo` ne porte pas
    /// de nom lisible, et remonter au nom d'application demanderait `NSRunningApplication`,
    /// donc une dépendance AppKit dans le cœur — ce que l'invariant §12 exclut. La
    /// traduction se fait donc ici, du côté interface, là où AppKit est chez lui.
    static func available() -> [CaptureSource] {
        var sources: [CaptureSource] = [.systemWide]

        if let processes = try? AudioProcessList.all() {
            sources += processes
                .filter { $0.isPlaying && !$0.bundleID.isEmpty }
                .map { .application(pid: $0.pid, name: displayName(forBundleID: $0.bundleID)) }
                .sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
        }

        sources.append(.inputDevice)
        return sources
    }

    private static func displayName(forBundleID bundleID: String) -> String {
        bundleID.split(separator: ".").last.map(String.init) ?? bundleID
    }
}
