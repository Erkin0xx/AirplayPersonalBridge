import AVFoundation
import CoreAudio
import Foundation
import OSLog

/// Capture depuis une entrée audio physique (micro ou ligne), troisième mode du CDC 4.2.
///
/// N'utilise pas le Process Tap mais `AVAudioEngine.inputNode`, disponible sans contrainte
/// de version macOS récente. Le périphérique effectivement capté est celui sélectionné dans
/// Réglages Son > Entrée : l'application n'a pas à gérer la liste des interfaces connectées.
///
/// Autorisation requise : micro classique (`NSMicrophoneUsageDescription`), distincte de
/// celle des deux modes Process Tap (voir `CapturePermission`).
///
/// Invariant section 12 : comme `ProcessTapCapture`, cette classe ne connaît aucune
/// destination et n'expose qu'un flux PCM.
public final class InputDeviceCapture: TimedAudioCaptureSource {
    private let engine = AVAudioEngine()
    private var isRunning = false
    private var configurationObserver: NSObjectProtocol?
    private let log = AudioLog.capture

    public init() {}

    deinit {
        setRouteChangeHandler(nil)
        teardown()
    }

    public var requiredPermission: CapturePermission.Kind? { .microphone }

    /// Format réel de l'entrée physique : **mono planaire à 48 kHz** sur cette machine, mais une
    /// interface multicanal donnerait autre chose. Le code en aval ne suppose rien
    /// (`CaptureBlockAdapter`).
    public func prepare() throws -> AVAudioFormat {
        let inputFormat = engine.inputNode.inputFormat(forBus: 0)
        guard inputFormat.channelCount > 0, inputFormat.sampleRate > 0 else {
            throw AudioCaptureError.noInputDevice
        }
        log.info("""
            Entrée physique : \(inputFormat.sampleRate, privacy: .public) Hz, \
            \(inputFormat.channelCount, privacy: .public) canaux
            """)
        return inputFormat
    }

    public func start(deliveringTo consumer: @escaping CaptureBlockConsumer) throws {
        try start(deliveringTimedBlocksTo: { list, frames, _ in consumer(list, frames) })
    }

    /// L'instant de chaque bloc est celui qu'`AVAudioEngine` donne à sa première trame : l'horodatage
    /// d'entrée du HAL, **sans** la latence du périphérique ni sa marge de sécurité, que
    /// ``inputLatency()`` relève à part.
    public func start(deliveringTimedBlocksTo consumer: @escaping TimedCaptureBlockConsumer) throws {
        guard !isRunning else { return }
        let input = engine.inputNode
        let inputFormat = input.inputFormat(forBus: 0)

        // bufferSize est une valeur souhaitée : le système peut livrer des blocs différents.
        input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { buffer, when in
            consumer(
                buffer.audioBufferList, buffer.frameLength, when.isHostTimeValid ? when.hostTime : 0
            )
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
        isRunning = true
    }

    public func stop() {
        guard isRunning else { return }
        isRunning = false
        teardown()
        log.info("Capture d'entrée physique arrêtée.")
    }

    /// `AVAudioEngine` s'arrête seul quand l'entrée par défaut change ou disparaît, et le
    /// signale par cette notification : sans la relancer, la capture resterait muette.
    public func setRouteChangeHandler(_ handler: (@Sendable () -> Void)?) {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
            self.configurationObserver = nil
        }
        guard let handler else { return }
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { _ in
            handler()
        }
    }

    public func routeRequiresRebuild() -> Bool { !engine.isRunning }

    /// Ce que l'entrée retient avant l'horodatage de ses blocs, pour information.
    public struct InputLatency: Sendable, Equatable {
        /// Nom du périphérique d'entrée par défaut.
        public let deviceName: String?
        /// `AVAudioInputNode.presentationLatency`, en secondes.
        public let presentationLatencySeconds: Double
        /// `kAudioDevicePropertyLatency`, côté entrée, en trames.
        public let deviceLatencyFrames: UInt32?
        /// `kAudioDevicePropertySafetyOffset`, côté entrée, en trames.
        public let safetyOffsetFrames: UInt32?

        public init(
            deviceName: String?, presentationLatencySeconds: Double,
            deviceLatencyFrames: UInt32?, safetyOffsetFrames: UInt32?
        ) {
            self.deviceName = deviceName
            self.presentationLatencySeconds = presentationLatencySeconds
            self.deviceLatencyFrames = deviceLatencyFrames
            self.safetyOffsetFrames = safetyOffsetFrames
        }
    }

    /// Relevé hors temps réel, une fois l'entrée préparée.
    public func inputLatency() -> InputLatency {
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        deviceID = (try? AudioObject.value(
            AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultInputDevice,
            defaultValue: deviceID, operation: "entrée par défaut"
        )) ?? AudioObjectID(kAudioObjectUnknown)
        let known = deviceID != AudioObjectID(kAudioObjectUnknown)
        return InputLatency(
            deviceName: known
                ? try? AudioObject.string(deviceID, kAudioObjectPropertyName, operation: "nom")
                : nil,
            presentationLatencySeconds: engine.inputNode.presentationLatency,
            deviceLatencyFrames: known
                ? try? AudioObject.value(
                    deviceID, kAudioDevicePropertyLatency, scope: kAudioObjectPropertyScopeInput,
                    defaultValue: UInt32(0), operation: "latence d'entrée")
                : nil,
            safetyOffsetFrames: known
                ? try? AudioObject.value(
                    deviceID, kAudioDevicePropertySafetyOffset,
                    scope: kAudioObjectPropertyScopeInput,
                    defaultValue: UInt32(0), operation: "marge d'entrée")
                : nil
        )
    }

    private func teardown() {
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
    }
}
