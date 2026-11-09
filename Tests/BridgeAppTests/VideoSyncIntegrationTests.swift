import AudioCore
import Foundation
import Testing

@testable import BridgeApp

/// La vraie bascule, par Core Audio. **Jamais lancé par défaut** : il fait du pilote la sortie par
/// défaut du Mac, le temps de quelques lectures, puis rend la sortie d'origine et la latence d'origine.
///
/// ```
/// VIRTUAL_OUTPUT_TESTS=1 swift test --filter VideoSyncIntegration
/// ```
///
/// Il ne fait rien sans pilote installé, sur un Mac déjà sur le pilote, ni si un processus a un flux de
/// sortie ouvert : celui-ci entendrait la bascule (le pilote jette le son, et l'agrégat d'une capture
/// en cours se reconstruirait).
@Suite(
    "Calage vidéo — Core Audio réel", .serialized,
    .enabled(if: ProcessInfo.processInfo.environment["VIRTUAL_OUTPUT_TESTS"] != nil)
)
struct VideoSyncIntegrationTests {
    @Test("Le pilote devient la sortie par défaut et annonce la latence, puis la sortie d'origine revient")
    func realSwitch() throws {
        let control = LiveDefaultOutputSwitch()
        guard control.isVirtualOutputInstalled() else { return }
        let playing = try AudioProcessList.playing().filter { $0.pid != getpid() }
        guard playing.isEmpty else { return }
        let original = try #require(control.currentOutput(), "aucune sortie par défaut")
        guard original.deviceUID != VirtualOutputDevice.deviceUID else { return }
        let originalLatency = VirtualOutputDevice.announcedLatencyFrames()
        // Quoi qu'il arrive au test, le Mac retrouve sa sortie et le pilote sa latence.
        defer {
            if control.currentOutput()?.deviceUID != original.deviceUID {
                control.makeDefault(uid: original.deviceUID)
            }
            if let originalLatency { control.setVirtualOutputLatency(frames: originalLatency) }
        }

        let videoSync = VideoSyncSwitch(control: control)
        #expect(videoSync.beginSession())
        #expect(videoSync.memory?.deviceUID == original.deviceUID)
        let current = try #require(control.currentOutput())
        #expect(current.deviceUID == VirtualOutputDevice.deviceUID)
        // Les touches du Mac y ont prise : le lien du volume pourra le relier au master.
        #expect(current.volume != nil)
        #expect(VirtualOutputDevice.announcedLatencyFrames() == VideoSyncLatency.frames())
        let report = try #require(VirtualOutputDevice.latencyReport(of: current.deviceID))
        #expect(abs(report.chromiumSeconds - VideoSyncLatency.seconds()) < 0.001)

        videoSync.endSession()
        let restored = try #require(control.currentOutput())
        #expect(restored.deviceUID == original.deviceUID)
        #expect(restored.isMuted == original.isMuted)
        if let volume = original.volume, let now = restored.volume { #expect(abs(volume - now) < 0.01) }
        #expect(videoSync.memory == nil)
    }
}
