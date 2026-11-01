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
public final class ProcessTapCapture: AudioCaptureSource {
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

    private let mode: Mode
    private let muteLocalOutput: Bool

    private var tapID: AudioObjectID = kAudioObjectUnknown
    private var tapUUID: UUID?
    private var aggregateID: AudioObjectID = kAudioObjectUnknown
    private var ioProcID: AudioDeviceIOProcID?
    private var isRunning = false
    /// UID du périphérique qui fournit l'horloge de l'agrégat (piège n° 2 de `CLAUDE.md`).
    private var clockDeviceUID: String?
    private var routeWatcher: DefaultOutputDeviceWatcher?
    /// Liste réduite aux flux du tap, quand l'agrégat en porte d'autres. Allouée hors du chemin
    /// temps réel, libérée une fois l'IO arrêtée.
    private var selectedBuffers: UnsafeMutableAudioBufferListPointer?

    /// File dédiée au callback d'IO. Core Audio la traite en contexte temps réel : les
    /// règles de la section 13 s'y appliquent (pas d'allocation, pas de verrou).
    private let ioQueue = DispatchQueue(
        label: "fr.baptiste.airplaymultioutput.tap-io", qos: .userInitiated
    )

    /// Format réellement livré par le tap, connu seulement après `prepare()`.
    public private(set) var format: AVAudioFormat?

    private let log = AudioLog.capture

    public var requiredPermission: CapturePermission.Kind? { .systemAudio }

    /// - Parameters:
    ///   - mode: ce qui est capté.
    ///   - muteLocalOutput: coupe le son du Mac le temps de la capture
    ///     (`CATapMutedWhenTapped`). Sans cela, le Mac et les enceintes jouent ensemble, avec
    ///     les deux secondes de décalage que retient une diffusion AirPlay. Le son local
    ///     revient de lui-même dès que le tap n'est plus lu, y compris si l'application plante.
    public init(mode: Mode, muteLocalOutput: Bool = false) {
        self.mode = mode
        self.muteLocalOutput = muteLocalOutput
    }

    deinit {
        // Le nettoyage passe par `stop()`, mais on garantit ici qu'aucun objet Core Audio
        // ne fuit si l'appelant a omis l'appel.
        routeWatcher = nil
        teardown()
    }

    // MARK: - Cycle de vie

    /// Crée le tap et rend son format. Aucun bloc ne circule encore.
    public func prepare() throws -> AVAudioFormat {
        // Une capture déjà préparée repart de zéro : c'est le chemin d'une reconstruction, où
        // le nouveau périphérique peut imposer un autre format.
        teardown()
        isRunning = false

        let description = Self.makeTapDescription(for: mode)
        // Tap privé : n'apparaît pas dans les autres applications audio du système.
        description.isPrivate = true
        description.muteBehavior = muteLocalOutput ? .mutedWhenTapped : .unmuted
        description.name = "AirPlayMultiOutput-\(UUID().uuidString.prefix(8))"

        var newTapID = AudioObjectID(kAudioObjectUnknown)
        try check(
            AudioHardwareCreateProcessTap(description, &newTapID),
            "AudioHardwareCreateProcessTap (\(mode.description))"
        )
        tapID = newTapID
        tapUUID = description.uuid
        log.info("Tap créé (\(self.mode.description, privacy: .public)), id=\(newTapID)")

        var streamFormat = try readTapFormat()
        guard let avFormat = AVAudioFormat(streamDescription: &streamFormat.asbd) else {
            teardown()
            throw AudioCaptureError.unsupportedFormat("ASBD du tap non convertible en AVAudioFormat")
        }
        format = avFormat
        log.info("""
            Format du tap : \(avFormat.sampleRate, privacy: .public) Hz, \
            \(avFormat.channelCount, privacy: .public) canaux
            """)
        return avFormat
    }

    /// Crée l'agrégat et démarre l'IO. `prepare()` doit avoir réussi.
    public func start(deliveringTo consumer: @escaping CaptureBlockConsumer) throws {
        guard !isRunning else { return }
        guard let tapUUID, let format else { throw AudioCaptureError.tapFormatUnavailable }
        do {
            // PIÈGE : l'UID à placer dans kAudioSubTapUIDKey est l'UUID de la *description*
            // (`CATapDescription.uuid`), pas la valeur lue via kAudioTapPropertyUID. Utiliser
            // la seconde produit un agrégat qui se crée sans erreur, dont le callback d'IO est
            // appelé au rythme normal, mais qui ne livre que des buffers de zéros.
            try createAggregateDevice(tapUID: tapUUID.uuidString)
            try startIO(format: format, consumer: consumer)
        } catch {
            teardown()
            throw error
        }
        isRunning = true
    }

    public func stop() {
        guard isRunning || tapID != kAudioObjectUnknown else { return }
        isRunning = false
        teardown()
        log.info("Capture arrêtée.")
    }

    /// Écoute les changements de sortie par défaut. Voir ``routeRequiresRebuild()``.
    public func setRouteChangeHandler(_ handler: (@Sendable () -> Void)?) {
        routeWatcher = handler.map { DefaultOutputDeviceWatcher(onChange: $0) }
    }

    /// Le périphérique qui porte l'horloge de l'agrégat a-t-il changé ?
    ///
    /// Sans ce contrôle, épingler les effets sonores sur un périphérique et changer la sortie
    /// principale reconstruirait la capture pour rien, avec un trou audible à la clé. Si la
    /// sortie est illisible, on ne touche à rien : reconstruire échouerait de la même façon.
    public func routeRequiresRebuild() -> Bool {
        guard let current = try? Self.currentClockDeviceUID() else { return false }
        return current != clockDeviceUID
    }

    /// Une application captée joue-t-elle ?
    ///
    /// Le sens de « jouer » est celui de Core Audio : un flux de sortie ouvert, pas forcément
    /// un signal non nul. C'est donc un indice, pas une preuve.
    public func isAudioExpected() -> Bool? {
        guard let playing = try? AudioProcessList.playing() else { return nil }
        let own = getpid()
        switch mode {
        case let .globalExcluding(pids):
            return playing.contains { $0.pid != own && !pids.contains($0.pid) }
        case let .processes(pids):
            return playing.contains { pids.contains($0.pid) }
        }
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

    private static func currentClockDeviceUID() throws -> String {
        let outputDeviceID = try AudioObject.value(
            AudioObjectID(kAudioObjectSystemObject),
            kAudioHardwarePropertyDefaultSystemOutputDevice,
            defaultValue: AudioObjectID(kAudioObjectUnknown),
            operation: "lecture du périphérique de sortie système"
        )
        return try AudioObject.string(
            outputDeviceID, kAudioDevicePropertyDeviceUID,
            operation: "lecture de l'UID du périphérique de sortie"
        )
    }

    /// Crée le périphérique agrégé privé qui porte le tap et fournit le callback d'IO.
    private func createAggregateDevice(tapUID: String) throws {
        // L'agrégat doit porter le périphérique de sortie courant comme sous-périphérique
        // principal : c'est lui qui fournit l'horloge qui fait tourner le tap.
        let outputUID = try Self.currentClockDeviceUID()
        clockDeviceUID = outputUID

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

    private func startIO(
        format: AVAudioFormat, consumer: @escaping CaptureBlockConsumer
    ) throws {
        // Le callback tourne sur le thread temps réel de Core Audio : callback C classique,
        // aucune allocation, aucun verrou (CDC section 13).
        let bytesPerFrame = format.streamDescription.pointee.mBytesPerFrame
        // Nombre de tampons que le tap occupe dans la liste livrée par l'agrégat.
        let tapBuffers = format.isInterleaved ? 1 : Int(format.channelCount)
        let selected = AudioBufferList.allocate(maximumBuffers: tapBuffers)
        selectedBuffers = selected

        var procID: AudioDeviceIOProcID?
        try check(
            AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, ioQueue) {
                [bytesPerFrame, tapBuffers, selected, consumer] _, inInputData, _, _, _ in
                // Une liste plus longue que le tap signale des entrées de sous-périphérique
                // devant lui : des haut-parleurs n'en ont pas, un casque à micro si. Les prendre
                // pour le tap diffuserait le micro du casque, sans erreur et au bon format.
                // L'ordre (sous-périphériques, puis tap) n'a pas pu être vérifié sur un tel
                // casque : voir le compte rendu. Sur la configuration validée, la liste ne
                // porte que le tap et ce chemin n'est pas emprunté.
                let total = Int(inInputData.pointee.mNumberBuffers)
                var list = inInputData
                if total > tapBuffers {
                    let all = UnsafeMutableAudioBufferListPointer(
                        UnsafeMutablePointer(mutating: inInputData))
                    // `while` : hors optimisation, `for … in 0..<n` alloue à chaque tour.
                    var index = 0
                    while index < tapBuffers {
                        selected[index] = all[total - tapBuffers + index]
                        index += 1
                    }
                    list = UnsafePointer(selected.unsafePointer)
                }
                // Le nombre de trames se déduit de mBytesPerFrame du format réel du tap,
                // pas de la taille d'un Float : en entrelacé stéréo une trame fait 8 octets,
                // et diviser par 4 donnerait le double du compte réel.
                let frames = bytesPerFrame > 0
                    ? list.pointee.mBuffers.mDataByteSize / bytesPerFrame
                    : 0
                consumer(list, frames)
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
        // Le bloc d'IO s'exécute sur `ioQueue` : un passage peut encore y être en cours au
        // retour d'`AudioDeviceStop`. Vider la file garantit qu'après `stop()` plus aucun bloc
        // n'arrive au consommateur — condition pour relancer une capture sans jamais avoir
        // deux producteurs sur un même ring buffer.
        ioQueue.sync {}
        if let selected = selectedBuffers {
            free(selected.unsafeMutablePointer)
            selectedBuffers = nil
        }
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = kAudioObjectUnknown
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = kAudioObjectUnknown
        }
        tapUUID = nil
        clockDeviceUID = nil
    }
}
