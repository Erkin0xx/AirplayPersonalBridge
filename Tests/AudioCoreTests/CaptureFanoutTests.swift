import AVFoundation
import Darwin
import Foundation
import Synchronization
import Testing

@testable import AudioCore

// MARK: - Sonde d'allocation

/// Compte les allocations du thread courant, à travers le crochet `malloc_logger` de libmalloc.
///
/// La règle « sans allocation dans le callback » est un invariant de la section 12, et rien dans
/// le langage ne le garantit : un `Array` temporaire ou une fermeture capturante s'y glisse sans
/// bruit. Cette sonde en fait une assertion. Partagée avec `MeasurementSourceTests`.
enum AllocationProbe {
    private typealias Logger = @convention(c) (UInt32, UInt, UInt, UInt, UInt, UInt32) -> Void

    /// Identifiant du thread observé, zéro si aucun. Atomique, seul de ces champs à l'être : le
    /// crochet s'exécute sur tous les threads du processus, mais seul le thread observé va plus
    /// loin que cette lecture.
    private static let watchedThread = Atomic<UInt>(0)
    nonisolated(unsafe) private static var count = 0
    /// Pile de la première allocation vue, pour qu'un échec dise où chercher. Mémoire réservée
    /// d'avance : le crochet ne doit pas allouer lui-même.
    nonisolated(unsafe) private static var stackDepth: Int32 = 0
    nonisolated(unsafe) private static let stack =
        UnsafeMutablePointer<UnsafeMutableRawPointer?>.allocate(capacity: 24)

    /// Bit positionné par libmalloc sur les événements d'allocation (`MALLOC_LOG_TYPE_ALLOCATE`).
    private static let allocateFlag: UInt32 = 2

    /// Le Thread Sanitizer remplace l'allocateur : le crochet n'y est jamais appelé, et un zéro
    /// n'y prouverait rien.
    static var isUsable: Bool {
        dlsym(UnsafeMutableRawPointer(bitPattern: -2), "__tsan_init") == nil
    }

    /// Rend le nombre d'allocations faites par `body` sur ce thread, ou `nil` si libmalloc
    /// n'expose pas le crochet.
    static func allocations(during body: () -> Void) -> Int? {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "malloc_logger") else {
            return nil
        }
        let slot = symbol.assumingMemoryBound(to: Logger?.self)
        _ = stack
        count = 0
        stackDepth = 0
        let current = UInt(bitPattern: pthread_self())
        watchedThread.store(current, ordering: .relaxed)
        slot.pointee = { type, _, _, _, _, _ in
            guard type & AllocationProbe.allocateFlag != 0 else { return }
            let thread = UInt(bitPattern: pthread_self())
            guard AllocationProbe.watchedThread.load(ordering: .relaxed) == thread else { return }
            if AllocationProbe.count == 0 {
                // Le crochet se désarme le temps de l'appel : `backtrace` peut allouer au premier
                // passage, et compter cette allocation-là serait mentir.
                AllocationProbe.watchedThread.store(0, ordering: .relaxed)
                AllocationProbe.stackDepth = backtrace(AllocationProbe.stack, 24)
                AllocationProbe.watchedThread.store(thread, ordering: .relaxed)
            }
            AllocationProbe.count += 1
        }
        body()
        watchedThread.store(0, ordering: .relaxed)
        slot.pointee = nil
        return count
    }

    /// La pile de la première allocation de la dernière mesure, symbolisée.
    static var firstAllocationStack: String {
        guard stackDepth > 0, let symbols = backtrace_symbols(stack, stackDepth) else { return "" }
        defer { free(symbols) }
        return (0..<Int(stackDepth)).compactMap { index in
            symbols[index].map { String(cString: $0) }
        }.joined(separator: "\n")
    }
}

@Suite(
    "Chemin temps réel : ni allocation, ni copie du tampon partagé",
    .serialized,
    .enabled(if: AllocationProbe.isUsable, "le Thread Sanitizer remplace l'allocateur")
)
struct RealTimePathTests {
    private func audioBufferList(
        _ samples: UnsafeMutablePointer<Float>, sampleCount: Int, channels: Int
    ) -> AudioBufferList {
        AudioBufferList(
            mNumberBuffers: 1,
            mBuffers: AudioBuffer(
                mNumberChannels: UInt32(channels),
                mDataByteSize: UInt32(sampleCount * MemoryLayout<Float>.size),
                mData: samples
            )
        )
    }

    /// La sonde doit d'abord prouver qu'elle voit une allocation, sans quoi un zéro ne vaudrait
    /// rien.
    @Test("La sonde détecte bien une allocation")
    func probeSeesAllocations() throws {
        // Un objet Objective-C plutôt qu'un `malloc` : en optimisé, le compilateur fait disparaître
        // un couple malloc/free dont il voit les deux bouts, et la sonde paraîtrait aveugle.
        var kept: NSMutableData?
        let observed = AllocationProbe.allocations { kept = NSMutableData(length: 64) }
        let count = try #require(observed)
        #expect(kept != nil)
        #expect(count >= 1)
    }

    /// Mesure un passage du chemin temps réel, une fois celui-ci amorcé.
    ///
    /// L'amorçage hors sonde couvre ce qui n'arrive qu'une fois dans la vie du processus : le
    /// runtime Swift instancie à la première utilisation les métadonnées d'un générique, et ce
    /// coût n'est pas celui d'un passage. Le débordement est inclus, c'est un chemin à part.
    private func allocationsPerRun(
        _ fanout: CaptureFanout, _ pass: () -> Void
    ) throws -> Int {
        var warmUp = 0
        while warmUp < 300 {
            pass()
            warmUp += 1
        }
        // `while` jusque dans la mesure : hors optimisation, `for … in 0..<n` alloue à chaque tour.
        // Cette sonde l'a montré sur sa propre boucle avant de le montrer sur le code mesuré.
        let observed = AllocationProbe.allocations {
            var run = 0
            while run < 1_000 {
                pass()
                run += 1
            }
        }
        return try #require(observed)
    }

    @Test("Écrire vers tous les pipelines n'alloue rien, débordement compris")
    func fanoutWriteDoesNotAllocate() throws {
        let fanout = CaptureFanout(format: stereoFormat(), slotCount: 8, capacityFrames: 48_000)
        for _ in 0..<8 { _ = fanout.acquireSlot() }
        var block = [Float](repeating: 0.5, count: 512)
        let base = try #require(block.withUnsafeMutableBufferPointer { $0.baseAddress })

        let count = try withExtendedLifetime(block) {
            try allocationsPerRun(fanout) { fanout.write(base, frameCount: 256) }
        }
        #expect(count == 0, "\(count) allocations pour 1 000 blocs\n\(AllocationProbe.firstAllocationStack)")
    }

    @Test("Basculer une sortie depuis le callback n'alloue rien")
    func slotActivationDoesNotAllocate() throws {
        let fanout = CaptureFanout(format: stereoFormat(), slotCount: 8, capacityFrames: 48_000)
        var block = [Float](repeating: 0.5, count: 512)
        let base = try #require(block.withUnsafeMutableBufferPointer { $0.baseAddress })
        let slot = try #require(fanout.acquireSlot())
        fanout.write(base, frameCount: 256)

        let observed = withExtendedLifetime(block) {
            AllocationProbe.allocations {
                // Le bloc suivant le retrait prend acte de la sortie, comme il le ferait d'une
                // entrée dans le jeu de sorties actives.
                fanout.releaseSlot(slot)
                fanout.write(base, frameCount: 256)
            }
        }
        #expect(try #require(observed) == 0)
    }

    @Test("Adapter du mono planaire n'alloue rien")
    func adapterDoesNotAllocate() throws {
        let fanout = CaptureFanout(format: stereoFormat(), slotCount: 2, capacityFrames: 48_000)
        _ = fanout.acquireSlot()
        let adapter = try CaptureBlockAdapter(sourceFormat: monoPlanarFormat(), fanout: fanout)
        var block = [Float](repeating: 0.25, count: 256)
        let base = try #require(block.withUnsafeMutableBufferPointer { $0.baseAddress })
        var list = audioBufferList(base, sampleCount: 256, channels: 1)

        let count = try withExtendedLifetime(block) {
            try allocationsPerRun(fanout) { adapter.consume(&list, frameCount: 256) }
        }
        #expect(count == 0, "\(count) allocations pour 1 000 blocs\n\(AllocationProbe.firstAllocationStack)")
    }

    @Test("Le consommateur remis à la source n'alloue rien")
    func consumerDoesNotAllocate() throws {
        let fanout = CaptureFanout(format: stereoFormat(), slotCount: 2, capacityFrames: 48_000)
        _ = fanout.acquireSlot()
        let adapter = try CaptureBlockAdapter(sourceFormat: stereoFormat(), fanout: fanout)
        let consumer = adapter.makeConsumer()
        var block = [Float](repeating: 0.25, count: 512)
        let base = try #require(block.withUnsafeMutableBufferPointer { $0.baseAddress })
        var list = audioBufferList(base, sampleCount: 512, channels: 2)

        let count = try withExtendedLifetime(block) {
            try allocationsPerRun(fanout) { consumer(&list, 256) }
        }
        #expect(count == 0, "\(count) allocations pour 1 000 blocs\n\(AllocationProbe.firstAllocationStack)")
    }
}

// MARK: - Fanout

@Suite("Fanout : pool de tampons")
struct CaptureFanoutTests {
    private func write(_ fanout: CaptureFanout, frames: Int, value: Float = 0.5) {
        let block = [Float](repeating: value, count: frames * Int(fanout.format.channelCount))
        block.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            fanout.write(base, frameCount: frames)
        }
    }

    @Test("Un tampon rejoint la graduation à la trame de son premier bloc")
    func slotJoinsTimelineAtFirstBlock() throws {
        let fanout = CaptureFanout(format: stereoFormat(), slotCount: 2, capacityFrames: 4_096)
        write(fanout, frames: 300)

        let slot = try #require(fanout.acquireSlot())
        let ring = fanout.ring(atSlot: slot)
        // Il n'a rien vu, mais sait déjà où il en est : aucun bloc n'a circulé depuis.
        #expect(ring.availableFrames == 0)
        #expect(ring.totalFramesWritten == 300)

        write(fanout, frames: 100)
        #expect(ring.availableFrames == 100)
        #expect(ring.totalFramesWritten == 400)
        #expect(ring.totalFramesRead == 300)
    }

    @Test("Deux tampons mis en service à des moments différents partagent la graduation")
    func slotsShareTimeline() throws {
        let fanout = CaptureFanout(format: stereoFormat(), slotCount: 2, capacityFrames: 4_096)
        let early = fanout.ring(atSlot: try #require(fanout.acquireSlot()))
        write(fanout, frames: 3_000)
        let late = fanout.ring(atSlot: try #require(fanout.acquireSlot()))
        write(fanout, frames: 1_000)
        #expect(early.totalFramesWritten == late.totalFramesWritten)
    }

    @Test("Un pipeline saturé ne retient pas les autres ni la graduation")
    func saturatedPipelineIsIsolated() throws {
        let fanout = CaptureFanout(format: stereoFormat(), slotCount: 2, capacityFrames: 1_000)
        let stuck = fanout.ring(atSlot: try #require(fanout.acquireSlot()))
        let healthy = fanout.ring(atSlot: try #require(fanout.acquireSlot()))

        var scratch = [Float](repeating: 0, count: 2_000)
        for _ in 0..<10 {
            write(fanout, frames: 500)
            scratch.withUnsafeMutableBufferPointer { buffer in
                guard let base = buffer.baseAddress else { return }
                _ = healthy.read(into: base, frameCount: 1_000)
            }
        }
        #expect(stuck.droppedFrames == 4_000)
        #expect(healthy.droppedFrames == 0)
        #expect(stuck.totalFramesWritten == 5_000)
        #expect(healthy.totalFramesWritten == 5_000)
        #expect(fanout.framesCaptured == 5_000)
    }

    @Test("Un tampon rendu reste indisponible tant que le producteur n'en a pas pris acte")
    func releaseWaitsForProducer() throws {
        let fanout = CaptureFanout(format: stereoFormat(), slotCount: 1, capacityFrames: 1_000)
        let slot = try #require(fanout.acquireSlot())
        write(fanout, frames: 100)
        #expect(fanout.acquireSlot() == nil)

        fanout.releaseSlot(slot)
        // Un bloc peut encore être en cours d'écriture dans ce tampon : le remettre à neuf ici
        // serait une écriture concurrente avec le producteur.
        #expect(fanout.acquireSlot() == nil)

        write(fanout, frames: 100)
        let again = try #require(fanout.acquireSlot())
        let ring = fanout.ring(atSlot: again)
        #expect(ring.availableFrames == 0)
        #expect(ring.droppedFrames == 0)
        #expect(ring.totalFramesWritten == 200)
    }

    @Test("Un tampon jamais activé se rend et se reprend sans attendre")
    func neverActivatedSlotIsReusable() throws {
        let fanout = CaptureFanout(format: stereoFormat(), slotCount: 1, capacityFrames: 1_000)
        let slot = try #require(fanout.acquireSlot())
        fanout.releaseSlot(slot)
        #expect(fanout.acquireSlot() == slot)
    }

    @Test("Le silence se mesure en trames depuis le dernier échantillon non nul")
    func silenceIsTracked() {
        let fanout = CaptureFanout(format: stereoFormat(), slotCount: 1, capacityFrames: 1_000)
        write(fanout, frames: 100, value: 0)
        #expect(fanout.framesSinceLastSignal == 100)
        write(fanout, frames: 50, value: 0.1)
        #expect(fanout.framesSinceLastSignal == 0)
        write(fanout, frames: 30, value: 0)
        #expect(fanout.framesSinceLastSignal == 30)
        #expect(fanout.framesCaptured == 180)
    }

    /// C'est lui qui donne son sens à `swift test --sanitize=thread` : un producteur au rythme du
    /// callback, des consommateurs, et des sorties qui vont et viennent en même temps. Aucune
    /// trame ne doit se perdre ni s'intervertir sur la sortie stable.
    @Test("Ajouts et retraits à chaud pendant que le producteur écrit")
    func hotPlugUnderConcurrency() async throws {
        let fanout = CaptureFanout(format: stereoFormat(), slotCount: 4, capacityFrames: 8_192)
        let steady = fanout.ring(atSlot: try #require(fanout.acquireSlot()))
        let frames = 200_000
        let blockFrames = 64

        let producer = Task.detached(priority: .userInitiated) { () -> Void in
            var next: Float = 1
            var block = [Float](repeating: 0, count: blockFrames * 2)
            var written = 0
            while written < frames {
                // Cadence limitée par le consommateur stable : on ne teste pas le débordement.
                if steady.availableFrames > 4_096 {
                    await Task.yield()
                    continue
                }
                for frame in 0..<blockFrames {
                    block[frame * 2] = next
                    block[frame * 2 + 1] = next
                    next += 1
                }
                block.withUnsafeBufferPointer { buffer in
                    guard let base = buffer.baseAddress else { return }
                    fanout.write(base, frameCount: blockFrames)
                }
                written += blockFrames
            }
        }

        let consumer = Task.detached(priority: .userInitiated) { () -> Bool in
            var expected: Float = 1
            var scratch = [Float](repeating: 0, count: 2_048 * 2)
            var total = 0
            while total < frames {
                let read = scratch.withUnsafeMutableBufferPointer { buffer -> Int in
                    guard let base = buffer.baseAddress else { return 0 }
                    return steady.read(into: base, frameCount: 2_048)
                }
                if read == 0 {
                    await Task.yield()
                    continue
                }
                for frame in 0..<read {
                    guard scratch[frame * 2] == expected, scratch[frame * 2 + 1] == expected else {
                        return false
                    }
                    expected += 1
                }
                total += read
            }
            return true
        }

        // Le contexte de contrôle, seul à toucher au pool : fait entrer et sortir des tampons,
        // avec un consommateur le temps de leur mise en service.
        var acquired = 0
        while fanout.framesCaptured < frames - blockFrames {
            if let slot = fanout.acquireSlot() {
                acquired += 1
                let ring = fanout.ring(atSlot: slot)
                await Task.yield()
                var scratch = [Float](repeating: 0, count: 128)
                scratch.withUnsafeMutableBufferPointer { buffer in
                    guard let base = buffer.baseAddress else { return }
                    _ = ring.read(into: base, frameCount: 64)
                }
                // Le producteur publie sa position après avoir écrit le bloc : elle peut retarder
                // d'un bloc sur le tampon, jamais davantage.
                #expect(ring.totalFramesRead <= fanout.framesCaptured + blockFrames)
                fanout.releaseSlot(slot)
            }
            await Task.yield()
        }

        await producer.value
        #expect(await consumer.value)
        #expect(steady.droppedFrames == 0)
        #expect(acquired > 0)
    }
}

// MARK: - Adaptateur

@Suite("Normalisation des blocs vers le stéréo entrelacé")
struct CaptureBlockAdapterTests {
    private func makeFanout() -> (CaptureFanout, AudioRingBuffer) {
        let fanout = CaptureFanout(format: stereoFormat(), slotCount: 1, capacityFrames: 16_384)
        guard let slot = fanout.acquireSlot() else { fatalError("pool vide") }
        return (fanout, fanout.ring(atSlot: slot))
    }

    private func readAll(_ ring: AudioRingBuffer) -> [Float] {
        var out = [Float](repeating: 0, count: ring.availableFrames * 2)
        let count = ring.availableFrames
        out.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            _ = ring.read(into: base, frameCount: count)
        }
        return out
    }

    private func format(channels: AVAudioChannelCount, interleaved: Bool) throws -> AVAudioFormat {
        // Au-delà de deux canaux, `AVAudioFormat` exige une disposition : c'est ainsi qu'une
        // interface multicanal se présente.
        let tag = kAudioChannelLayoutTag_DiscreteInOrder | channels
        let layout = try #require(AVAudioChannelLayout(layoutTag: tag))
        return AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 48_000, interleaved: interleaved,
            channelLayout: layout
        )
    }

    /// Plusieurs tampons distincts dans la liste : la disposition planaire.
    private func withPlanarList(
        _ channels: [[Float]], _ body: (UnsafePointer<AudioBufferList>) -> Void
    ) {
        let list = AudioBufferList.allocate(maximumBuffers: channels.count)
        defer { free(list.unsafeMutablePointer) }
        var storage = channels
        let frames = channels.first?.count ?? 0
        for index in storage.indices {
            let pointer = storage[index].withUnsafeMutableBufferPointer { $0.baseAddress }
            list[index] = AudioBuffer(
                mNumberChannels: 1,
                mDataByteSize: UInt32(frames * MemoryLayout<Float>.size),
                mData: pointer
            )
        }
        withExtendedLifetime(storage) { body(UnsafePointer(list.unsafePointer)) }
    }

    @Test("Le stéréo entrelacé passe tel quel, sans format de remplacement")
    func stereoInterleavedIsUntouched() throws {
        let source = stereoFormat()
        #expect(try CaptureBlockAdapter.normalizedFormat(for: source) === source)

        let (fanout, ring) = makeFanout()
        let adapter = try CaptureBlockAdapter(sourceFormat: source, fanout: fanout)
        var samples: [Float] = [1, 2, 3, 4]
        samples.withUnsafeMutableBytes { raw in
            var list = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(
                    mNumberChannels: 2, mDataByteSize: UInt32(raw.count), mData: raw.baseAddress
                ))
            adapter.consume(&list, frameCount: 2)
        }
        fanout.write([9, 9], frameCount: 1)
        #expect(readAll(ring) == [1, 2, 3, 4, 9, 9])
    }

    @Test("Le mono planaire est dupliqué, et le tampon de la source n'est pas modifié")
    func monoPlanarIsDuplicated() throws {
        let (fanout, ring) = makeFanout()
        let adapter = try CaptureBlockAdapter(
            sourceFormat: try format(channels: 1, interleaved: false), fanout: fanout
        )
        var samples: [Float] = [0.1, 0.2, 0.3]
        samples.withUnsafeMutableBytes { raw in
            var list = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(
                    mNumberChannels: 1, mDataByteSize: UInt32(raw.count), mData: raw.baseAddress
                ))
            adapter.consume(&list, frameCount: 3)
        }
        #expect(readAll(ring) == [0.1, 0.1, 0.2, 0.2, 0.3, 0.3])
        #expect(samples == [0.1, 0.2, 0.3])
    }

    @Test("Le stéréo planaire est entrelacé")
    func stereoPlanarIsInterleaved() throws {
        let (fanout, ring) = makeFanout()
        let adapter = try CaptureBlockAdapter(
            sourceFormat: try format(channels: 2, interleaved: false), fanout: fanout
        )
        withPlanarList([[1, 2, 3], [10, 20, 30]]) { adapter.consume($0, frameCount: 3) }
        #expect(readAll(ring) == [1, 10, 2, 20, 3, 30])
    }

    @Test("Une interface multicanal planaire donne sa paire 1-2")
    func multichannelPlanarKeepsFirstPair() throws {
        let (fanout, ring) = makeFanout()
        let adapter = try CaptureBlockAdapter(
            sourceFormat: try format(channels: 4, interleaved: false), fanout: fanout
        )
        withPlanarList([[1, 2], [10, 20], [100, 200], [1000, 2000]]) {
            adapter.consume($0, frameCount: 2)
        }
        #expect(readAll(ring) == [1, 10, 2, 20])
    }

    @Test("Une interface multicanal entrelacée donne sa paire 1-2")
    func multichannelInterleavedKeepsFirstPair() throws {
        let (fanout, ring) = makeFanout()
        let adapter = try CaptureBlockAdapter(
            sourceFormat: try format(channels: 3, interleaved: true), fanout: fanout
        )
        var samples: [Float] = [1, 10, 100, 2, 20, 200]
        samples.withUnsafeMutableBytes { raw in
            var list = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(
                    mNumberChannels: 3, mDataByteSize: UInt32(raw.count), mData: raw.baseAddress
                ))
            adapter.consume(&list, frameCount: 2)
        }
        #expect(readAll(ring) == [1, 10, 2, 20])
    }

    @Test("Un bloc plus long que le tampon de travail n'est pas tronqué")
    func longBlockIsNotTruncated() throws {
        let (fanout, ring) = makeFanout()
        let adapter = try CaptureBlockAdapter(
            sourceFormat: try format(channels: 1, interleaved: false), fanout: fanout
        )
        var samples = (0..<10_000).map { Float($0) }
        samples.withUnsafeMutableBytes { raw in
            var list = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(
                    mNumberChannels: 1, mDataByteSize: UInt32(raw.count), mData: raw.baseAddress
                ))
            adapter.consume(&list, frameCount: 10_000)
        }
        let read = readAll(ring)
        #expect(read.count == 20_000)
        #expect(read[19_998] == 9_999)
        #expect(fanout.framesCaptured == 10_000)
    }

    @Test("Le nombre de trames annoncé ne fait pas lire au-delà du tampon")
    func frameCountIsBoundedByBuffer() throws {
        let (fanout, ring) = makeFanout()
        let adapter = try CaptureBlockAdapter(
            sourceFormat: try format(channels: 1, interleaved: false), fanout: fanout
        )
        var samples: [Float] = [1, 2]
        samples.withUnsafeMutableBytes { raw in
            var list = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(
                    mNumberChannels: 1, mDataByteSize: UInt32(raw.count), mData: raw.baseAddress
                ))
            adapter.consume(&list, frameCount: 500)
        }
        #expect(readAll(ring) == [1, 1, 2, 2])
    }

    @Test("Un format non flottant est refusé dès la préparation")
    func nonFloatIsRefused() throws {
        let int16 = try #require(
            AVAudioFormat(
                commonFormat: .pcmFormatInt16, sampleRate: 48_000, channels: 2, interleaved: true
            ))
        #expect(throws: AudioCaptureError.self) {
            _ = try CaptureBlockAdapter.normalizedFormat(for: int16)
        }
    }
}

// MARK: - Sinusoïde

@Suite("Source synthétique")
struct ToneCaptureSourceTests {
    @Test("La phase reste continue d'un bloc à l'autre, au niveau demandé")
    func toneIsContinuousAtRequestedLevel() throws {
        let generator = ToneBlockGenerator(
            frequency: 440, levelDBFS: -20, sampleRate: 48_000, channelCount: 2,
            interleaved: true, blockFrames: 100
        )
        var samples: [Float] = []
        for _ in 0..<20 {
            generator.renderNextBlock()
            generator.withBufferList { list in
                let data = list.pointee.mBuffers.mData?.assumingMemoryBound(to: Float.self)
                samples += UnsafeBufferPointer(start: data, count: 200)
            }
        }
        let peak = samples.map(abs).max() ?? 0
        #expect(abs(peak - 0.1) < 0.001)

        // Le pas maximal d'une sinusoïde est 2π·f/fs × crête. Un saut de phase entre deux blocs
        // le dépasserait franchement.
        let maximalStep = Float(2 * Double.pi * 440 / 48_000) * 0.1 * 1.01
        for frame in 1..<(samples.count / 2) {
            #expect(abs(samples[frame * 2] - samples[(frame - 1) * 2]) <= maximalStep)
            #expect(samples[frame * 2] == samples[frame * 2 + 1])
        }
    }

    @Test("Le générateur planaire remplit bien chaque canal")
    func planarGeneratorFillsEachChannel() {
        let generator = ToneBlockGenerator(
            frequency: 440, levelDBFS: -6, sampleRate: 48_000, channelCount: 2,
            interleaved: false, blockFrames: 64
        )
        generator.renderNextBlock()
        generator.withBufferList { list in
            let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
            #expect(buffers.count == 2)
            let left = buffers[0].mData?.assumingMemoryBound(to: Float.self)
            let right = buffers[1].mData?.assumingMemoryBound(to: Float.self)
            #expect(left?[10] == right?[10])
            #expect(left?[10] != 0)
        }
    }

    /// `stop` doit garantir qu'aucun bloc ne suit son retour : c'est ce qui autorise à relancer
    /// une capture sans jamais avoir deux producteurs sur un même tampon.
    @Test("Plus aucun bloc après le retour de `stop`, et la source repart")
    func stopIsSynchronousAndRestartable() async throws {
        let counter = BlockCounter()
        let source = ToneCaptureSource(blockFrames: 64)
        let format = try source.prepare()
        #expect(format.channelCount == 2)
        #expect(source.requiredPermission == nil)

        try source.start(deliveringTo: counter.makeConsumer())
        #expect(await eventually { counter.blocks > 2 })
        source.stop()
        let frozen = counter.blocks
        try await Task.sleep(for: .milliseconds(30))
        #expect(counter.blocks == frozen)

        try source.start(deliveringTo: counter.makeConsumer())
        #expect(await eventually { counter.blocks > frozen })
        source.stop()
    }

    @Test("Le rythme est celui du temps réel, pas celui du processeur")
    func toneRunsInRealTime() async throws {
        let counter = BlockCounter()
        let source = ToneCaptureSource(sampleRate: 48_000, blockFrames: 480)
        _ = try source.prepare()
        try source.start(deliveringTo: counter.makeConsumer())
        try await Task.sleep(for: .milliseconds(500))
        source.stop()
        // 480 trames = 10 ms : ~50 blocs en 500 ms. Large marge, la machine de test est occupée.
        #expect(counter.blocks >= 25)
        #expect(counter.blocks <= 80)
    }
}

/// Compte les blocs reçus depuis le fil de génération.
private final class BlockCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var blocks: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func makeConsumer() -> CaptureBlockConsumer {
        { [self] _, _ in
            lock.lock()
            count += 1
            lock.unlock()
        }
    }
}

// MARK: - Mesure de niveau

@Suite("Mesure de niveau")
struct LevelMeterTests {
    /// Sans le `stride`, seule la première moitié de chaque bloc entrelacé était lue : un signal
    /// présent uniquement à la fin du bloc passait pour un silence strict.
    @Test("En entrelacé, tout le bloc est mesuré")
    func interleavedBlockIsFullyMeasured() throws {
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: stereoFormat(), frameCapacity: 100))
        buffer.frameLength = 100
        let samples = try #require(buffer.floatChannelData)[0]
        for index in 0..<200 { samples[index] = 0 }
        samples[198] = 0.5  // Dernière trame, canal gauche.

        var meter = LevelMeter()
        meter.consume(buffer)
        #expect(!meter.isDigitalSilence)
        #expect(meter.peak == 0.5)
        #expect(meter.sampleCount == 200)
    }

    @Test("En planaire, chaque canal est mesuré")
    func planarBlockIsMeasured() throws {
        let format = try #require(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false
            ))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 10))
        buffer.frameLength = 10
        let channels = try #require(buffer.floatChannelData)
        for frame in 0..<10 {
            channels[0][frame] = 0
            channels[1][frame] = 0
        }
        channels[1][9] = 0.25
        var meter = LevelMeter()
        meter.consume(buffer)
        #expect(meter.peak == 0.25)
    }
}
