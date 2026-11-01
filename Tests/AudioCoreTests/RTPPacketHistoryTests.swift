import Foundation
import Testing

@testable import AudioCore

@Suite("Historique des paquets et demandes de retransmission")
struct RTPPacketHistoryTests {
    @Test("Un paquet écrasé par son successeur n'est jamais rendu à sa place")
    func overwrittenPacketIsNotReturned() {
        var history = RTPPacketHistory(capacity: 4)
        history.record(sequence: 1, packet: Data([1]))
        history.record(sequence: 5, packet: Data([5]))
        #expect(history.packet(sequence: 1) == nil)
        #expect(history.packet(sequence: 5) == Data([5]))
    }

    @Test("La demande se lit en big-endian, marqueur compris, et passe le bouclage du compteur")
    func requestParsing() throws {
        let request = try #require(
            RTPRetransmitRequest(datagram: Data([0x80, 0xD5, 0, 1, 0xFF, 0xFF, 0, 3]))
        )
        #expect(request.firstSequence == 0xFFFF)
        #expect(request.sequences == [0xFFFF, 0, 1])
    }

    @Test("Un autre type de paquet de contrôle n'est pas pris pour une demande")
    func otherControlPacketIsRejected() {
        #expect(RTPRetransmitRequest(datagram: Data([0x80, 0xD4, 0, 1, 0, 2, 0, 3])) == nil)
        #expect(RTPRetransmitRequest(datagram: Data([0x80, 0xD5, 0, 1])) == nil)
    }
}
