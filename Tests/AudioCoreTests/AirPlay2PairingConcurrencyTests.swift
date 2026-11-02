import Foundation
import Testing

@testable import AudioCore

// Le défaut relevé sur la paire stéréo « Salon » / « Salon (2) » : deux pair-setups transitoires
// partis dans la même milliseconde, l'un refusé à M4, et la sortie abandonnée pour de bon. Deux
// corrections, testées séparément : le refus transitoire est réessayé et passager, et deux
// pair-setups d'un même moteur ne partent plus jamais ensemble.

/// Un refus qui ne vaut que pour les `count` premières occurrences.
private final class Countdown: @unchecked Sendable {
    private let lock = NSLock()
    private var remaining: Int

    init(_ count: Int) { remaining = count }

    /// Vrai tant qu'il reste des refus à servir, et en consomme un.
    func take() -> Bool {
        lock.withLock {
            guard remaining > 0 else { return false }
            remaining -= 1
            return true
        }
    }
}

/// Ordre d'entrée et nombre de détenteurs simultanés, vus de l'intérieur du tour.
private final class TurnLog: @unchecked Sendable {
    private let lock = NSLock()
    private var holders = 0
    private(set) var maximumHolders = 0
    private(set) var order: [Int] = []

    func enter(_ id: Int) {
        lock.withLock {
            holders += 1
            maximumHolders = max(maximumHolders, holders)
            order.append(id)
        }
    }

    func leave() { lock.withLock { holders -= 1 } }

    var snapshot: (maximum: Int, order: [Int]) { lock.withLock { (maximumHolders, order) } }
}

private typealias Script = @Sendable (FakeAirPlay2Receiver.Request, Int) -> FakeAirPlay2Receiver.Action

/// Le pair-setup répond `action` à l'étape `state`, les `times` premières fois.
private func refusing(
    _ action: FakeAirPlay2Receiver.Action, at state: PairingTLV8.State, times: Int = .max
) -> Script {
    let countdown = Countdown(times)
    // La valeur brute : l'étape elle-même n'est pas `Sendable`.
    let step = state.rawValue
    return { request, _ in
        guard request.uri == "/pair-setup", request.pairingState?.rawValue == step, countdown.take()
        else {
            return .normal
        }
        return action
    }
}

/// M1 retardé : un pair-setup qui dure, comme sur un HomePod qui calcule sa réponse SRP. Deux
/// pair-setups lancés ensemble se chevauchent alors à coup sûr, s'ils ne sont pas sérialisés.
private let slowPairSetup: Script = { request, _ in
    request.uri == "/pair-setup" && request.pairingState == .m1 ? .delayed(0.25) : .normal
}

private func makeReceiver(script: Script? = nil) async throws -> FakeAirPlay2Receiver {
    let receiver = FakeAirPlay2Receiver()
    try await receiver.start()
    receiver.script = script
    return receiver
}

/// Les intervalles de pair-setup vus par les récepteurs, du plus ancien au plus récent.
private func spans(_ receivers: [FakeAirPlay2Receiver]) -> [FakeAirPlay2Receiver.PairSetupSpan] {
    receivers.flatMap { $0.pairSetupSpans() }.sorted { $0.start < $1.start }
}

/// Deux intervalles qui se chevauchent : le second a commencé avant la fin du premier.
private func overlaps(_ spans: [FakeAirPlay2Receiver.PairSetupSpan]) -> Int {
    zip(spans, spans.dropFirst()).filter { first, second in
        guard let end = first.end else { return true }
        return second.start < end
    }.count
}

// MARK: - Suite parente

/// Les trois suites ci-dessous, **une à la fois** : chacune enchaîne des pair-setups SRP 3072 bits
/// et des sessions qui diffusent. Menées en parallèle, elles chargeaient assez la machine pour faire
/// manquer leur échéance à des tests de cadence d'autres suites (`burstDoesNotDelayAudio`,
/// `fermetureApresRecord`), qui passent seuls comme sans elles.
@Suite("AirPlay 2 — pairing concurrent et refus transitoire", .serialized)
struct AirPlay2PairingConcurrencyTests {}

// MARK: - Le tour lui-même

extension AirPlay2PairingConcurrencyTests {
    @Suite("AirPlay 2 — tour de pairing")
    struct AirPlay2PairingGateTests {

        @Test("Un seul détenteur à la fois, dans l'ordre d'arrivée")
        func exclusionEtOrdre() async throws {
            let gate = SerialPairingGate()
            let log = TurnLog()
            try await gate.acquire()

            var tasks: [Task<Void, Error>] = []
            for id in 0..<5 {
                tasks.append(Task {
                    try await gate.acquire()
                    log.enter(id)
                    try? await Task.sleep(for: .milliseconds(5))
                    log.leave()
                    gate.release()
                })
                // Chacun inscrit avant le suivant : l'ordre d'arrivée est alors connu.
                #expect(await waitUntil(timeout: .seconds(2)) { gate.waitingCount == id + 1 })
            }
            gate.release()
            for task in tasks { try await task.value }

            let result = log.snapshot
            #expect(result.maximum == 1)
            #expect(result.order == [0, 1, 2, 3, 4])
            #expect(gate.waitingCount == 0)
            // Rendu : il se reprend aussitôt.
            try await gate.acquire()
            gate.release()
        }

        @Test("Une attente annulée ne prend pas le tour, et le laisse au suivant")
        func attenteAnnulee() async throws {
            let gate = SerialPairingGate()
            let log = TurnLog()
            try await gate.acquire()

            let cancelled = Task {
                try await gate.acquire()
                log.enter(1)
                gate.release()
            }
            #expect(await waitUntil(timeout: .seconds(2)) { gate.waitingCount == 1 })
            let next = Task {
                try await gate.acquire()
                log.enter(2)
                gate.release()
            }
            #expect(await waitUntil(timeout: .seconds(2)) { gate.waitingCount == 2 })

            cancelled.cancel()
            await #expect(throws: CancellationError.self) { try await cancelled.value }
            #expect(gate.waitingCount == 1)

            gate.release()
            try await next.value
            #expect(log.snapshot.order == [2])
        }

        @Test("Une tâche déjà annulée n'attend pas, et ne prend pas le tour")
        func dejaAnnulee() async throws {
            let gate = SerialPairingGate()
            let task = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                try await gate.acquire()
            }
            await #expect(throws: CancellationError.self) { try await task.value }
            // Le tour est resté libre.
            try await gate.acquire()
            gate.release()
        }
    }
}

// MARK: - Le refus transitoire

extension AirPlay2PairingConcurrencyTests {
    @Suite("AirPlay 2 — pair-setup transitoire refusé")
    struct AirPlay2TransientRefusalTests {

        /// Le cas relevé sur le HomePod : un TLV d'erreur « authentification » en réponse à M3. La
        /// sortie partait en `failed`, définitivement ; le pair-setup suivant aurait abouti.
        @Test("Un refus d'authentification à M4 est réessayé, et la session aboutit")
        func refusUniqueRattrape() async throws {
            let receiver = try await makeReceiver(
                script: refusing(.pairingError(.authentication), at: .m3, times: 1))
            defer { receiver.stop() }
            let harness = try SenderHarness(receiver: receiver)
            defer { harness.feeder.stop() }

            try await harness.sender.start(volume: -20)

            #expect(await harness.sender.state == .streaming)
            #expect(receiver.sessionCount == 2)
            let statistics = await harness.sender.statistics
            #expect(statistics.transientPairingRetries == 1)
            #expect(statistics.lastFailure == nil)
            #expect(await waitUntil { receiver.audioPackets(inSession: 1).count >= 5 })

            // Le nouvel essai attend de 200 à 800 ms après le refus : de quoi désynchroniser deux
            // sorties refusées ensemble.
            let refusedAt = try #require(receiver.pairSetupSpans().first?.end)
            let retriedAt = try #require(receiver.acceptedAt(session: 1))
            #expect(retriedAt - refusedAt >= .milliseconds(195), "\(retriedAt - refusedAt)")
            #expect(retriedAt - refusedAt < .seconds(2), "\(retriedAt - refusedAt)")
            await harness.sender.stop()
        }

        /// Le même refus en réponse à M1, et une preuve du récepteur qui ne vérifie pas : tous deux
        /// relèvent de l'authentification SRP, et aucun ne vient d'un code saisi.
        @Test("Un refus à M2 et une preuve invalide sont réessayés de même")
        func autresEchecsSRP() async throws {
            let cases: [(Script, String)] = [
                (refusing(.pairingError(.authentication), at: .m1, times: 1), "M2"),
                (refusing(.invalidServerProof, at: .m3, times: 1), "M4"),
            ]
            for (script, step) in cases {
                let receiver = try await makeReceiver(script: script)
                defer { receiver.stop() }
                let harness = try SenderHarness(receiver: receiver)
                defer { harness.feeder.stop() }

                try await harness.sender.start(volume: -20)
                #expect(await harness.sender.state == .streaming, "\(step)")
                #expect(receiver.sessionCount == 2, "\(step)")
                #expect(await harness.sender.statistics.transientPairingRetries == 1, "\(step)")
                await harness.sender.stop()
            }
        }

        /// Au-delà des nouveaux essais, l'échec rendu au moteur est passager : il réessaie avec son
        /// repli, au lieu de laisser l'enceinte muette jusqu'à ce qu'on la décoche.
        @Test("Un refus répété est réessayé trois fois, puis rendu comme passager")
        func refusRepete() async throws {
            for (state, step) in [(PairingTLV8.State.m3, "M4"), (.m1, "M2")] {
                let receiver = try await makeReceiver(
                    script: refusing(.pairingError(.authentication), at: state))
                defer { receiver.stop() }
                let harness = try SenderHarness(receiver: receiver)
                defer { harness.feeder.stop() }
                await harness.sender.setPairingRetryPolicy(.init(retries: 3, delayMilliseconds: 1...5))

                await #expect(
                    throws: AirPlay2SenderError.transientPairingRejected(
                        receiver: "Récepteur simulé", step: step)
                ) {
                    try await harness.sender.start(volume: -20)
                }
                // Le premier essai et trois nouveaux, chacun sur une connexion neuve.
                #expect(receiver.sessionCount == 4, "\(step)")
                #expect(await harness.sender.statistics.transientPairingRetries == 3, "\(step)")

                let failure = AirPlay2SenderError.transientPairingRejected(
                    receiver: "Récepteur simulé", step: step)
                #expect(await harness.sender.statistics.lastFailure == failure.description)
                #expect(!failure.isPermanent)
                #expect(!isPermanentOutputFailure(failure))
                #expect(failure.description.contains(step))
                #expect(!failure.description.contains("code de pairing erroné"))
                #expect(!failure.description.contains("atvremote"))
                #expect(!failure.description.contains("--credentials2"))
            }
        }

        @Test("stop() pendant l'attente d'un nouveau pair-setup rend la main aussitôt")
        func stopPendantAttente() async throws {
            let receiver = try await makeReceiver(
                script: refusing(.pairingError(.authentication), at: .m3))
            defer { receiver.stop() }
            let harness = try SenderHarness(receiver: receiver)
            defer { harness.feeder.stop() }
            await harness.sender.setPairingRetryPolicy(.init(retries: 3, delayMilliseconds: 3_000...3_000))

            let sender = harness.sender
            let task = Task { try await sender.start(volume: -20) }
            #expect(await waitUntil { await sender.statistics.transientPairingRetries == 1 })
            let start = ContinuousClock.now
            await sender.stop()
            let result = await task.result
            #expect(ContinuousClock.now - start < .milliseconds(500))
            #expect(throws: CancellationError.self) { try result.get() }
            #expect(await sender.state == .idle)
            try await Task.sleep(for: .milliseconds(300))
            #expect(receiver.sessionCount == 1)
        }

        /// Avec des credentials, un refus d'authentification au `pair-verify` désigne bien des
        /// credentials périmés ou étrangers : il reste définitif, sans nouvel essai.
        @Test("Un pair-verify refusé reste définitif, sans nouvel essai")
        func pairVerifyRefuse() async throws {
            let identity = SimulatedIdentity.random(identifier: "96A1F186-3B44-4AFC-9E53-3F2DEC7B6B01")
            let client = try Ed25519KeyPair()
            let stranger = try Ed25519KeyPair()
            let clientIdentifier = Data("D2A1E8C0-0000-4000-8000-1234567890AB".utf8)
            var options = FakeAirPlay2Receiver.Options()
            options.transientEnabled = false
            options.identity = identity
            // L'accessoire en connaît un autre : notre signature M3 ne vérifie pas.
            options.pairedClient = (clientIdentifier, stranger.publicKey)
            let receiver = FakeAirPlay2Receiver(options: options)
            try await receiver.start()
            defer { receiver.stop() }

            let credentials = HapCredentials(
                receiverPublicKey: try identity.publicKey,
                clientSecretSeed: client.seed,
                receiverIdentifier: identity.identifier,
                clientIdentifier: clientIdentifier
            )
            let harness = try SenderHarness(receiver: receiver, credentials: credentials)
            defer { harness.feeder.stop() }

            do {
                try await harness.sender.start(volume: -20)
                Issue.record("la session aurait dû échouer")
            } catch let error as AirPlay2SenderError {
                guard case .credentialsRejected = error else {
                    Issue.record("mauvaise erreur : \(error)")
                    return
                }
                #expect(error.isPermanent)
                #expect(isPermanentOutputFailure(error))
            }
            #expect(receiver.sessionCount == 1)
            #expect(await harness.sender.statistics.transientPairingRetries == 0)
        }

        /// Le partage permanent / passager, sur les erreurs brutes comme sur leur traduction : 470, 401
        /// et un pair-verify refusé restent définitifs, un échec SRP transitoire ne l'est plus.
        @Test("Classement : 470, 401 et pair-verify définitifs, échec SRP transitoire passager")
        func classement() {
            func translated(_ error: Error, credentials: Bool = false) -> AirPlay2SenderError {
                AirPlay2SenderError(
                    classifying: error, receiver: "R", address: "a", hasCredentials: credentials)
            }

            for code in [401, 470] {
                let pairing = AirPlay2PairingSession.Failure.authorizationRequired(status: code, step: "M1")
                #expect(isPermanentOutputFailure(pairing), "\(code)")
                #expect(translated(pairing).isPermanent, "\(code)")
                #expect(isPermanentOutputFailure(translated(pairing)), "\(code)")
                let session = RTSPError.unexpectedStatus(method: "SETUP", code: code, reason: "")
                #expect(isPermanentOutputFailure(session), "\(code)")
                #expect(translated(session).isPermanent, "\(code)")
            }

            // Le pair-verify refusé : TLV d'erreur « authentification », avec des credentials.
            let verify = AirPlay2PairingSession.Failure.receiverRejected(.authentication, step: "verify-M3")
            #expect(isPermanentOutputFailure(verify))
            #expect(translated(verify, credentials: true) == .credentialsRejected(
                receiver: "R", detail: PairingTLV8.PairingError.authentication.description))
            #expect(translated(verify, credentials: true).isPermanent)

            for (step, reason) in [
                ("M4", "TLV d'erreur « authentification »"), ("M2", "TLV d'erreur « authentification »"),
                ("M4", "preuve du récepteur invalide"),
            ] {
                let transient = AirPlay2PairingSession.Failure.transientAuthenticationFailed(
                    step: step, reason: reason)
                #expect(!isPermanentOutputFailure(transient), "\(step) \(reason)")
                let readable = translated(transient)
                #expect(readable == .transientPairingRejected(receiver: "R", step: step))
                #expect(!readable.isPermanent)
                #expect(!isPermanentOutputFailure(readable))
                #expect(!transient.description.contains("code de pairing erroné"))
            }
        }
    }
}

// MARK: - Les pair-setups concurrents

extension AirPlay2PairingConcurrencyTests {
    @Suite("AirPlay 2 — pair-setups concurrents")
    struct AirPlay2ConcurrentPairingTests {
        /// `tsid` relevé sur les deux HomePod de la paire.
        private static let pairID = "D6058176-6F7F-50E4-BA1D-DD08AA4B44A3"

        /// Le témoin : sans tour commun, deux pair-setups lancés ensemble se chevauchent, et le
        /// récepteur simulé le voit. Sans lui, le test suivant pourrait passer à vide.
        @Test("Sans tour commun, deux pair-setups lancés ensemble se chevauchent")
        func temoinSansTour() async throws {
            let salon = try await makeReceiver(script: slowPairSetup)
            let salon2 = try await makeReceiver(script: slowPairSetup)
            defer {
                salon.stop()
                salon2.stop()
            }
            let first = try SenderHarness(receiver: salon, name: "Salon")
            let second = try SenderHarness(receiver: salon2, name: "Salon (2)")
            defer {
                first.feeder.stop()
                second.feeder.stop()
            }

            async let a: Void = first.sender.start(volume: -20)
            async let b: Void = second.sender.start(volume: -20)
            _ = try await (a, b)
            await first.sender.stop()
            await second.sender.stop()

            #expect(overlaps(spans([salon, salon2])) == 1)
        }

        @Test("Deux senders qui partagent le tour ne font jamais leurs pair-setups ensemble")
        func sendersSerialises() async throws {
            let salon = try await makeReceiver(script: slowPairSetup)
            let salon2 = try await makeReceiver(script: slowPairSetup)
            defer {
                salon.stop()
                salon2.stop()
            }
            let gate = SerialPairingGate()
            let first = try SenderHarness(receiver: salon, name: "Salon", pairingGate: gate)
            let second = try SenderHarness(receiver: salon2, name: "Salon (2)", pairingGate: gate)
            defer {
                first.feeder.stop()
                second.feeder.stop()
            }

            async let a: Void = first.sender.start(volume: -20)
            async let b: Void = second.sender.start(volume: -20)
            _ = try await (a, b)
            #expect(await first.sender.state == .streaming)
            #expect(await second.sender.state == .streaming)
            await first.sender.stop()
            await second.sender.stop()

            let observed = spans([salon, salon2])
            #expect(observed.count == 2)
            #expect(observed.allSatisfy { $0.end != nil })
            #expect(overlaps(observed) == 0)
        }

        /// Ce que fait l'application, et le CLI avec deux `--airplay2` : un moteur, deux sorties
        /// démarrées ensemble. C'est le moteur qui doit leur donner le même tour.
        @Test("Deux sorties d'un même moteur : pair-setups successifs, et les deux diffusent")
        func moteurSerialise() async throws {
            let salon = try await makeReceiver(script: slowPairSetup)
            let salon2 = try await makeReceiver(script: slowPairSetup)
            defer {
                salon.stop()
                salon2.stop()
            }
            let devices = [
                "Salon": salon.device(name: "Salon", txt: ["tsid": Self.pairID]),
                "Salon (2)": salon2.device(name: "Salon (2)", txt: ["tsid": Self.pairID]),
            ]
            var dependencies = BridgeEngine.Dependencies.live
            dependencies.senderFactory = LiveOutputSenderFactory(
                findRAOP: { name, _, _ in throw RAOPDiscoveryError.notFound(name: name, seen: []) },
                findAirPlay2: { name, _, _ in
                    guard let device = devices[name] else {
                        throw AirPlay2DiscoveryError.notFound(name: name, seen: [])
                    }
                    return device
                }
            )
            dependencies.tuning.monitorInterval = .milliseconds(20)
            let engine = BridgeEngine(dependencies: dependencies)
            let outputs = ["Salon", "Salon (2)"].map {
                BridgeEngine.OutputRequest(
                    id: "airplay2/\($0)", proto: .airplay2, deviceName: $0, volumeDB: -30)
            }

            try await engine.start(source: .tone(frequency: 440, levelDBFS: -50), outputs: outputs)
            for output in outputs {
                #expect(await eventually(timeout: .seconds(15)) {
                    await engine.phase(of: output.id) == .streaming
                }, "\(output.id)")
            }
            await engine.stop()

            let observed = spans([salon, salon2])
            #expect(observed.count == 2)
            #expect(overlaps(observed) == 0)
            #expect(salon.devicePairSetupCount == 1)
            #expect(salon2.devicePairSetupCount == 1)
        }

        /// Le défaut tel qu'il se présentait : un refus à M4 pour l'une des deux sorties. Elle ne passe
        /// plus en `failed`, et finit par diffuser comme l'autre.
        @Test("Une sortie refusée à M4 ne passe pas en échec, et diffuse")
        func moteurSortieRefusee() async throws {
            let salon = try await makeReceiver(
                script: refusing(.pairingError(.authentication), at: .m3, times: 1))
            defer { salon.stop() }
            var dependencies = BridgeEngine.Dependencies.live
            dependencies.senderFactory = LiveOutputSenderFactory(
                findRAOP: { name, _, _ in throw RAOPDiscoveryError.notFound(name: name, seen: []) },
                findAirPlay2: { _, _, _ in salon.device(name: "Salon") }
            )
            dependencies.tuning.monitorInterval = .milliseconds(20)
            let engine = BridgeEngine(dependencies: dependencies)
            let output = BridgeEngine.OutputRequest(
                id: "airplay2/Salon", proto: .airplay2, deviceName: "Salon", volumeDB: -30)

            try await engine.start(source: .tone(frequency: 440, levelDBFS: -50), outputs: [output])
            let failed = LockedFlag()
            let streaming = await eventually(timeout: .seconds(15)) {
                let phase = await engine.phase(of: output.id)
                if case .failed = phase { failed.set() }
                return phase == .streaming
            }
            #expect(streaming)
            #expect(!failed.value, "la sortie est passée en échec")
            await engine.stop()
            #expect(salon.sessionCount == 2)
        }

        /// Un récepteur qui refuse à chaque fois : la sortie attend son récepteur, comme un appareil
        /// éteint, au lieu d'être abandonnée.
        @Test("Une sortie toujours refusée à M4 attend son récepteur, sans abandon")
        func moteurSortieToujoursRefusee() async throws {
            let salon = try await makeReceiver(script: refusing(.pairingError(.authentication), at: .m3))
            defer { salon.stop() }
            var dependencies = BridgeEngine.Dependencies.live
            dependencies.senderFactory = LiveOutputSenderFactory(
                findRAOP: { name, _, _ in throw RAOPDiscoveryError.notFound(name: name, seen: []) },
                findAirPlay2: { _, _, _ in salon.device(name: "Salon") }
            )
            dependencies.tuning.monitorInterval = .milliseconds(20)
            dependencies.tuning.retryInitialDelay = .seconds(30)
            let engine = BridgeEngine(dependencies: dependencies)
            let output = BridgeEngine.OutputRequest(
                id: "airplay2/Salon", proto: .airplay2, deviceName: "Salon", volumeDB: -30)

            try await engine.start(source: .tone(frequency: 440, levelDBFS: -50), outputs: [output])
            #expect(await eventually(timeout: .seconds(15)) {
                if case .waitingForReceiver = await engine.phase(of: output.id) { return true }
                return false
            })
            let snapshot = try #require(await engine.snapshot(of: output.id))
            let message = try #require(snapshot.lastError)
            #expect(message.contains("sans code"))
            #expect(!message.contains("code de pairing erroné"))
            #expect(!message.contains("atvremote"))
            await engine.stop()
        }

        /// Un sender qui attend son tour ne doit pas retenir l'arrêt le temps du pairing d'un autre.
        @Test("stop() pendant l'attente du tour rend la main aussitôt, sans rien envoyer")
        func stopPendantAttenteDuTour() async throws {
            let slow: Script = { request, _ in
                request.uri == "/pair-setup" && request.pairingState == .m1 ? .delayed(1.5) : .normal
            }
            let salon = try await makeReceiver(script: slow)
            let salon2 = try await makeReceiver()
            defer {
                salon.stop()
                salon2.stop()
            }
            let gate = SerialPairingGate()
            let first = try SenderHarness(receiver: salon, name: "Salon", pairingGate: gate)
            let second = try SenderHarness(receiver: salon2, name: "Salon (2)", pairingGate: gate)
            defer {
                first.feeder.stop()
                second.feeder.stop()
            }

            let firstSender = first.sender
            let secondSender = second.sender
            let firstStart = Task { try await firstSender.start(volume: -20) }
            #expect(await waitUntil { !salon.pairSetupSpans().isEmpty })
            let secondStart = Task { try await secondSender.start(volume: -20) }
            #expect(await waitUntil { gate.waitingCount == 1 })

            let start = ContinuousClock.now
            await secondSender.stop()
            let result = await secondStart.result
            #expect(ContinuousClock.now - start < .milliseconds(500))
            #expect(throws: CancellationError.self) { try result.get() }
            #expect(await secondSender.state == .idle)
            #expect(gate.waitingCount == 0)

            // Le premier n'en a rien su, et le tour lui revient bien à la fin.
            try await firstStart.value
            #expect(await firstSender.state == .streaming)
            #expect(salon2.pairSetupSpans().isEmpty)
            try await gate.acquire()
            gate.release()
            await firstSender.stop()
        }
    }
}

extension FakeAirPlay2Receiver {
    /// Pair-setups reçus par ce récepteur.
    fileprivate var devicePairSetupCount: Int { pairSetupSpans().count }
}
