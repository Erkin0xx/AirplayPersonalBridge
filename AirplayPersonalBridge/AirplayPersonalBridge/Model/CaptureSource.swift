//
//  CaptureSource.swift
//  AirplayPersonalBridge
//

import AppKit
import AudioCore
import Darwin
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
    /// Mixdown d'une application précise, **auxiliaires compris**.
    ///
    /// Plusieurs PID et non un seul : un navigateur ne joue pas le son depuis son processus
    /// principal mais depuis un processus de rendu. Vérifié sur Dia le 2026-08-11 —
    /// `company.thebrowser.dia` est silencieux pendant que
    /// `company.thebrowser.browser.helper` joue. Ne capturer que le processus principal
    /// donnerait un silence numérique, sans erreur.
    case application(pids: [pid_t], name: String, bundleID: String)
    /// Entrée physique (ligne/micro) — le mode le mieux documenté des trois (CDC 11).
    case inputDevice

    var id: String {
        switch self {
        case .systemWide: "system"
        case let .application(_, _, bundleID): "app-\(bundleID)"
        case .inputDevice: "input"
        }
    }

    var label: String {
        switch self {
        case .systemWide: "Son système global"
        case let .application(_, name, _): name
        case .inputDevice: "Entrée physique (ligne/micro)"
        }
    }

    /// Traduction vers le cœur. `nil` pour l'entrée physique, qui ne passe pas par un tap.
    var tapMode: ProcessTapCapture.Mode? {
        switch self {
        case .systemWide: .globalExcluding(pids: [])
        case let .application(pids, _, _): .processes(pids: pids)
        case .inputDevice: nil
        }
    }
}

extension CaptureSource {
    /// Les applications qui produisent du son en ce moment, plus les deux modes fixes.
    ///
    /// Chaque processus audio est rattaché à **l'application qui le possède**, en remontant
    /// la chaîne des parents jusqu'à trouver une application au sens d'AppKit. C'est ce qui
    /// permet d'afficher « Dia » plutôt que « helper », et surtout de capturer l'ensemble de
    /// ses processus — sans quoi la sélection ne capterait rien.
    static func available() -> [CaptureSource] {
        var sources: [CaptureSource] = [.systemWide]

        if let processes = try? AudioProcessList.all() {
            // Groupes indexés par bundle ID de l'application propriétaire, pour que les
            // auxiliaires rejoignent leur application au lieu de figurer à part.
            var groups: [String: (name: String, pids: [pid_t])] = [:]
            for process in processes where process.isPlaying && !process.bundleID.isEmpty {
                let owner = owningApplication(of: process.pid)
                let bundleID = owner?.bundleIdentifier ?? process.bundleID
                let name = owner?.localizedName ?? displayName(forBundleID: process.bundleID)
                groups[bundleID, default: (name, [])].pids.append(process.pid)
            }
            sources += groups
                .map { CaptureSource.application(pids: $1.pids.sorted(), name: $1.name, bundleID: $0) }
                .sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
        }

        sources.append(.inputDevice)
        return sources
    }

    /// Remonte la chaîne des parents jusqu'à une application connue d'AppKit.
    ///
    /// Un processus de rendu n'est pas une application : il n'apparaît pas dans
    /// `NSRunningApplication`. Son parent, lui, l'est. La remontée est bornée pour ne pas
    /// dépendre de la forme de l'arbre.
    private static func owningApplication(of pid: pid_t) -> NSRunningApplication? {
        var current = pid
        for _ in 0..<8 {
            if let application = NSRunningApplication(processIdentifier: current),
                application.bundleIdentifier != nil
            {
                return application
            }
            guard let parent = parentProcess(of: current), parent > 1 else { return nil }
            current = parent
        }
        return nil
    }

    /// PID du parent, via `sysctl` — aucune API Foundation ne l'expose.
    private static func parentProcess(of pid: pid_t) -> pid_t? {
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        let result = sysctl(&name, UInt32(name.count), &info, &size, nil, 0)
        guard result == 0, size > 0 else { return nil }
        return info.kp_eproc.e_ppid
    }

    private static func displayName(forBundleID bundleID: String) -> String {
        bundleID.split(separator: ".").last.map(String.init) ?? bundleID
    }
}
