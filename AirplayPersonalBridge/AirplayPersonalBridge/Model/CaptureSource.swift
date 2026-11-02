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
        case let .application(_, _, bundleID): "\(Self.applicationIDPrefix)\(bundleID)"
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

    /// Réconcilie la sélection avec les sources disponibles.
    ///
    /// La comparaison se fait sur l'identifiant, jamais sur la valeur : les PID d'une application
    /// changent à chaque relevé dès qu'un processus de rendu se crée, et une sélection comparée à
    /// la valeur retomberait sur le mode global alors que l'application joue toujours.
    ///
    /// Une application qui cesse de jouer disparaît de la liste. Hors diffusion, la sélection
    /// retombe sur le mode global plutôt que de désigner un process mort, et le choix de
    /// l'utilisateur attend son retour. Pendant une diffusion, rien ne bouge ici : une simple pause
    /// ne doit pas relancer la capture sur tout le son du Mac, et c'est ``followTarget`` qui dit
    /// quand la capture doit changer.
    static func resolve(
        preferredID: String, current: CaptureSource, available: [CaptureSource], isLive: Bool
    ) -> (sources: [CaptureSource], selected: CaptureSource) {
        guard isLive else {
            return (available, available.first { $0.id == preferredID } ?? .systemWide)
        }
        guard !available.contains(where: { $0.id == current.id }) else {
            return (available, current)
        }
        var sources = available
        let position = sources.firstIndex(of: .inputDevice) ?? sources.endIndex
        sources.insert(current, at: position)
        return (sources, current)
    }

    /// Ce que la capture doit prendre maintenant, si ce n'est plus ce qu'elle prend.
    ///
    /// Un tap capte des processus désignés à sa création, jamais ceux qui apparaissent après. Sans ce
    /// suivi, un navigateur qui joue depuis un nouveau processus de rendu laissait le tap sur l'ancien
    /// PID, et les enceintes muettes. De même, une application en pause au démarrage faisait retomber
    /// la diffusion sur le mode global, où elle restait quand l'application reprenait.
    ///
    /// **Un processus qui s'arrête ne compte pas** : le tap continue de le suivre, sans rien coûter.
    /// Et un processus déjà capté, toujours vivant, reste dans la liste même s'il ne joue plus à
    /// l'instant du relevé. La liste ne fait donc que grandir : c'est ce qui empêche deux processus
    /// qui jouent à tour de rôle, ou un seul qui clignote, de relancer la capture à chaque fois.
    static func followTarget(
        preferredID: String, current: CaptureSource, available: [CaptureSource],
        isProcessAlive: (pid_t) -> Bool
    ) -> CaptureSource? {
        guard let wanted = available.first(where: { $0.id == preferredID }) else { return nil }
        guard wanted.id == current.id else { return wanted }
        guard case let .application(found, name, bundleID) = wanted,
            case let .application(captured, _, _) = current,
            !Set(found).isSubset(of: captured)
        else { return nil }
        let kept = captured.filter(isProcessAlive)
        return .application(pids: Set(kept + found).sorted(), name: name, bundleID: bundleID)
    }

    private static let applicationIDPrefix = "app-"

    /// Le nom de l'application que désigne cet identifiant, `nil` s'il n'en désigne pas une. Elle peut
    /// ne figurer dans aucune liste : seules y sont celles qui jouent.
    static func applicationName(forID id: String) -> String? {
        guard id.hasPrefix(applicationIDPrefix) else { return nil }
        let bundleID = String(id.dropFirst(applicationIDPrefix.count))
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return url.deletingPathExtension().lastPathComponent
        }
        return displayName(forBundleID: bundleID)
    }

    /// Le processus existe-t-il encore ? `EPERM` veut dire oui : il appartient à un autre utilisateur.
    nonisolated static func isProcessAlive(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
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

/// Espace les changements de capture qui suivent les processus d'une application.
///
/// La liste qui ne fait que grandir (``CaptureSource/followTarget``) règle le cas d'un processus
/// connu. Celui-ci couvre le reste : une application qui crée sans arrêt de nouveaux processus. Le
/// délai double tant que les changements s'enchaînent, et revient au minimum après un moment calme.
struct SourceFollowPacer {
    let minimum: Duration
    let maximum: Duration
    private var last: ContinuousClock.Instant?
    private var spacing: Duration

    init(minimum: Duration, maximum: Duration) {
        self.minimum = minimum
        self.maximum = maximum
        self.spacing = minimum
    }

    func allows(at now: ContinuousClock.Instant) -> Bool {
        guard let last else { return true }
        return last.duration(to: now) >= spacing
    }

    mutating func noteChange(at now: ContinuousClock.Instant) {
        if let last, last.duration(to: now) < spacing * 4 {
            spacing = min(spacing * 2, maximum)
        } else {
            spacing = minimum
        }
        last = now
    }
}
