import AVFoundation
import Foundation
import Testing

@testable import AudioCore
@testable import audiocap

/// Un enregistrement de mesure fabriqué de bout en bout par les vraies classes, sans micro ni
/// enceinte, pour vérifier `scripts/measure-clicks.py` sur ce que le CLI écrit vraiment :
///
///   MEASURE_EXPORT_DIR=<dossier> swift test --filter MeasurementExport
///   scripts/measure-clicks.py <dossier>/export.wav     # attendu : un groupe à +7,25 ms
///
/// Les salves sont celles du générateur des clics ; une « enceinte » les rejoue 7,25 ms après
/// l'instant que l'horloge commune leur assigne. Sans la variable, le test ne fait rien.
@Suite("CLI : export d'une mesure synthétique")
struct MeasurementExport {
    static let delayMs = 7.25

    @Test("Écrit export.wav et export.json")
    func export() throws {
        guard let directory = ProcessInfo.processInfo.environment["MEASURE_EXPORT_DIR"] else { return }
        let timebase = HostTimebase.current()
        let rate = 48_000.0
        let nanosecondsPerFrame = 1e9 / rate
        let skipped = 30_000
        let recordedFrames = 12 * Int(rate)

        // La trame 0 de capture est attendue en `frameZeroHost` ; l'enregistrement commence
        // `skipped` trames plus tard, retard de l'enceinte compris.
        let frameZeroHost = 2_000_000_000_000.0
        let firstSampleHost = frameZeroHost + Double(skipped) * nanosecondsPerFrame + Self.delayMs * 1e6

        let generator = PatternBlockGenerator(pattern: ClickPattern.make(levelDBFS: -20), blockFrames: 480)
        var left: [Float] = []
        while left.count < skipped + recordedFrames {
            generator.renderNextBlock()
            generator.withBufferList { list in
                guard let data = list.pointee.mBuffers.mData?.assumingMemoryBound(to: Float.self)
                else { return }
                for frame in 0..<generator.blockFrames { left.append(data[frame * 2]) }
            }
        }

        let format = try #require(AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false))
        let recorder = try TimedInputRecorder(sourceFormat: format)
        let consumer = recorder.makeConsumer()
        let url = URL(fileURLWithPath: directory).appendingPathComponent("export.wav")
        let writer = try WAVWriter(url: url, format: recorder.recordingFormat)
        var offset = 0
        while offset < recordedFrames {
            var block = Array(left[(skipped + offset)..<(skipped + offset + 480)])
            let host = firstSampleHost + Double(offset) * nanosecondsPerFrame
            block.withUnsafeMutableBytes { raw in
                var list = AudioBufferList(
                    mNumberBuffers: 1,
                    mBuffers: AudioBuffer(
                        mNumberChannels: 1, mDataByteSize: UInt32(raw.count), mData: raw.baseAddress)
                )
                consumer(&list, 480, timebase.ticks(fromNanoseconds: UInt64(host)))
            }
            offset += 480
            try recorder.drain(into: writer)
        }
        writer.close()

        let unixZero = 1_762_100_000.0
        let mapping = HostClockMapping(timebase: timebase, pairs: [
            WallHostPair(unixTime: unixZero, hostNanoseconds: UInt64(frameZeroHost), uncertaintyNanoseconds: 0),
        ])
        let document = MeasurementDocument.make(
            wavFile: "export.wav", recorder: recorder, mapping: mapping,
            latency: InputDeviceCapture.InputLatency(
                deviceName: "synthétique", presentationLatencySeconds: 0, deviceLatencyFrames: nil,
                safetyOffsetFrames: nil),
            timeline: BridgeEngine.PlaybackTimeline(
                captureSampleRate: rate, playoutDelaySeconds: 2,
                frameZeroPresentationUnixTime: unixZero, interruptedSeconds: 0),
            timelineChanges: [],
            source: .clicks(levelDBFS: -20),
            outputs: [MeasurementDocument.OutputInfo(
                id: "airplay2/Salon", protocole: "airplay2", nomDemande: "Salon", volumeDb: -20,
                delaiDemandeMs: 0, delaiManuelMs: 0, latenceRecepteurMs: 0, renfortBassesDb: nil,
                etatFinal: "diffusion", paquets: 0)]
        )
        try document.encoded().write(
            to: MeasurementRecording.jsonURL(for: url))
        #expect(recorder.framesDrained == recordedFrames)
    }
}
