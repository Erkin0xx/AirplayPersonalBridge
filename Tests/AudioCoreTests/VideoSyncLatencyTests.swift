import CoreAudio
import Foundation
import Testing

@testable import AudioCore

/// La latence que la sortie virtuelle annonce aux lecteurs vidéo (phase 1 du prompt vidéo).
///
/// Rien de ceci ne touche au fil : la latence n'est lue que par les applications du Mac, jamais
/// par les senders. D'où un test qui vérifie que le délai de restitution reste celui qui a été
/// écouté sur les enceintes.
struct VideoSyncLatencyTests {
    @Test("2,045 s par défaut : 2 s de restitution plus le résidu mesuré au micro")
    func defaultLatency() {
        #expect(SharedPlaybackClock.defaultPlayoutDelaySeconds == 2.0)
        #expect(abs(VideoSyncLatency.seconds() - 2.045) < 1e-9)
        #expect(VideoSyncLatency.frames() == 98_160)
    }

    @Test("La latence suit le délai de restitution : un seul endroit à changer")
    func followsPlayoutDelay() {
        #expect(VideoSyncLatency.frames(playoutDelaySeconds: 1.5) == 74_160)
        #expect(VideoSyncLatency.frames(playoutDelaySeconds: 1.5, sampleRate: 44_100) == 68_135)
    }

    @Test("Bornée à ce que le pilote et Chromium acceptent")
    func clamped() {
        #expect(VideoSyncLatency.frames(playoutDelaySeconds: 60) == VirtualOutputDevice.maximumLatencyFrames)
        #expect(VideoSyncLatency.frames(playoutDelaySeconds: -5) == 0)
    }

    @Test("Le fil ne bouge pas : l'horloge commune garde 2 s par défaut")
    func wireUnchanged() {
        let clock = SharedPlaybackClock(captureSampleRate: 48_000)
        #expect(clock.playoutDelaySeconds == 2.0)
    }

    @Test("Chromium lit périphérique + flux, jamais le safety offset")
    func chromiumSum() {
        let report = VirtualOutputDevice.LatencyReport(
            deviceFrames: 110_400, streamFrames: 0, safetyOffsetFrames: 4_800, sampleRate: 48_000
        )
        #expect(abs(report.chromiumSeconds - 2.30) < 1e-9)
        let speakers = VirtualOutputDevice.LatencyReport(
            deviceFrames: 60, streamFrames: 690, safetyOffsetFrames: 48, sampleRate: 48_000
        )
        #expect(abs(speakers.chromiumSeconds - 0.015_625) < 1e-9)
    }
}

/// Le vrai pilote, par Core Audio. **Jamais lancé par défaut** : il écrit la latence du pilote
/// installé, puis rend la valeur d'origine. Sans pilote installé, il ne fait rien.
///
/// ```
/// VIRTUAL_OUTPUT_TESTS=1 swift test --filter VirtualOutputIntegration
/// ```
@Suite(
    "Sortie virtuelle — pilote réel", .serialized,
    .enabled(if: ProcessInfo.processInfo.environment["VIRTUAL_OUTPUT_TESTS"] != nil)
)
struct VirtualOutputIntegrationTests {
    @Test("La latence écrite est celle que lisent les applications")
    func latencyRoundTrip() throws {
        guard let device = VirtualOutputDevice.deviceID(),
            let original = VirtualOutputDevice.announcedLatencyFrames()
        else { return }
        defer { VirtualOutputDevice.setAnnouncedLatency(frames: original) }

        #expect(VirtualOutputDevice.setAnnouncedLatency(frames: 12_345))
        #expect(VirtualOutputDevice.announcedLatencyFrames() == 12_345)
        let report = try #require(VirtualOutputDevice.latencyReport(of: device))
        #expect(report.deviceFrames == 12_345)
        #expect(report.safetyOffsetFrames == 0)
        #expect(report.streamFrames == 0)
        #expect(report.sampleRate == 48_000)

        #expect(!VirtualOutputDevice.setAnnouncedLatency(frames: VirtualOutputDevice.maximumLatencyFrames + 1))
        #expect(VirtualOutputDevice.announcedLatencyFrames() == 12_345)
    }
}
