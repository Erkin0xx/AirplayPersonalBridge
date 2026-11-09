import AVFoundation
import Darwin
import Foundation
import Synchronization
import Testing

@testable import AudioCore

/// Horloges d'essai : l'horloge hôte avance d'un pas fixe à chaque lecture, l'horloge murale en
/// est une fonction connue, et certaines lectures sont « préemptées » (l'horloge hôte saute).
private final class ScriptedClock: HostClockReading, @unchecked Sendable {
    private let lock = NSLock()
    private var ticks: UInt64
    private var reads = 0
    let timebase: HostTimebase
    /// Instant Unix correspondant à 0 ns d'horloge hôte.
    let unixAtZero: TimeInterval
    /// Lectures d'horloge hôte après lesquelles un saut est simulé.
    let preemptedReads: Set<Int>

    init(
        startTicks: UInt64, timebase: HostTimebase, unixAtZero: TimeInterval,
        preemptedReads: Set<Int> = []
    ) {
        self.ticks = startTicks
        self.timebase = timebase
        self.unixAtZero = unixAtZero
        self.preemptedReads = preemptedReads
    }

    func hostTicks() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        reads += 1
        ticks += preemptedReads.contains(reads) ? 2_400_000 : 24
        return ticks
    }

    /// L'heure exacte de l'instant présent de l'horloge hôte, un pas après la dernière lecture.
    func unixTime() -> TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        ticks += 24
        return unixAtZero + Double(timebase.nanoseconds(fromTicks: ticks)) / 1e9
    }
}

@Suite("Horloge hôte et horloge commune")
struct HostClockTests {
    private let appleSilicon = HostTimebase(numer: 125, denom: 3)

    @Test("Ticks et nanosecondes se convertissent exactement, sans débordement")
    func timebaseIsExact() {
        #expect(appleSilicon.nanoseconds(fromTicks: 3) == 125)
        #expect(appleSilicon.nanoseconds(fromTicks: 24_000_000) == 1_000_000_000)
        #expect(appleSilicon.nanoseconds(fromTicks: 1) == 41)
        // 2⁵⁸ ticks (plus de 380 ans) : `ticks × 125` déborderait 64 bits, pas le résultat.
        let large: UInt64 = 1 << 58
        let (high, low) = large.multipliedFullWidth(by: 125)
        let exact = UInt64(3).dividingFullWidth((high, low)).quotient
        #expect(appleSilicon.nanoseconds(fromTicks: large) == exact)
        #expect(appleSilicon.ticks(fromNanoseconds: 1_000_000_000) == 24_000_000)
        let ticks: UInt64 = 123_456_789_012
        let back = appleSilicon.ticks(fromNanoseconds: appleSilicon.nanoseconds(fromTicks: ticks))
        #expect(ticks - back <= 1)
        #expect(HostTimebase(numer: 1, denom: 1).nanoseconds(fromTicks: 77) == 77)
    }

    @Test("La base de la machine est celle d'AVAudioTime")
    func machineTimebaseMatchesAVAudioTime() {
        let timebase = HostTimebase.current()
        let ticks = mach_absolute_time()
        let ours = Double(timebase.nanoseconds(fromTicks: ticks))
        let theirs = AVAudioTime.seconds(forHostTime: ticks) * 1e9
        #expect(abs(ours - theirs) < 1_000)
        #expect(AVAudioTime.hostTime(forSeconds: ours / 1e9).distance(to: ticks).magnitude <= 2)
    }

    @Test("Le relevé garde la lecture la plus serrée, et la date au milieu de son encadrement")
    func measureKeepsTightestBracket() {
        let clock = ScriptedClock(
            startTicks: 1_000_000, timebase: appleSilicon, unixAtZero: 1_700_000_000,
            // Les deux premiers encadrements sont élargis par une « préemption ».
            preemptedReads: [2, 4]
        )
        let pair = HostClockMapping.measure(clock: clock, timebase: appleSilicon, attempts: 5)
        // Encadrement normal : lecture hôte, +24 (heure lue), +24 (lecture hôte) = 48 ticks.
        #expect(pair.uncertaintyNanoseconds == appleSilicon.nanoseconds(fromTicks: 48))
        // Heure lue exactement au milieu : la correspondance est exacte à la nanoseconde près.
        let error = Double(pair.hostNanoseconds) / 1e9 + clock.unixAtZero - pair.unixTime
        #expect(abs(error) < 2e-6)
    }

    @Test("Deux relevés : la pente de l'horloge murale est suivie, et l'aller-retour est exact")
    func mappingFollowsWallClockSlope() {
        // L'horloge murale avance de 50 ppm plus vite que l'horloge hôte entre les deux relevés.
        let start = WallHostPair(
            unixTime: 1_762_000_000, hostNanoseconds: 5_000_000_000_000, uncertaintyNanoseconds: 100
        )
        let end = WallHostPair(
            unixTime: 1_762_000_000 + 60 * (1 + 50e-6),
            hostNanoseconds: 5_000_000_000_000 + 60_000_000_000, uncertaintyNanoseconds: 100
        )
        let mapping = HostClockMapping(timebase: appleSilicon, pairs: [start, end])
        #expect(abs(mapping.rateDeviationPPM + 50) < 0.01)
        // Au milieu : 30 s d'horloge hôte, soit 30 s × (1 + 50 ppm) d'horloge murale.
        let middle = mapping.hostNanoseconds(forUnixTime: 1_762_000_000 + 30 * (1 + 50e-6))
        #expect(abs(middle - 5_030_000_000_000) < 1_000)
        let unix = mapping.unixTime(forHostNanoseconds: 5_045_000_000_000)
        #expect(abs(mapping.hostNanoseconds(forUnixTime: unix) - 5_045_000_000_000) < 1_000)

        // Un seul relevé : pente nulle.
        let single = HostClockMapping(timebase: appleSilicon, pairs: [start])
        #expect(single.rateDeviationPPM == 0)
        #expect(single.hostNanoseconds(forUnixTime: 1_762_000_002.5) == 5_002_500_000_000)
    }

    @Test("Sur cette machine, deux relevés successifs concordent à la milliseconde")
    func liveMeasurementIsConsistent() async throws {
        let first = HostClockMapping.measure()
        try await Task.sleep(for: .milliseconds(50))
        let second = HostClockMapping.measure()
        #expect(first.uncertaintyNanoseconds < 1_000_000)
        #expect(second.uncertaintyNanoseconds < 1_000_000)
        let hostSeconds = (Double(second.hostNanoseconds) - Double(first.hostNanoseconds)) / 1e9
        let wallSeconds = second.unixTime - first.unixTime
        #expect(hostSeconds > 0.04)
        #expect(abs(hostSeconds - wallSeconds) < 0.001)
    }

    /// La conversion que le JSON de `--record-input` publie : l'instant de restitution de la trame 0
    /// en temps Unix, vu sur l'horloge hôte, puis celui de la salve k.
    @Test("L'instant de restitution d'une salve se lit sur l'horloge hôte")
    func burstPresentationOnHostClock() throws {
        let timeline = BridgeEngine.PlaybackTimeline(
            captureSampleRate: 48_000, playoutDelaySeconds: 2,
            frameZeroPresentationUnixTime: 1_762_000_010.25, interruptedSeconds: 0
        )
        let pair = WallHostPair(
            unixTime: 1_762_000_000, hostNanoseconds: 900_000_000_000, uncertaintyNanoseconds: 0
        )
        let mapping = HostClockMapping(timebase: appleSilicon, pairs: [pair])
        let frameZero = mapping.hostNanoseconds(forUnixTime: timeline.frameZeroPresentationUnixTime)
        #expect(abs(frameZero - 910_250_000_000) < 1_000)
        let burst = mapping.hostNanoseconds(
            forUnixTime: timeline.presentationUnixTime(
                forCaptureFrame: Double(7 * ClickPattern.periodFrames))
        )
        #expect(abs(burst - frameZero - 14_000_000_000) < 1_000)
    }
}

@Suite("Moteur : horloge commune publiée")
struct BridgeEngineTimelineTests {
    @Test("L'horloge publiée est celle de la diffusion : trame 0 restituée 2 s après la capture")
    func timelineIsPublishedWhileRunning() async throws {
        let source = ManualCaptureSource(format: stereoFormat())
        let engine = makeEngine(source: source, factory: FakeSenderFactory())
        #expect(await engine.playbackTimeline == nil)

        let before = Date().timeIntervalSince1970
        try await engine.start(source: .clicks(levelDBFS: -20), outputs: [request("a")])
        let after = Date().timeIntervalSince1970
        let timeline = try #require(await engine.playbackTimeline)
        #expect(timeline.captureSampleRate == 48_000)
        let delay = SharedPlaybackClock.defaultPlayoutDelaySeconds
        #expect(timeline.playoutDelaySeconds == delay)
        #expect(timeline.frameZeroPresentationUnixTime >= before + delay)
        #expect(timeline.frameZeroPresentationUnixTime <= after + delay)
        #expect(timeline.presentationUnixTime(forCaptureFrame: 96_000)
            - timeline.frameZeroPresentationUnixTime == 2)

        await engine.stop()
        #expect(await engine.playbackTimeline == nil)
    }

    @Test("Les clics et le test de canaux sont des sources sans autorisation")
    func liveFactoryBuildsPatternSources() throws {
        let make = BridgeEngine.Dependencies.live.makeSource
        let clicks = make(.clicks(levelDBFS: -20), BridgeEngine.StartOptions())
        let channels = make(.channelTest(levelDBFS: -20), BridgeEngine.StartOptions())
        let clickSource = try #require(clicks as? PatternCaptureSource)
        let channelSource = try #require(channels as? PatternCaptureSource)
        #expect(clickSource.pattern == ClickPattern.make(levelDBFS: -20))
        #expect(channelSource.pattern == ChannelTestPattern.make(levelDBFS: -20))
        #expect(clicks.requiredPermission == nil)
        #expect(channels.requiredPermission == nil)
    }
}
