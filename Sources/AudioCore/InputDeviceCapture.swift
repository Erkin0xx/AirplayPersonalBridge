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
public final class InputDeviceCapture {
    private let engine = AVAudioEngine()
    private var isRunning = false
    private let log = AudioLog.capture

    /// Format réel de l'entrée physique, connu après `start()`.
    public private(set) var format: AVAudioFormat?

    /// Consommateur des buffers capturés.
    ///
    /// Appelé sur le thread de rendu d'AVAudioEngine : mêmes contraintes que le callback du
    /// Process Tap (pas d'allocation, pas de verrou) — voir CDC section 13.
    private let sink: (AVAudioPCMBuffer) -> Void

    public init(sink: @escaping (AVAudioPCMBuffer) -> Void) {
        self.sink = sink
    }

    deinit { teardown() }

    public func start() throws {
        guard !isRunning else { return }

        let input = engine.inputNode
        let inputFormat = input.inputFormat(forBus: 0)
        guard inputFormat.channelCount > 0, inputFormat.sampleRate > 0 else {
            throw AudioCaptureError.noInputDevice
        }
        format = inputFormat
        log.info("""
            Entrée physique : \(inputFormat.sampleRate, privacy: .public) Hz, \
            \(inputFormat.channelCount, privacy: .public) canaux
            """)

        // bufferSize est une valeur souhaitée : le système peut livrer des blocs différents.
        input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [sink] buffer, _ in
            sink(buffer)
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

    private func teardown() {
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
    }
}
