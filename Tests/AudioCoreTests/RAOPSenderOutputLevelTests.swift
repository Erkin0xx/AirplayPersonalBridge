import AVFoundation
import Foundation
import Testing

@testable import AudioCore

/// Le gain et le silence de la sortie RAOP, mesurés sur le flux L16 que reçoit le faux récepteur.
///
/// L'étage est en bout de chaîne DSP : le silence coupe aussi le renfort de basses, et il survit à
/// une reconnexion comme lui.
@Suite("Sender RAOP — gain et silence de la sortie", .serialized)
struct RAOPSenderOutputLevelTests {
    private struct Rig {
        let server: FakeRAOPReceiver
        let sender: RAOPSender
        let feeder: ToneFeeder

        func close() async {
            await sender.stop()
            feeder.stop()
            server.shutdown()
        }
    }

    private func makeRig() async throws -> Rig {
        let format = try #require(captureFormat())
        let server = try await FakeRAOPReceiver()
        let ring = AudioRingBuffer(capacityFrames: 48_000, channelCount: 2)
        let feeder = ToneFeeder(ring: ring, format: format, hz: 440, amplitude: 0.25)
        let sender = RAOPSender(device: server.device(), ring: ring, captureFormat: format)
        return Rig(server: server, sender: sender, feeder: feeder)
    }

    /// Niveau efficace des derniers paquets, en pleine échelle 16 bits.
    private func rms(_ server: FakeRAOPReceiver, lastPackets count: Int) -> Double {
        var energy = 0.0
        var samples = 0
        for packet in server.audioPackets.suffix(count) {
            let bytes = [UInt8](packet.payload)
            var index = 0
            while index + 1 < bytes.count {
                let value = Double(Int16(bitPattern: UInt16(bytes[index]) << 8 | UInt16(bytes[index + 1])))
                energy += value * value
                samples += 1
                index += 2
            }
        }
        return samples > 0 ? (energy / Double(samples)).squareRoot() : 0
    }

    private func waitForPackets(_ count: Int, from server: FakeRAOPReceiver) async -> Bool {
        let before = server.audioPackets.count
        return await raopEventually { server.audioPackets.count >= before + count }
    }

    @Test("Le gain s'entend dans le flux, le silence coupe aussi les basses, et rien ne se renégocie")
    func levelReachesTheWire() async throws {
        let rig = try await makeRig()
        await rig.sender.setOutputLevel(OutputLevel(gainDB: -6))
        try await rig.sender.start(volume: -20)
        #expect(await raopEventually { rig.server.audioPackets.count > 110 })
        let unity = 0.25 / 2.0.squareRoot() * 32_768
        let attenuated = rms(rig.server, lastPackets: 40)
        let gain = 20 * log10(attenuated / unity)
        #expect(abs(gain + 6) < 0.5, "gain mesuré sur le flux : \(gain) dB")

        // Le renfort reste réglé pendant le silence : celui-ci est en bout de chaîne.
        await rig.sender.setBassBoost(decibels: 12)
        await rig.sender.setOutputLevel(OutputLevel(gainDB: -6, isMuted: true))
        #expect(await waitForPackets(80, from: rig.server))
        let tail = rig.server.audioPackets.suffix(30)
        #expect(tail.allSatisfy { $0.payload.allSatisfy { $0 == 0 } })
        #expect(await rig.sender.state == .streaming)

        // Une reconnexion garde la consigne : toujours le silence.
        rig.server.closeConnections()
        #expect(await raopEventually(within: .seconds(5)) {
            rig.server.requests.filter { $0.method == "RECORD" }.count == 2
        })
        #expect(await waitForPackets(60, from: rig.server))
        #expect(rig.server.audioPackets.suffix(30).allSatisfy { $0.payload.allSatisfy { $0 == 0 } })

        await rig.sender.setBassBoost(decibels: 0)
        await rig.sender.setOutputLevel(.unity)
        #expect(await waitForPackets(80, from: rig.server))
        let restored = 20 * log10(rms(rig.server, lastPackets: 40) / unity)
        #expect(abs(restored) < 0.5, "niveau rétabli : \(restored) dB")

        let volumes = rig.server.requests.filter {
            $0.method == "SET_PARAMETER" && $0.bodyText.contains("volume")
        }
        #expect(volumes.count == 2, "un volume par session, aucun pour le silence")
        await rig.close()
    }
}
