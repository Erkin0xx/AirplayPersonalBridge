import AVFoundation
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
public final class InputDeviceCapture: AudioCaptureSource {
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
        guard !isRunning else { return }
        let input = engine.inputNode
        let inputFormat = input.inputFormat(forBus: 0)

        // bufferSize est une valeur souhaitée : le système peut livrer des blocs différents.
        input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { buffer, _ in
            consumer(buffer.audioBufferList, buffer.frameLength)
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

    private func teardown() {
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
    }
}
