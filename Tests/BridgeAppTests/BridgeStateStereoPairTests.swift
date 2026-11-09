import AudioCore
import Foundation
import Testing

@testable import BridgeApp

// La paire stéréo : une seule coche pour ses deux membres, et une entrée en session d'un seul tenant
// (`StereoPairs`). Le vrai `BridgeEngine`, avec des senders sans réseau (`BridgeStateTestSupport`).
//
// Deux sessions ouvertes à des moments différents s'expulsent en boucle sur la vraie paire (entendu le
// 2026-11-02) ; ouvertes ensemble, elles tiennent. Ces tests vérifient que l'app ne les ouvre plus
// jamais l'une sans l'autre, et qu'une reconnexion reste l'affaire du seul membre concerné.

/// La Geneva et la paire, vues ensemble à la toute première recherche : tout est coché.
@MainActor
private func salonHarness(
    tuning: BridgeEngine.Tuning? = nil
) async throws -> (BridgeHarness, geneva: OutputState, left: OutputState, right: OutputState) {
    let harness = BridgeHarness(tuning: tuning)
    await harness.discover(
        raop: [Devices.genevaRAOP], airplay2: [PairDevices.left, PairDevices.right]
    )
    let geneva = try #require(harness.output(Devices.genevaID))
    let left = try #require(harness.output(Devices.leftID))
    let right = try #require(harness.output(Devices.rightID))
    return (harness, geneva, left, right)
}

/// Un HomePod d'une autre pièce, et de sa propre paire.
private func homePod(_ name: String, host: String, tsid: String) -> AirPlay2Device {
    AirPlay2Device(
        serviceName: name, host: host, port: 7000,
        txt: ["features": Devices.homePodFeatures, "model": "AudioAccessory5,1", "tsid": tsid]
    )
}

/// Le réglage enregistré d'un membre de la paire.
private func pairRecord(isEnabled: Bool) -> BridgeSettings.Output {
    var record = BridgeSettings.Output(isEnabled: isEnabled)
    record.tightSyncIdentifier = PairDevices.tsid
    return record
}

@Suite("Paire stéréo — une seule coche")
struct StereoPairCheckTests {
    @Test("Cocher ou décocher un membre coche ou décoche toute la paire, et rien d'autre")
    func gestureCarriesThePair() async throws {
        let (harness, geneva, left, right) = try await salonHarness()
        let state = harness.state
        #expect(state.stereoPartners(of: left).map(\.id) == [Devices.rightID])
        #expect(state.stereoPartners(of: right).map(\.id) == [Devices.leftID])
        #expect(state.stereoPartners(of: geneva).isEmpty)

        state.toggleEnabled(left)
        #expect(!left.isEnabled)
        #expect(!right.isEnabled)
        #expect(geneva.isEnabled)

        state.toggleEnabled(right)
        #expect(left.isEnabled)
        #expect(right.isEnabled)

        state.setEnabled(false, for: right)
        #expect(!left.isEnabled)
        #expect(!right.isEnabled)
        // Enregistré pour les deux : au prochain lancement, la paire repart telle qu'on l'a laissée.
        #expect(await eventually {
            harness.store.stored.outputs[Devices.leftID]?.isEnabled == false
                && harness.store.stored.outputs[Devices.rightID]?.isEnabled == false
        })

        // La Geneva, elle, ne change que d'elle-même.
        state.toggleEnabled(geneva)
        #expect(!geneva.isEnabled)
        #expect(!left.isEnabled)
        #expect(!right.isEnabled)
    }

    @Test("Sans tsid, ou de tsid différents, les sorties restent indépendantes")
    func unrelatedOutputsStayIndependent() async throws {
        let harness = BridgeHarness()
        let kitchen = homePod("Cuisine", host: "192.168.1.70", tsid: "PAIRE-CUISINE")
        let bedroom = homePod("Chambre", host: "192.168.1.71", tsid: "PAIRE-CHAMBRE")
        await harness.discover(
            raop: [Devices.genevaRAOP], airplay2: [Devices.left, Devices.right, kitchen, bedroom]
        )
        let state = harness.state
        let all = state.outputs
        #expect(all.count == 5)
        #expect(all.allSatisfy { $0.isEnabled })

        for output in all {
            #expect(state.stereoPartners(of: output).isEmpty, "\(output.id)")
            state.toggleEnabled(output)
            for other in all where other !== output {
                #expect(other.isEnabled, "\(output.id) a décoché \(other.id)")
            }
            state.toggleEnabled(output)
        }
    }

    @Test("Un membre absent de la liste suit la coche de sa paire, et la retrouve à son retour")
    func unlistedMemberFollows() async throws {
        var settings = BridgeSettings()
        settings.outputs[Devices.leftID] = pairRecord(isEnabled: false)
        settings.outputs[Devices.rightID] = pairRecord(isEnabled: false)
        let harness = BridgeHarness(settings: settings)
        // « Salon (2) » est éteint : la liste ne l'a pas, seul son réglage enregistré existe.
        await harness.discover(airplay2: [PairDevices.left])
        let left = try #require(harness.output(Devices.leftID))
        #expect(harness.output(Devices.rightID) == nil)

        harness.state.toggleEnabled(left)
        #expect(await eventually { harness.store.stored.outputs[Devices.rightID]?.isEnabled == true })
        harness.state.toggleEnabled(left)
        #expect(await eventually { harness.store.stored.outputs[Devices.rightID]?.isEnabled == false })

        // Décochée, la paire le reste quand il revient.
        await harness.discover(airplay2: [PairDevices.left, PairDevices.right])
        #expect(harness.output(Devices.rightID)?.isEnabled == false)

        // Cochée pendant qu'il était parti : il revient coché.
        await harness.discover(airplay2: [PairDevices.left])
        await harness.discover(airplay2: [PairDevices.left])
        #expect(harness.output(Devices.rightID) == nil)
        harness.state.toggleEnabled(left)
        await harness.discover(airplay2: [PairDevices.left, PairDevices.right])
        #expect(harness.output(Devices.rightID)?.isEnabled == true)
    }
}

@Suite("Paire stéréo — entrée en session d'un seul tenant")
struct StereoPairSessionTests {
    @Test("Une paire cochée en pleine diffusion entre avec ses deux membres, sans toucher au reste")
    func hotAddedPairJoinsWhole() async throws {
        let (harness, geneva, left, right) = try await salonHarness()
        harness.state.setEnabled(false, for: left)
        await harness.startStreaming(expecting: [Devices.genevaID])
        let genevaSender = try #require(harness.factory.latest(Devices.genevaID))
        #expect(harness.factory.senders(Devices.leftID).isEmpty)

        harness.state.toggleEnabled(right)
        #expect(await eventually { left.connection == .streaming && right.connection == .streaming })
        #expect(harness.factory.senders(Devices.leftID).count == 1)
        #expect(harness.factory.senders(Devices.rightID).count == 1)
        // Sur le volume commun de la paire, d'emblée.
        let leftSender = try #require(harness.factory.latest(Devices.leftID))
        let rightSender = try #require(harness.factory.latest(Devices.rightID))
        #expect(await leftSender.startedVolume == rightSender.startedVolume)

        #expect(harness.factory.senders(Devices.genevaID).count == 1)
        #expect(await genevaSender.stopCount == 0)
        #expect(geneva.connection == .streaming)
        #expect(harness.captures.count == 1)
        await harness.stopStreaming()
    }

    @Test("Jamais l'un sans l'autre : un membre encore en TEARDOWN retient toute la paire")
    func busyMemberHoldsThePair() async throws {
        var tuning = BridgeHarness.fastTuning
        // Le retrait attend le `TEARDOWN` aussi longtemps que le test le retient.
        tuning.stopTimeout = .seconds(10)
        let (harness, _, left, right) = try await salonHarness(tuning: tuning)
        harness.factory.makeStopHang(Devices.rightID)
        await harness.startStreaming(expecting: [Devices.genevaID, Devices.leftID, Devices.rightID])
        let firstLeft = try #require(harness.factory.latest(Devices.leftID))
        let firstRight = try #require(harness.factory.latest(Devices.rightID))

        harness.state.setEnabled(false, for: left)
        #expect(await eventually {
            let leftStopped = await firstLeft.stopCount == 1
            let rightStopping = await firstRight.stopCount == 1
            return leftStopped && rightStopping
        })
        // « Salon » est libre, « Salon (2) » attend encore la fin de son `TEARDOWN`.
        harness.state.setEnabled(true, for: left)
        #expect(await staysFalse(during: .milliseconds(150)) {
            harness.factory.senders(Devices.leftID).count > 1
        })
        #expect(left.connection == .connecting)
        #expect(right.connection == .connecting)

        await firstRight.releaseStop()
        #expect(await eventually {
            harness.factory.senders(Devices.leftID).count == 2
                && harness.factory.senders(Devices.rightID).count == 2
        })
        #expect(await eventually { left.connection == .streaming && right.connection == .streaming })

        // Le `TEARDOWN` du nouveau « Salon (2) » se retient aussi : on le libère à l'arrêt.
        let secondRight = try #require(harness.factory.latest(Devices.rightID))
        harness.state.toggleStreaming()
        #expect(await eventually { await secondRight.stopCount == 1 })
        await secondRight.releaseStop()
        #expect(await eventually { harness.state.streamingPhase == .idle })
    }

    @Test("Un membre qui arrive pendant que l'autre diffuse : celui-ci sort, et la paire rentre ensemble")
    func lateMemberReopensThePair() async throws {
        // Des réglages qui ne cochaient qu'un membre, et l'autre éteint au lancement.
        var settings = BridgeSettings()
        settings.outputs[Devices.genevaID] = BridgeSettings.Output(isEnabled: true)
        settings.outputs[Devices.leftID] = pairRecord(isEnabled: true)
        settings.outputs[Devices.rightID] = pairRecord(isEnabled: false)
        let harness = BridgeHarness(settings: settings)
        #expect(harness.output(Devices.rightID) == nil)
        await harness.startStreaming(expecting: [Devices.genevaID, Devices.leftID])
        let left = try #require(harness.output(Devices.leftID))
        let geneva = try #require(harness.output(Devices.genevaID))
        let firstLeft = try #require(harness.factory.latest(Devices.leftID))
        let genevaSender = try #require(harness.factory.latest(Devices.genevaID))

        // Le second apparaît sur le réseau : il rejoint sa paire, cochée.
        await harness.discover(
            raop: [Devices.genevaRAOP], airplay2: [PairDevices.left, PairDevices.right]
        )
        let right = try #require(harness.output(Devices.rightID))
        #expect(right.isEnabled)

        var rightOpenedBesideFirstLeft = false
        #expect(await eventually {
            let rightCreated = !harness.factory.senders(Devices.rightID).isEmpty
            if rightCreated, await firstLeft.stopCount == 0 { rightOpenedBesideFirstLeft = true }
            return rightCreated && harness.factory.senders(Devices.leftID).count == 2
        })
        #expect(!rightOpenedBesideFirstLeft, "« Salon (2) » ouvert pendant que « Salon » diffusait")
        #expect(await firstLeft.stopCount == 1)
        #expect(harness.factory.senders(Devices.rightID).count == 1)
        #expect(await eventually { left.connection == .streaming && right.connection == .streaming })
        let secondLeft = try #require(harness.factory.latest(Devices.leftID))
        let rightSender = try #require(harness.factory.latest(Devices.rightID))
        #expect(await secondLeft.startedVolume == rightSender.startedVolume)

        // Ni la Geneva ni la capture n'ont bougé.
        #expect(harness.factory.senders(Devices.genevaID).count == 1)
        #expect(await genevaSender.stopCount == 0)
        #expect(geneva.connection == .streaming)
        #expect(harness.captures.count == 1)
        await harness.stopStreaming()
    }

    @Test("Une paire à moitié cochée se rouvre ensemble quand on coche le membre manquant")
    func checkingTheMissingMemberReopensThePair() async throws {
        // Sans tsid connu, les deux HomePod sont indépendants : on en décoche un, puis la paire se révèle.
        let harness = BridgeHarness()
        await harness.discover(airplay2: [Devices.left, Devices.right])
        let left = try #require(harness.output(Devices.leftID))
        let right = try #require(harness.output(Devices.rightID))
        harness.state.setEnabled(false, for: right)
        await harness.startStreaming(expecting: [Devices.leftID])
        let firstLeft = try #require(harness.factory.latest(Devices.leftID))

        await harness.discover(airplay2: [PairDevices.left, PairDevices.right])
        #expect(left.stereoPairKey == PairDevices.tsid)
        // Rien ne bouge de soi-même : seul un geste rouvre la paire.
        #expect(await staysFalse { harness.factory.createdCount != 1 })
        #expect(!right.isEnabled)

        harness.state.toggleEnabled(right)
        #expect(await eventually {
            harness.factory.senders(Devices.leftID).count == 2
                && harness.factory.senders(Devices.rightID).count == 1
        })
        #expect(await firstLeft.stopCount == 1)
        #expect(await eventually { left.connection == .streaming && right.connection == .streaming })
        await harness.stopStreaming()
    }

    @Test("Une reconnexion isolée d'un membre ne relance jamais l'autre")
    func reconnectionStaysIsolated() async throws {
        let (harness, geneva, left, right) = try await salonHarness()
        await harness.startStreaming(expecting: [Devices.genevaID, Devices.leftID, Devices.rightID])
        let firstLeft = try #require(harness.factory.latest(Devices.leftID))
        let rightSender = try #require(harness.factory.latest(Devices.rightID))
        let genevaSender = try #require(harness.factory.latest(Devices.genevaID))

        // Le sender se reconnecte lui-même.
        await firstLeft.become(.reconnecting, error: "récepteur occupé")
        #expect(await eventually { left.connection == .reconnecting(message: "récepteur occupé") })
        await firstLeft.become(.streaming)
        #expect(await eventually { left.connection == .streaming })

        // Session perdue : le moteur remplace le sender de ce membre, et de lui seul.
        await firstLeft.become(.failed)
        #expect(await eventually { harness.factory.senders(Devices.leftID).count == 2 })
        #expect(await eventually { left.connection == .streaming })

        #expect(await staysFalse(during: .milliseconds(100)) {
            harness.factory.senders(Devices.rightID).count != 1
        })
        #expect(await rightSender.stopCount == 0)
        #expect(right.connection == .streaming)
        #expect(harness.factory.senders(Devices.genevaID).count == 1)
        #expect(await genevaSender.stopCount == 0)
        #expect(geneva.connection == .streaming)
        await harness.stopStreaming()
    }

    @Test("Un membre attendu par le moteur entre seul quand il répond, comme tout récepteur absent")
    func absentMemberIsAwaitedByTheEngine() async throws {
        let (harness, _, left, right) = try await salonHarness()
        harness.factory.markAbsent(Devices.rightID)
        await harness.startStreaming(expecting: [Devices.leftID])
        #expect(await eventually {
            if case .waiting = right.connection { return true }
            return false
        })
        let leftSender = try #require(harness.factory.latest(Devices.leftID))

        harness.factory.markAbsent(Devices.rightID, false)
        #expect(await eventually { right.connection == .streaming })
        #expect(await leftSender.stopCount == 0)
        #expect(harness.factory.senders(Devices.leftID).count == 1)
        #expect(left.connection == .streaming)
        await harness.stopStreaming()
    }
}

@Suite("Paire stéréo — le plan d'un tour")
struct StereoPairPlanTests {
    private func member(
        _ id: String, pair: String? = "p", enabled: Bool = true, active: Bool, busy: Bool = false
    ) -> StereoPairs.SessionMember {
        StereoPairs.SessionMember(
            id: id, pairKey: pair, isEnabled: enabled, isActive: active, isBusy: busy
        )
    }

    @Test("Deux membres libres hors session : rien à retenir, ils entrent au même tour")
    func freePairEnters() {
        #expect(StereoPairs.sessionPlan(for: [member("g", active: false), member("d", active: false)])
            == StereoPairs.SessionPlan())
    }

    @Test("L'un diffuse, l'autre arrive : le premier sort, l'arrivant attend")
    func streamingMemberLeaves() {
        let plan = StereoPairs.sessionPlan(for: [member("g", active: true), member("d", active: false)])
        #expect(plan.leaving == ["g"])
        #expect(plan.held == ["d"])
    }

    @Test("Un membre occupé retient les autres")
    func busyMemberHolds() {
        let plan = StereoPairs.sessionPlan(
            for: [member("g", active: false), member("d", active: false, busy: true)]
        )
        #expect(plan.held == ["g", "d"])
        #expect(plan.leaving.isEmpty)
    }

    @Test("Tous en session, reconnexion ou non : rien à faire")
    func activePairIsLeftAlone() {
        #expect(StereoPairs.sessionPlan(for: [member("g", active: true), member("d", active: true, busy: true)])
            == StereoPairs.SessionPlan())
    }

    @Test("Un membre décoché, une sortie sans paire, ou seule de sa paire : la règle ordinaire")
    func ordinaryRule() {
        let plan = StereoPairs.sessionPlan(for: [
            member("g", active: true), member("d", enabled: false, active: false),
            member("geneva", pair: nil, active: false), member("cuisine", pair: "q", active: false),
        ])
        #expect(plan == StereoPairs.SessionPlan())
    }

    @Test("Les partenaires se disent en une phrase")
    func names() {
        #expect(StereoPairs.names([]) == nil)
        #expect(StereoPairs.names(["Salon (2)"]) == "Salon (2)")
        #expect(StereoPairs.names(["A", "B", "C"]) == "A, B et C")
        #expect(PanelStereoPair.legend(partners: ["Salon (2)"]) == "stéréo avec Salon (2)")
        #expect(PanelStereoPair.legend(partners: []) == nil)
    }
}
