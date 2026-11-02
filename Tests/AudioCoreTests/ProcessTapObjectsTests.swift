import CoreAudio
import Testing

@testable import AudioCore

@Suite("Process Tap : les process visés")
struct ProcessTapObjectsTests {
    /// Une reconstruction retraduit tous les PID de la capture, y compris ceux morts depuis.
    @Test("Un processus mort ne figure pas dans la description du tap")
    func deadProcessIsDropped() {
        let unknown = AudioObjectID(kAudioObjectUnknown)
        let objects = ProcessTapCapture.audioObjects(forPIDs: [10, 20, 30]) { pid in
            pid == 20 ? unknown : AudioObjectID(pid) + 100
        }
        #expect(objects == [110, 130])
    }
}
