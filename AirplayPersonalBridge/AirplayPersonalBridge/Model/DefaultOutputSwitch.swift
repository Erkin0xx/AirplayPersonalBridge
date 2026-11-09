//
//  DefaultOutputSwitch.swift
//  AirplayPersonalBridge
//

import AudioCore
import CoreAudio
import Foundation

/// Ce que l'app lit et règle des sorties du Mac pour caler l'image des vidéos : la sortie par défaut,
/// le volume et le silence d'une sortie désignée par son identifiant stable, et la sortie virtuelle
/// (`Drivers/APBOutput`), sa présence et sa latence.
///
/// Injecté (CDC section 13) : aucun test ne doit changer la sortie du Mac. La politique, quand basculer
/// et quoi rendre, vit dans `VideoSyncSwitch`. Une sortie est toujours désignée par son UID :
/// l'identifiant Core Audio ne survit pas forcément à une relance de coreaudiod.
protocol DefaultOutputSwitching: AnyObject {
    /// Le pilote est-il installé et chargé par coreaudiod ?
    func isVirtualOutputInstalled() -> Bool
    /// La sortie par défaut, son volume et son silence, ou `nil` si elle est illisible.
    func currentOutput() -> SystemOutputVolume.Reading?
    /// Une sortie et son volume, ou `nil` si elle n'est plus branchée.
    func output(uid: String) -> SystemOutputVolume.Reading?
    @discardableResult func setVolume(_ scalar: Float, onOutput uid: String) -> Bool
    @discardableResult func setMuted(_ muted: Bool, onOutput uid: String) -> Bool
    /// En fait la sortie par défaut, celle où jouent les applications.
    @discardableResult func makeDefault(uid: String) -> Bool
    /// La latence que le pilote annonce aux applications, en trames.
    @discardableResult func setVirtualOutputLatency(frames: Int) -> Bool
    /// La sortie intégrée du Mac, s'il en a une.
    func builtInOutputUID() -> String?
    /// Les sorties qui peuvent devenir sortie par défaut, pilote compris, dans l'ordre de Core Audio.
    func outputUIDs() -> [String]
}

/// Les vraies sorties du Mac, par Core Audio (`VirtualOutputDevice`, `DefaultOutputDevice`,
/// `SystemOutputVolume`). Des propriétés de périphérique, lues et écrites hors de tout callback d'IO.
final class LiveDefaultOutputSwitch: DefaultOutputSwitching {
    func isVirtualOutputInstalled() -> Bool {
        VirtualOutputDevice.deviceID() != nil
    }

    func currentOutput() -> SystemOutputVolume.Reading? {
        SystemOutputVolume.read()
    }

    func output(uid: String) -> SystemOutputVolume.Reading? {
        SystemOutputVolume.device(forUID: uid).map(SystemOutputVolume.read(device:))
    }

    @discardableResult
    func setVolume(_ scalar: Float, onOutput uid: String) -> Bool {
        guard let device = SystemOutputVolume.device(forUID: uid) else { return false }
        return SystemOutputVolume.setVolume(scalar, on: device)
    }

    @discardableResult
    func setMuted(_ muted: Bool, onOutput uid: String) -> Bool {
        guard let device = SystemOutputVolume.device(forUID: uid) else { return false }
        return SystemOutputVolume.setMuted(muted, on: device)
    }

    @discardableResult
    func makeDefault(uid: String) -> Bool {
        guard let device = SystemOutputVolume.device(forUID: uid) else { return false }
        return DefaultOutputDevice.set(device)
    }

    @discardableResult
    func setVirtualOutputLatency(frames: Int) -> Bool {
        VirtualOutputDevice.setAnnouncedLatency(frames: frames)
    }

    func builtInOutputUID() -> String? {
        DefaultOutputDevice.builtIn().flatMap(DefaultOutputDevice.uid(of:))
    }

    func outputUIDs() -> [String] {
        DefaultOutputDevice.candidates().compactMap(DefaultOutputDevice.uid(of:))
    }
}

/// Pour les aperçus et les tests : aucune sortie, rien d'écrit. La présence du pilote se règle, pour
/// montrer l'option telle qu'elle apparaît pilote installé ; sans sortie lisible, rien ne bascule.
final class InertDefaultOutputSwitch: DefaultOutputSwitching {
    private let driverInstalled: Bool

    init(driverInstalled: Bool = false) {
        self.driverInstalled = driverInstalled
    }

    func isVirtualOutputInstalled() -> Bool { driverInstalled }
    func currentOutput() -> SystemOutputVolume.Reading? { nil }
    func output(uid: String) -> SystemOutputVolume.Reading? { nil }
    func setVolume(_ scalar: Float, onOutput uid: String) -> Bool { false }
    func setMuted(_ muted: Bool, onOutput uid: String) -> Bool { false }
    func makeDefault(uid: String) -> Bool { false }
    func setVirtualOutputLatency(frames: Int) -> Bool { false }
    func builtInOutputUID() -> String? { nil }
    func outputUIDs() -> [String] { [] }
}
