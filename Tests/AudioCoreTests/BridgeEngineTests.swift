import AVFoundation
import Foundation
import Testing

@testable import AudioCore

private let source0 = BridgeEngine.Source.tone(frequency: 440, levelDBFS: -50)

@Suite("Moteur : cycle de vie")
struct BridgeEngineLifecycleTests {
    @Test("Démarrage puis arrêt : capture et sorties suivent")
    func startThenStop() async throws {
        let source = ManualCaptureSource()
        let factory = FakeSenderFactory()
        let engine = makeEngine(source: source, factory: factory)

        try await engine.start(source: source0, outputs: [request("a"), request("b")])
        #expect(await engine.isRunning)
        #expect(source.startCount == 1)
        #expect(await eventually { await engine.phase(of: "a") == .streaming })
        #expect(await eventually { await engine.phase(of: "b") == .streaming })

        await engine.stop()
        #expect(await !engine.isRunning)
        #expect(source.stopCount == 1)
        #expect(await engine.phase(of: "a") == .idle)
        for sender in factory.allSenders() {
            #expect(await sender.stopCount >= 1)
        }
    }

    /// Défaut d'origine : le callback lisait un `var sink` écrit après le démarrage de l'IO, sans
    /// aucune synchronisation. Le format connu dès `prepare` permet de tout créer avant : un bloc
    /// livré pendant `start` même doit donc arriver à bon port.
    @Test("Un bloc livré dès le démarrage de l'IO n'est pas perdu")
    func blockDeliveredDuringStartIsCounted() async throws {
        let source = ManualCaptureSource()
        source.framesPushedDuringStart = 256
        let factory = FakeSenderFactory()
        let engine = makeEngine(source: source, factory: factory)

        try await engine.start(source: source0, outputs: [request("a")])
        #expect(source.prepareCount == 1)
        #expect(await eventually { factory.latest("a") != nil })
        let sender = try #require(factory.latest("a"))
        #expect(sender.context.ring.totalFramesWritten == 256)
        await engine.stop()
    }

    /// `start` suspend sur l'autorisation : sans état posé avant la suspension, deux appels
    /// rapprochés démarrent deux captures, en violation de l'invariant section 12.
    @Test("Deux démarrages rapprochés ne font qu'une capture")
    func concurrentStartsMakeOneCapture() async throws {
        let ledger = CaptureLedger()
        let permissions = FakePermissions(status: .notDetermined)
        let factory = FakeSenderFactory()
        let engine = BridgeEngine(
            dependencies: BridgeEngine.Dependencies(
                makeSource: { _, _ in
                    ManualCaptureSource(permission: .systemAudio, ledger: ledger)
                },
                senderFactory: factory, permissions: permissions, tuning: .fast
            )
        )

        let first = Task { try await engine.start(source: source0, outputs: [request("a")]) }
        #expect(await eventually { permissions.requestCount == 1 })

        var secondRefused = false
        do {
            try await engine.start(source: source0, outputs: [request("b")])
        } catch BridgeEngine.Failure.alreadyRunning {
            secondRefused = true
        }
        #expect(secondRefused)

        permissions.answer(true)
        try await first.value
        #expect(ledger.createdCount == 1)
        #expect(ledger.maximumActive == 1)
        await engine.stop()
    }

    @Test("Un arrêt pendant l'attente de l'autorisation annule le démarrage")
    func stopDuringStartCancelsIt() async throws {
        let ledger = CaptureLedger()
        let permissions = FakePermissions(status: .notDetermined)
        let factory = FakeSenderFactory()
        let engine = BridgeEngine(
            dependencies: BridgeEngine.Dependencies(
                makeSource: { _, _ in
                    ManualCaptureSource(permission: .systemAudio, ledger: ledger)
                },
                senderFactory: factory, permissions: permissions, tuning: .fast
            )
        )

        let pending = Task { try await engine.start(source: source0, outputs: [request("a")]) }
        #expect(await eventually { permissions.requestCount == 1 })
        await engine.stop()
        permissions.answer(true)

        var cancelled = false
        do { try await pending.value } catch BridgeEngine.Failure.stoppedDuringStart {
            cancelled = true
        }
        #expect(cancelled)
        #expect(ledger.maximumActive == 0)
        #expect(await !engine.isRunning)

        // Et l'on peut repartir aussitôt.
        try await engine.start(source: source0, outputs: [request("a")])
        #expect(ledger.maximumActive == 1)
        await engine.stop()
    }

    @Test("Un démarrage demandé pendant un arrêt attend que la capture soit libérée")
    func startDuringStopWaitsForRelease() async throws {
        let ledger = CaptureLedger()
        let factory = FakeSenderFactory()
        factory.makeStopHang("a")
        let engine = BridgeEngine(
            dependencies: BridgeEngine.Dependencies(
                makeSource: { _, _ in ManualCaptureSource(ledger: ledger) },
                senderFactory: factory, permissions: FakePermissions(), tuning: .fast
            )
        )

        try await engine.start(source: source0, outputs: [request("a")])
        #expect(await eventually { await engine.phase(of: "a") == .streaming })

        let stopping = Task { await engine.stop() }
        #expect(await eventually {
            guard let sender = factory.latest("a") else { return false }
            return await sender.stopCount == 1
        })
        try await engine.start(source: source0, outputs: [request("b")])
        await stopping.value

        #expect(ledger.maximumActive == 1)
        #expect(ledger.createdCount == 2)
        await factory.latest("a")?.releaseStop()
        await engine.stop()
    }

    @Test("Le redémarrage après un arrêt fonctionne, sur une capture neuve")
    func restartAfterStop() async throws {
        let ledger = CaptureLedger()
        let factory = FakeSenderFactory()
        let engine = BridgeEngine(
            dependencies: BridgeEngine.Dependencies(
                makeSource: { _, _ in ManualCaptureSource(ledger: ledger) },
                senderFactory: factory, permissions: FakePermissions(), tuning: .fast
            )
        )
        for round in 1...3 {
            try await engine.start(source: source0, outputs: [request("a")])
            #expect(await eventually { await engine.phase(of: "a") == .streaming })
            await engine.stop()
            #expect(factory.senders("a").count == round)
            #expect(ledger.activeCount == 0)
        }
        #expect(ledger.maximumActive == 1)
    }

    @Test("Démarrer sans sortie ou avec un doublon est refusé, sans capture")
    func invalidRequestsAreRefused() async throws {
        let source = ManualCaptureSource()
        let engine = makeEngine(source: source, factory: FakeSenderFactory())

        await #expect(throws: BridgeEngine.Failure.self) {
            try await engine.start(source: source0, outputs: [])
        }
        await #expect(throws: BridgeEngine.Failure.self) {
            try await engine.start(source: source0, outputs: [request("a"), request("a")])
        }
        #expect(source.startCount == 0)
    }

    @Test("Une autorisation refusée remonte, et n'a rien démarré")
    func deniedPermissionThrows() async throws {
        let source = ManualCaptureSource(permission: .microphone)
        let permissions = FakePermissions(status: .notDetermined)
        let engine = makeEngine(
            source: source, factory: FakeSenderFactory(), permissions: permissions
        )
        let pending = Task { try await engine.start(source: source0, outputs: [request("a")]) }
        #expect(await eventually { permissions.requestCount == 1 })
        #expect(permissions.requestedKinds == [.microphone])
        permissions.answer(false)
        await #expect(throws: BridgeEngine.Failure.self) { try await pending.value }
        #expect(source.startCount == 0)
        #expect(await !engine.isRunning)
    }
}

@Suite("Moteur : arrêt borné")
struct BridgeEngineStopTests {
    /// Un récepteur muet peut retenir un `TEARDOWN` : il n'a pas à retenir aussi l'interface.
    @Test("Un sender qui ne rend pas la main ne retient pas l'arrêt")
    func hangingSenderDoesNotHoldStop() async throws {
        let source = ManualCaptureSource()
        let factory = FakeSenderFactory()
        factory.makeStopHang("a")
        let engine = makeEngine(source: source, factory: factory)

        try await engine.start(source: source0, outputs: [request("a")])
        #expect(await eventually { await engine.phase(of: "a") == .streaming })

        let clock = ContinuousClock()
        let elapsed = await clock.measure { await engine.stop() }
        #expect(elapsed < .seconds(5))
        #expect(source.stopCount == 1)
        #expect(await !engine.isRunning)
        await factory.latest("a")?.releaseStop()
    }

    /// La négociation ne surveille pas l'annulation : c'est `stop` qui l'interrompt, et il doit
    /// être appelé y compris quand `start` n'a jamais abouti, sinon la socket reste ouverte.
    @Test("Une sortie annulée pendant la négociation est refermée")
    func cancelledDuringStartIsClosed() async throws {
        let source = ManualCaptureSource()
        let factory = FakeSenderFactory()
        factory.script("a", [.hang])
        let engine = makeEngine(source: source, factory: factory)

        try await engine.start(source: source0, outputs: [request("a")])
        #expect(await eventually {
            guard let sender = factory.latest("a") else { return false }
            return await sender.isNegotiating
        })

        await engine.stop()
        let sender = try #require(factory.latest("a"))
        #expect(await sender.stopCount >= 1)
        #expect(await sender.state == .idle)
        #expect(await engine.phase(of: "a") == .idle)
    }

    @Test("Un `start` qui aboutit malgré l'annulation laisse quand même la session fermée")
    func startSucceedingAfterCancelIsClosed() async throws {
        let source = ManualCaptureSource()
        let factory = FakeSenderFactory()
        factory.script("a", [.hang])
        let engine = makeEngine(source: source, factory: factory)

        try await engine.start(source: source0, outputs: [request("a")])
        #expect(await eventually {
            guard let sender = factory.latest("a") else { return false }
            return await sender.isNegotiating
        })
        let sender = try #require(factory.latest("a"))
        await sender.releaseStart()
        await engine.stop()
        #expect(await eventually { await sender.stopCount >= 1 })
    }
}

@Suite("Moteur : récepteur absent et reconnexion")
struct BridgeEngineRetryTests {
    @Test("Un récepteur absent au démarrage est réessayé, sans toucher à l'autre sortie")
    func absentReceiverIsRetried() async throws {
        let source = ManualCaptureSource()
        let factory = FakeSenderFactory()
        factory.failDiscovery("absent", times: 3)
        let engine = makeEngine(source: source, factory: factory)

        try await engine.start(source: source0, outputs: [request("ok"), request("absent")])
        #expect(await eventually { await engine.phase(of: "ok") == .streaming })
        #expect(await eventually { await engine.phase(of: "absent") == .streaming })
        #expect(factory.senders("absent").count == 1)
        #expect(factory.senders("ok").count == 1)
        await engine.stop()
    }

    @Test("La phase d'attente est distincte et porte l'essai et l'erreur")
    func waitingPhaseIsVisible() async throws {
        var tuning = BridgeEngine.Tuning.fast
        tuning.retryInitialDelay = .seconds(600)
        tuning.retryMaximumDelay = .seconds(600)
        let factory = FakeSenderFactory()
        factory.failDiscovery("absent", times: 1)
        let engine = makeEngine(source: ManualCaptureSource(), factory: factory, tuning: tuning)

        try await engine.start(source: source0, outputs: [request("absent")])
        #expect(await eventually {
            if case .waitingForReceiver(1, _) = await engine.phase(of: "absent") { return true }
            return false
        })
        let snapshot = try #require(await engine.snapshot(of: "absent"))
        #expect(snapshot.nextAttemptAt != nil)
        #expect(await engine.isRunning)

        // L'attente doit s'interrompre sur un arrêt : 600 s n'ont pas à s'écouler.
        await engine.stop()
        #expect(await engine.phase(of: "absent") == .idle)
    }

    @Test("Un sender qui échoue à la négociation est remplacé par un neuf")
    func failedStartGetsAFreshSender() async throws {
        let factory = FakeSenderFactory()
        factory.script("a", [.fail(.absent), .fail(.absent), .succeed])
        let engine = makeEngine(source: ManualCaptureSource(), factory: factory)

        try await engine.start(source: source0, outputs: [request("a")])
        #expect(await eventually { await engine.phase(of: "a") == .streaming })
        #expect(factory.senders("a").count == 3)
        // Le sender d'un essai raté a libéré sa session.
        #expect(await factory.senders("a")[0].stopCount >= 1)
        await engine.stop()
    }

    @Test("Un refus définitif n'est pas réessayé et n'atteint pas les autres")
    func permanentFailureIsNotRetried() async throws {
        let source = ManualCaptureSource()
        let factory = FakeSenderFactory()
        factory.script("refus", [.failPermanently])
        let engine = makeEngine(source: source, factory: factory)

        try await engine.start(source: source0, outputs: [request("refus"), request("ok")])
        #expect(await eventually {
            if case .failed = await engine.phase(of: "refus") { return true }
            return false
        })
        #expect(await eventually { await engine.phase(of: "ok") == .streaming })
        #expect(factory.senders("refus").count == 1)
        #expect(source.stopCount == 0)
        await engine.stop()
    }

    @Test("Le repli est exponentiel et plafonné")
    func backoffIsExponentialAndCapped() {
        var tuning = BridgeEngine.Tuning()
        tuning.retryInitialDelay = .seconds(2)
        tuning.retryMaximumDelay = .seconds(30)
        let delays = (1...7).map { BridgeEngine.retryDelay(attempt: $0, tuning: tuning) }
        #expect(delays == [
            .seconds(2), .seconds(4), .seconds(8), .seconds(16), .seconds(30), .seconds(30),
            .seconds(30),
        ])
    }

    @Test("Les refus d'authentification et de capacité sont définitifs, l'absence non")
    func failureClassification() {
        #expect(isPermanentOutputFailure(RAOPSenderError.alacUnsupported("x")))
        #expect(isPermanentOutputFailure(
            RTSPError.unexpectedStatus(method: "POST", code: 470, reason: "")))
        #expect(!isPermanentOutputFailure(
            RTSPError.unexpectedStatus(method: "SETUP", code: 453, reason: "")))
        #expect(!isPermanentOutputFailure(RAOPDiscoveryError.notFound(name: "x", seen: [])))
        #expect(!isPermanentOutputFailure(RTSPError.connectionFailed("x")))
        #expect(isPermanentOutputFailure(
            AirPlay2PairingSession.Failure.receiverRejected(.authentication, step: "M2")))
        #expect(!isPermanentOutputFailure(
            AirPlay2PairingSession.Failure.receiverRejected(.busy, step: "M2")))
    }

    @Test("La reconnexion d'un sender se lit dans la phase")
    func reconnectionIsPublished() async throws {
        let factory = FakeSenderFactory()
        let engine = makeEngine(source: ManualCaptureSource(), factory: factory)
        try await engine.start(source: source0, outputs: [request("a")])
        #expect(await eventually { await engine.phase(of: "a") == .streaming })

        let sender = try #require(factory.latest("a"))
        await sender.setState(.reconnecting)
        #expect(await eventually { await engine.phase(of: "a") == .reconnecting })
        await sender.setState(.streaming)
        #expect(await eventually { await engine.phase(of: "a") == .streaming })
        await engine.stop()
    }

    @Test("Un sender qui abandonne en pleine session est remplacé")
    func senderGivingUpIsReplaced() async throws {
        let factory = FakeSenderFactory()
        let engine = makeEngine(source: ManualCaptureSource(), factory: factory)
        try await engine.start(source: source0, outputs: [request("a")])
        #expect(await eventually { await engine.phase(of: "a") == .streaming })

        let first = try #require(factory.latest("a"))
        await first.setState(.failed)
        #expect(await eventually { factory.senders("a").count == 2 })
        #expect(await eventually { await engine.phase(of: "a") == .streaming })
        #expect(await first.stopCount >= 1)
        await engine.stop()
    }

    /// Défaut d'origine : un réglage poussé avant la fin de la connexion était perdu, alors que
    /// l'appelant le croyait transmis et ne le renvoyait jamais.
    @Test("Volume et délai réglés pendant la négociation sont appliqués à la connexion")
    func settingsDuringNegotiationAreApplied() async throws {
        let factory = FakeSenderFactory()
        factory.script("a", [.hang])
        let engine = makeEngine(source: ManualCaptureSource(), factory: factory)
        try await engine.start(source: source0, outputs: [request("a", volume: -20)])
        #expect(await eventually {
            guard let sender = factory.latest("a") else { return false }
            return await sender.isNegotiating
        })

        await engine.setVolume(-7, for: "a")
        await engine.setManualDelay(0.05, for: "a")
        let sender = try #require(factory.latest("a"))
        await sender.releaseStart()

        #expect(await eventually { await sender.pushedVolumes.last == -7 })
        #expect(await eventually { await sender.pushedDelays.last == 0.05 })
        await engine.stop()
    }

    @Test("Un nouvel essai part des derniers réglages, pas de ceux de la requête initiale")
    func retryUsesLatestSettings() async throws {
        var tuning = BridgeEngine.Tuning.fast
        tuning.retryInitialDelay = .milliseconds(50)
        let factory = FakeSenderFactory()
        factory.failDiscovery("a", times: 1)
        let engine = makeEngine(source: ManualCaptureSource(), factory: factory, tuning: tuning)

        try await engine.start(source: source0, outputs: [request("a", volume: -20)])
        await engine.setVolume(-9, for: "a")
        await engine.setManualDelay(-0.02, for: "a")
        #expect(await eventually { await engine.phase(of: "a") == .streaming })
        let sender = try #require(factory.latest("a"))
        #expect(await sender.startedVolume == -9)
        #expect(await sender.startedDelay == -0.02)
        await engine.stop()
    }
}

@Suite("Moteur : sorties à chaud")
struct BridgeEngineHotPlugTests {
    /// Une sortie ajoutée après coup doit parler de la même graduation que les autres : c'est ce
    /// qui l'aligne, quelle que soit la durée de sa négociation.
    @Test("Une sortie ajoutée en cours de route reste sur l'horloge commune")
    func addedOutputSharesTimeline() async throws {
        let source = ManualCaptureSource()
        let factory = FakeSenderFactory()
        let engine = makeEngine(source: source, factory: factory)

        try await engine.start(source: source0, outputs: [request("a")])
        #expect(await eventually { await engine.phase(of: "a") == .streaming })
        let first = try #require(factory.latest("a"))
        source.push(frames: 10_000)
        await first.drain()

        try await engine.addOutput(request("b"))
        #expect(await eventually { await engine.phase(of: "b") == .streaming })
        let second = try #require(factory.latest("b"))
        source.push(frames: 512)

        #expect(first.context.ring.totalFramesWritten == 10_512)
        #expect(second.context.ring.totalFramesWritten == 10_512)
        // La nouvelle sortie n'a vu que ce qui suit son activation, et le sait.
        #expect(second.context.ring.availableFrames == 512)
        #expect(second.context.ring.totalFramesRead == 10_000)

        // Les deux sont sur la même horloge, et situent donc la trame n° 10 000 au même instant.
        let clock = first.context.clock
        #expect(
            clock.presentationUnixTime(forCaptureFrame: 10_000)
                == second.context.clock.presentationUnixTime(forCaptureFrame: 10_000))

        // Et le contenu lu par chacune correspond à la position annoncée.
        let samples = await second.drain()
        #expect(samples.first == 10_001)
        await engine.stop()
    }

    @Test("Ajouter et retirer une sortie ne perturbe pas le flux des autres")
    func hotPlugDoesNotDisturbOthers() async throws {
        let source = ManualCaptureSource()
        let factory = FakeSenderFactory()
        let engine = makeEngine(source: source, factory: factory)

        try await engine.start(source: source0, outputs: [request("a")])
        #expect(await eventually { await engine.phase(of: "a") == .streaming })
        let steady = try #require(factory.latest("a"))

        var received: [Float] = []
        for round in 0..<20 {
            source.push(frames: 256)
            if round == 5 {
                try await engine.addOutput(request("b"))
                #expect(await eventually { await engine.phase(of: "b") == .streaming })
            }
            if round == 12 { await engine.removeOutput(id: "b") }
            received += await steady.drain()
        }

        // Toutes les trames, dans l'ordre, sans trou : 1, 1, 2, 2, 3, 3…
        let expected = (1...(20 * 256)).flatMap { [Float($0), Float($0)] }
        #expect(received == expected)
        #expect(await engine.phase(of: "a") == .streaming)
        #expect(source.stopCount == 0)
        await engine.stop()
    }

    @Test("Retirer une sortie ferme son sender et la fait disparaître de l'état publié")
    func removeOutputClosesSender() async throws {
        let factory = FakeSenderFactory()
        let engine = makeEngine(source: ManualCaptureSource(), factory: factory)
        try await engine.start(source: source0, outputs: [request("a"), request("b")])
        #expect(await eventually { await engine.phase(of: "b") == .streaming })

        await engine.removeOutput(id: "b")
        let sender = try #require(factory.latest("b"))
        #expect(await sender.stopCount >= 1)
        #expect(await engine.outputOrder == ["a"])
        #expect(await engine.phase(of: "b") == nil)
        await engine.stop()
    }

    @Test("Un tampon rendu est réattribué, remis à neuf et bien situé")
    func releasedSlotIsReusedCleanly() async throws {
        var tuning = BridgeEngine.Tuning.fast
        tuning.maximumOutputs = 2
        let source = ManualCaptureSource()
        let factory = FakeSenderFactory()
        let engine = makeEngine(source: source, factory: factory, tuning: tuning)

        try await engine.start(source: source0, outputs: [request("a"), request("b")])
        #expect(await eventually { await engine.phase(of: "b") == .streaming })
        source.push(frames: 1_000)

        await engine.removeOutput(id: "b")
        // Le producteur n'a pas encore pris acte du retrait : le tampon reste indisponible.
        await #expect(throws: BridgeEngine.Failure.self) {
            try await engine.addOutput(request("c"))
        }
        source.push(frames: 1_000)
        await factory.latest("a")?.drain()

        try await engine.addOutput(request("c"))
        #expect(await eventually { await engine.phase(of: "c") == .streaming })
        source.push(frames: 500)

        let reused = try #require(factory.latest("c"))
        #expect(reused.context.ring.availableFrames == 500)
        #expect(reused.context.ring.droppedFrames == 0)
        #expect(reused.context.ring.totalFramesRead == 2_000)
        let samples = await reused.drain()
        #expect(samples.first == 2_001)
        await engine.stop()
    }

    @Test("Le nombre de sorties est borné par les tampons pré-alloués")
    func outputCountIsBounded() async throws {
        var tuning = BridgeEngine.Tuning.fast
        tuning.maximumOutputs = 2
        let engine = makeEngine(
            source: ManualCaptureSource(), factory: FakeSenderFactory(), tuning: tuning
        )
        await #expect(throws: BridgeEngine.Failure.self) {
            try await engine.start(
                source: source0, outputs: [request("a"), request("b"), request("c")]
            )
        }
        try await engine.start(source: source0, outputs: [request("a"), request("b")])
        await #expect(throws: BridgeEngine.Failure.self) {
            try await engine.addOutput(request("c"))
        }
        await engine.stop()
    }

    @Test("Ajouter hors diffusion ou deux fois la même sortie est refusé")
    func invalidAddIsRefused() async throws {
        let engine = makeEngine(source: ManualCaptureSource(), factory: FakeSenderFactory())
        await #expect(throws: BridgeEngine.Failure.self) {
            try await engine.addOutput(request("a"))
        }
        try await engine.start(source: source0, outputs: [request("a")])
        await #expect(throws: BridgeEngine.Failure.self) {
            try await engine.addOutput(request("a"))
        }
        await engine.stop()
    }

    @Test("Recocher une sortie en échec définitif la relance")
    func addAfterPermanentFailureRetries() async throws {
        let factory = FakeSenderFactory()
        factory.script("a", [.failPermanently])
        let engine = makeEngine(source: ManualCaptureSource(), factory: factory)
        try await engine.start(source: source0, outputs: [request("a")])
        #expect(await eventually {
            if case .failed = await engine.phase(of: "a") { return true }
            return false
        })
        try await engine.addOutput(request("a"))
        #expect(await eventually { await engine.phase(of: "a") == .streaming })
        #expect(await engine.outputOrder == ["a"])
        await engine.stop()
    }
}

@Suite("Moteur : ce qui remonte au diagnostic")
struct BridgeEngineSnapshotTests {
    @Test("Tous les compteurs du sender remontent")
    func allStatisticsAreForwarded() async throws {
        let factory = FakeSenderFactory()
        let engine = makeEngine(source: ManualCaptureSource(), factory: factory)
        try await engine.start(source: source0, outputs: [request("a")])
        #expect(await eventually { await engine.phase(of: "a") == .streaming })

        var statistics = OutputStatistics()
        statistics.packetsSent = 1
        statistics.framesRead = 2
        statistics.errors = 3
        statistics.resyncs = 4
        statistics.syncPacketsSent = 5
        statistics.anchoredSyncPackets = 6
        statistics.framesInserted = 7
        statistics.framesRemoved = 8
        statistics.reconnections = 9
        statistics.reconnectionAttempts = 10
        statistics.droppedBeforeStreaming = 11
        statistics.reportedLatencyFrames = 4_096
        await factory.latest("a")?.setStatistics(statistics)

        let expected = statistics
        #expect(await eventually { await engine.snapshot(of: "a")?.statistics == expected })
        let snapshot = try #require(await engine.snapshot(of: "a"))
        #expect(snapshot.packetsSent == 1)
        #expect(snapshot.errors == 3)
        #expect(snapshot.driftCorrections == 15)
        #expect(snapshot.sync != nil)
        await engine.stop()
    }

    @Test("Les compteurs d'un sender RAOP gardent absents ceux qu'il ne mesure pas")
    func raopStatisticsMapping() async {
        let device = RAOPDevice(
            serviceName: "AA@Test", host: "127.0.0.1", port: 5000, txt: ["et": "0", "cn": "0"]
        )
        let ring = AudioRingBuffer(capacityFrames: 1_024, channelCount: 2)
        let sender = RAOPSender(device: device, ring: ring, captureFormat: stereoFormat())
        let statistics = await sender.currentOutputStatistics()
        #expect(statistics.timingResponsesSent == 0)
        // L'en-tête `Audio-Latency` n'a pas été vu : la valeur est inconnue, pas nulle.
        #expect(statistics.reportedLatencyFrames == nil)
        #expect(statistics.retransmitRequests == nil)
        #expect(statistics.eventChannelConnected == nil)
        #expect(statistics.receiverBufferSize == nil)
        #expect(await sender.currentOutputState() == .idle)
    }

    @Test("Les compteurs d'un sender AirPlay 2 gardent absents ceux qu'il ne mesure pas")
    func airplay2StatisticsMapping() async {
        let device = AirPlay2Device(
            serviceName: "Test", host: "127.0.0.1", port: 7000, txt: [:]
        )
        let ring = AudioRingBuffer(capacityFrames: 1_024, channelCount: 2)
        let sender = AirPlay2Sender(device: device, ring: ring, captureFormat: stereoFormat())
        let statistics = await sender.currentOutputStatistics()
        #expect(statistics.retransmitRequests == 0)
        #expect(statistics.eventChannelConnected == false)
        #expect(statistics.timingResponsesSent == nil)
        #expect(statistics.reportedLatencyFrames == nil)
        #expect(statistics.volumeDB == nil)
        #expect(await sender.currentOutputState() == .idle)
    }

    @Test("Les refus en régime établi sont distingués de ceux de la négociation")
    func droppedWhileStreamingIsReported() async throws {
        let source = ManualCaptureSource()
        let factory = FakeSenderFactory()
        let engine = makeEngine(source: source, factory: factory)
        try await engine.start(source: source0, outputs: [request("a")])
        #expect(await eventually { await engine.phase(of: "a") == .streaming })

        // Personne ne lit : le tampon d'une seconde déborde.
        for _ in 0..<60 { source.push(frames: 1_000) }
        #expect(await eventually { await engine.snapshot(of: "a")?.droppedWhileStreaming == 12_000 })
        await engine.stop()
    }
}

@Suite("Moteur : entrée physique")
struct BridgeEngineInputTests {
    /// Le callback du moteur supposait `list.first` entrelacé : un flux mono planaire y aurait été
    /// lu comme du stéréo, à double vitesse et sur des échantillons voisins.
    @Test("Une source mono planaire devient du stéréo, sans toucher à son tampon")
    func monoPlanarBecomesStereo() async throws {
        let source = ManualCaptureSource(format: monoPlanarFormat(), permission: .microphone)
        let factory = FakeSenderFactory()
        let permissions = FakePermissions(status: .authorized)
        let engine = makeEngine(source: source, factory: factory, permissions: permissions)

        try await engine.start(source: .inputDevice, outputs: [request("a")])
        #expect(await eventually { await engine.phase(of: "a") == .streaming })
        let sender = try #require(factory.latest("a"))
        #expect(sender.context.captureFormat.channelCount == 2)
        #expect(sender.context.captureFormat.isInterleaved)
        #expect(sender.context.captureFormat.sampleRate == 48_000)

        source.pushRaw([0.1, 0.2, 0.3, 0.4], frames: 4, channels: 1)
        let samples = await sender.drain()
        #expect(samples == [0.1, 0.1, 0.2, 0.2, 0.3, 0.3, 0.4, 0.4])
        #expect(sender.context.ring.totalFramesWritten == 4)
        await engine.stop()
    }

    @Test("La source demande l'autorisation qui lui est propre")
    func inputAsksForMicrophone() async throws {
        let source = ManualCaptureSource(format: monoPlanarFormat(), permission: .microphone)
        let permissions = FakePermissions(status: .notDetermined)
        let engine = makeEngine(
            source: source, factory: FakeSenderFactory(), permissions: permissions
        )
        let pending = Task { try await engine.start(source: .inputDevice, outputs: [request("a")]) }
        #expect(await eventually { permissions.requestCount == 1 })
        #expect(permissions.requestedKinds == [.microphone])
        permissions.answer(true)
        try await pending.value
        await engine.stop()
    }

    /// Bout en bout sur le vrai fil de génération et le vrai rééchantillonneur : ce sont eux qui
    /// verraient un format mal déclaré, sous la forme d'une erreur ou d'un silence.
    @Test("Une sinusoïde mono planaire traverse le moteur et le rééchantillonneur")
    func monoToneReachesResampler() async throws {
        let tone = ToneCaptureSource(
            levelDBFS: -20, channelCount: 1, interleaved: false, blockFrames: 256
        )
        let factory = FakeSenderFactory()
        let engine = BridgeEngine(
            dependencies: BridgeEngine.Dependencies(
                makeSource: { _, _ in tone },
                senderFactory: factory, permissions: FakePermissions(), tuning: .fast
            )
        )
        try await engine.start(source: .inputDevice, outputs: [request("a")])
        #expect(await eventually { factory.latest("a") != nil })
        let sender = try #require(factory.latest("a"))
        #expect(await eventually { sender.context.ring.availableFrames > 4_800 })

        let samples = await sender.drain()
        let frames = samples.count / 2
        #expect(frames > 0)
        #expect(samples.contains { $0 != 0 })
        for frame in 0..<frames {
            #expect(samples[frame * 2] == samples[frame * 2 + 1])
        }

        let resampler = try RAOPResampler(inputFormat: sender.context.captureFormat)
        let converted = try samples.withUnsafeBufferPointer { buffer -> [Int16] in
            guard let base = buffer.baseAddress else { return [] }
            return try resampler.convert(base, frameCount: frames)
        }
        #expect(converted.contains { $0 != 0 })
        await engine.stop()
    }
}

@Suite("Moteur : changement de périphérique")
struct BridgeEngineRouteTests {
    /// Débrancher un casque retire son horloge à l'agrégat (piège n° 2 de `CLAUDE.md`). Les senders
    /// n'ont pas à le savoir : leur tampon reste vide un instant, et le flux reprend.
    @Test("La capture est reconstruite sans toucher aux senders")
    func rebuildKeepsSenders() async throws {
        let ledger = CaptureLedger()
        let source = ManualCaptureSource(ledger: ledger)
        let factory = FakeSenderFactory()
        let engine = makeEngine(source: source, factory: factory)
        try await engine.start(source: source0, outputs: [request("a")])
        #expect(await eventually { await engine.phase(of: "a") == .streaming })
        let sender = try #require(factory.latest("a"))
        source.push(frames: 1_000)
        await sender.drain()

        #expect(source.hasRouteHandler)
        source.fireRouteChange()
        #expect(await eventually { await engine.captureHealth.rebuilds == 1 })

        #expect(source.startCount == 2)
        #expect(source.stopCount == 1)
        #expect(ledger.maximumActive == 1)
        #expect(await sender.stopCount == 0)
        #expect(factory.senders("a").count == 1)

        // Le flux reprend sur la même graduation, et la série continue sans trou.
        source.push(frames: 100)
        #expect(sender.context.ring.totalFramesWritten == 1_100)
        let samples = await sender.drain()
        #expect(samples.first == 1_001)
        await engine.stop()
    }

    @Test("Un changement sans effet sur l'horloge ne reconstruit rien")
    func noRebuildWhenRouteUnchanged() async throws {
        let source = ManualCaptureSource()
        let engine = makeEngine(source: source, factory: FakeSenderFactory())
        try await engine.start(source: source0, outputs: [request("a")])
        await engine.rebuildCaptureIfNeeded()
        #expect(source.startCount == 1)
        #expect(await engine.captureHealth.rebuilds == 0)
        await engine.stop()
    }

    /// Le rééchantillonneur des senders est construit pour une fréquence : les laisser en place
    /// ferait jouer tout le flux à la mauvaise hauteur, sans la moindre erreur.
    @Test("Une nouvelle fréquence relance les sorties sur le bon format")
    func sampleRateChangeRestartsOutputs() async throws {
        let source = ManualCaptureSource(
            format: stereoFormat(sampleRate: 48_000),
            laterFormats: [stereoFormat(sampleRate: 96_000)]
        )
        let factory = FakeSenderFactory()
        let engine = makeEngine(source: source, factory: factory)
        try await engine.start(source: source0, outputs: [request("a", volume: -20)])
        #expect(await eventually { await engine.phase(of: "a") == .streaming })
        await engine.setVolume(-5, for: "a")

        source.fireRouteChange()
        #expect(await eventually { await engine.captureHealth.rebuilds == 1 })
        #expect(await eventually { factory.senders("a").count == 2 })
        #expect(await eventually { await engine.phase(of: "a") == .streaming })

        let replacement = try #require(factory.latest("a"))
        #expect(replacement.context.captureFormat.sampleRate == 96_000)
        #expect(await replacement.startedVolume == -5)
        #expect(await factory.senders("a")[0].stopCount >= 1)
        await engine.stop()
    }

    @Test("Une reconstruction en échec est réessayée, et l'erreur est publiée entre-temps")
    func failedRebuildIsRetried() async throws {
        let source = ManualCaptureSource()
        let factory = FakeSenderFactory()
        var tuning = BridgeEngine.Tuning.fast
        tuning.rebuildRetryInitialDelay = .milliseconds(100)
        tuning.rebuildRetryMaximumDelay = .milliseconds(100)
        let engine = makeEngine(source: source, factory: factory, tuning: tuning)
        try await engine.start(source: source0, outputs: [request("a")])
        #expect(await eventually { await engine.phase(of: "a") == .streaming })

        source.preparesToFail = 2
        source.fireRouteChange()
        #expect(await eventually { await engine.captureHealth.lastRebuildError != nil })
        #expect(await eventually { await engine.captureHealth.rebuilds == 1 })
        #expect(await engine.captureHealth.lastRebuildError == nil)
        #expect(source.prepareCount == 4)
        #expect(await factory.latest("a")?.stopCount == 0)
        await engine.stop()
    }

    /// Deux reconstructions simultanées lanceraient deux IO, donc deux producteurs sur un même
    /// tampon. Une notification reçue en pleine reconstruction est prise en compte à sa fin.
    @Test("Une notification pendant une reconstruction ne la démarre pas en double")
    func notificationDuringRebuildIsSerialized() async throws {
        let ledger = CaptureLedger()
        let source = ManualCaptureSource(ledger: ledger)
        var tuning = BridgeEngine.Tuning.fast
        tuning.rebuildRetryInitialDelay = .milliseconds(50)
        tuning.rebuildRetryMaximumDelay = .milliseconds(50)
        let engine = makeEngine(source: source, factory: FakeSenderFactory(), tuning: tuning)
        try await engine.start(source: source0, outputs: [request("a")])

        source.preparesToFail = 2
        source.fireRouteChange()
        #expect(await eventually { await engine.captureHealth.lastRebuildError != nil })
        // La reconstruction est en attente de son nouvel essai : cette notification ne doit pas
        // en lancer une seconde.
        source.fireRouteChange()
        #expect(await eventually { await engine.captureHealth.rebuilds >= 1 })
        #expect(await eventually { source.startCount >= 2 })
        try await Task.sleep(for: .milliseconds(50))

        #expect(ledger.maximumActive == 1)
        #expect(ledger.activeCount == 1)
        await engine.stop()
        #expect(ledger.activeCount == 0)
    }

    /// `stop` doit attendre la reconstruction : sinon elle relancerait la source après son arrêt.
    @Test("Un arrêt pendant une reconstruction ne laisse aucune capture derrière lui")
    func stopDuringRebuildLeavesNoCapture() async throws {
        let ledger = CaptureLedger()
        let source = ManualCaptureSource(ledger: ledger)
        var tuning = BridgeEngine.Tuning.fast
        tuning.rebuildRetryInitialDelay = .milliseconds(20)
        tuning.rebuildRetryMaximumDelay = .milliseconds(20)
        let engine = makeEngine(source: source, factory: FakeSenderFactory(), tuning: tuning)
        try await engine.start(source: source0, outputs: [request("a")])

        source.preparesToFail = 1_000
        source.fireRouteChange()
        #expect(await eventually { await engine.captureHealth.lastRebuildError != nil })
        await engine.stop()

        source.preparesToFail = 0
        try await Task.sleep(for: .milliseconds(60))
        #expect(ledger.activeCount == 0)
        #expect(await !engine.isRunning)
    }

    @Test("L'arrêt retire le gestionnaire de route")
    func stopRemovesRouteHandler() async throws {
        let source = ManualCaptureSource()
        let engine = makeEngine(source: source, factory: FakeSenderFactory())
        try await engine.start(source: source0, outputs: [request("a")])
        #expect(source.hasRouteHandler)
        await engine.stop()
        #expect(!source.hasRouteHandler)
    }
}

@Suite("Moteur : santé de la capture")
struct BridgeEngineHealthTests {
    private func startedEngine(
        _ source: ManualCaptureSource, permissions: FakePermissions = FakePermissions()
    ) async throws -> BridgeEngine {
        let engine = makeEngine(
            source: source, factory: FakeSenderFactory(), permissions: permissions
        )
        try await engine.start(source: source0, outputs: [request("a")])
        return engine
    }

    @Test("Avant le premier bloc : attente, pas panne")
    func waitingBeforeFirstBlock() async throws {
        let engine = try await startedEngine(ManualCaptureSource())
        await engine.tickHealth(now: Date().addingTimeInterval(30))
        #expect(await engine.captureHealth.diagnosis == .waitingForFirstBlock)
        #expect(await engine.captureHealth.stalledSince == nil)
        await engine.stop()
        #expect(await engine.captureHealth.diagnosis == .notRunning)
    }

    /// Le cas de l'autorisation révoquée par un rebuild : le tap livre des zéros, sans erreur, au
    /// rythme normal, pendant qu'une application joue (`CLAUDE.md`, jalon 1).
    @Test("Silence strict alors qu'une application joue : suspect")
    func silenceWhilePlayingIsSuspect() async throws {
        let source = ManualCaptureSource()
        source.expectation = true
        let engine = try await startedEngine(source)

        source.pushSilence(frames: 48_000 * 4)
        let now = Date()
        await engine.tickHealth(now: now)
        let health = await engine.captureHealth
        #expect(health.diagnosis == .silentWhilePlaying)
        let since = try #require(health.silentSince)
        #expect(abs(now.timeIntervalSince(since) - 4) < 0.01)
        await engine.stop()
    }

    @Test("Silence strict quand rien ne joue : rien d'anormal, et dit comme tel")
    func silenceWithNothingPlaying() async throws {
        let source = ManualCaptureSource()
        source.expectation = false
        let engine = try await startedEngine(source)
        source.pushSilence(frames: 48_000 * 4)
        await engine.tickHealth(now: Date())
        #expect(await engine.captureHealth.diagnosis == .silentNothingPlaying)
        await engine.stop()
    }

    @Test("Silence strict sans indice : ni affirmation, ni fausse alerte")
    func silenceWithoutHint() async throws {
        let source = ManualCaptureSource()
        source.expectation = nil
        let engine = try await startedEngine(source)
        source.pushSilence(frames: 48_000 * 4)
        await engine.tickHealth(now: Date())
        #expect(await engine.captureHealth.diagnosis == .silentUnknown)
        await engine.stop()
    }

    @Test("Un silence plus court que le seuil n'alerte pas")
    func shortSilenceIsIgnored() async throws {
        let source = ManualCaptureSource()
        source.expectation = true
        let engine = try await startedEngine(source)
        source.pushSilence(frames: 48_000)
        await engine.tickHealth(now: Date())
        #expect(await engine.captureHealth.silentSince == nil)
        #expect(await engine.captureHealth.diagnosis == .healthy)
        await engine.stop()
    }

    @Test("Un seul échantillon non nul lève le silence")
    func signalClearsSilence() async throws {
        let source = ManualCaptureSource()
        source.expectation = true
        let engine = try await startedEngine(source)
        source.pushSilence(frames: 48_000 * 4)
        await engine.tickHealth(now: Date())
        #expect(await engine.captureHealth.silentSince != nil)

        source.pushRaw([0, 0, 0, 1e-6], frames: 2, channels: 2)
        await engine.tickHealth(now: Date())
        #expect(await engine.captureHealth.silentSince == nil)
        #expect(await engine.captureHealth.diagnosis == .healthy)
        await engine.stop()
    }

    @Test("L'état de l'autorisation accompagne le diagnostic")
    func permissionIsReported() async throws {
        let source = ManualCaptureSource(permission: .systemAudio)
        let engine = try await startedEngine(source)
        await engine.tickHealth(now: Date())
        #expect(await engine.captureHealth.permission == .authorized)
        await engine.stop()
    }

    @Test("Des blocs qui cessent d'arriver se voient, et leur reprise aussi")
    func stallIsReported() async throws {
        let source = ManualCaptureSource()
        let engine = try await startedEngine(source)
        source.push(frames: 480)
        let start = Date()
        await engine.tickHealth(now: start)
        #expect(await engine.captureHealth.diagnosis == .healthy)

        await engine.tickHealth(now: start.addingTimeInterval(5))
        #expect(await engine.captureHealth.diagnosis == .stalled)
        #expect(await engine.captureHealth.stalledSince == start)

        source.push(frames: 480)
        await engine.tickHealth(now: start.addingTimeInterval(5.01))
        #expect(await engine.captureHealth.diagnosis == .healthy)
        #expect(await engine.captureHealth.stalledSince == nil)
        await engine.stop()
    }

    /// La graduation ne compte que les trames produites : sans ce report, une interruption
    /// entame d'autant les 2 s de marge de restitution, jusqu'à annoncer des instants déjà passés.
    @Test("Une interruption est reportée sur l'horloge commune")
    func interruptionShiftsSharedClock() async throws {
        let source = ManualCaptureSource()
        let factory = FakeSenderFactory()
        let engine = makeEngine(source: source, factory: factory)
        try await engine.start(source: source0, outputs: [request("a"), request("b")])
        #expect(await eventually { factory.latest("a") != nil && factory.latest("b") != nil })
        let clock = try #require(factory.latest("a")).context.clock
        let other = try #require(factory.latest("b")).context.clock
        source.push(frames: 480)

        let start = Date()
        await engine.tickHealth(now: start)
        let before = try #require(clock.presentationUnixTime(forCaptureFrame: 0))

        // 3 s sans le moindre bloc, puis la reprise.
        await engine.tickHealth(now: start.addingTimeInterval(3))
        let after = try #require(clock.presentationUnixTime(forCaptureFrame: 0))
        #expect(abs((after - before) - 3) < 0.001)
        #expect(abs(await engine.captureHealth.interruptedSeconds - 3) < 0.001)

        // L'horloge étant commune, l'alignement mutuel n'a pas bougé.
        #expect(
            other.presentationUnixTime(forCaptureFrame: 0)
                == clock.presentationUnixTime(forCaptureFrame: 0))
        await engine.stop()
    }

    /// Un gros bloc d'IO peut tomber à cheval sur deux relevés, et la dérive d'horloge s'accumule
    /// lentement : ni l'un ni l'autre n'est une interruption, et reporter l'horloge pour si peu
    /// ferait resynchroniser les récepteurs sans raison.
    @Test("Le rythme normal, gigue comprise, ne touche pas à l'horloge")
    func normalFlowLeavesClockAlone() async throws {
        let source = ManualCaptureSource()
        let factory = FakeSenderFactory()
        let engine = makeEngine(source: source, factory: factory)
        try await engine.start(source: source0, outputs: [request("a")])
        #expect(await eventually { factory.latest("a") != nil })
        let clock = try #require(factory.latest("a")).context.clock

        source.push(frames: 480)
        var now = Date()
        await engine.tickHealth(now: now)
        let before = try #require(clock.presentationUnixTime(forCaptureFrame: 0))

        // Relevés toutes les 250 ms, par blocs de 4 096 trames (85 ms) : selon le relevé, 2 ou
        // 3 blocs sont déjà là, soit jusqu'à 80 ms d'écart en plus ou en moins.
        for tick in 0..<400 {
            now = now.addingTimeInterval(0.25)
            source.push(frames: (tick % 3 == 0 ? 2 : 3) * 4_096)
            await engine.tickHealth(now: now)
        }
        let after = try #require(clock.presentationUnixTime(forCaptureFrame: 0))
        #expect(after == before)
        #expect(await engine.captureHealth.interruptedSeconds == 0)
        await engine.stop()
    }

    /// Le tap ne livre rien tant que rien ne joue : si l'horloge restait figée sur le démarrage,
    /// lancer la musique une minute plus tard annoncerait des instants vieux d'une minute.
    @Test("L'attente du premier son ne laisse pas l'horloge dans le passé")
    func waitingForFirstBlockKeepsClockCurrent() async throws {
        let source = ManualCaptureSource()
        let factory = FakeSenderFactory()
        let engine = makeEngine(source: source, factory: factory)
        try await engine.start(source: source0, outputs: [request("a")])
        #expect(await eventually { factory.latest("a") != nil })
        let clock = try #require(factory.latest("a")).context.clock

        let start = Date()
        for second in 1...60 {
            await engine.tickHealth(now: start.addingTimeInterval(Double(second)))
        }
        let frameZero = try #require(clock.presentationUnixTime(forCaptureFrame: 0))
        // La trame n° 0, qui n'existe pas encore, est attendue à +60 s, plus les 2 s de marge.
        #expect(abs(frameZero - (start.timeIntervalSince1970 + 62)) < 1)
        await engine.stop()
    }
}
