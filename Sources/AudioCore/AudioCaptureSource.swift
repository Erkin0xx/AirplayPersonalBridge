import AVFoundation
import Foundation

/// Consommateur des blocs capturés.
///
/// **Appelé depuis le thread temps réel de la source** : ni allocation, ni verrou, ni E/S, ni
/// Swift Concurrency (CDC section 13). En usage réel il se contente de recopier le bloc dans
/// des ring buffers.
public typealias CaptureBlockConsumer = (UnsafePointer<AudioBufferList>, UInt32) -> Void

/// Une source PCM : Process Tap, entrée physique, ou sinusoïde de test.
///
/// Injectée par protocole (CDC section 13) pour que le moteur soit testable sans matériel ni
/// autorisation TCC. Invariant section 12 : une source ne connaît aucune destination, elle
/// remet des blocs à un consommateur et ignore ce qu'il en fait.
///
/// ## Deux temps, pour une raison précise
///
/// `prepare` rend le format **avant** que le moindre bloc ne circule. Les ring buffers en
/// dépendent, et le consommateur doit exister quand `start` lance l'IO : c'est ce qui dispense
/// de toute indirection mutable lue par le callback temps réel pendant qu'une autre tâche
/// l'écrit — ce que faisaient le moteur et le CLI avec un `nonisolated(unsafe) var sink`.
public protocol AudioCaptureSource: AnyObject {
    /// Autorisation à obtenir avant `prepare`, ou `nil` si la source n'en exige aucune.
    var requiredPermission: CapturePermission.Kind? { get }

    /// Prépare la source et rend le format réel des blocs. Aucun bloc ne circule encore.
    func prepare() throws -> AVAudioFormat

    /// Démarre l'IO. Le consommateur peut être appelé avant le retour de cette méthode.
    func start(deliveringTo consumer: @escaping CaptureBlockConsumer) throws

    /// Arrête l'IO. **Au retour, le consommateur n'est plus appelé** : c'est ce qui permet de
    /// relancer la source sans jamais avoir deux producteurs sur un même ring buffer.
    func stop()

    /// Signale un changement de route audio (sortie ou entrée par défaut) susceptible de
    /// rendre la capture caduque. `nil` retire le gestionnaire.
    func setRouteChangeHandler(_ handler: (@Sendable () -> Void)?)

    /// Le dernier changement de route impose-t-il de reconstruire la capture ?
    func routeRequiresRebuild() -> Bool

    /// Une application est-elle censée produire du son pour cette source ?
    ///
    /// Sert à lever l'ambiguïté d'un silence strict : `true` le rend suspect (autorisation,
    /// câblage), `false` l'explique (rien ne joue), `nil` ne dit rien. Hors temps réel.
    func isAudioExpected() -> Bool?
}

extension AudioCaptureSource {
    public func setRouteChangeHandler(_ handler: (@Sendable () -> Void)?) {}
    public func routeRequiresRebuild() -> Bool { false }
    public func isAudioExpected() -> Bool? { nil }
}

/// Accès aux autorisations de capture, injecté pour que les tests n'aient pas à dépendre de
/// l'état TCC de la machine.
public protocol CapturePermissionProviding: Sendable {
    func status(for kind: CapturePermission.Kind) -> CapturePermission.Status
    func request(for kind: CapturePermission.Kind) async -> Bool
}

/// Autorisations réelles du système.
public struct SystemCapturePermissions: CapturePermissionProviding {
    public init() {}
    public func status(for kind: CapturePermission.Kind) -> CapturePermission.Status {
        CapturePermission.status(for: kind)
    }
    public func request(for kind: CapturePermission.Kind) async -> Bool {
        await CapturePermission.request(for: kind)
    }
}
