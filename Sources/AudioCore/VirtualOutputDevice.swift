import AudioToolbox
import CoreAudio
import Foundation
import OSLog

private let videoSyncLog = Logger(subsystem: AudioLog.subsystem, category: "video-sync")

/// La latence que la sortie virtuelle annonce aux applications, pour que les lecteurs vidéo
/// retardent l'image d'autant que le son met à sortir des enceintes.
///
/// **Calculée ici et nulle part ailleurs** : le pilote (`Drivers/APBOutput`) ne connaît aucune valeur,
/// il annonce ce qu'on lui écrit. Si le délai de restitution change un jour, la latence suit.
public enum VideoSyncLatency {
    /// Ce que les enceintes jouent au-delà du délai commun de restitution : +290 à +307 ms mesurés au
    /// micro le 2026-11-02, enceinte par enceinte (`CLAUDE.md`, « Mesure acoustique »). Sans doute les
    /// 11 025 trames (0,25 s) qu'un récepteur ajoute à la latence annoncée, plus le trajet du son.
    public static let measuredReceiverResidualSeconds = 0.30

    /// Le retard de bout en bout, en secondes.
    public static func seconds(
        playoutDelaySeconds: Double = SharedPlaybackClock.defaultPlayoutDelaySeconds
    ) -> Double {
        playoutDelaySeconds + measuredReceiverResidualSeconds
    }

    /// Le même retard en trames de la sortie virtuelle, borné à ce qu'elle accepte.
    public static func frames(
        playoutDelaySeconds: Double = SharedPlaybackClock.defaultPlayoutDelaySeconds,
        sampleRate: Double = VirtualOutputDevice.sampleRate
    ) -> Int {
        let frames = (seconds(playoutDelaySeconds: playoutDelaySeconds) * sampleRate).rounded()
        return min(max(Int(frames), 0), VirtualOutputDevice.maximumLatencyFrames)
    }
}

/// La sortie audio virtuelle « AirPlay Personal Bridge » (`Drivers/APBOutput`), vue de l'app : une
/// sortie qui jette le son et annonce dans `kAudioDevicePropertyLatency` la latence qu'on lui écrit.
///
/// Rien ici ne touche au chemin temps réel : ce sont des propriétés de périphérique, lues et écrites
/// hors de tout callback d'IO.
public enum VirtualOutputDevice {
    /// Identifiant stable du périphérique, celui du pilote (`kAPB_DeviceUID`).
    public static let deviceUID = "fr.baptiste.airplaypersonalbridge.output"
    public static let sampleRate: Double = 48_000
    /// 10 s : la borne de Chromium, et celle du pilote.
    public static let maximumLatencyFrames = 480_000
    /// Propriété personnalisée du pilote : la latence annoncée en trames, un `CFNumber` (`'apbL'`).
    static let latencySelector: AudioObjectPropertySelector = 0x6170_624C

    /// Le périphérique, si le pilote est installé et chargé par coreaudiod.
    public static func deviceID() -> AudioObjectID? {
        SystemOutputVolume.device(forUID: deviceUID)
    }

    /// La latence que le pilote annonce, en trames.
    public static func announcedLatencyFrames() -> Int? {
        guard let device = deviceID() else { return nil }
        var address = AudioObject.address(latencySelector)
        var size = UInt32(MemoryLayout<UnsafeRawPointer?>.size)
        // Le pilote rend un CFNumber dont l'appelant devient propriétaire.
        var raw: UnsafeMutableRawPointer?
        let status = withUnsafeMutableBytes(of: &raw) { buffer -> OSStatus in
            guard let base = buffer.baseAddress else { return kAudio_ParamError }
            return AudioObjectGetPropertyData(device, &address, 0, nil, &size, base)
        }
        guard status == noErr, let raw else { return nil }
        let number = Unmanaged<CFNumber>.fromOpaque(raw).takeRetainedValue()
        var frames: Int32 = 0
        guard CFNumberGetValue(number, .sInt32Type, &frames) else { return nil }
        return Int(frames)
    }

    /// Écrit la latence à annoncer. Le pilote la garde d'une relance de coreaudiod à l'autre. Une
    /// application la relit à l'ouverture de son flux : une page déjà ouverte doit être rechargée.
    @discardableResult
    public static func setAnnouncedLatency(frames: Int) -> Bool {
        guard let device = deviceID() else { return false }
        guard (0...maximumLatencyFrames).contains(frames) else { return false }
        var address = AudioObject.address(latencySelector)
        var number = NSNumber(value: Int32(frames)) as CFNumber
        let status = withUnsafeMutablePointer(to: &number) { pointer in
            AudioObjectSetPropertyData(
                device, &address, 0, nil, UInt32(MemoryLayout<CFNumber>.size), pointer
            )
        }
        if status != noErr {
            videoSyncLog.error("Latence de la sortie virtuelle refusée : \(status)")
            return false
        }
        videoSyncLog.info("Latence de la sortie virtuelle : \(frames) trames")
        return true
    }

    /// Ce qu'une sortie annonce aux applications, en trames de sa propre fréquence.
    public struct LatencyReport: Sendable, Equatable {
        public var deviceFrames: Int
        public var streamFrames: Int
        public var safetyOffsetFrames: Int
        public var sampleRate: Double

        /// Ce que Chromium ajoute au retard de l'image : périphérique + premier flux, **sans** le
        /// safety offset (`media/audio/mac/core_audio_util_mac.cc`, lu le 2026-11-09). La latence
        /// de l'AUHAL, troisième terme de sa somme, est nulle sur une sortie.
        public var chromiumSeconds: Double {
            sampleRate > 0 ? Double(deviceFrames + streamFrames) / sampleRate : 0
        }
    }

    public static func latencyReport(of device: AudioObjectID) -> LatencyReport? {
        let output = kAudioObjectPropertyScopeOutput
        guard
            let deviceFrames = try? AudioObject.value(
                device, kAudioDevicePropertyLatency, scope: output, defaultValue: UInt32(0),
                operation: "latence du périphérique"),
            let safety = try? AudioObject.value(
                device, kAudioDevicePropertySafetyOffset, scope: output, defaultValue: UInt32(0),
                operation: "safety offset"),
            let rate = try? AudioObject.value(
                device, kAudioDevicePropertyNominalSampleRate, defaultValue: Float64(0),
                operation: "fréquence du périphérique")
        else { return nil }
        let streams =
            (try? AudioObject.array(
                device, kAudioDevicePropertyStreams, scope: output, of: AudioObjectID.self,
                operation: "flux de sortie")) ?? []
        var streamFrames: UInt32 = 0
        if let first = streams.first {
            streamFrames =
                (try? AudioObject.value(
                    first, kAudioStreamPropertyLatency, defaultValue: UInt32(0),
                    operation: "latence du flux")) ?? 0
        }
        return LatencyReport(
            deviceFrames: Int(deviceFrames), streamFrames: Int(streamFrames),
            safetyOffsetFrames: Int(safety), sampleRate: rate
        )
    }
}

/// La sortie par défaut du Mac, celle où jouent les applications.
public enum DefaultOutputDevice {
    public static func current() -> AudioObjectID? {
        SystemOutputVolume.defaultOutputDevice()
    }

    public static func uid(of device: AudioObjectID) -> String? {
        try? AudioObject.string(device, kAudioDevicePropertyDeviceUID, operation: "UID de la sortie")
    }

    public static func name(of device: AudioObjectID) -> String? {
        try? AudioObject.string(device, kAudioObjectPropertyName, operation: "nom de la sortie")
    }

    /// Fait de cette sortie la sortie par défaut.
    @discardableResult
    public static func set(_ device: AudioObjectID) -> Bool {
        var address = AudioObject.address(kAudioHardwarePropertyDefaultOutputDevice)
        var value = device
        let status = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
            UInt32(MemoryLayout<AudioObjectID>.size), &value
        )
        if status != noErr {
            videoSyncLog.error("Changement de sortie par défaut refusé : \(status)")
        }
        return status == noErr
    }
}
