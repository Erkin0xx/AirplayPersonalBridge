import AudioToolbox
import CoreAudio
import Foundation
import OSLog

private let volumeLog = Logger(subsystem: AudioLog.subsystem, category: "volume")

/// Le volume du Mac tel que le règlent les touches de volume, la touche silence et le curseur du
/// Centre de contrôle : le **volume principal virtuel** de la sortie par défaut
/// (`kAudioHardwareServiceDeviceProperty_VirtualMainVolume`, un scalaire de 0 à 1), et son silence
/// (`kAudioDevicePropertyMute`).
///
/// Rien ici ne touche au chemin temps réel : ce sont des propriétés de périphérique, lues et écrites
/// hors de tout callback d'IO, et les notifications arrivent sur une file dispatch propre.
///
/// Lire et écrire ne tiennent aucun état : la sortie par défaut est relue à chaque appel. Seul
/// `Observer` tient des abonnements, et les retire à sa destruction.
///
/// Ce module ignore à quoi sert ce volume : c'est l'app qui décide de le relier aux enceintes.
public enum SystemOutputVolume {
    /// Un relevé de la sortie par défaut.
    public struct Reading: Sendable, Equatable {
        public var deviceID: AudioObjectID
        /// L'identifiant stable de la sortie (`kAudioDevicePropertyDeviceUID`). `deviceID` peut changer
        /// d'un démarrage de `coreaudiod` à l'autre : c'est par lui qu'on retrouve une sortie plus tard.
        public var deviceUID: String
        public var deviceName: String
        /// Le scalaire de 0 à 1, ou `nil` si la sortie n'a pas de volume réglable : une sortie
        /// numérique ou HDMI, où les touches de volume n'ont aucun effet.
        public var volume: Float?
        /// `nil` si la sortie n'a pas de silence réglable.
        public var isMuted: Bool?

        public init(
            deviceID: AudioObjectID, deviceUID: String, deviceName: String, volume: Float?,
            isMuted: Bool?
        ) {
            self.deviceID = deviceID
            self.deviceUID = deviceUID
            self.deviceName = deviceName
            self.volume = volume
            self.isMuted = isMuted
        }
    }

    /// La sortie par défaut et son volume, ou `nil` s'il n'y a aucune sortie.
    public static func read() -> Reading? {
        defaultOutputDevice().map(read(device:))
    }

    /// Une sortie précise et son volume, qu'elle soit la sortie par défaut ou non.
    public static func read(device: AudioObjectID) -> Reading {
        let name =
            (try? AudioObject.string(device, kAudioObjectPropertyName, operation: "nom de la sortie"))
            ?? ""
        let uid =
            (try? AudioObject.string(device, kAudioDevicePropertyDeviceUID, operation: "UID de la sortie"))
            ?? ""
        var volume: Float?
        if isSettable(device, volumeAddress) {
            volume = try? AudioObject.value(
                device, volumeAddress.mSelector, scope: volumeAddress.mScope,
                defaultValue: Float32(0), operation: "volume de la sortie"
            )
        }
        var isMuted: Bool?
        if isSettable(device, muteAddress) {
            let raw = try? AudioObject.value(
                device, muteAddress.mSelector, scope: muteAddress.mScope,
                defaultValue: UInt32(0), operation: "silence de la sortie"
            )
            isMuted = raw.map { $0 != 0 }
        }
        return Reading(
            deviceID: device, deviceUID: uid, deviceName: name,
            volume: volume.map { min(max($0, 0), 1) }, isMuted: isMuted
        )
    }

    /// La sortie qui porte cet identifiant stable, si elle est encore là.
    public static func device(forUID uid: String) -> AudioObjectID? {
        guard !uid.isEmpty else { return nil }
        var address = AudioObject.address(kAudioHardwarePropertyTranslateUIDToDevice)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var qualifier = uid as CFString
        let status = withUnsafeMutablePointer(to: &qualifier) { pointer in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &address,
                UInt32(MemoryLayout<CFString>.size), pointer, &size, &device
            )
        }
        guard status == noErr, device != kAudioObjectUnknown else { return nil }
        return device
    }

    /// Règle le volume d'une sortie précise : celle qu'on a relevée, pas celle qui serait devenue la
    /// sortie par défaut entre-temps. `false` si elle n'a pas de volume réglable.
    @discardableResult
    public static func setVolume(_ scalar: Float, on device: AudioObjectID) -> Bool {
        var value = Float32(min(max(scalar, 0), 1))
        return set(&value, on: device, at: volumeAddress)
    }

    @discardableResult
    public static func setMuted(_ muted: Bool, on device: AudioObjectID) -> Bool {
        var value = UInt32(muted ? 1 : 0)
        return set(&value, on: device, at: muteAddress)
    }

    // MARK: - Adresses

    static let volumeAddress = AudioObject.address(
        kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: kAudioDevicePropertyScopeOutput
    )
    static let muteAddress = AudioObject.address(
        kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeOutput
    )

    /// Ce qu'on écoute sur la sortie : le volume virtuel, et, au cas où une sortie ne le notifierait
    /// pas, les volumes et silences réels qu'il résume (élément principal, puis les deux canaux).
    /// Chaque notification ne fait que provoquer une relecture : un doublon ne coûte rien.
    static var observedDeviceAddresses: [AudioObjectPropertyAddress] {
        var addresses = [volumeAddress, muteAddress]
        for element in [kAudioObjectPropertyElementMain, 1, 2] {
            addresses.append(
                AudioObject.address(
                    kAudioDevicePropertyVolumeScalar, scope: kAudioDevicePropertyScopeOutput,
                    element: element
                )
            )
            if element != kAudioObjectPropertyElementMain {
                addresses.append(
                    AudioObject.address(
                        kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeOutput,
                        element: element
                    )
                )
            }
        }
        return addresses
    }

    static func defaultOutputDevice() -> AudioObjectID? {
        let device = try? AudioObject.value(
            AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice,
            defaultValue: AudioObjectID(kAudioObjectUnknown), operation: "sortie par défaut"
        )
        guard let device, device != kAudioObjectUnknown else { return nil }
        return device
    }

    private static func isSettable(_ device: AudioObjectID, _ address: AudioObjectPropertyAddress) -> Bool {
        var address = address
        guard AudioObjectHasProperty(device, &address) else { return false }
        var settable: DarwinBoolean = false
        guard AudioObjectIsPropertySettable(device, &address, &settable) == noErr else { return false }
        return settable.boolValue
    }

    private static func set<T>(
        _ value: inout T, on device: AudioObjectID, at address: AudioObjectPropertyAddress
    ) -> Bool {
        guard isSettable(device, address) else { return false }
        var address = address
        let size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutableBytes(of: &value) { raw -> OSStatus in
            guard let base = raw.baseAddress else { return kAudio_ParamError }
            return AudioObjectSetPropertyData(device, &address, 0, nil, size, base)
        }
        if status != noErr {
            volumeLog.error("Réglage du volume du Mac refusé : \(status)")
        }
        return status == noErr
    }

    // MARK: - Observation

    /// Prévient à chaque changement du volume ou du silence de la sortie par défaut, et à chaque
    /// changement de sortie par défaut, après s'être réabonné à la nouvelle.
    ///
    /// `onChange` ne porte aucune valeur : l'appelant relit (`read`) au moment de la traiter. Une
    /// notification qui arrive en retard lit donc la valeur courante, jamais une valeur périmée.
    ///
    /// Appelé sur une file dispatch propre, jamais sur le thread temps réel. Les écouteurs sont
    /// retirés au `deinit` : Core Audio ne connaît pas la durée de vie des blocs.
    public final class Observer: @unchecked Sendable {
        private let queue = DispatchQueue(label: "fr.baptiste.airplaymultioutput.system-volume")
        private let onChange: @Sendable () -> Void
        private let deviceBlock: AudioObjectPropertyListenerBlock
        private var systemBlock: AudioObjectPropertyListenerBlock?
        private static let systemAddress = AudioObject.address(kAudioHardwarePropertyDefaultOutputDevice)

        /// Protège ce qui suit : l'abonnement change sur la file des notifications, et se retire
        /// depuis le fil qui détruit l'observateur.
        private let lock = NSLock()
        private var observedDevice: AudioObjectID?
        private var observedAddresses: [AudioObjectPropertyAddress] = []

        public init(onChange: @escaping @Sendable () -> Void) {
            self.onChange = onChange
            self.deviceBlock = { _, _ in onChange() }
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                self?.defaultDeviceDidChange()
            }
            systemBlock = block
            var address = Self.systemAddress
            let status = AudioObjectAddPropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &address, queue, block
            )
            if status != noErr {
                volumeLog.error("Écoute de la sortie par défaut impossible : \(status)")
            }
            lock.lock()
            subscribe(to: SystemOutputVolume.defaultOutputDevice())
            lock.unlock()
        }

        deinit {
            if let systemBlock {
                var address = Self.systemAddress
                AudioObjectRemovePropertyListenerBlock(
                    AudioObjectID(kAudioObjectSystemObject), &address, queue, systemBlock
                )
            }
            lock.lock()
            unsubscribe()
            lock.unlock()
        }

        private func defaultDeviceDidChange() {
            lock.lock()
            let device = SystemOutputVolume.defaultOutputDevice()
            if device != observedDevice {
                unsubscribe()
                subscribe(to: device)
            }
            lock.unlock()
            onChange()
        }

        /// Sous verrou.
        private func subscribe(to device: AudioObjectID?) {
            guard let device else { return }
            observedDevice = device
            for candidate in SystemOutputVolume.observedDeviceAddresses {
                var address = candidate
                guard AudioObjectHasProperty(device, &address) else { continue }
                if AudioObjectAddPropertyListenerBlock(device, &address, queue, deviceBlock) == noErr {
                    observedAddresses.append(candidate)
                }
            }
        }

        /// Sous verrou.
        private func unsubscribe() {
            if let observedDevice {
                for candidate in observedAddresses {
                    var address = candidate
                    AudioObjectRemovePropertyListenerBlock(observedDevice, &address, queue, deviceBlock)
                }
            }
            observedDevice = nil
            observedAddresses = []
        }
    }
}
