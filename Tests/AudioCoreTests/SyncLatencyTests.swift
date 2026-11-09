import AVFoundation
import Foundation
import Testing

@testable import AudioCore

/// Horloge qui rend le même instant de restitution pour toute trame : l'instant NTP d'un paquet de
/// synchro ne dépend alors ni de la durée de la négociation ni du rythme du test, et se compare à
/// la fraction NTP près.
private struct ConstantClock: PlaybackClockProtocol {
    let captureSampleRate: Double = 48_000
    let playoutDelaySeconds: Double
    let epoch: TimeInterval = 1_000_000

    func presentationUnixTime(forCaptureFrame frame: Double) -> TimeInterval? {
        epoch + playoutDelaySeconds
    }
}

/// Ce qu'un paquet de synchro dit, lu comme le lit un récepteur.
private struct SyncAnnouncement {
    /// Estampille courante moins latence annoncée (octets 4 à 7).
    let rtpLessLatency: UInt32
    let ntpUnixTime: TimeInterval
    /// Estampille courante (octets 16 à 19).
    let rtpTimestamp: UInt32

    init?(_ packet: Data) {
        let bytes = [UInt8](packet)
        guard bytes.count >= 20, let ntp = NTPTime(bigEndianBytes: Array(bytes[8..<16])) else {
            return nil
        }
        rtpLessLatency = bytes[4..<8].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        rtpTimestamp = bytes[16..<20].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        ntpUnixTime = ntp.unixTime
    }

    var announcedFrames: UInt32 { rtpTimestamp &- rtpLessLatency }

    /// Instant auquel un récepteur qui ajoute `added` trames à la latence annoncée restitue
    /// l'estampille courante.
    func playbackUnixTime(receiverAdding added: UInt32, sampleRate: Double = 44_100) -> TimeInterval {
        ntpUnixTime + Double(announcedFrames + added) / sampleRate
    }
}

@Suite("Latence des paquets de synchro : visée, annoncée, ajoutée par le récepteur")
struct SyncLatencyTests {
    @Test("Sans ajout du récepteur, on annonce la latence visée")
    func noReceiverAddition() {
        let latency = SyncLatency(playoutDelaySeconds: 2, sampleRate: 44_100, receiverAddedFrames: 0)
        #expect(latency.playoutFrames == 88_200)
        #expect(latency.announcedFrames == 88_200)
    }

    /// La valeur d'Airfoil : 1,75 s annoncée pour 2,0 s réels.
    @Test("Les 11 025 trames du récepteur sont retranchées de l'annonce, pas de la visée")
    func historicalAdditionIsSubtracted() {
        let latency = SyncLatency(
            playoutDelaySeconds: 2, sampleRate: 44_100,
            receiverAddedFrames: ReceiverAddedLatency.historicalFrames
        )
        #expect(latency.playoutFrames == 88_200)
        #expect(latency.announcedFrames == 77_175)
    }

    @Test("La latence suit le délai de restitution")
    func followsPlayoutDelay() {
        let latency = SyncLatency(playoutDelaySeconds: 1.5, sampleRate: 44_100, receiverAddedFrames: 11_025)
        #expect(latency.playoutFrames == 66_150)
        #expect(latency.announcedFrames == 55_125)
    }

    @Test("Un ajout plus grand que la visée ne rend pas l'annonce négative")
    func additionIsClamped() {
        let latency = SyncLatency(playoutDelaySeconds: 0.1, sampleRate: 44_100, receiverAddedFrames: 11_025)
        #expect(latency.playoutFrames == 4_410)
        #expect(latency.announcedFrames == 0)
        #expect(SyncLatency(playoutDelaySeconds: -1, sampleRate: 44_100, receiverAddedFrames: 0).playoutFrames == 0)
    }

    /// Mesuré au micro le 2026-11-09 : la Geneva et les deux HomePod avancent tous de 0,25 s. Une
    /// seule famille compensée les mettrait à 0,25 s l'une de l'autre.
    @Test("Par défaut, les deux familles sont compensées, de la même constante")
    func defaultCompensatesBothFamilies() {
        #expect(
            ReceiverAddedLatency.default == ReceiverAddedLatency(raopFrames: 11_025, airPlay2Frames: 11_025))
    }

    /// L'ancrage retranche la latence **visée** : retrancher la seule latence annoncée ferait
    /// reculer toutes les enceintes de l'ajout qu'on vient de retirer de l'annonce.
    @Test("Avec la compensation, un récepteur qui ajoute 11 025 trames joue à l'instant visé")
    func anchorTargetsPresentation() throws {
        let clock = ConstantClock(playoutDelaySeconds: 2)
        let synchronizer = OutputSynchronizer(label: "test", clock: clock, outputSampleRate: 44_100)
        synchronizer.beginStreaming(atCaptureFrame: 0)
        let latency = SyncLatency(
            playoutDelaySeconds: clock.playoutDelaySeconds, sampleRate: 44_100, receiverAddedFrames: 11_025
        )
        let anchor = try #require(synchronizer.syncAnchorUnixTime(latencyFrames: latency.playoutFrames))
        let played = anchor + Double(latency.announcedFrames + 11_025) / 44_100
        let presentation = try #require(clock.presentationUnixTime(forCaptureFrame: 0))
        #expect(abs(played - presentation) < 1e-6)
    }
}

/// Les deux senders réels, contre leurs faux récepteurs : ce qui part dans le paquet de synchro.
///
/// Sérialisés : chaque test tient un flux cadencé en temps réel.
@Suite("Paquet de synchro des senders : latence annoncée et instant d'ancrage", .serialized)
struct SenderSyncAnnouncementTests {
    private func firstRAOPAnnouncement(
        playoutDelaySeconds: Double, receiverAddedFrames: UInt32?
    ) async throws -> (SyncAnnouncement, ConstantClock) {
        let clock = ConstantClock(playoutDelaySeconds: playoutDelaySeconds)
        let format = try #require(captureFormat())
        let server = try await FakeRAOPReceiver(script: { _ in .standard })
        let ring = AudioRingBuffer(capacityFrames: 48_000, channelCount: 2)
        let feeder = ToneFeeder(ring: ring, format: format, hz: 440, amplitude: 0.003)
        let sender: RAOPSender
        if let receiverAddedFrames {
            sender = RAOPSender(
                device: server.device(), ring: ring, captureFormat: format, clock: clock,
                receiverAddedLatencyFrames: receiverAddedFrames
            )
        } else {
            sender = RAOPSender(device: server.device(), ring: ring, captureFormat: format, clock: clock)
        }
        try await sender.start(volume: -30)
        #expect(await raopEventually { !server.syncPackets.isEmpty })
        await sender.stop()
        feeder.stop()
        server.shutdown()
        let packet = try #require(server.syncPackets.first)
        return (try #require(SyncAnnouncement(packet)), clock)
    }

    private func firstAirPlay2Announcement(
        playoutDelaySeconds: Double, receiverAddedFrames: UInt32?
    ) async throws -> (SyncAnnouncement, ConstantClock) {
        let clock = ConstantClock(playoutDelaySeconds: playoutDelaySeconds)
        let receiver = FakeAirPlay2Receiver(options: .init())
        try await receiver.start()
        defer { receiver.stop() }
        let ring = AudioRingBuffer(capacityFrames: 48_000, channelCount: 2)
        let feeder = SineFeeder(ring: ring)
        let format = try SenderHarness.captureFormat()
        let sender: AirPlay2Sender
        if let receiverAddedFrames {
            sender = AirPlay2Sender(
                device: receiver.device(name: "Récepteur simulé"), ring: ring, captureFormat: format,
                clock: clock, receiverAddedLatencyFrames: receiverAddedFrames
            )
        } else {
            sender = AirPlay2Sender(
                device: receiver.device(name: "Récepteur simulé"), ring: ring, captureFormat: format,
                clock: clock
            )
        }
        feeder.start()
        defer { feeder.stop() }
        try await sender.start(volume: -30)
        await waitUntil { receiver.syncPacketCount(inSession: 0) > 0 }
        await sender.stop()
        let packet = try #require(receiver.syncPackets(inSession: 0).first)
        return (try #require(SyncAnnouncement(packet)), clock)
    }

    /// Sans réglage, la compensation mesurée : 77 175 trames annoncées, NTP = instant visé moins 2 s.
    @Test("RAOP, sans réglage : 77 175 trames annoncées")
    func raopDefault() async throws {
        let (sync, clock) = try await firstRAOPAnnouncement(playoutDelaySeconds: 2, receiverAddedFrames: nil)
        #expect(sync.announcedFrames == 77_175)
        #expect(abs(sync.ntpUnixTime - clock.epoch) < 1e-6)
    }

    /// Le fil d'avant le 2026-11-09, pour une mesure de comparaison : 88 200 trames annoncées.
    @Test("RAOP, compensation coupée : 88 200 trames annoncées, même instant NTP")
    func raopUncompensated() async throws {
        let (sync, clock) = try await firstRAOPAnnouncement(playoutDelaySeconds: 2, receiverAddedFrames: 0)
        #expect(sync.announcedFrames == 88_200)
        #expect(abs(sync.ntpUnixTime - clock.epoch) < 1e-6)
    }

    @Test("RAOP, compensation : 77 175 trames annoncées, et l'instant NTP ne bouge pas")
    func raopCompensated() async throws {
        let (sync, clock) = try await firstRAOPAnnouncement(playoutDelaySeconds: 2, receiverAddedFrames: 11_025)
        #expect(sync.announcedFrames == 77_175)
        // L'instant annoncé reste « visé − 2 s » : seul le champ de latence change sur le fil.
        #expect(abs(sync.ntpUnixTime - clock.epoch) < 1e-6)
        // Vu du récepteur qui ajoute ses 11 025 trames : l'estampille courante sort à l'instant visé.
        let target = clock.epoch + clock.playoutDelaySeconds
        #expect(abs(sync.playbackUnixTime(receiverAdding: 11_025) - target) < 1e-6)
    }

    @Test("AirPlay 2, sans réglage : 77 175 trames annoncées")
    func airPlay2Default() async throws {
        let (sync, clock) = try await firstAirPlay2Announcement(playoutDelaySeconds: 2, receiverAddedFrames: nil)
        #expect(sync.announcedFrames == 77_175)
        #expect(abs(sync.ntpUnixTime - clock.epoch) < 1e-6)
    }

    @Test("AirPlay 2, compensation : 77 175 trames annoncées, et l'instant NTP ne bouge pas")
    func airPlay2Compensated() async throws {
        let (sync, clock) = try await firstAirPlay2Announcement(
            playoutDelaySeconds: 2, receiverAddedFrames: 11_025)
        #expect(sync.announcedFrames == 77_175)
        #expect(abs(sync.ntpUnixTime - clock.epoch) < 1e-6)
        let target = clock.epoch + clock.playoutDelaySeconds
        #expect(abs(sync.playbackUnixTime(receiverAdding: 11_025) - target) < 1e-6)
    }

    /// Une seule constante : le délai de l'horloge. Les senders n'ont plus de 88 200 à eux, et un
    /// délai raccourci déplace ensemble la latence annoncée et l'instant d'ancrage.
    @Test("Un délai de restitution de 1,5 s se lit dans les deux senders, sans autre réglage")
    func playoutDelayDrivesBothSenders() async throws {
        let (raop, raopClock) = try await firstRAOPAnnouncement(playoutDelaySeconds: 1.5, receiverAddedFrames: 11_025)
        #expect(raop.announcedFrames == 55_125)
        #expect(abs(raop.playbackUnixTime(receiverAdding: 11_025) - (raopClock.epoch + 1.5)) < 1e-6)

        let (airPlay2, airPlay2Clock) = try await firstAirPlay2Announcement(
            playoutDelaySeconds: 1.5, receiverAddedFrames: 11_025)
        #expect(airPlay2.announcedFrames == 55_125)
        #expect(abs(airPlay2.playbackUnixTime(receiverAdding: 11_025) - (airPlay2Clock.epoch + 1.5)) < 1e-6)
    }
}

@Suite("La fabrique réelle transmet la compensation à chaque famille de récepteurs")
struct ReceiverAddedLatencyWiringTests {
    /// Latence visée de l'horloge par défaut, à 44,1 kHz.
    private let playoutFrames = UInt32(SharedPlaybackClock.defaultPlayoutDelaySeconds * 44_100)

    private func context() throws -> OutputSenderContext {
        OutputSenderContext(
            ring: AudioRingBuffer(capacityFrames: 1_024, channelCount: 2),
            captureFormat: try #require(captureFormat()),
            clock: SharedPlaybackClock(captureSampleRate: 48_000)
        )
    }

    private func factory(_ latency: ReceiverAddedLatency?) -> LiveOutputSenderFactory {
        let findRAOP: LiveOutputSenderFactory.RAOPFinder = { _, _, _ in
            RAOPDevice(
                serviceName: "000000000000@Boucle", host: "127.0.0.1", port: 9,
                txt: ["et": "0", "cn": "0", "sr": "44100", "ss": "16", "ch": "2"])
        }
        let findAirPlay2: LiveOutputSenderFactory.AirPlay2Finder = { _, _, _ in
            AirPlay2Device(serviceName: "Boucle", host: "127.0.0.1", port: 9, txt: [:])
        }
        guard let latency else {
            return LiveOutputSenderFactory(findRAOP: findRAOP, findAirPlay2: findAirPlay2)
        }
        return LiveOutputSenderFactory(
            findRAOP: findRAOP, findAirPlay2: findAirPlay2, receiverAddedLatency: latency)
    }

    private func announced(
        _ proto: BridgeEngine.OutputProtocol, by factory: LiveOutputSenderFactory
    ) async throws -> UInt32? {
        let sender = try await factory.makeSender(
            for: BridgeEngine.OutputRequest(id: "a", proto: proto, deviceName: "Boucle", volumeDB: -30),
            context: try context()
        )
        if let raop = sender as? RAOPSender { return raop.syncLatency.announcedFrames }
        if let airPlay2 = sender as? AirPlay2Sender { return airPlay2.syncLatency.announcedFrames }
        return nil
    }

    @Test("Sans réglage, les deux familles annoncent la latence compensée")
    func defaultFactory() async throws {
        #expect(try await announced(.raop, by: factory(nil)) == playoutFrames - 11_025)
        #expect(try await announced(.airplay2, by: factory(nil)) == playoutFrames - 11_025)
    }

    /// Réglées séparément : la mesure au micro peut donner une constante par protocole.
    @Test("Chaque famille reçoit sa propre compensation")
    func perProtocol() async throws {
        let latency = ReceiverAddedLatency(raopFrames: 11_025, airPlay2Frames: 4_410)
        #expect(try await announced(.raop, by: factory(latency)) == playoutFrames - 11_025)
        #expect(try await announced(.airplay2, by: factory(latency)) == playoutFrames - 4_410)
    }
}
