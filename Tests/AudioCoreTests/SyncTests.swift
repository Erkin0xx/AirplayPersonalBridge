import Foundation
import Testing

@testable import AudioCore

// Tests du jalon 4 — synchronisation et dérive (CDC 4.5).
//
// Ce qui est vérifié ici n'est pas de la couverture de lignes : un défaut de
// synchronisation ne provoque ni crash ni exception, il produit un décalage qui s'installe
// lentement et ne se voit qu'à l'oreille, après une demi-heure de lecture. Chaque test
// ci-dessous cible une affirmation précise du CDC 4.5 ou de la section 8.

// MARK: - Ajout/suppression d'un échantillon (technique Snapcast)

/// Horloge de test : origine et délai fixés, aucune dépendance à l'heure réelle.
private struct FixedClock: PlaybackClockProtocol {
    let captureSampleRate: Double
    let playoutDelaySeconds: Double
    let epoch: TimeInterval

    func presentationUnixTime(forCaptureFrame frame: Double) -> TimeInterval? {
        epoch + frame / captureSampleRate + playoutDelaySeconds
    }
}

@Suite("Correction de dérive — un échantillon, avec fondu (CDC 4.5)")
struct SampleSpliceTests {
    private let channels = 2

    /// Signal de test volontairement pénible : une sinusoïde proche de Nyquist, où toute
    /// discontinuité de raccord s'entend et se mesure.
    private func tone(frames: Int, cyclesPerFrame: Double = 0.25) -> [Int16] {
        (0..<frames).flatMap { frame -> [Int16] in
            let value = Int16(20_000 * sin(2 * .pi * cyclesPerFrame * Double(frame)))
            return [value, value]
        }
    }

    @Test("Supprimer une trame rend exactement une trame de moins")
    func removingKeepsExactLength() {
        let input = tone(frames: 353)
        let output = SampleSplice.removingOneFrame(from: input, channelCount: channels)
        #expect(output.count == 352 * channels)
    }

    @Test("Ajouter une trame rend exactement une trame de plus")
    func insertingKeepsExactLength() {
        let input = tone(frames: 351)
        let output = SampleSplice.insertingOneFrame(into: input, channelCount: channels)
        #expect(output.count == 352 * channels)
    }

    /// Le raccord doit être **exact** : passé la fenêtre de fondu, la sortie suit le flux
    /// décalé d'une trame, pas d'un peu moins. C'est ce qui garantit qu'une correction vaut
    /// une trame pleine et que le compte de trames consommées reste juste.
    @Test("Passé le fondu, la sortie suit exactement le flux décalé")
    func spliceIsExactAfterCrossfade() {
        let input = tone(frames: 353)
        let fade = 32
        let output = SampleSplice.removingOneFrame(
            from: input, channelCount: channels, crossfadeFrames: fade
        )
        for frame in (fade + 1)..<352 {
            for channel in 0..<channels {
                #expect(
                    output[frame * channels + channel]
                        == input[(frame + 1) * channels + channel]
                )
            }
        }

        let shorter = tone(frames: 351)
        let expanded = SampleSplice.insertingOneFrame(
            into: shorter, channelCount: channels, crossfadeFrames: fade
        )
        for frame in (fade + 1)..<352 {
            for channel in 0..<channels {
                #expect(
                    expanded[frame * channels + channel]
                        == shorter[(frame - 1) * channels + channel]
                )
            }
        }
    }

    /// Le début du bloc doit rester collé à l'entrée : c'est la continuité avec le paquet
    /// précédent, déjà envoyé et non modifiable.
    @Test("Le début du bloc reste continu avec le paquet précédent")
    func spliceStartsContinuous() {
        let input = tone(frames: 353)
        let output = SampleSplice.removingOneFrame(from: input, channelCount: channels)
        // Un écart d'un pas de fondu au plus, pas un saut d'une trame entière.
        let step = abs(Int(input[0]) - Int(input[channels]))
        #expect(abs(Int(output[0]) - Int(input[0])) <= step / 16 + 1)
    }

    /// **L'exigence explicite du CDC 4.5** : jamais de coupure instantanée. Le fondu doit
    /// réduire franchement la discontinuité par rapport à un raccord brut.
    @Test("Le fondu réduit la discontinuité par rapport à une coupure brute")
    func crossfadeBeatsHardCut() {
        let input = tone(frames: 353)

        // Raccord brut : on jette la trame du milieu et on recolle.
        var hardCut = Array(input[0..<(176 * channels)])
        hardCut.append(contentsOf: input[(177 * channels)...])

        func maxStep(_ samples: [Int16]) -> Int {
            var worst = 0
            for frame in 1..<(samples.count / channels) {
                let delta = abs(
                    Int(samples[frame * channels]) - Int(samples[(frame - 1) * channels])
                )
                worst = max(worst, delta)
            }
            return worst
        }

        let faded = SampleSplice.removingOneFrame(from: input, channelCount: channels)
        // La sinusoïde a son propre pas maximal, qui sert de référence. Le raccord brut le
        // dépasse de moitié au moins — c'est le clic que le CDC 4.5 veut éviter ; le raccord
        // fondu reste dans son voisinage immédiat.
        let naturalStep = maxStep(tone(frames: 352))
        #expect(maxStep(hardCut) >= naturalStep * 3 / 2)
        #expect(maxStep(faded) <= naturalStep * 11 / 10)
    }

    @Test("Les fonctions sont pures : l'entrée n'est jamais modifiée")
    func spliceDoesNotMutateInput() {
        let input = tone(frames: 353)
        let copy = input
        _ = SampleSplice.removingOneFrame(from: input, channelCount: channels)
        _ = SampleSplice.insertingOneFrame(into: input, channelCount: channels)
        #expect(input == copy)
    }
}

// MARK: - Horloge de restitution commune

@Suite("Horloge de restitution commune (CDC 4.5)")
struct PlaybackClockTests {
    @Test("Une trame de capture donne le même instant à qui la demande")
    func sameFrameSameInstant() {
        let clock = SharedPlaybackClock(captureSampleRate: 48_000, playoutDelaySeconds: 2)
        clock.startIfNeeded()
        let first = clock.presentationUnixTime(forCaptureFrame: 96_000)
        let second = clock.presentationUnixTime(forCaptureFrame: 96_000)
        #expect(first == second)
    }

    @Test("Deux secondes de trames valent deux secondes d'horloge")
    func frameToTimeConversion() {
        let clock = SharedPlaybackClock(captureSampleRate: 48_000, playoutDelaySeconds: 2)
        clock.startIfNeeded()
        guard let start = clock.presentationUnixTime(forCaptureFrame: 0),
            let later = clock.presentationUnixTime(forCaptureFrame: 96_000)
        else {
            Issue.record("horloge non démarrée")
            return
        }
        #expect(abs((later - start) - 2.0) < 1e-5)
    }

    /// Réancrer l'horloge en cours de route décalerait les deux sorties l'une par rapport à
    /// l'autre : c'est exactement ce que cette classe existe pour empêcher.
    @Test("L'origine ne bouge plus une fois posée")
    func startIsIdempotent() async throws {
        let clock = SharedPlaybackClock(captureSampleRate: 48_000)
        clock.startIfNeeded()
        let first = clock.presentationUnixTime(forCaptureFrame: 0)
        try await Task.sleep(for: .milliseconds(20))
        clock.startIfNeeded()
        #expect(clock.presentationUnixTime(forCaptureFrame: 0) == first)
    }

    @Test("Sans démarrage, aucune date n'est inventée")
    func noAnchorBeforeStart() {
        let clock = SharedPlaybackClock(captureSampleRate: 48_000)
        #expect(clock.hasStarted == false)
        #expect(clock.presentationUnixTime(forCaptureFrame: 0) == nil)
    }

    /// L'origine doit correspondre à la trame n° 0, pas à l'instant de création : la capture
    /// tourne déjà quand l'horloge est posée.
    @Test("L'origine remonte aux trames déjà capturées")
    func anchorAccountsForFramesAlreadyCaptured() {
        let now = Date().timeIntervalSince1970
        let clock = SharedPlaybackClock(captureSampleRate: 48_000, playoutDelaySeconds: 0)
        clock.startIfNeeded(framesAlreadyWritten: 48_000)
        guard let zero = clock.presentationUnixTime(forCaptureFrame: 0) else {
            Issue.record("horloge non démarrée")
            return
        }
        // La trame 0 a été captée il y a environ une seconde.
        #expect(abs((now - zero) - 1.0) < 0.5)
    }
}

// MARK: - Mesure par le canal de timing natif

@Suite("Mesure de décalage par le canal de timing (CDC 4.5)")
struct TimingEstimatorTests {
    @Test("Sans échantillon, la mesure est absente et non nulle")
    func noEstimateWithoutSamples() {
        let estimator = TimingEstimator()
        let snapshot = estimator.snapshot()
        #expect(snapshot.offsetSeconds == nil)
        #expect(snapshot.sampleCount == 0)
    }

    /// Le filtre est un minimum, pas une moyenne : l'échantillon le moins retardé par la
    /// file d'attente est le plus proche du décalage d'horloge réel.
    @Test("Le décalage retenu est le minimum de la fenêtre")
    func minimumFiltersQueueingDelay() {
        let estimator = TimingEstimator()
        // Décalage réel de 10 ms, pollué par des délais de trajet variables.
        for extra in [0.004, 0.031, 0.012, 0.001, 0.020] {
            estimator.record(remoteTransmitUnix: 1_000, localReceiveUnix: 1_000.010 + extra)
        }
        let snapshot = estimator.snapshot()
        #expect(snapshot.sampleCount == 5)
        guard let offset = snapshot.offsetSeconds, let spread = snapshot.spreadSeconds else {
            Issue.record("mesure absente")
            return
        }
        #expect(abs(offset - 0.011) < 1e-6)
        #expect(abs(spread - 0.030) < 1e-6)
    }

    /// Régression du jalon 4 : shairport-sync 5.2.1 envoie ses requêtes de timing
    /// **intégralement à zéro** (vérifié en capture). L'estampille lue vaut alors l'époque
    /// NTP, et une soustraction naïve annonçait un décalage de 3 995 042 823 685 ms. Une
    /// mesure absente doit rester absente, jamais devenir un nombre absurde.
    @Test("Une requête non horodatée ne produit pas un décalage absurde")
    func unstampedRequestsAreRejected() {
        let estimator = TimingEstimator()
        let now: TimeInterval = 1_786_000_000
        // Estampille à zéro : NTP 0 correspond à 1900, soit −2 208 988 800 en temps Unix.
        for _ in 0..<5 {
            estimator.record(remoteTransmitUnix: -NTPTime.epochOffset, localReceiveUnix: now)
        }
        let snapshot = estimator.snapshot(now: now)
        #expect(snapshot.offsetSeconds == nil)
        #expect(snapshot.spreadSeconds == nil)
        // Le signal de vie, lui, reste valide : les requêtes ont bien été reçues.
        #expect(snapshot.sampleCount == 5)
        #expect(snapshot.unstampedCount == 5)
        #expect(snapshot.secondsSinceLastSample == 0)
    }

    @Test("Une requête horodatée reste mesurée malgré les requêtes muettes")
    func stampedRequestsSurviveUnstampedOnes() {
        let estimator = TimingEstimator()
        let now: TimeInterval = 1_786_000_000
        estimator.record(remoteTransmitUnix: -NTPTime.epochOffset, localReceiveUnix: now)
        estimator.record(remoteTransmitUnix: now - 0.004, localReceiveUnix: now)
        let snapshot = estimator.snapshot(now: now)
        #expect(snapshot.sampleCount == 2)
        #expect(snapshot.unstampedCount == 1)
        guard let offset = snapshot.offsetSeconds else {
            Issue.record("mesure absente")
            return
        }
        #expect(abs(offset - 0.004) < 1e-6)
    }

    @Test("L'âge du dernier échantillon est exposé — c'est le signal de vie")
    func reportsSampleAge() {
        let estimator = TimingEstimator()
        estimator.record(remoteTransmitUnix: 1_000, localReceiveUnix: 1_000)
        let snapshot = estimator.snapshot(now: 1_042)
        #expect(snapshot.secondsSinceLastSample == 42)
    }
}

// MARK: - Alignement et pilotage de la dérive

@Suite("Alignement automatique et correction de dérive (CDC 4.5)")
struct OutputSynchronizerTests {
    private let outputRate: Double = 44_100
    private let packetFrames = ALACEncoder.framesPerPacket

    private func makeClock() -> FixedClock {
        FixedClock(captureSampleRate: 48_000, playoutDelaySeconds: 2, epoch: 1_000_000)
    }

    private func settle(_ synchronizer: OutputSynchronizer, delayFrames: Double) {
        // La stabilisation dure 10 s ; à 352 trames par paquet, ~1 254 paquets suffisent.
        for _ in 0..<1_400 {
            _ = synchronizer.observe(pipelineDelayOutputFrames: delayFrames)
            synchronizer.didConsume(outputFrames: packetFrames)
        }
    }

    @Test("Aucune correction pendant la phase de stabilisation")
    func noCorrectionWhileSettling() {
        let synchronizer = OutputSynchronizer(
            label: "test", clock: makeClock(), outputSampleRate: outputRate
        )
        synchronizer.beginStreaming(atCaptureFrame: 0)
        for _ in 0..<100 {
            #expect(synchronizer.observe(pipelineDelayOutputFrames: 4_000) == .none)
        }
        #expect(synchronizer.snapshot().targetDelaySeconds == nil)
    }

    @Test("La consigne est observée, pas décrétée")
    func targetIsMeasured() {
        let synchronizer = OutputSynchronizer(
            label: "test", clock: makeClock(), outputSampleRate: outputRate
        )
        synchronizer.beginStreaming(atCaptureFrame: 0)
        settle(synchronizer, delayFrames: 4_410)
        guard let target = synchronizer.snapshot().targetDelaySeconds else {
            Issue.record("consigne non arrêtée")
            return
        }
        #expect(abs(target - 0.1) < 0.001)
    }

    /// Un arriéré qui enfle veut dire que la restitution prend du retard : il faut supprimer
    /// des trames pour rattraper. Le sens inverse doit être vrai aussi — un signe inversé
    /// ferait diverger la boucle au lieu de la ramener.
    @Test("Le sens de la correction suit le sens de la dérive")
    func correctionFollowsDriftDirection() {
        let clock = makeClock()
        let ahead = OutputSynchronizer(label: "a", clock: clock, outputSampleRate: outputRate)
        ahead.beginStreaming(atCaptureFrame: 0)
        settle(ahead, delayFrames: 4_410)

        var removals = 0
        for _ in 0..<4_000 {
            if ahead.observe(pipelineDelayOutputFrames: 8_000) == .removeFrame { removals += 1 }
            ahead.didConsume(outputFrames: packetFrames)
        }
        #expect(removals > 0)

        let behind = OutputSynchronizer(label: "b", clock: clock, outputSampleRate: outputRate)
        behind.beginStreaming(atCaptureFrame: 0)
        settle(behind, delayFrames: 4_410)

        var insertions = 0
        for _ in 0..<4_000 {
            if behind.observe(pipelineDelayOutputFrames: 1_000) == .insertFrame { insertions += 1 }
            behind.didConsume(outputFrames: packetFrames)
        }
        #expect(insertions > 0)
    }

    /// Corriger dans le bruit de mesure ferait osciller la boucle sans rien gagner : la
    /// bande morte est à 1,45 ms, un vingtième du seuil de perception du CDC section 8.
    @Test("Un écart dans la bande morte ne déclenche rien")
    func deadbandSuppressesNoise() {
        let synchronizer = OutputSynchronizer(
            label: "test", clock: makeClock(), outputSampleRate: outputRate
        )
        synchronizer.beginStreaming(atCaptureFrame: 0)
        settle(synchronizer, delayFrames: 4_410)

        var corrections = 0
        for step in 0..<2_000 {
            // ±20 trames autour de la consigne : bien en deçà des 64 trames de bande morte.
            let jitter = Double((step % 2 == 0) ? 20 : -20)
            if synchronizer.observe(pipelineDelayOutputFrames: 4_410 + jitter) != .none {
                corrections += 1
            }
            synchronizer.didConsume(outputFrames: packetFrames)
        }
        #expect(corrections == 0)
    }

    /// **Le cœur du jalon.** Deux sorties qui partagent l'horloge doivent annoncer le même
    /// instant de restitution pour la même trame captée — sans jamais se connaître.
    @Test("Deux sorties sur la même horloge s'alignent sur la même trame")
    func twoOutputsAgreeOnPresentationInstant() {
        let clock = makeClock()
        let raop = OutputSynchronizer(label: "raop", clock: clock, outputSampleRate: outputRate)
        let airplay2 = OutputSynchronizer(label: "ap2", clock: clock, outputSampleRate: outputRate)

        // Les deux démarrent à des instants différents et n'ont pas consommé autant : c'est
        // le cas réel, la négociation AirPlay 2 étant bien plus longue que celle de RAOP.
        raop.beginStreaming(atCaptureFrame: 48_000)
        airplay2.beginStreaming(atCaptureFrame: 240_000)
        for _ in 0..<2_000 { raop.didConsume(outputFrames: packetFrames) }

        // On amène les deux sur la même trame de capture, puis on compare leurs ancrages.
        guard let raopFrame = raop.currentCaptureFrame else {
            Issue.record("flux non ancré")
            return
        }
        let delta = raopFrame - 240_000
        #expect(delta > 0)
        airplay2.didConsume(outputFrames: Int((delta * outputRate / clock.captureSampleRate).rounded()))

        guard let a = raop.syncAnchorUnixTime(latencyFrames: 88_200),
            let b = airplay2.syncAnchorUnixTime(latencyFrames: 88_200)
        else {
            Issue.record("ancrage indisponible")
            return
        }
        // Moins d'une trame de sortie d'écart : l'alignement est exact à l'arrondi près,
        // soit 23 µs — trois ordres de grandeur sous le seuil de perception du CDC 8.
        #expect(abs(a - b) < 1.0 / outputRate)
    }

    /// L'ancrage doit dire « cette estampille, moins la latence annoncée, se joue
    /// maintenant » : c'est l'interprétation qu'en fait le récepteur.
    @Test("L'ancrage retranche exactement la latence annoncée")
    func anchorSubtractsAnnouncedLatency() {
        let clock = makeClock()
        let synchronizer = OutputSynchronizer(
            label: "test", clock: clock, outputSampleRate: outputRate
        )
        synchronizer.beginStreaming(atCaptureFrame: 0)
        guard let anchor = synchronizer.syncAnchorUnixTime(latencyFrames: 88_200),
            let presentation = clock.presentationUnixTime(forCaptureFrame: 0)
        else {
            Issue.record("ancrage indisponible")
            return
        }
        #expect(abs((presentation - anchor) - 88_200 / outputRate) < 1e-6)
    }

    /// Le réglage manuel est un fine-tune, pas un mécanisme parallèle : il se lit dans
    /// l'ancrage, en plus de l'alignement automatique, et n'altère aucun échantillon.
    @Test("Le réglage manuel décale l'ancrage d'exactement sa valeur")
    func manualOffsetShiftsAnchor() {
        let synchronizer = OutputSynchronizer(
            label: "test", clock: makeClock(), outputSampleRate: outputRate
        )
        synchronizer.beginStreaming(atCaptureFrame: 0)
        guard let neutral = synchronizer.syncAnchorUnixTime(latencyFrames: 88_200) else {
            Issue.record("ancrage indisponible")
            return
        }
        synchronizer.manualOffsetSeconds = 0.030
        guard let delayed = synchronizer.syncAnchorUnixTime(latencyFrames: 88_200) else {
            Issue.record("ancrage indisponible")
            return
        }
        #expect(abs((delayed - neutral) - 0.030) < 1e-6)
    }

    /// Une correction déplace le flux d'une trame : le compte doit le refléter, sinon
    /// l'ancrage dériverait d'une trame à chaque correction.
    @Test("Une trame corrigée déplace la position du flux d'une trame")
    func correctionMovesStreamPosition() {
        let clock = makeClock()
        let synchronizer = OutputSynchronizer(
            label: "test", clock: clock, outputSampleRate: outputRate
        )
        synchronizer.beginStreaming(atCaptureFrame: 0)
        guard let before = synchronizer.currentCaptureFrame else {
            Issue.record("flux non ancré")
            return
        }
        synchronizer.didConsume(outputFrames: packetFrames + 1)
        guard let after = synchronizer.currentCaptureFrame else {
            Issue.record("flux non ancré")
            return
        }
        let expected = Double(packetFrames + 1) * clock.captureSampleRate / outputRate
        #expect(abs((after - before) - expected) < 1e-6)
    }

    /// Sans horloge démarrée (sortie unique hors contexte du jalon 4), l'ancrage doit être
    /// absent plutôt qu'inventé : l'appelant retombe alors sur « maintenant », comportement
    /// validé au jalon 2.
    @Test("Sans diffusion démarrée, aucun ancrage n'est fabriqué")
    func noAnchorBeforeStreaming() {
        let synchronizer = OutputSynchronizer(
            label: "test", clock: makeClock(), outputSampleRate: outputRate
        )
        #expect(synchronizer.syncAnchorUnixTime(latencyFrames: 88_200) == nil)
        #expect(synchronizer.currentCaptureFrame == nil)
    }
}

// MARK: - Horloge de capture partagée par les deux pipelines

@Suite("Graduation de capture commune (invariant section 12)")
struct CaptureTimelineTests {
    /// Les deux ring buffers sont alimentés par le **même** callback : leurs compteurs
    /// d'écriture avancent donc de concert. C'est ce qui donne aux deux sorties une
    /// référence commune sans qu'aucune ne connaisse l'autre.
    @Test("Deux pipelines alimentés ensemble portent la même graduation")
    func bothPipelinesShareTheSameTimeline() {
        let first = AudioRingBuffer(capacityFrames: 4_096, channelCount: 2)
        let second = AudioRingBuffer(capacityFrames: 4_096, channelCount: 2)
        let block = [Float](repeating: 0.25, count: 512 * 2)

        for _ in 0..<3 {
            block.withUnsafeBufferPointer { buffer in
                guard let base = buffer.baseAddress else { return }
                first.write(from: base, frameCount: 512)
                second.write(from: base, frameCount: 512)
            }
        }
        #expect(first.totalFramesWritten == 1_536)
        #expect(first.totalFramesWritten == second.totalFramesWritten)

        // Les consommateurs, eux, avancent indépendamment : une sortie qui draine n'avance
        // pas la lecture de l'autre.
        var scratch = [Float](repeating: 0, count: 512 * 2)
        scratch.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            first.read(into: base, frameCount: 512)
        }
        #expect(first.totalFramesRead == 512)
        #expect(second.totalFramesRead == 0)
        #expect(second.availableFrames == 1_536)
    }
}
