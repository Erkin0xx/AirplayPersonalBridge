import Foundation
import Testing

@testable import AudioCore

/// Le gain et le silence d'une sortie AirPlay 2, mesurés sur ce que le récepteur simulé déchiffre :
/// c'est ce qui donne à chaque HomePod d'une paire son propre niveau, et ce qui en coupe un sans
/// toucher à la session ni au volume, commun à la paire.
@Suite("Sender AirPlay 2 — gain et silence de la sortie", .serialized)
struct AirPlay2SenderOutputLevelTests {
    /// Crête du canal gauche des derniers paquets reçus, en pleine échelle 16 bits.
    private func peak(
        of receiver: FakeAirPlay2Receiver, lastPackets count: Int
    ) throws -> Int32 {
        let key = receiver.streamKey(inSession: 0)
        var peak: Int32 = 0
        for packet in receiver.audioPackets(inSession: 0).suffix(count) {
            let pcm = try FakeAirPlay2Receiver.decryptAudio(packet, key: key)
            let bytes = [UInt8](pcm)
            var index = 0
            while index + 1 < bytes.count {
                let sample = Int32(Int16(bitPattern: UInt16(bytes[index]) << 8 | UInt16(bytes[index + 1])))
                peak = max(peak, abs(sample))
                index += 4
            }
        }
        return peak
    }

    /// Attend `count` paquets de plus que maintenant : de quoi vider ce qui était déjà converti.
    private func waitForPackets(_ count: Int, from receiver: FakeAirPlay2Receiver) async -> Bool {
        let before = receiver.audioPackets(inSession: 0).count
        return await waitUntil { receiver.audioPackets(inSession: 0).count >= before + count }
    }

    @Test("Le gain s'entend dans le flux, et le silence part en zéros sans toucher à la session")
    func levelReachesTheWire() async throws {
        let receiver = FakeAirPlay2Receiver()
        try await receiver.start()
        defer { receiver.stop() }
        let harness = try SenderHarness(receiver: receiver)
        defer { harness.feeder.stop() }

        // Sinusoïde à −6 dBFS (0,5), atténuée de 6 dB : un quart de la pleine échelle.
        await harness.sender.setOutputLevel(OutputLevel(gainDB: -6))
        try await harness.sender.start(volume: -20)
        #expect(await waitUntil { receiver.audioPackets(inSession: 0).count >= 150 })
        let attenuated = try peak(of: receiver, lastPackets: 30)
        let expected = 0.5 * pow(10, -6.0 / 20) * 32_767
        #expect(abs(Double(attenuated) - expected) < expected * 0.05, "crête : \(attenuated)")

        await harness.sender.setOutputLevel(OutputLevel(gainDB: -6, isMuted: true))
        #expect(await waitForPackets(80, from: receiver))
        #expect(try peak(of: receiver, lastPackets: 30) == 0)
        // La session vit : le flux continue, sans nouvelle négociation, sans volume ni TEARDOWN.
        #expect(await harness.sender.state == .streaming)
        #expect(receiver.volumes(inSession: 0).count == 1)
        #expect(receiver.count(method: "TEARDOWN") == 0)
        #expect(receiver.count(method: "RECORD") == 1)

        await harness.sender.setOutputLevel(.unity)
        #expect(await waitForPackets(80, from: receiver))
        let restored = try peak(of: receiver, lastPackets: 30)
        let unity = 0.5 * 32_767
        #expect(abs(Double(restored) - unity) < unity * 0.05, "crête : \(restored)")
        await harness.sender.stop()
    }
}
