//
//  SystemVolumeControl.swift
//  AirplayPersonalBridge
//

import AudioCore
import CoreAudio
import Foundation

/// Ce que l'app lit et règle du volume du Mac : celui que changent les touches de volume, la touche
/// silence et le curseur du Centre de contrôle.
///
/// Injecté (CDC section 13) : aucun test ne doit toucher au volume de la machine. La politique, ce qui
/// relie ce volume aux enceintes, vit dans `SystemVolumeLink`.
protocol SystemVolumeControlling: AnyObject {
    /// Abonne `onChange`, appelé sur le MainActor à chaque changement du volume ou du silence de la
    /// sortie par défaut, et à chaque changement de sortie par défaut. Remplace un abonnement
    /// précédent. La notification ne porte aucune valeur : l'appelant relit (`read`).
    func startObserving(_ onChange: @escaping @MainActor () -> Void)
    func stopObserving()
    /// La sortie par défaut et son volume, ou `nil` s'il n'y a aucune sortie.
    func read() -> SystemOutputVolume.Reading?
    /// La sortie qui porte cet identifiant stable, si elle est encore branchée.
    func device(forUID uid: String) -> AudioObjectID?
    @discardableResult func setVolume(_ scalar: Float, on device: AudioObjectID) -> Bool
    @discardableResult func setMuted(_ muted: Bool, on device: AudioObjectID) -> Bool
}

/// Le vrai volume du Mac, par Core Audio (`SystemOutputVolume`).
///
/// Sans interception des touches : ni autorisation Accessibilité, ni Surveillance de l'entrée, ni
/// `CGEventTap`. On observe la propriété que les touches modifient, comme le fait le Centre de contrôle.
final class LiveSystemVolumeControl: SystemVolumeControlling {
    /// L'abonnement Core Audio. Le relâcher retire les écouteurs (`deinit` de l'observateur).
    private var observer: SystemOutputVolume.Observer?

    func startObserving(_ onChange: @escaping @MainActor () -> Void) {
        // Les notifications arrivent sur la file de l'observateur : on repasse sur le MainActor, où
        // vit l'état. Jamais un thread temps réel ici, ce ne sont que des propriétés de périphérique.
        observer = SystemOutputVolume.Observer {
            Task { @MainActor in onChange() }
        }
    }

    func stopObserving() {
        observer = nil
    }

    func read() -> SystemOutputVolume.Reading? {
        SystemOutputVolume.read()
    }

    func device(forUID uid: String) -> AudioObjectID? {
        SystemOutputVolume.device(forUID: uid)
    }

    @discardableResult
    func setVolume(_ scalar: Float, on device: AudioObjectID) -> Bool {
        SystemOutputVolume.setVolume(scalar, on: device)
    }

    @discardableResult
    func setMuted(_ muted: Bool, on device: AudioObjectID) -> Bool {
        SystemOutputVolume.setMuted(muted, on: device)
    }
}

/// Pour les aperçus et les tests : aucune sortie, donc rien de lié.
final class NoSystemVolumeControl: SystemVolumeControlling {
    func startObserving(_ onChange: @escaping @MainActor () -> Void) {}
    func stopObserving() {}
    func read() -> SystemOutputVolume.Reading? { nil }
    func device(forUID uid: String) -> AudioObjectID? { nil }
    func setVolume(_ scalar: Float, on device: AudioObjectID) -> Bool { false }
    func setMuted(_ muted: Bool, on device: AudioObjectID) -> Bool { false }
}
