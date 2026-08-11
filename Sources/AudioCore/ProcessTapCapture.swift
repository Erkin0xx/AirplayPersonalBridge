import AVFoundation
import CoreAudio
import Foundation
import OSLog

/// Capture via Core Audio Process Tap (CDC 4.2), pour les deux modes qui reposent sur
/// cette API : audio système global, et audio d'une application précise.
///
/// Un tap seul ne délivre aucun audio : il doit être rattaché à un périphérique agrégé
/// privé, dont le callback d'IO fournit les buffers. C'est ce que fait cette classe.
///
/// Invariant section 12 : cette classe ne connaît aucune destination (Geneva, HomePod).
/// Elle expose un flux PCM et rien d'autre.
@available(macOS 14.2, *)
public final class ProcessTapCapture {
    /// Les deux modes bâtis sur le Process Tap. Le choix se fait à la création du tap,
    /// sans changement d'architecture entre les deux (CDC 4.2).
    public enum Mode: Sendable {
        /// Son système global. Les process listés sont exclus (liste vide = tout capter).
        case globalExcluding(pids: [pid_t])
        /// Mixdown d'une application précise.
        case processes(pids: [pid_t])

        var description: String {
            switch self {
            case let .globalExcluding(pids):
                return pids.isEmpty ? "système global" : "système global (hors \(pids))"
            case let .processes(pids):
                return "processus \(pids)"
            }
        }
    }

    private var tapID: AudioObjectID = kAudioObjectUnknown
    private var aggregateID: AudioObjectID = kAudioObjectUnknown
    private var ioProcID: AudioDeviceIOProcID?
    private var isRunning = false

    /// File dédiée au callback d'IO. Core Audio la traite en contexte temps réel : les
    /// règles de la section 13 s'y appliquent (pas d'allocation, pas de verrou).
    private let ioQueue = DispatchQueue(
        label: "fr.baptiste.airplaymultioutput.tap-io", qos: .userInitiated
    )

    /// Format réellement livré par le tap, connu seulement après sa création.
    public private(set) var format: AVAudioFormat?

    /// Consommateur des buffers capturés.
    ///
    /// ATTENTION : appelé depuis le thread temps réel de Core Audio. L'implémentation ne
    /// doit ni allouer, ni verrouiller, ni faire d'I/O (CDC section 13). En usage réel,
    /// elle se contente d'écrire dans un ring buffer lock-free.
    private let sink: (UnsafePointer<AudioBufferList>, UInt32) -> Void

    private let log = AudioLog.capture

    public init(sink: @escaping (UnsafePointer<AudioBufferList>, UInt32) -> Void) {
        self.sink = sink
    }

    deinit {
        // Le nettoyage passe par `stop()`, mais on garantit ici qu'aucun objet Core Audio
        // ne fuit si l'appelant a omis l'appel.
        teardown()
    }

    // MARK: - Cycle de vie

    public func start(mode: Mode) throws {
        guard !isRunning else { return }

        let description = Self.makeTapDescription(for: mode)
        // Tap privé : n'apparaît pas dans les autres applications audio du système.
        description.isPrivate = true
        // Le son doit continuer à sortir des haut-parleurs pendant la capture.
        description.muteBehavior = .unmuted
        description.name = "AirPlayMultiOutput-\(UUID().uuidString.prefix(8))"

        var newTapID = AudioObjectID(kAudioObjectUnknown)
        try check(
            AudioHardwareCreateProcessTap(description, &newTapID),
            "AudioHardwareCreateProcessTap (\(mode.description))"
        )
        tapID = newTapID
        log.info("Tap créé (\(mode.description, privacy: .public)), id=\(newTapID)")

        // PIÈGE : l'UID à placer dans kAudioSubTapUIDKey est l'UUID de la *description*
        // (`CATapDescription.uuid`), pas la valeur lue via kAudioTapPropertyUID. Utiliser
        // la seconde produit un agrégat qui se crée sans erreur, dont le callback d'IO est
        // appelé au rythme normal, mais qui ne livre que des buffers de zéros.
        let tapUID = description.uuid.uuidString
        var streamFormat = try readTapFormat()
        guard let avFormat = AVAudioFormat(streamDescription: &streamFormat.asbd) else {
            throw AudioCaptureError.unsupportedFormat("ASBD du tap non convertible en AVAudioFormat")
        }
        format = avFormat
        log.info("""
            Format du tap : \(avFormat.sampleRate, privacy: .public) Hz, \
            \(avFormat.channelCount, privacy: .public) canaux
            """)

        try createAggregateDevice(tapUID: tapUID)
        try startIO()
        isRunning = true
    }

    public func stop() {
        guard isRunning else { return }
        isRunning = false
        teardown()
        log.info("Capture arrêtée.")
    }

    // MARK: - Construction

    private static func makeTapDescription(for mode: Mode) -> CATapDescription {
        switch mode {
        case let .globalExcluding(pids):
            // Ces initialiseurs sont NS_REFINED_FOR_SWIFT : Swift les expose avec des
            // AudioObjectID typés plutôt que des NSNumber.
            return CATapDescription(
                stereoGlobalTapButExcludeProcesses: pids.map(objectID(forPID:))
            )
        case let .processes(pids):
            return CATapDescription(stereoMixdownOfProcesses: pids.map(objectID(forPID:)))
        }
    }

    /// Traduit un pid système en AudioObjectID de process audio, seule forme acceptée par
    /// `CATapDescription`.
    private static func objectID(forPID pid: pid_t) -> AudioObjectID {
        var addr = AudioObject.address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var inputPID = pid
        var objectID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr,
            UInt32(MemoryLayout<pid_t>.size), &inputPID,
            &size, &objectID
        )
        return status == noErr ? objectID : AudioObjectID(kAudioObjectUnknown)
    }

    private struct TapFormat {
        var asbd: AudioStreamBasicDescription
    }

    private func readTapFormat() throws -> TapFormat {
        var addr = AudioObject.address(kAudioTapPropertyFormat)
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioObjectGetPropertyData(tapID, &addr, 0, nil, &size, &asbd) == noErr else {
            throw AudioCaptureError.tapFormatUnavailable
        }
        return TapFormat(asbd: asbd)
    }

    /// Crée le périphérique agrégé privé qui porte le tap et fournit le callback d'IO.
    private func createAggregateDevice(tapUID: String) throws {
        // L'agrégat doit porter le périphérique de sortie courant comme sous-périphérique
        // principal : c'est lui qui fournit l'horloge qui fait tourner le tap.
        let outputDeviceID = try AudioObject.value(
            AudioObjectID(kAudioObjectSystemObject),
            kAudioHardwarePropertyDefaultSystemOutputDevice,
            defaultValue: AudioObjectID(kAudioObjectUnknown),
            operation: "lecture du périphérique de sortie système"
        )
        let outputUID = try AudioObject.string(
            outputDeviceID, kAudioDevicePropertyDeviceUID,
            operation: "lecture de l'UID du périphérique de sortie"
        )

        let uid = "fr.baptiste.airplaymultioutput.aggregate.\(UUID().uuidString)"
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "AirPlayMultiOutput Capture",
            kAudioAggregateDeviceUIDKey: uid,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            // Privé : invisible dans Réglages Son, n'altère pas la config audio de l'utilisateur.
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: outputUID]
            ],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: tapUID,
                    kAudioSubTapDriftCompensationKey: true,
                ]
            ],
        ]

        var newID = AudioObjectID(kAudioObjectUnknown)
        try check(
            AudioHardwareCreateAggregateDevice(description as CFDictionary, &newID),
            "AudioHardwareCreateAggregateDevice"
        )
        aggregateID = newID
        log.info("Périphérique agrégé privé créé, id=\(newID)")
    }

    private func startIO() throws {
        // Le callback tourne sur le thread temps réel de Core Audio : callback C classique,
        // aucune allocation, aucun verrou (CDC section 13).
        let context = Unmanaged.passUnretained(self).toOpaque()
        let bytesPerFrame = format?.streamDescription.pointee.mBytesPerFrame ?? 0
        var procID: AudioDeviceIOProcID?
        try check(
            AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, ioQueue) {
                [bytesPerFrame] _, inInputData, _, _, _ in
                let capture = Unmanaged<ProcessTapCapture>
                    .fromOpaque(context).takeUnretainedValue()
                // Le nombre de trames se déduit de mBytesPerFrame du format réel du tap,
                // pas de la taille d'un Float : en entrelacé stéréo une trame fait 8 octets,
                // et diviser par 4 donnerait le double du compte réel.
                let frames = bytesPerFrame > 0
                    ? inInputData.pointee.mBuffers.mDataByteSize / bytesPerFrame
                    : 0
                capture.sink(inInputData, frames)
            },
            "AudioDeviceCreateIOProcIDWithBlock"
        )
        ioProcID = procID
        try check(AudioDeviceStart(aggregateID, procID), "AudioDeviceStart")
    }

    private func teardown() {
        if let procID = ioProcID, aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
            ioProcID = nil
        }
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = kAudioObjectUnknown
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = kAudioObjectUnknown
        }
    }
}
