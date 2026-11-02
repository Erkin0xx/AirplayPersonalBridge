import AVFoundation
import Darwin
import Foundation
import Testing

@testable import AudioCore

// Outils de mesure du calage acoustique : les clics, le test de canaux, l'enregistrement daté du
// micro et le passage de l'horloge commune à l'horloge hôte.

/// Rend `frames` trames stéréo d'un générateur, bloc après bloc, désentrelacées.
private func render(
    _ generator: PatternBlockGenerator, frames: Int
) -> (left: [Float], right: [Float]) {
    var left: [Float] = []
    var right: [Float] = []
    left.reserveCapacity(frames + generator.blockFrames)
    right.reserveCapacity(frames + generator.blockFrames)
    while left.count < frames {
        generator.renderNextBlock()
        generator.withBufferList { list in
            guard let data = list.pointee.mBuffers.mData?.assumingMemoryBound(to: Float.self)
            else { return }
            for frame in 0..<generator.blockFrames {
                left.append(data[frame * 2])
                right.append(data[frame * 2 + 1])
            }
        }
    }
    return (Array(left.prefix(frames)), Array(right.prefix(frames)))
}

/// Plages `[début, fin)` de trames non nulles, deux plages séparées d'au moins `gap` trames nulles.
private func nonZeroRuns(_ samples: [Float], gap: Int = 50) -> [Range<Int>] {
    var runs: [Range<Int>] = []
    var start: Int?
    var last = 0
    for (index, value) in samples.enumerated() where value != 0 {
        if let current = start, index - last > gap {
            runs.append(current..<(last + 1))
            start = index
        } else if start == nil {
            start = index
        }
        last = index
    }
    if let start { runs.append(start..<(last + 1)) }
    return runs
}

@Suite("Clics de mesure")
struct ClickPatternTests {
    /// Cinq cycles de repère et un peu plus, en blocs de 512 qui ne divisent pas 96 000 : des
    /// salves tombent à cheval sur deux blocs.
    private static let renderedFrames = 2 * ClickPattern.markerEvery * ClickPattern.periodFrames + 30_000

    @Test("Chaque salve commence exactement à une trame k · 96 000, sur les deux canaux")
    func burstsSitOnTheCaptureGraduation() {
        let level = -20.0
        let generator = PatternBlockGenerator(
            pattern: ClickPattern.make(levelDBFS: level), blockFrames: 512
        )
        let (left, right) = render(generator, frames: Self.renderedFrames)
        let burst = ClickPattern.burstSamples(amplitude: pow(10, level / 20))
        #expect(burst.count == 240)

        // Le signal attendu, trame par trame : la salve à chaque k · 96 000, sa doublure 12 000
        // trames plus loin quand k est multiple de 5, et des zéros stricts partout ailleurs.
        var mismatches = 0
        for frame in 0..<left.count {
            let period = frame / ClickPattern.periodFrames
            let position = frame % ClickPattern.periodFrames
            var expected: Float = 0
            if position < burst.count { expected += burst[position] }
            let markerPosition = position - ClickPattern.markerOffsetFrames
            if period % ClickPattern.markerEvery == 0, markerPosition >= 0,
               markerPosition < burst.count
            {
                expected += burst[markerPosition]
            }
            if left[frame] != expected || right[frame] != expected { mismatches += 1 }
        }
        #expect(mismatches == 0)

        // Crête au niveau demandé, au milieu de la salve.
        #expect(abs(Double(left[120]) - pow(10, level / 20)) < 1e-6)
        #expect(left[0] == 0)
    }

    @Test("Le repère double une salve sur cinq, 250 ms plus tard, et aucune autre")
    func markerEveryFifthBurst() {
        let generator = PatternBlockGenerator(
            pattern: ClickPattern.make(levelDBFS: -20), blockFrames: 512
        )
        let (left, _) = render(generator, frames: Self.renderedFrames)
        let runs = nonZeroRuns(left)
        // Toutes les salves : 240 trames dont la première et la dernière valent 0 (Hann).
        #expect(runs.allSatisfy { $0.count == 239 })
        let starts = runs.map { $0.lowerBound - 1 }
        var markerPeriods: [Int] = []
        var periods: [Int] = []
        for start in starts {
            if start % ClickPattern.periodFrames == 0 {
                periods.append(start / ClickPattern.periodFrames)
            } else {
                #expect(start % ClickPattern.periodFrames == ClickPattern.markerOffsetFrames)
                markerPeriods.append(start / ClickPattern.periodFrames)
            }
        }
        let expectedPeriods = Array(0...(Self.renderedFrames / ClickPattern.periodFrames))
        #expect(periods == expectedPeriods)
        #expect(markerPeriods == expectedPeriods.filter { $0 % 5 == 0 })
        #expect(markerPeriods == [0, 5, 10])
    }

    /// Une source arrêtée puis relancée reprend son motif où il en était : c'est ce qui garde ses
    /// salves sur la graduation de capture, que le moteur ne remet pas à zéro.
    @Test("La graduation continue d'un démarrage à l'autre")
    func graduationSurvivesRestart() async throws {
        // Un motif dense, pour que deux courtes périodes de fonctionnement en contiennent beaucoup.
        let pattern = SyntheticPattern(cycleFrames: 1_000, bursts: [
            SyntheticPattern.Burst(
                startFrame: 0, samples: (1...10).map(Float.init), onLeft: true, onRight: false
            ),
        ])
        let source = PatternCaptureSource(pattern: pattern, blockFrames: 128)
        let collector = SampleCollector()
        let format = try source.prepare()
        #expect(format.channelCount == 2 && format.isInterleaved)
        #expect(source.requiredPermission == nil)

        try source.start(deliveringTo: collector.makeConsumer())
        #expect(await eventually { collector.frameCount >= 2_000 })
        source.stop()
        let firstRun = collector.frameCount
        try source.start(deliveringTo: collector.makeConsumer())
        #expect(await eventually { collector.frameCount >= firstRun + 2_000 })
        source.stop()

        let left = collector.left
        for frame in 0..<left.count {
            let position = frame % 1_000
            let expected: Float = position < 10 ? Float(position + 1) : 0
            guard left[frame] == expected else {
                Issue.record("trame \(frame) : \(left[frame]) au lieu de \(expected)")
                return
            }
        }
    }
}

@Suite("Test de canaux gauche/droite")
struct ChannelTestPatternTests {
    private func zeroCrossings(_ samples: ArraySlice<Float>) -> Int {
        var count = 0
        var previous = samples.first ?? 0
        for value in samples.dropFirst() {
            if (previous < 0) != (value < 0) { count += 1 }
            previous = value
        }
        return count
    }

    @Test("Gauche seul puis droit seul, jamais les deux à la fois")
    func channelsNeverOverlap() {
        let generator = PatternBlockGenerator(
            pattern: ChannelTestPattern.make(levelDBFS: -20), blockFrames: 512
        )
        let cycles = 3
        let (left, right) = render(generator, frames: cycles * ChannelTestPattern.cycleFrames)

        var both = 0
        for frame in 0..<left.count where left[frame] != 0 && right[frame] != 0 { both += 1 }
        #expect(both == 0)

        let leftRuns = nonZeroRuns(left)
        let rightRuns = nonZeroRuns(right)
        #expect(leftRuns.count == cycles)
        #expect(rightRuns.count == 2 * cycles)

        for cycle in 0..<cycles {
            let base = cycle * ChannelTestPattern.cycleFrames
            let low = leftRuns[cycle]
            let highs = rightRuns[(2 * cycle)..<(2 * cycle + 2)]
            // Gauche : un bip, de 0 à 0,4 s du cycle.
            #expect(low.lowerBound >= base)
            #expect(low.upperBound <= base + ChannelTestPattern.leftFrames)
            // Droite : deux bips, à 2,0 et 2,3 s, après le bip gauche.
            for (high, start) in zip(highs, ChannelTestPattern.rightStartFrames) {
                #expect(high.lowerBound >= base + start)
                #expect(high.upperBound <= base + start + ChannelTestPattern.rightFrames)
                #expect(high.lowerBound > low.upperBound)
            }
            // Grave à gauche, aigu à droite : 400 Hz sur 0,4 s, 1 600 Hz sur 0,15 s.
            let lowCrossings = zeroCrossings(left[low])
            #expect(abs(lowCrossings - 320) <= 4)
            for high in highs {
                #expect(abs(zeroCrossings(right[high]) - 480) <= 4)
            }
        }
    }
}

// MARK: - Temps réel

extension RealTimePathTests {
    /// Ce que fait le fil des sources synthétiques à chaque bloc : calculer, puis remettre au
    /// consommateur du moteur, qui recopie dans les tampons des sorties.
    @Test("Les clics et le test de canaux n'allouent rien, consommateur du moteur compris")
    func patternSourcesDoNotAllocate() throws {
        for pattern in [ClickPattern.make(levelDBFS: -20), ChannelTestPattern.make(levelDBFS: -20)] {
            let generator = PatternBlockGenerator(pattern: pattern, blockFrames: 512)
            let fanout = CaptureFanout(format: stereoFormat(), slotCount: 2, capacityFrames: 48_000)
            _ = fanout.acquireSlot()
            let adapter = try CaptureBlockAdapter(sourceFormat: stereoFormat(), fanout: fanout)
            let consumer = adapter.makeConsumer()
            let pass = {
                generator.renderNextBlock()
                generator.withBufferList { consumer($0, 512) }
            }
            var warmUp = 0
            while warmUp < 300 {
                pass()
                warmUp += 1
            }
            // 1 000 blocs de 512 trames : plus de 10 s de motif, donc des salves et des silences.
            let observed = AllocationProbe.allocations {
                var run = 0
                while run < 1_000 {
                    pass()
                    run += 1
                }
            }
            let count = try #require(observed)
            #expect(count == 0, "\(count) allocations\n\(AllocationProbe.firstAllocationStack)")
        }
    }

    @Test("L'enregistrement daté n'alloue rien, en mono planaire comme en stéréo entrelacé")
    func timedRecorderDoesNotAllocate() throws {
        for format in [monoPlanarFormat(), stereoFormat()] {
            let recorder = try TimedInputRecorder(
                sourceFormat: format, bufferSeconds: 1, anchorIntervalSeconds: 0.001,
                anchorCapacity: 100
            )
            let consumer = recorder.makeConsumer()
            let channels = Int(format.channelCount)
            var block = [Float](repeating: 0.25, count: 480 * channels)
            let base = try #require(block.withUnsafeMutableBufferPointer { $0.baseAddress })
            var list = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(
                    mNumberChannels: UInt32(channels),
                    mDataByteSize: UInt32(480 * channels * MemoryLayout<Float>.size),
                    mData: base
                )
            )
            var ticks: UInt64 = 1_000
            let count = try withExtendedLifetime(block) { () throws -> Int in
                var warmUp = 0
                while warmUp < 50 {
                    consumer(&list, 480, ticks)
                    ticks += 240_000
                    warmUp += 1
                }
                // Tampon plein et ancrages épuisés compris : ce sont des chemins à part.
                let observed = AllocationProbe.allocations {
                    var run = 0
                    while run < 1_000 {
                        consumer(&list, 480, ticks)
                        ticks += 240_000
                        run += 1
                    }
                }
                return try #require(observed)
            }
            #expect(count == 0, "\(count) allocations\n\(AllocationProbe.firstAllocationStack)")
            #expect(recorder.droppedFrames > 0)
            #expect(recorder.anchors.count == 100)
        }
    }
}

// MARK: - Enregistrement daté

@Suite("Enregistrement daté de l'entrée")
struct TimedInputRecorderTests {
    private func feed(
        _ recorder: TimedInputRecorder, channels: Int, frames: Int, start: Float, ticks: UInt64
    ) {
        var block = [Float](repeating: 0, count: frames * channels)
        for frame in 0..<frames {
            for channel in 0..<channels {
                // Voie 0 : une rampe ; les autres : du bruit qui ne doit jamais apparaître.
                block[frame * channels + channel] = channel == 0 ? start + Float(frame) : -99
            }
        }
        block.withUnsafeMutableBytes { raw in
            var list = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(
                    mNumberChannels: UInt32(channels), mDataByteSize: UInt32(raw.count),
                    mData: raw.baseAddress
                )
            )
            recorder.consume(&list, frameCount: frames, hostTicks: ticks)
        }
    }

    private func drained(_ recorder: TimedInputRecorder) -> [Float] {
        var samples: [Float] = []
        recorder.drain { buffer in
            guard let data = buffer.floatChannelData?[0] else { return }
            samples += UnsafeBufferPointer(start: data, count: Int(buffer.frameLength))
        }
        return samples
    }

    @Test("La première voie est gardée, et chaque ancrage date la trame qui ouvre son bloc")
    func keepsFirstChannelAndAnchors() throws {
        let recorder = try TimedInputRecorder(
            sourceFormat: stereoFormat(), anchorIntervalSeconds: 0.01  // 480 trames
        )
        feed(recorder, channels: 2, frames: 300, start: 0, ticks: 1_000)
        feed(recorder, channels: 2, frames: 300, start: 300, ticks: 2_000)  // trop tôt : 300 < 480
        feed(recorder, channels: 2, frames: 300, start: 600, ticks: 3_000)  // 600 ≥ 480
        feed(recorder, channels: 2, frames: 300, start: 900, ticks: 0)      // non daté
        feed(recorder, channels: 2, frames: 300, start: 1_200, ticks: 5_000)

        #expect(drained(recorder) == (0..<1_500).map(Float.init))
        #expect(recorder.framesDrained == 1_500)
        #expect(recorder.anchors == [
            TimedInputRecorder.Anchor(frame: 0, hostTicks: 1_000),
            TimedInputRecorder.Anchor(frame: 600, hostTicks: 3_000),
            TimedInputRecorder.Anchor(frame: 1_200, hostTicks: 5_000),
        ])
        #expect(recorder.recordingFormat.channelCount == 1)
        #expect(recorder.droppedFrames == 0)
    }

    @Test("Le mono planaire passe tel quel")
    func monoPlanarPassesThrough() throws {
        let recorder = try TimedInputRecorder(sourceFormat: monoPlanarFormat())
        feed(recorder, channels: 1, frames: 1_000, start: 5, ticks: 42)
        #expect(drained(recorder) == (0..<1_000).map { Float($0 + 5) })
        #expect(recorder.anchors == [TimedInputRecorder.Anchor(frame: 0, hostTicks: 42)])
    }

    /// Le processus du CLI quitte par `exit`, qui ne libère pas le fichier : sans `close`, l'en-tête
    /// annonçait 0 trame et `wave` de Python lisait un fichier vide.
    @Test("Le fichier écrit annonce toutes ses trames une fois fermé")
    func writtenFileIsFinalized() throws {
        let recorder = try TimedInputRecorder(sourceFormat: monoPlanarFormat())
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("enregistrement-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try WAVWriter(url: url, format: recorder.recordingFormat)
        feed(recorder, channels: 1, frames: 30_000, start: 0, ticks: 1)
        try recorder.drain(into: writer)
        writer.close()

        let data = try Data(contentsOf: url)
        // En-tête RIFF : la taille du bloc `data` suit son identifiant.
        let marker = try #require(data.range(of: Data("data".utf8)))
        let size = data[marker.upperBound..<(marker.upperBound + 4)]
            .enumerated().reduce(0) { $0 | Int($1.element) << (8 * $1.offset) }
        #expect(size == 30_000 * 2)
        let file = try AVAudioFile(forReading: url)
        #expect(file.length == 30_000)
        #expect(file.fileFormat.channelCount == 1)
    }

    /// Un bloc refusé faute de place n'a aucune trame dans le fichier : l'ancrer daterait une trame
    /// qui n'est pas la sienne.
    @Test("Un bloc refusé en entier n'est pas ancré, et la perte est comptée")
    func refusedBlockIsNotAnchored() throws {
        let recorder = try TimedInputRecorder(
            sourceFormat: monoPlanarFormat(), bufferSeconds: 0, anchorIntervalSeconds: 0
        )
        // Tampon de 4 096 trames au minimum.
        feed(recorder, channels: 1, frames: 4_096, start: 0, ticks: 10)
        feed(recorder, channels: 1, frames: 100, start: 4_096, ticks: 20)
        #expect(recorder.droppedFrames == 100)
        #expect(recorder.anchors.map(\.hostTicks) == [10])
        #expect(drained(recorder).count == 4_096)
        feed(recorder, channels: 1, frames: 100, start: 0, ticks: 30)
        #expect(recorder.anchors.map(\.frame) == [0, 4_096])
    }
}

/// Recueille les blocs stéréo entrelacés d'une source cadencée.
private final class SampleCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [Float] = []

    var frameCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return samples.count / 2
    }

    var left: [Float] {
        lock.lock()
        defer { lock.unlock() }
        return stride(from: 0, to: samples.count, by: 2).map { samples[$0] }
    }

    func makeConsumer() -> CaptureBlockConsumer {
        { [self] list, frameCount in
            guard let data = list.pointee.mBuffers.mData?.assumingMemoryBound(to: Float.self)
            else { return }
            lock.lock()
            samples += UnsafeBufferPointer(start: data, count: Int(frameCount) * 2)
            lock.unlock()
        }
    }
}
