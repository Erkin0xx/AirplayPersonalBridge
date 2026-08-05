import Testing
@testable import AudioCore

/// Tests du ring buffer lock-free (invariant section 12).
///
/// L'enjeu n'est pas la couverture de lignes mais la correction de la synchronisation :
/// un ring buffer faux ne se manifeste pas par un crash mais par de l'audio corrompu,
/// intermittent et pénible à diagnostiquer une fois les senders branchés dessus.
struct RingBufferTests {
    private let channels = 2

    @Test func writeThenReadRoundTripsSamples() {
        let ring = AudioRingBuffer(capacityFrames: 16, channelCount: channels)
        var input: [Float] = (0..<8).flatMap { [Float($0), Float($0) + 0.5] }

        let written = input.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return 0 }
            return ring.write(from: base, frameCount: 4)
        }
        #expect(written == 4)
        #expect(ring.availableFrames == 4)

        var output = [Float](repeating: -1, count: 8)
        let read = output.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return 0 }
            return ring.read(into: base, frameCount: 4)
        }
        #expect(read == 4)
        #expect(Array(output.prefix(8)) == Array(input.prefix(8)))
        #expect(ring.availableFrames == 0)
    }

    @Test func readOnEmptyBufferReturnsZero() {
        let ring = AudioRingBuffer(capacityFrames: 8, channelCount: channels)
        var output = [Float](repeating: 0, count: 4)
        let read = output.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return 0 }
            return ring.read(into: base, frameCount: 2)
        }
        #expect(read == 0)
    }

    /// Le cas qui casse les implémentations naïves : un bloc à cheval sur la fin du tampon.
    @Test func writeWrapsAroundEndOfBuffer() {
        let capacity = 8
        let ring = AudioRingBuffer(capacityFrames: capacity, channelCount: channels)

        // Remplit puis vide 6 trames pour décaler les index près de la fin du tampon.
        var filler = [Float](repeating: 1, count: 6 * channels)
        _ = filler.withUnsafeBufferPointer { ring.write(from: $0.baseAddress!, frameCount: 6) }
        var drain = [Float](repeating: 0, count: 6 * channels)
        _ = drain.withUnsafeMutableBufferPointer { ring.read(into: $0.baseAddress!, frameCount: 6) }

        // Écrit 5 trames : 2 avant la fin du tampon, 3 après le repli.
        var input: [Float] = (0..<5).flatMap { [Float($0) * 10, Float($0) * 10 + 1] }
        let written = input.withUnsafeBufferPointer {
            ring.write(from: $0.baseAddress!, frameCount: 5)
        }
        #expect(written == 5)

        var output = [Float](repeating: -1, count: 5 * channels)
        let read = output.withUnsafeMutableBufferPointer {
            ring.read(into: $0.baseAddress!, frameCount: 5)
        }
        #expect(read == 5)
        #expect(output == input)
    }

    /// Saturation : le producteur temps réel ne doit jamais bloquer, il abandonne.
    @Test func writeDropsFramesWhenFullRatherThanBlocking() {
        let ring = AudioRingBuffer(capacityFrames: 4, channelCount: channels)
        var input = [Float](repeating: 2, count: 10 * channels)

        let written = input.withUnsafeBufferPointer {
            ring.write(from: $0.baseAddress!, frameCount: 10)
        }
        #expect(written == 4, "n'écrit que ce qui tient")
        #expect(ring.droppedFrames == 6, "comptabilise les trames perdues")

        // Une écriture supplémentaire sur un tampon plein n'écrit rien et ne bloque pas.
        let again = input.withUnsafeBufferPointer {
            ring.write(from: $0.baseAddress!, frameCount: 2)
        }
        #expect(again == 0)
        #expect(ring.droppedFrames == 8)
    }

    @Test func partialReadLeavesRemainderAvailable() {
        let ring = AudioRingBuffer(capacityFrames: 16, channelCount: channels)
        var input = [Float](repeating: 3, count: 10 * channels)
        _ = input.withUnsafeBufferPointer { ring.write(from: $0.baseAddress!, frameCount: 10) }

        var output = [Float](repeating: 0, count: 4 * channels)
        let read = output.withUnsafeMutableBufferPointer {
            ring.read(into: $0.baseAddress!, frameCount: 4)
        }
        #expect(read == 4)
        #expect(ring.availableFrames == 6)
    }

    /// Producteur et consommateur concurrents : vérifie qu'aucun échantillon n'est corrompu
    /// ni réordonné. C'est le test qui justifie l'ordonnancement acquire/release.
    @Test func concurrentProducerConsumerPreservesSequence() async {
        let frames = 20_000
        let ring = AudioRingBuffer(capacityFrames: 512, channelCount: 1)

        let producer = Task.detached(priority: .userInitiated) {
            var next: Float = 0
            var pending: Float?
            while next < Float(frames) {
                var value = pending ?? next
                let ok = withUnsafePointer(to: &value) { ring.write(from: $0, frameCount: 1) }
                if ok == 1 {
                    pending = nil
                    next += 1
                } else {
                    pending = value       // tampon plein : on réessaie la même valeur
                    await Task.yield()
                }
            }
        }

        let consumer = Task.detached(priority: .userInitiated) { () -> Bool in
            var expected: Float = 0
            var sample: Float = 0
            while expected < Float(frames) {
                let got = withUnsafeMutablePointer(to: &sample) {
                    ring.read(into: $0, frameCount: 1)
                }
                if got == 1 {
                    guard sample == expected else { return false }
                    expected += 1
                } else {
                    await Task.yield()
                }
            }
            return true
        }

        await producer.value
        let ordered = await consumer.value
        // Le seul invariant qui compte ici : aucune corruption ni réordonnancement. Le
        // consommateur a bien relu les 20 000 valeurs dans l'ordre exact d'écriture.
        // `droppedFrames` est non nul et c'est normal : il compte chaque refus sur tampon
        // plein, y compris ceux que le producteur réessaie ensuite avec succès. Ce
        // compteur mesure la pression sur le tampon, pas une perte de données définitive.
        #expect(ordered, "la séquence lue doit être strictement identique à la séquence écrite")
    }
}
