import AudioCore
import Foundation
import Testing

@testable import BridgeApp

@Suite("État — volume")
struct BridgeStateVolumeTests {
    @Test("Le niveau de départ validé à l'oreille arrive sur le fil : −12 dB")
    func defaultLevel() {
        #expect(BridgeState.defaultMasterVolumeDB == -24)
        #expect(BridgeState.receiverVolume(forGainDB: BridgeState.defaultMasterVolumeDB) == -12)
    }

    @Test("Toute la course du master agit, le silence excepté")
    func scale() {
        #expect(BridgeState.receiverVolume(forGainDB: 0) == 0)
        #expect(BridgeState.receiverVolume(forGainDB: -60) == -144)
        #expect(BridgeState.receiverVolume(forGainDB: -30) == -15)
        #expect(BridgeState.receiverVolume(forGainDB: -59) < BridgeState.receiverVolume(forGainDB: -58))
    }

    /// Défaut d'origine : le démarrage passait le gain brut (−12), et les poussées suivantes la
    /// valeur traduite (−6). Le premier réglage touché faisait donc sauter le volume.
    @Test("Le démarrage et les poussées emploient la même échelle")
    func startUsesReceiverScale() async throws {
        let harness = BridgeHarness()
        await harness.discover(raop: [Devices.genevaRAOP])
        await harness.startStreaming(expecting: [Devices.genevaID])

        let sender = try #require(harness.factory.latest(Devices.genevaID))
        #expect(await sender.startedVolume == -12)

        // Aucun réglage n'a bougé : rien à repousser, et surtout pas une autre valeur.
        #expect(await staysFalse { await !sender.pushedVolumes.isEmpty })

        harness.state.masterVolumeDB = -30
        #expect(await eventually { await sender.pushedVolumes.last == -15 })
        await harness.stopStreaming()
    }
}

@Suite("État — volume au minimum")
struct BridgeStateMasterMinimumTests {
    @Test("Master au minimum : silence, même avec un trim positif")
    func masterMinimumIsSilence() async throws {
        let harness = BridgeHarness()
        await harness.discover(raop: [Devices.genevaRAOP], airplay2: [Devices.left, Devices.right])
        let right = try #require(harness.output(Devices.rightID))
        right.trimDB = 1.5
        harness.state.masterVolumeDB = -60

        let wire = BridgeState.receiverVolume(forGainDB: harness.state.effectiveGainDB(for: right))
        #expect(wire == -144)

        // Juste au-dessus, le trim compte de nouveau : seul le minimum absolu vaut silence.
        harness.state.masterVolumeDB = -59
        #expect(harness.state.effectiveGainDB(for: right) == -57.5)
    }
}

@Suite("État — sélection des enceintes")
struct BridgeStateSelectionTests {
    @Test("Hors diffusion, cocher ne fait que retenir la sélection")
    func outsideSession() async throws {
        let harness = BridgeHarness()
        await harness.discover(raop: [Devices.genevaRAOP])
        let geneva = try #require(harness.output(Devices.genevaID))
        geneva.isEnabled = false
        geneva.isEnabled = true
        #expect(await staysFalse { harness.factory.createdCount > 0 })
        #expect(harness.captures.count == 0)
    }

    @Test("Cocher pendant une diffusion ajoute la sortie, sans toucher aux autres")
    func checkAddsOutput() async throws {
        let harness = BridgeHarness()
        await harness.discover(raop: [Devices.genevaRAOP], airplay2: [Devices.left])
        let left = try #require(harness.output(Devices.leftID))
        left.isEnabled = false

        await harness.startStreaming(expecting: [Devices.genevaID])
        let geneva = try #require(harness.factory.latest(Devices.genevaID))
        #expect(harness.factory.senders(Devices.leftID).isEmpty)

        left.isEnabled = true
        #expect(await eventually { left.connection == .streaming })
        #expect(harness.captures.count == 1)
        #expect(harness.factory.senders(Devices.genevaID).count == 1)
        #expect(await geneva.stopCount == 0)
        await harness.stopStreaming()
    }

    @Test("Décocher pendant une diffusion retire la sortie, sans toucher aux autres")
    func uncheckRemovesOutput() async throws {
        let harness = BridgeHarness()
        await harness.discover(raop: [Devices.genevaRAOP], airplay2: [Devices.left])
        await harness.startStreaming(expecting: [Devices.genevaID, Devices.leftID])
        let genevaSender = try #require(harness.factory.latest(Devices.genevaID))
        let leftSender = try #require(harness.factory.latest(Devices.leftID))
        let left = try #require(harness.output(Devices.leftID))

        left.isEnabled = false
        #expect(await eventually { await leftSender.stopCount >= 1 })
        #expect(left.connection == .idle)
        #expect(await genevaSender.stopCount == 0)
        #expect(harness.state.isStreaming)
        #expect(harness.output(Devices.genevaID)?.connection == .streaming)
        #expect(harness.captures.count == 1)
        await harness.stopStreaming()
    }

    /// Le récepteur doit avoir reçu son `TEARDOWN` avant de se voir proposer une nouvelle session.
    @Test("Décocher puis recocher attend la fin du retrait")
    func recheckWaitsForRemoval() async throws {
        let harness = BridgeHarness()
        await harness.discover(raop: [Devices.genevaRAOP], airplay2: [Devices.left])
        harness.factory.makeStopHang(Devices.leftID)
        await harness.startStreaming(expecting: [Devices.genevaID, Devices.leftID])
        let first = try #require(harness.factory.latest(Devices.leftID))
        let left = try #require(harness.output(Devices.leftID))

        left.isEnabled = false
        #expect(await eventually { await first.stopCount == 1 })
        left.isEnabled = true
        // Le retrait est retenu par son `TEARDOWN` : le nouveau sender attend son tour.
        #expect(await staysFalse { harness.factory.senders(Devices.leftID).count > 1 })

        await first.releaseStop()
        #expect(await eventually { harness.factory.senders(Devices.leftID).count == 2 })
        await harness.stopStreaming()
    }

    @Test("Un récepteur lent ne retarde pas les réglages des autres")
    func slowReceiverDoesNotBlockOthers() async throws {
        let harness = BridgeHarness()
        await harness.discover(raop: [Devices.genevaRAOP], airplay2: [Devices.left])
        harness.factory.makeStopHang(Devices.leftID)
        await harness.startStreaming(expecting: [Devices.genevaID, Devices.leftID])
        let genevaSender = try #require(harness.factory.latest(Devices.genevaID))
        let leftSender = try #require(harness.factory.latest(Devices.leftID))
        let geneva = try #require(harness.output(Devices.genevaID))
        let left = try #require(harness.output(Devices.leftID))

        left.isEnabled = false
        #expect(await eventually { await leftSender.stopCount == 1 })
        geneva.trimDB = 3
        #expect(await eventually { await genevaSender.pushedVolumes.count == 1 })
        await leftSender.releaseStop()
        await harness.stopStreaming()
    }

    @Test("Décocher la dernière enceinte arrête la diffusion, après un délai de grâce")
    func lastUncheckStops() async throws {
        var timing = BridgeEnvironment.Timing.fast
        timing.emptySelectionGrace = .milliseconds(40)
        let harness = BridgeHarness(timing: timing)
        await harness.discover(raop: [Devices.genevaRAOP])
        await harness.startStreaming(expecting: [Devices.genevaID])

        try #require(harness.output(Devices.genevaID)).isEnabled = false
        #expect(harness.state.isStreaming)
        #expect(await eventually { harness.state.streamingPhase == .idle })
        #expect(!harness.activity.isHeld)
    }

    @Test("Cocher une autre enceinte pendant le délai de grâce évite l'arrêt de la capture")
    func swapWithinGraceKeepsCapture() async throws {
        var timing = BridgeEnvironment.Timing.fast
        timing.emptySelectionGrace = .milliseconds(200)
        let harness = BridgeHarness(timing: timing)
        await harness.discover(raop: [Devices.genevaRAOP], airplay2: [Devices.left])
        let left = try #require(harness.output(Devices.leftID))
        left.isEnabled = false
        await harness.startStreaming(expecting: [Devices.genevaID])

        try #require(harness.output(Devices.genevaID)).isEnabled = false
        #expect(await eventually {
            let sender = harness.factory.latest(Devices.genevaID)
            return await sender?.stopCount ?? 0 >= 1
        })
        left.isEnabled = true
        #expect(await eventually { left.connection == .streaming })
        #expect(await staysFalse(during: .milliseconds(260)) { !harness.state.isStreaming })
        #expect(harness.captures.count == 1)
        await harness.stopStreaming()
    }

    @Test("Une sortie en échec se relance en la décochant puis en la recochant")
    func failedOutputCanBeRetried() async throws {
        let harness = BridgeHarness()
        await harness.discover(raop: [Devices.genevaRAOP], airplay2: [Devices.left])
        harness.factory.script(
            Devices.leftID, [.fail(AirPlay2SenderError.pairingRequired(receiver: "Salon", status: 470))]
        )
        await harness.startStreaming(expecting: [Devices.genevaID])
        let left = try #require(harness.output(Devices.leftID))
        #expect(await eventually { left.connection.isFailure })

        left.isEnabled = false
        #expect(await eventually { left.connection == .idle })
        left.isEnabled = true
        #expect(await eventually { left.connection == .streaming })
        await harness.stopStreaming()
    }
}

@Suite("État — sortie visée")
struct BridgeStateReceiverNameTests {
    /// L'application connaît le nom exact de chacune de ses sorties, y compris le préfixe matériel qui
    /// distingue en RAOP deux HomePod baptisés « Salon ».
    @Test("Le moteur reçoit le nom complet de l'instance, à prendre exactement")
    func requestsExactInstance() async throws {
        let harness = BridgeHarness()
        await harness.discover(raop: [Devices.genevaRAOP], airplay2: [Devices.left, Devices.right])
        await harness.startStreaming(expecting: [Devices.genevaID, Devices.leftID, Devices.rightID])

        let geneva = try #require(harness.factory.lastRequest(Devices.genevaID))
        #expect(geneva.deviceName == "AABBCCDDEEFF@Geneva")
        #expect(geneva.nameMatching == .exact)
        let left = try #require(harness.factory.lastRequest(Devices.leftID))
        #expect(left.deviceName == "Salon")
        #expect(left.nameMatching == .exact)
        #expect(harness.factory.lastRequest(Devices.rightID)?.deviceName == "Salon (2)")
        await harness.stopStreaming()
    }
}

@Suite("État — réglages poussés")
struct BridgeStatePushTests {
    @Test("Basses : valeur de départ, puis sur changement seulement")
    func bassBoost() async throws {
        let harness = BridgeHarness()
        await harness.discover(raop: [Devices.genevaRAOP])
        let geneva = try #require(harness.output(Devices.genevaID))
        geneva.bassBoostDB = 6
        await harness.startStreaming(expecting: [Devices.genevaID])

        let sender = try #require(harness.factory.latest(Devices.genevaID))
        #expect(await sender.startedBass == 6)
        #expect(await staysFalse { await sender.pushedBass.count > 1 })

        geneva.bassBoostDB = 9
        #expect(await eventually { await sender.pushedBass.last == 9 })
        await harness.stopStreaming()
    }

    @Test("Aigus : valeur de départ, puis sur changement seulement, sans toucher aux basses")
    func trebleCut() async throws {
        let harness = BridgeHarness()
        await harness.discover(raop: [Devices.genevaRAOP])
        let geneva = try #require(harness.output(Devices.genevaID))
        geneva.bassBoostDB = 6
        geneva.trebleCutDB = -3
        await harness.startStreaming(expecting: [Devices.genevaID])

        let sender = try #require(harness.factory.latest(Devices.genevaID))
        #expect(await sender.startedTreble == -3)
        #expect(await staysFalse { await sender.pushedTreble.count > 1 })

        geneva.trebleCutDB = -7.5
        #expect(await eventually { await sender.pushedTreble.last == -7.5 })
        #expect(await sender.pushedBass == [6])
        await harness.stopStreaming()
    }

    @Test("Aigus : une sortie AirPlay 2 n'en reçoit jamais")
    func trebleCutSkipsAirPlay2() async throws {
        let harness = BridgeHarness()
        await harness.discover(airplay2: [Devices.left])
        let left = try #require(harness.output(Devices.leftID))
        left.trebleCutDB = -6
        await harness.startStreaming(expecting: [Devices.leftID])
        let sender = try #require(harness.factory.latest(Devices.leftID))

        left.trebleCutDB = -9
        left.trimDB = 1
        #expect(await eventually { await sender.pushedVolumes.count == 1 })
        #expect(await sender.pushedTreble.isEmpty)
        #expect(harness.factory.lastRequest(Devices.leftID)?.trebleCutDB == 0)
        await harness.stopStreaming()
    }

    @Test("Basses : une sortie AirPlay 2 n'en reçoit jamais")
    func bassBoostSkipsAirPlay2() async throws {
        let harness = BridgeHarness()
        await harness.discover(airplay2: [Devices.left])
        let left = try #require(harness.output(Devices.leftID))
        left.bassBoostDB = 6
        await harness.startStreaming(expecting: [Devices.leftID])
        let sender = try #require(harness.factory.latest(Devices.leftID))

        left.bassBoostDB = 9
        left.trimDB = 1
        #expect(await eventually { await sender.pushedVolumes.count == 1 })
        #expect(await sender.pushedBass.isEmpty)
        #expect(harness.factory.lastRequest(Devices.leftID)?.bassBoostDB == 0)
        await harness.stopStreaming()
    }

    @Test("Délai et trim suivent, silence compris")
    func delayTrimAndMute() async throws {
        let harness = BridgeHarness()
        await harness.discover(raop: [Devices.genevaRAOP])
        let geneva = try #require(harness.output(Devices.genevaID))
        geneva.delayMS = 25
        await harness.startStreaming(expecting: [Devices.genevaID])
        let sender = try #require(harness.factory.latest(Devices.genevaID))
        #expect(await sender.startedDelay == 0.025)

        geneva.delayMS = 40
        #expect(await eventually { await sender.pushedDelays.last == 0.04 })

        harness.state.isMuted = true
        #expect(await eventually { await sender.pushedVolumes.last == -144 })
        harness.state.isMuted = false
        #expect(await eventually { await sender.pushedVolumes.last == -12 })
        await harness.stopStreaming()
    }

    @Test("Une sortie ajoutée à chaud part de ses réglages, sans repoussée")
    func hotAddStartsFromCurrentSettings() async throws {
        let harness = BridgeHarness()
        await harness.discover(raop: [Devices.genevaRAOP], airplay2: [Devices.left])
        let left = try #require(harness.output(Devices.leftID))
        left.isEnabled = false
        left.trimDB = 6
        await harness.startStreaming(expecting: [Devices.genevaID])

        left.isEnabled = true
        #expect(await eventually { left.connection == .streaming })
        let sender = try #require(harness.factory.latest(Devices.leftID))
        #expect(await sender.startedVolume == BridgeState.receiverVolume(forGainDB: -18))
        #expect(await staysFalse { await !sender.pushedVolumes.isEmpty })
        await harness.stopStreaming()
    }
}

@Suite("État — lieu d'écoute")
struct BridgeStateListeningPlaceTests {
    // Tout à la même hauteur, pour lire les délais à la règle : 3,43 m font 10 ms.
    private let tableID = UUID()
    private let sofaID = UUID()

    private func speaker(_ output: String?, x: Double, name: String = "") -> RoomObject {
        RoomObject(
            kind: .speaker(outputID: output), position: CGPoint(x: x, y: 0),
            size: CGSize(width: 0.2, height: 0.2), elevation: 1.10, name: name, shape: .ellipse
        )
    }

    private func place(id: UUID, _ name: String, x: Double) -> RoomObject {
        var object = RoomObject(
            kind: .listener, position: CGPoint(x: x, y: 0),
            size: CGSize(width: 0.45, height: 0.40), elevation: 1.10, name: name
        )
        object.id = id
        return object
    }

    /// Depuis la table (x = 0), la Geneva est 3,43 m plus proche que le HomePod : +10 ms pour elle.
    /// Depuis le canapé (x = 10), c'est l'inverse : +10 ms pour le HomePod.
    private var plan: RoomLayout {
        var layout = RoomLayout(
            objects: [
                speaker(Devices.genevaID, x: 3.43, name: "Geneva"),
                speaker(Devices.leftID, x: 6.86, name: "HomePod G"),
                place(id: tableID, "À table", x: 0),
                place(id: sofaID, "Au canapé", x: 10),
            ]
        )
        layout.activeListenerID = tableID
        return layout
    }

    private func isClose(_ value: Double?, to expected: Double) -> Bool {
        guard let value else { return false }
        return abs(value - expected) < 1e-9
    }

    private func makeHarness() -> BridgeHarness {
        let harness = BridgeHarness()
        harness.layout = plan
        return harness
    }

    @Test("Le plan ne trace de trait que pour les sorties cochées")
    func planDrawsCheckedOutputsOnly() async throws {
        let harness = makeHarness()
        await harness.discover(raop: [Devices.genevaRAOP], airplay2: [Devices.left])
        #expect(Set(harness.state.outputIDsDrawnOnPlan) == [Devices.genevaID, Devices.leftID])

        let geneva = try #require(harness.state.outputs.first { $0.id == Devices.genevaID })
        geneva.isEnabled = false
        #expect(harness.state.outputIDsDrawnOnPlan == [Devices.leftID])
    }

    @Test("La compensation part dès le démarrage, sans geste de l'utilisateur")
    func compensationIsApplied() async throws {
        let harness = makeHarness()
        await harness.discover(raop: [Devices.genevaRAOP], airplay2: [Devices.left])
        await harness.startStreaming(expecting: [Devices.genevaID, Devices.leftID])

        let geneva = try #require(harness.factory.latest(Devices.genevaID))
        let left = try #require(harness.factory.latest(Devices.leftID))
        #expect(isClose(await geneva.startedDelay, to: 0.010))
        #expect(isClose(await left.startedDelay, to: 0))
        await harness.stopStreaming()
    }

    /// Le cœur de la demande : sans cela, le sélecteur n'aurait aucun effet.
    @Test("Changer de lieu pousse les bons délais, sans toucher à la session")
    func changingPlacePushesDelays() async throws {
        let harness = makeHarness()
        await harness.discover(raop: [Devices.genevaRAOP], airplay2: [Devices.left])
        await harness.startStreaming(expecting: [Devices.genevaID, Devices.leftID])
        let geneva = try #require(harness.factory.latest(Devices.genevaID))
        let left = try #require(harness.factory.latest(Devices.leftID))
        #expect(await geneva.pushedDelays.isEmpty)
        #expect(await left.pushedDelays.isEmpty)

        harness.state.selectListeningPlace(id: sofaID)
        #expect(harness.state.roomLayout.listener?.id == sofaID)
        #expect(harness.layoutSaveCount == 1)
        let reached = await eventually {
            let (g, l) = (await geneva.pushedDelays.last, await left.pushedDelays.last)
            return isClose(g, to: 0) && isClose(l, to: 0.010)
        }
        #expect(reached)

        // Ni capture relancée, ni sender remplacé : c'est ce qui garantit l'absence de coupure.
        #expect(harness.captures.count == 1)
        #expect(await geneva.stopCount == 0)
        #expect(await left.stopCount == 0)
        #expect(harness.factory.senders(Devices.genevaID).count == 1)
        #expect(harness.factory.senders(Devices.leftID).count == 1)
        await harness.stopStreaming()
    }

    @Test("Le lieu choisi vaut pour la diffusion suivante")
    func placeOutsideSession() async throws {
        let harness = makeHarness()
        await harness.discover(raop: [Devices.genevaRAOP], airplay2: [Devices.left])
        harness.state.selectListeningPlace(id: sofaID)
        await harness.startStreaming(expecting: [Devices.genevaID, Devices.leftID])

        let left = try #require(harness.factory.latest(Devices.leftID))
        #expect(isClose(await left.startedDelay, to: 0.010))
        await harness.stopStreaming()
    }

    @Test("Le réglage manuel s'additionne à la compensation, et la suit d'un lieu à l'autre")
    func manualDelayAdds() async throws {
        let harness = makeHarness()
        await harness.discover(raop: [Devices.genevaRAOP], airplay2: [Devices.left])
        let output = try #require(harness.output(Devices.genevaID))
        output.delayMS = 5
        #expect(isClose(harness.state.effectiveDelayMS(for: output), to: 15))

        await harness.startStreaming(expecting: [Devices.genevaID, Devices.leftID])
        let geneva = try #require(harness.factory.latest(Devices.genevaID))
        #expect(isClose(await geneva.startedDelay, to: 0.015))

        output.delayMS = 8
        #expect(await eventually { isClose(await geneva.pushedDelays.last, to: 0.018) })

        // Le réglage manuel n'a pas absorbé la compensation : changer de lieu ne l'emporte pas.
        harness.state.selectListeningPlace(id: sofaID)
        #expect(await eventually { isClose(await geneva.pushedDelays.last, to: 0.008) })
        #expect(output.delayMS == 8)
        await harness.stopStreaming()
    }

    /// Le défaut que la consigne écarte : calculée sur les sorties cochées, la compensation de la
    /// Geneva changerait dès qu'on coche le HomePod, qui en est la référence.
    @Test("Cocher une sortie ne change rien au calage des autres")
    func checkingDoesNotMoveOthers() async throws {
        let harness = makeHarness()
        await harness.discover(raop: [Devices.genevaRAOP], airplay2: [Devices.left])
        let left = try #require(harness.output(Devices.leftID))
        left.isEnabled = false
        await harness.startStreaming(expecting: [Devices.genevaID])
        let geneva = try #require(harness.factory.latest(Devices.genevaID))
        #expect(isClose(await geneva.startedDelay, to: 0.010))

        left.isEnabled = true
        #expect(await eventually { left.connection == .streaming })
        #expect(await staysFalse { await !geneva.pushedDelays.isEmpty })

        left.isEnabled = false
        #expect(await staysFalse { await !geneva.pushedDelays.isEmpty })
        await harness.stopStreaming()
    }

    /// Même défaut, côté réseau : la Geneva éteinte reste rattachée, donc reste la référence.
    @Test("Une enceinte rattachée qui s'allume ne change rien au calage des autres")
    func discoveryDoesNotMoveOthers() async throws {
        let harness = BridgeHarness()
        var layout = RoomLayout(
            objects: [
                speaker(Devices.genevaID, x: 6.86, name: "Geneva"),
                speaker(Devices.leftID, x: 3.43, name: "HomePod G"),
                place(id: tableID, "À table", x: 0),
            ]
        )
        layout.activeListenerID = tableID
        harness.layout = layout

        await harness.discover(airplay2: [Devices.left])
        await harness.startStreaming(expecting: [Devices.leftID])
        let left = try #require(harness.factory.latest(Devices.leftID))
        #expect(isClose(await left.startedDelay, to: 0.010))

        await harness.discover(raop: [Devices.genevaRAOP], airplay2: [Devices.left])
        #expect(harness.output(Devices.genevaID) != nil)
        #expect(await staysFalse { await !left.pushedDelays.isEmpty })
        await harness.stopStreaming()
    }

    @Test("Une sortie absente du plan n'a que son réglage manuel, et ne bouge pas")
    func outputOutOfPlan() async throws {
        let harness = makeHarness()
        await harness.discover(
            raop: [Devices.genevaRAOP], airplay2: [Devices.left, Devices.right]
        )
        let right = try #require(harness.output(Devices.rightID))
        right.isEnabled = true
        #expect(harness.state.listeningCompensationMS(for: right) == nil)
        #expect(harness.state.effectiveDelayMS(for: right) == 0)
        right.delayMS = 7
        #expect(harness.state.effectiveDelayMS(for: right) == 7)

        await harness.startStreaming(expecting: [Devices.rightID])
        let sender = try #require(harness.factory.latest(Devices.rightID))
        #expect(isClose(await sender.startedDelay, to: 0.007))

        harness.state.selectListeningPlace(id: sofaID)
        let geneva = try #require(harness.factory.latest(Devices.genevaID))
        #expect(await eventually { await !geneva.pushedDelays.isEmpty })
        #expect(await sender.pushedDelays.isEmpty)
        await harness.stopStreaming()
    }

    /// Les deux enceintes d'une paire portent la même sortie : la liste des sorties rattachées doit
    /// être sans doublon, sous peine de planter dans `Dictionary(uniqueKeysWithValues:)`.
    @Test("Une sortie posée deux fois sur le plan compte une fois, à sa distance moyenne")
    func stereoPair() throws {
        let harness = BridgeHarness()
        var layout = RoomLayout(
            objects: [
                speaker(Devices.leftID, x: 1, name: "HomePod G"),
                speaker(Devices.leftID, x: 3, name: "HomePod D"),
                speaker(Devices.genevaID, x: 5.43, name: "Geneva"),
                place(id: tableID, "À table", x: 0),
            ]
        )
        layout.activeListenerID = tableID
        harness.layout = layout
        let output = OutputState(
            id: Devices.leftID, displayName: "Salon", host: "", port: 0, proto: .airplay2
        )
        let compensation = try #require(harness.state.listeningCompensationMS(for: output))
        // Moyenne de 1 et 3 m contre 5,43 m : 3,43 m, soit 10 ms.
        #expect(abs(compensation - 10) < 1e-9)
    }

    @Test("Sans lieu d'écoute, aucune compensation")
    func noListener() {
        let harness = BridgeHarness()
        harness.layout = RoomLayout(objects: [speaker(Devices.genevaID, x: 3)])
        let output = OutputState(
            id: Devices.genevaID, displayName: "Geneva", host: "", port: 0, proto: .raop
        )
        output.delayMS = 4
        #expect(harness.state.listeningCompensationMS(for: output) == nil)
        #expect(harness.state.effectiveDelayMS(for: output) == 4)
    }

    @Test("Resélectionner le lieu en vigueur, ou un inconnu, n'écrit rien")
    func uselessSelections() {
        let harness = makeHarness()
        harness.state.selectListeningPlace(id: tableID)
        harness.state.selectListeningPlace(id: UUID())
        #expect(harness.layoutSaveCount == 0)
        #expect(harness.state.roomLayout.listener?.id == tableID)
        #expect(harness.state.listeningPlaceName == "À table")
    }

    @Test("Le plan du salon propose bien ses deux lieux, la table d'abord")
    func salonPlan() {
        let harness = BridgeHarness()
        harness.layout = RoomLayout.salon
        #expect(harness.state.roomLayout.listeners.map(\.name) == ["À table", "Au canapé"])
        #expect(harness.state.listeningPlaceName == "À table")
    }
}

@Suite("État — ce que le moteur dit")
struct BridgeStateReflectionTests {
    @Test("Un récepteur absent se lit en attente, avec le message du moteur")
    func waiting() async throws {
        let harness = BridgeHarness()
        await harness.discover(raop: [Devices.genevaRAOP], airplay2: [Devices.left])
        harness.factory.markAbsent(Devices.genevaID)
        await harness.startStreaming(expecting: [Devices.leftID])

        let geneva = try #require(harness.output(Devices.genevaID))
        #expect(await eventually {
            if case let .waiting(attempt, message, _) = geneva.connection {
                return attempt >= 1 && message == StubError.absent.description
            }
            return false
        })
        #expect(geneva.statusLine?.text == StubError.absent.description)
        #expect(geneva.statusLine?.tone == .warning)

        harness.factory.markAbsent(Devices.genevaID, false)
        #expect(await eventually { geneva.connection == .streaming })
        #expect(geneva.statusLine == nil)
        await harness.stopStreaming()
    }

    @Test("Une reconnexion se lit, et sa cause aussi")
    func reconnecting() async throws {
        let harness = BridgeHarness()
        await harness.discover(raop: [Devices.genevaRAOP])
        await harness.startStreaming(expecting: [Devices.genevaID])
        let sender = try #require(harness.factory.latest(Devices.genevaID))
        let geneva = try #require(harness.output(Devices.genevaID))

        await sender.become(.reconnecting, error: "récepteur occupé")
        #expect(await eventually { geneva.connection == .reconnecting(message: "récepteur occupé") })
        #expect(geneva.statusLine?.text == "Reconnexion… récepteur occupé")

        await sender.become(.streaming)
        #expect(await eventually { geneva.connection == .streaming })
        await harness.stopStreaming()
    }

    @Test("Une panne définitive se lit telle que le moteur la rédige")
    func failure() async throws {
        let harness = BridgeHarness()
        await harness.discover(raop: [Devices.genevaRAOP], airplay2: [Devices.left])
        await harness.startStreaming(expecting: [Devices.genevaID, Devices.leftID])
        let sender = try #require(harness.factory.latest(Devices.genevaID))
        let geneva = try #require(harness.output(Devices.genevaID))

        await sender.become(.failed, error: "le récepteur exige un mot de passe")
        #expect(await eventually {
            geneva.connection == .failed("le récepteur exige un mot de passe")
        })
        #expect(geneva.statusLine?.tone == .critical)
        #expect(harness.output(Devices.leftID)?.connection == .streaming)
        #expect(harness.state.status.menuBar == .trouble)
        await harness.stopStreaming()
    }

    @Test("Les compteurs du moteur arrivent jusqu'au diagnostic")
    func statistics() async throws {
        let harness = BridgeHarness()
        await harness.discover(raop: [Devices.genevaRAOP])
        await harness.startStreaming(expecting: [Devices.genevaID])
        let sender = try #require(harness.factory.latest(Devices.genevaID))
        let geneva = try #require(harness.output(Devices.genevaID))

        var statistics = OutputStatistics()
        statistics.packetsSent = 1_234
        statistics.reconnections = 2
        statistics.reportedLatencyFrames = 11_025
        await sender.setStatistics(statistics)
        #expect(await eventually { geneva.statistics == statistics })
        #expect(await eventually { geneva.sync != nil })
        await harness.stopStreaming()
    }

    @Test("Un échec de démarrage s'affiche, et le suivant l'efface")
    func startFailure() async throws {
        let harness = BridgeHarness()
        await harness.discover(raop: [Devices.genevaRAOP])
        harness.captures.failNextCaptures(true)

        harness.state.toggleStreaming()
        #expect(await eventually { harness.state.startFailure != nil })
        #expect(harness.state.startFailure?.message == StubError.prepareFailed.description)
        #expect(!harness.state.isStreaming)
        #expect(harness.state.streamingPhase == .idle)
        #expect(harness.output(Devices.genevaID)?.connection == .idle)
        #expect(harness.state.status.menuBar == .trouble)
        #expect(!harness.activity.isHeld)

        harness.captures.failNextCaptures(false)
        await harness.startStreaming(expecting: [Devices.genevaID])
        #expect(harness.state.startFailure == nil)
        await harness.stopStreaming()
    }

    @Test("Une autorisation refusée mène au bon panneau des Réglages")
    func permissionDenied() async throws {
        let harness = BridgeHarness(permissions: StubPermissions(granted: false))
        await harness.discover(raop: [Devices.genevaRAOP])
        harness.captures.require(permission: .systemAudio)

        harness.state.toggleStreaming()
        #expect(await eventually { harness.state.startFailure != nil })
        #expect(harness.state.startFailure?.settingsPane == .systemAudioCapture)
    }

    @Test("La santé de la capture devient une alerte tant que la diffusion tourne")
    func captureAlert() async throws {
        var tuning = BridgeHarness.fastTuning
        tuning.healthInterval = .milliseconds(2)
        let harness = BridgeHarness(
            permissions: StubPermissions(granted: false), tuning: tuning
        )
        await harness.discover(raop: [Devices.genevaRAOP])
        await harness.startStreaming(expecting: [Devices.genevaID])
        #expect(harness.state.captureHealth.diagnosis != .notRunning)
        await harness.stopStreaming()
        #expect(harness.state.captureAlert == nil)
        #expect(harness.state.captureHealth.diagnosis == .notRunning)
    }
}

@Suite("État — cycle de vie de la diffusion")
struct BridgeStateLifecycleTests {
    @Test("Un double clic ne démarre rien en double, ni ne s'annule lui-même")
    func doubleClick() async throws {
        var timing = BridgeEnvironment.Timing.fast
        timing.minimumToggleInterval = .seconds(10)
        let harness = BridgeHarness(timing: timing)
        await harness.discover(raop: [Devices.genevaRAOP])

        harness.state.toggleStreaming()
        harness.state.toggleStreaming()
        #expect(await eventually { harness.state.isStreaming })
        #expect(await staysFalse { harness.captures.count > 1 })
        #expect(await staysFalse { !harness.state.isStreaming })
        #expect(harness.factory.senders(Devices.genevaID).count == 1)
    }

    @Test("Pendant une transition, le bouton ne répond pas")
    func transitionsAreExclusive() async throws {
        let harness = BridgeHarness()
        await harness.discover(raop: [Devices.genevaRAOP])
        harness.state.toggleStreaming()
        #expect(harness.state.streamingPhase == .starting)
        #expect(!harness.state.isStreaming)
        #expect(!harness.state.canToggleStreaming)
        harness.state.toggleStreaming()
        #expect(await eventually { harness.state.isStreaming })
        #expect(harness.captures.count == 1)
        await harness.stopStreaming()
    }

    @Test("Sans enceinte cochée, le bouton ne répond pas")
    func nothingChecked() async throws {
        let harness = BridgeHarness()
        await harness.discover(raop: [Devices.genevaRAOP])
        try #require(harness.output(Devices.genevaID)).isEnabled = false
        #expect(!harness.state.canToggleStreaming)
        harness.state.toggleStreaming()
        #expect(harness.state.streamingPhase == .idle)
        #expect(await staysFalse { harness.captures.count > 0 })
    }

    @Test("L'arrêt remet tout au repos, et la boucle de suivi n'écrit plus rien")
    func stopIsClean() async throws {
        let harness = BridgeHarness()
        await harness.discover(raop: [Devices.genevaRAOP])
        await harness.startStreaming(expecting: [Devices.genevaID])
        #expect(harness.activity.isHeld)
        let sender = try #require(harness.factory.latest(Devices.genevaID))
        let geneva = try #require(harness.output(Devices.genevaID))

        await harness.stopStreaming()
        #expect(geneva.connection == .idle)
        #expect(!harness.state.isStreaming)
        #expect(!harness.activity.isHeld)
        #expect(await sender.stopCount >= 1)

        // Une consigne touchée après l'arrêt ne part pas : plus personne ne la lit.
        let pushed = await sender.pushedVolumes.count
        geneva.trimDB = 5
        #expect(await staysFalse { await sender.pushedVolumes.count > pushed })
        #expect(await staysFalse { geneva.connection != .idle })
    }

    @Test("Le processus ne s'endort pas pendant une diffusion : App Nap casserait le cadencement")
    func activityIsHeldWhileStreaming() async throws {
        let harness = BridgeHarness()
        await harness.discover(raop: [Devices.genevaRAOP])
        #expect(!harness.activity.isHeld)
        await harness.startStreaming(expecting: [Devices.genevaID])
        #expect(harness.activity.isHeld)
        await harness.stopStreaming()
        #expect(!harness.activity.isHeld)
        #expect(harness.activity.beginCount == 1)
    }

    @Test("Démarrer, arrêter, redémarrer : les réglages suivent et rien ne reste")
    func restartAfterStop() async throws {
        let harness = BridgeHarness()
        await harness.discover(raop: [Devices.genevaRAOP])
        await harness.startStreaming(expecting: [Devices.genevaID])
        await harness.stopStreaming()
        harness.state.masterVolumeDB = -30
        await harness.startStreaming(expecting: [Devices.genevaID])
        let sender = try #require(harness.factory.latest(Devices.genevaID))
        #expect(harness.factory.senders(Devices.genevaID).count == 2)
        #expect(await sender.startedVolume == -15)
        #expect(await staysFalse { await !sender.pushedVolumes.isEmpty })
        await harness.stopStreaming()
    }
}

@Suite("État — réglages d'une enceinte AirPlay 1", .serialized)
struct BridgeStateUnconfirmedAnnouncementTests {
    private let blankGeneva = AirPlay2Device(
        serviceName: "Geneva", host: "192.168.1.42", port: 7000, txt: [:]
    )

    @Test("Une recherche creuse ne coûte ni la coche ni les réglages de la Geneva")
    func singleBadRoundKeepsSettings() async throws {
        let harness = BridgeHarness()
        await harness.discover(raop: [Devices.genevaRAOP], airplay2: [Devices.genevaAirPlay2])
        let geneva = try #require(harness.output(Devices.genevaID))
        geneva.trimDB = 3
        geneva.delayMS = 25
        geneva.bassBoostDB = 6
        harness.state.flushSettings()

        await harness.discover(raop: [], airplay2: [blankGeneva])
        #expect(harness.output(Devices.genevaID) === geneva)
        #expect(harness.output("airplay2/Geneva") == nil)
        #expect(geneva.presence == .online)
        harness.state.flushSettings()
        #expect(harness.store.stored.outputs[Devices.genevaID]?.bassBoostDB == 6)

        await harness.discover(raop: [Devices.genevaRAOP], airplay2: [Devices.genevaAirPlay2])
        #expect(harness.output(Devices.genevaID) === geneva)
        #expect(geneva.isEnabled)
        #expect(geneva.trimDB == 3)
        #expect(geneva.delayMS == 25)
    }

    @Test("La Geneva allumée ne finit pas hors ligne après une annonce AirPlay 2 sans TXT")
    func blankAnnouncementLeavesNoGhost() async throws {
        let harness = BridgeHarness()
        await harness.discover(raop: [Devices.genevaRAOP], airplay2: [Devices.genevaAirPlay2])

        await harness.discover(raop: [], airplay2: [blankGeneva])
        for _ in 0..<4 {
            await harness.discover(raop: [Devices.genevaRAOP], airplay2: [Devices.genevaAirPlay2])
        }

        #expect(harness.output(Devices.genevaID)?.presence == .online)
        #expect(harness.output("airplay2/Geneva") == nil)
    }

    /// Le cas que la règle ne doit pas casser : un HomePod déjà vu avec le bit 48 dont le TXT se perd
    /// le temps d'une recherche reste une seule ligne, sur le bon protocole.
    @Test("Un HomePod confirmé garde sa ligne quand son TXT se perd")
    func confirmedHomePodStillAbsorbs() async throws {
        let harness = BridgeHarness()
        await harness.discover(raop: [Devices.leftRAOP], airplay2: [Devices.left])
        let left = try #require(harness.output(Devices.leftID))

        let blank = AirPlay2Device(
            serviceName: "Salon", host: Devices.left.host, port: 7000, txt: [:]
        )
        await harness.discover(raop: [Devices.leftRAOP], airplay2: [blank])

        #expect(harness.state.outputs.map(\.id) == [Devices.leftID])
        #expect(harness.output(Devices.leftID) === left)
        #expect(left.presence == .online)
    }
}

@Suite("État — source")
struct BridgeStateSourceTests {
    private let music = CaptureSource.application(pids: [42], name: "Music", bundleID: "com.apple.Music")

    @Test("Changer de source pendant une diffusion la relance sur la nouvelle")
    func sourceChangeRestarts() async throws {
        let harness = BridgeHarness()
        harness.sources = [.systemWide, music, .inputDevice]
        harness.state.refreshSources()
        await harness.discover(raop: [Devices.genevaRAOP])
        await harness.startStreaming(expecting: [Devices.genevaID])
        let first = try #require(harness.factory.latest(Devices.genevaID))
        #expect(harness.captures.count == 1)

        harness.state.selectSource(id: music.id)
        #expect(harness.state.isRestarting)
        #expect(await eventually { harness.captures.count == 2 })
        #expect(await eventually { !harness.state.isRestarting && harness.state.isStreaming })
        #expect(await first.stopCount >= 1)
        #expect(await eventually { harness.output(Devices.genevaID)?.connection == .streaming })

        guard case let .processTap(mode)? = harness.captures.last?.source,
            case let .processes(pids) = mode
        else {
            Issue.record("la capture n'est pas celle de l'application")
            return
        }
        #expect(pids == [42])
        await harness.stopStreaming()
    }

    @Test("Hors diffusion, changer de source ne démarre rien")
    func sourceChangeOutsideSession() async {
        let harness = BridgeHarness()
        harness.sources = [.systemWide, music, .inputDevice]
        harness.state.refreshSources()
        harness.state.selectSource(id: music.id)
        #expect(harness.state.selectedSource == music)
        #expect(await staysFalse { harness.captures.count > 0 })
    }

    @Test("Resélectionner la source en cours ne relance pas")
    func sameSourceDoesNotRestart() async {
        let harness = BridgeHarness()
        await harness.discover(raop: [Devices.genevaRAOP])
        await harness.startStreaming(expecting: [Devices.genevaID])
        harness.state.selectSource(id: CaptureSource.systemWide.id)
        #expect(!harness.state.isRestarting)
        #expect(await staysFalse { harness.captures.count > 1 })
        await harness.stopStreaming()
    }

    @Test("Deux changements rapprochés ne font qu'une relance, sur le dernier choix")
    func rapidChangesCoalesce() async throws {
        let harness = BridgeHarness()
        harness.sources = [.systemWide, music, .inputDevice]
        harness.state.refreshSources()
        await harness.discover(raop: [Devices.genevaRAOP])
        await harness.startStreaming(expecting: [Devices.genevaID])

        harness.state.selectSource(id: music.id)
        harness.state.selectSource(id: CaptureSource.inputDevice.id)
        #expect(await eventually { !harness.state.isRestarting && harness.state.isStreaming })
        #expect(harness.captures.count == 2)
        guard case .inputDevice? = harness.captures.last?.source else {
            Issue.record("la relance n'a pas pris le dernier choix")
            return
        }
        await harness.stopStreaming()
    }

    @Test("L'option de son du Mac part au moteur, et la changer relance la diffusion")
    func muteLocalOutput() async throws {
        let harness = BridgeHarness()
        await harness.discover(raop: [Devices.genevaRAOP])
        await harness.startStreaming(expecting: [Devices.genevaID])
        #expect(harness.captures.last?.options.muteLocalOutput == false)

        harness.state.muteLocalOutput = true
        #expect(await eventually { harness.captures.count == 2 })
        #expect(harness.captures.last?.options.muteLocalOutput == true)
        #expect(await eventually { harness.state.isStreaming && !harness.state.isRestarting })
        await harness.stopStreaming()
    }

    @Test("Une application qui cesse de jouer ne fait pas basculer une diffusion en cours")
    func pausedApplicationKeepsCapture() async throws {
        let harness = BridgeHarness()
        harness.sources = [.systemWide, music, .inputDevice]
        harness.state.refreshSources()
        harness.state.selectSource(id: music.id)
        await harness.discover(raop: [Devices.genevaRAOP])
        await harness.startStreaming(expecting: [Devices.genevaID])

        harness.sources = [.systemWide, .inputDevice]
        harness.state.panelDidOpen()
        #expect(harness.state.selectedSource == music)
        #expect(harness.state.sources.contains(music))
        #expect(await staysFalse { harness.captures.count > 1 })
        await harness.stopStreaming()

        // La diffusion finie, la sélection retombe sur le mode global, et le choix attend son
        // retour.
        harness.state.refreshSources()
        #expect(harness.state.selectedSource == .systemWide)
        harness.sources = [.systemWide, music, .inputDevice]
        harness.state.refreshSources()
        #expect(harness.state.selectedSource == music)
    }

    /// Vérifié sur Dia le 2026-08-11 : le son vient d'un processus de rendu créé à la demande. Une
    /// capture sur les PID d'un ancien relevé rendrait un silence numérique, sans erreur.
    @Test("Les PID d'une application sont relus au démarrage")
    func startReadsFreshPIDs() async throws {
        let harness = BridgeHarness()
        harness.sources = [.systemWide, music, .inputDevice]
        harness.state.refreshSources()
        harness.state.selectSource(id: music.id)
        await harness.discover(raop: [Devices.genevaRAOP])

        harness.sources = [
            .systemWide,
            .application(pids: [42, 77], name: "Music", bundleID: "com.apple.Music"),
            .inputDevice,
        ]
        await harness.startStreaming(expecting: [Devices.genevaID])
        guard case let .processTap(mode)? = harness.captures.last?.source,
            case let .processes(pids) = mode
        else {
            Issue.record("la capture n'est pas celle de l'application")
            return
        }
        #expect(pids == [42, 77])
        await harness.stopStreaming()
    }

    @Test("Des PID renouvelés n'égarent pas la sélection")
    func newPIDsKeepSelection() {
        let harness = BridgeHarness()
        harness.sources = [.systemWide, music, .inputDevice]
        harness.state.refreshSources()
        harness.state.selectSource(id: music.id)

        let renewed = CaptureSource.application(pids: [42, 77], name: "Music", bundleID: "com.apple.Music")
        harness.sources = [.systemWide, renewed, .inputDevice]
        harness.state.refreshSources()
        #expect(harness.state.selectedSource == renewed)
    }
}

@Suite("État — découverte continue")
struct BridgeStateDiscoveryTests {
    @Test("Une recherche conserve les objets, et les réglages avec eux")
    func identityIsKept() async throws {
        let harness = BridgeHarness()
        await harness.discover(raop: [Devices.genevaRAOP], airplay2: [Devices.left])
        let geneva = try #require(harness.output(Devices.genevaID))
        geneva.trimDB = 3

        await harness.discover(raop: [Devices.genevaRAOP], airplay2: [Devices.left])
        #expect(harness.output(Devices.genevaID) === geneva)
        #expect(geneva.trimDB == 3)
    }

    @Test("Une adresse qui change suit, sans recréer la sortie")
    func hostFollows() async throws {
        let harness = BridgeHarness()
        await harness.discover(raop: [Devices.genevaRAOP])
        let geneva = try #require(harness.output(Devices.genevaID))
        let moved = RAOPDevice(
            serviceName: "AABBCCDDEEFF@Geneva", host: "192.168.1.99", port: 7001, txt: [:]
        )
        await harness.discover(raop: [moved])
        #expect(harness.output(Devices.genevaID) === geneva)
        #expect(geneva.host == "192.168.1.99")
        #expect(geneva.port == 7001)
    }

    @Test("Une sortie cochée qui disparaît reste affichée hors ligne, puis revient à sa place")
    func checkedOutputGoesOffline() async throws {
        let harness = BridgeHarness()
        await harness.discover(raop: [Devices.genevaRAOP], airplay2: [Devices.left])
        let geneva = try #require(harness.output(Devices.genevaID))

        await harness.discover(airplay2: [Devices.left])
        #expect(geneva.presence == .online)
        await harness.discover(airplay2: [Devices.left])
        #expect(geneva.presence == .offline)
        #expect(geneva.statusLine?.text == "Hors ligne")
        #expect(harness.state.outputs.map(\.id) == [Devices.genevaID, Devices.leftID])

        await harness.discover(raop: [Devices.genevaRAOP], airplay2: [Devices.left])
        #expect(harness.output(Devices.genevaID) === geneva)
        #expect(geneva.presence == .online)
        #expect(geneva.statusLine == nil)
    }

    @Test("Une sortie en diffusion qui disparaît reste affichée, et le moteur continue de la chercher")
    func streamingOutputStays() async throws {
        let harness = BridgeHarness()
        await harness.discover(raop: [Devices.genevaRAOP])
        await harness.startStreaming(expecting: [Devices.genevaID])
        let geneva = try #require(harness.output(Devices.genevaID))

        await harness.state.refreshOutputs()
        harness.discovery.result = OutputDiscoveryResult()
        await harness.state.refreshOutputs()
        await harness.state.refreshOutputs()
        #expect(harness.output(Devices.genevaID) === geneva)
        #expect(geneva.presence == .offline)
        // L'état du moteur prime sur ce qu'annonce le réseau.
        #expect(geneva.statusLine == nil)
        await harness.stopStreaming()
    }

    @Test("Deux recherches demandées en même temps n'en font qu'une")
    func noConcurrentRounds() async {
        let harness = BridgeHarness()
        harness.discovery.holds = true
        async let first: Void = harness.state.refreshOutputs()
        #expect(await eventually { harness.discovery.roundCount == 1 })
        #expect(harness.state.isBrowsing)
        async let second: Void = harness.state.refreshOutputs()
        async let third: Void = harness.state.refreshOutputs()
        #expect(await staysFalse { harness.discovery.roundCount > 1 })
        harness.discovery.release()
        _ = await (first, second, third)
        #expect(harness.discovery.maximumRunning == 1)
        #expect(!harness.state.isBrowsing)

        // La recherche finie, la suivante peut partir.
        await harness.state.refreshOutputs()
        #expect(harness.discovery.roundCount == 2)
    }

    @Test("La recherche périodique tourne dès le lancement, sans fenêtre, sans chevauchement")
    func periodicRounds() async {
        var timing = BridgeEnvironment.Timing.fast
        timing.discoveryInterval = .milliseconds(5)
        let harness = BridgeHarness(timing: timing)
        harness.state.startBackgroundWork()
        harness.state.startBackgroundWork()
        #expect(await eventually { harness.discovery.roundCount >= 4 })
        #expect(harness.discovery.maximumRunning == 1)
    }

    /// La découverte ne fait que des requêtes DNS : elle n'a aucune raison de s'interrompre pendant
    /// une diffusion, et aucun effet sur elle.
    @Test("La recherche continue pendant une diffusion, sans toucher à la session")
    func roundsContinueDuringSession() async throws {
        var timing = BridgeEnvironment.Timing.fast
        timing.discoveryInterval = .milliseconds(5)
        let harness = BridgeHarness(timing: timing)
        harness.discovery.result = OutputDiscoveryResult(raop: [Devices.genevaRAOP])
        harness.state.startBackgroundWork()
        #expect(await eventually { harness.output(Devices.genevaID) != nil })

        await harness.startStreaming(expecting: [Devices.genevaID])
        let sender = try #require(harness.factory.latest(Devices.genevaID))
        let rounds = harness.discovery.roundCount
        #expect(await eventually { harness.discovery.roundCount >= rounds + 3 })
        #expect(harness.discovery.maximumRunning == 1)
        #expect(await sender.stopCount == 0)
        #expect(harness.factory.senders(Devices.genevaID).count == 1)
        await harness.stopStreaming()
    }

    @Test("L'ouverture du panneau rafraîchit, sauf juste après une recherche")
    func panelRefresh() async {
        var timing = BridgeEnvironment.Timing.fast
        timing.panelRefreshMinimumAge = .seconds(60)
        let harness = BridgeHarness(timing: timing)
        harness.state.panelDidOpen()
        #expect(await eventually { harness.discovery.roundCount == 1 })
        #expect(await eventually { !harness.state.isBrowsing })
        harness.state.panelDidOpen()
        #expect(await staysFalse { harness.discovery.roundCount > 1 })
    }

    @Test("L'Apple TV n'est pas cochée d'office, la Geneva et les HomePod si")
    func pairingIsUncheckedByDefault() async throws {
        let harness = BridgeHarness()
        await harness.discover(raop: Devices.allRAOP, airplay2: Devices.allAirPlay2)

        let appleTV = try #require(harness.output(Devices.appleTVRaopID))
        #expect(!appleTV.isEnabled)
        #expect(appleTV.unavailability == .pairingRequired)
        #expect(appleTV.statusLine?.text == "Appairage requis")

        for id in [Devices.genevaID, Devices.leftID, Devices.rightID] {
            let output = try #require(harness.output(id))
            #expect(output.isEnabled)
            #expect(output.statusLine == nil)
        }

        // Diffuser ne la contacte donc pas : plus de ligne rouge au premier essai.
        await harness.startStreaming(
            expecting: [Devices.genevaID, Devices.leftID, Devices.rightID]
        )
        #expect(harness.factory.senders(Devices.appleTVRaopID).isEmpty)
        await harness.stopStreaming()
    }

    @Test("La cocher quand même reste possible : le récepteur tranchera")
    func pairingCanStillBeTried() async throws {
        let harness = BridgeHarness()
        await harness.discover(raop: [Devices.appleTVRAOP], airplay2: [Devices.appleTVPairingOnly])
        let appleTV = try #require(harness.output(Devices.appleTVRaopID))
        appleTV.isEnabled = true
        await harness.startStreaming(expecting: [Devices.appleTVRaopID])
        // Elle joue : la mention était trop prudente, elle s'efface.
        #expect(appleTV.statusLine == nil)
        await harness.stopStreaming()
    }

    @Test("Seule la toute première découverte coche d'office : ensuite, c'est à l'utilisateur")
    func onlyFirstDiscoveryChecks() async throws {
        let harness = BridgeHarness()
        // Une recherche vide n'en est pas une : le premier appareil vu reste « le premier ».
        await harness.discover()
        await harness.discover(raop: [Devices.genevaRAOP])
        #expect(try #require(harness.output(Devices.genevaID)).isEnabled)

        await harness.discover(raop: [Devices.genevaRAOP], airplay2: [Devices.left])
        let left = try #require(harness.output(Devices.leftID))
        #expect(!left.isEnabled)
    }

    @Test("Avec des réglages déjà en place, une enceinte inconnue n'est pas cochée")
    func knownInstallationDoesNotCheck() async throws {
        var settings = BridgeSettings()
        settings.outputs[Devices.genevaID] = BridgeSettings.Output(displayName: "Geneva")
        let harness = BridgeHarness(settings: settings)
        await harness.discover(raop: [Devices.genevaRAOP], airplay2: [Devices.left])
        #expect(try #require(harness.output(Devices.genevaID)).isEnabled)
        #expect(!(try #require(harness.output(Devices.leftID))).isEnabled)
    }

    /// Cocher, c'est jouer : une enceinte de passage ne doit pas se mettre à chanter toute seule.
    @Test("Une enceinte découverte pendant une diffusion n'y entre jamais d'elle-même")
    func newOutputDuringSessionStaysOut() async throws {
        let harness = BridgeHarness()
        await harness.discover(raop: [Devices.genevaRAOP])
        await harness.startStreaming(expecting: [Devices.genevaID])

        await harness.discover(raop: [Devices.genevaRAOP], airplay2: [Devices.left])
        let left = try #require(harness.output(Devices.leftID))
        #expect(!left.isEnabled)
        #expect(await staysFalse { !harness.factory.senders(Devices.leftID).isEmpty })
        await harness.stopStreaming()
    }

    @Test("Le plan ne se sauvegarde que si le rattachement a changé quelque chose")
    func layoutIsSavedOnlyWhenBound() async {
        let harness = BridgeHarness()
        harness.layout = RoomLayout(
            objects: [
                RoomObject(
                    kind: .speaker(outputID: nil), position: .zero,
                    size: CGSize(width: 0.45, height: 0.45), elevation: 1.8, name: "Geneva"
                )
            ]
        )
        await harness.discover()
        #expect(harness.layoutSaveCount == 0)

        await harness.discover(raop: [Devices.genevaRAOP])
        #expect(harness.layoutSaveCount == 1)
        guard case let .speaker(outputID)? = harness.state.roomLayout.objects.first?.kind else {
            Issue.record("l'enceinte a disparu du plan")
            return
        }
        #expect(outputID == Devices.genevaID)

        await harness.discover(raop: [Devices.genevaRAOP])
        #expect(harness.layoutSaveCount == 1)
    }

    @Test("Une liste vide dit quoi vérifier, et le message s'efface au retour d'une enceinte")
    func emptyNotice() async {
        let harness = BridgeHarness()
        await harness.discover()
        #expect(harness.state.hasCompletedDiscovery)
        #expect(harness.state.discoveryNotice?.contains("Réseau local") == true)
        await harness.discover(raop: [Devices.genevaRAOP])
        #expect(harness.state.discoveryNotice == nil)
    }
}

@Suite("État — veille")
struct BridgeStateSleepTests {
    @Test("La politique de reprise : ce qui s'est arrêté à cause de la veille, et rien d'autre")
    func policy() {
        var policy = SleepResumePolicy()
        var mustStop = policy.systemWillSleep(isStreaming: false)
        #expect(!mustStop)
        #expect(!policy.shouldResumeAfterWake)

        mustStop = policy.systemWillSleep(isStreaming: true)
        #expect(mustStop)
        #expect(policy.shouldResumeAfterWake)

        // Une seconde veille pendant le délai de reprise, alors que plus rien ne tourne.
        mustStop = policy.systemWillSleep(isStreaming: false)
        #expect(!mustStop)
        #expect(policy.shouldResumeAfterWake)

        policy.resumeDidStart()
        #expect(!policy.shouldResumeAfterWake)

        mustStop = policy.systemWillSleep(isStreaming: true)
        #expect(mustStop)
        policy.userTookOver()
        #expect(!policy.shouldResumeAfterWake)
    }

    @Test("La veille arrête la diffusion, le réveil la reprend")
    func sleepAndWake() async throws {
        let harness = BridgeHarness()
        await harness.discover(raop: [Devices.genevaRAOP])
        await harness.startStreaming(expecting: [Devices.genevaID])
        let first = try #require(harness.factory.latest(Devices.genevaID))

        harness.state.systemWillSleep()
        #expect(await eventually { harness.state.streamingPhase == .idle })
        #expect(await first.stopCount >= 1)

        harness.state.systemDidWake()
        #expect(await eventually { harness.state.isStreaming })
        #expect(await eventually { harness.output(Devices.genevaID)?.connection == .streaming })
        #expect(harness.captures.count == 2)
        await harness.stopStreaming()
    }

    @Test("Le Mac qui se réveille sans avoir rien interrompu ne démarre rien")
    func wakeWithoutSession() async {
        let harness = BridgeHarness()
        await harness.discover(raop: [Devices.genevaRAOP])
        harness.state.systemWillSleep()
        harness.state.systemDidWake()
        #expect(await staysFalse { harness.captures.count > 0 })
    }

    @Test("Le geste de l'utilisateur prime sur la reprise programmée")
    func userWinsOverResume() async throws {
        var timing = BridgeEnvironment.Timing.fast
        timing.wakeResumeDelay = .milliseconds(80)
        let harness = BridgeHarness(timing: timing)
        await harness.discover(raop: [Devices.genevaRAOP], airplay2: [Devices.left])
        await harness.startStreaming(expecting: [Devices.genevaID, Devices.leftID])

        harness.state.systemWillSleep()
        #expect(await eventually { harness.state.streamingPhase == .idle })
        harness.state.systemDidWake()

        // L'utilisateur relance lui-même pendant le délai : la reprise n'en fait pas une seconde.
        harness.state.toggleStreaming()
        #expect(await eventually { harness.state.isStreaming })
        #expect(await staysFalse(during: .milliseconds(150)) { harness.captures.count > 2 })
        await harness.stopStreaming()
    }

    @Test("Une nouvelle veille pendant le délai reporte la reprise au réveil suivant")
    func secondSleepDefersResume() async throws {
        var timing = BridgeEnvironment.Timing.fast
        timing.wakeResumeDelay = .milliseconds(60)
        let harness = BridgeHarness(timing: timing)
        await harness.discover(raop: [Devices.genevaRAOP])
        await harness.startStreaming(expecting: [Devices.genevaID])

        harness.state.systemWillSleep()
        #expect(await eventually { harness.state.streamingPhase == .idle })
        harness.state.systemDidWake()
        harness.state.systemWillSleep()
        #expect(await staysFalse(during: .milliseconds(120)) { harness.captures.count > 1 })

        harness.state.systemDidWake()
        #expect(await eventually { harness.state.isStreaming })
        await harness.stopStreaming()
    }

    @Test("Aucune recherche pendant la veille : le réseau n'est pas là pour répondre")
    func noDiscoveryWhileAsleep() async {
        var timing = BridgeEnvironment.Timing.fast
        timing.discoveryInterval = .milliseconds(5)
        let harness = BridgeHarness(timing: timing)
        harness.state.startBackgroundWork()
        #expect(await eventually { harness.discovery.roundCount >= 1 })
        harness.state.systemWillSleep()
        let rounds = harness.discovery.roundCount
        #expect(await staysFalse { harness.discovery.roundCount > rounds + 1 })
    }
}

@Suite("État — fermeture de l'application")
struct BridgeStateShutdownTests {
    private func lifecycle(
        _ harness: BridgeHarness, coreAudio: StubCoreAudioRestarter,
        budget: QuitSequence.Budget = AppLifecycle.quitBudget
    ) -> AppLifecycle {
        AppLifecycle(
            state: harness.state,
            loginItem: LoginItemController(service: PreviewLoginItemService()),
            dock: DockIconController(presenter: StubPresenter()),
            coreAudio: coreAudio, quitBudget: budget
        )
    }

    /// La relance de coreaudiod vaut à chaque fermeture : AppKit attend donc sa réponse même sans
    /// diffusion, au lieu de quitter sur-le-champ.
    @Test("Quitter sans diffusion passe aussi par la relance de coreaudiod, et sauvegarde")
    func quitWhileIdle() async {
        let harness = BridgeHarness()
        let coreAudio = StubCoreAudioRestarter()
        let lifecycle = lifecycle(harness, coreAudio: coreAudio)
        harness.state.masterVolumeDB = -9
        var replies = 0
        var repliedBeforeRestart = false
        coreAudio.onRestart = { repliedBeforeRestart = replies > 0 }
        #expect(lifecycle.handleTerminationRequest { replies += 1 } == .terminateLater)
        #expect(await eventually { replies == 1 })
        #expect(coreAudio.restartCount == 1)
        #expect(!repliedBeforeRestart)
        #expect(harness.store.stored.masterVolumeDB == -9)
        #expect(harness.layoutSaveCount == 1)
    }

    /// Sans cela, un récepteur reste bloqué sur une session sans `TEARDOWN`.
    @Test("Quitter pendant une diffusion attend l'arrêt des sorties avant de répondre")
    func quitWhileStreaming() async throws {
        let harness = BridgeHarness()
        await harness.discover(raop: [Devices.genevaRAOP])
        await harness.startStreaming(expecting: [Devices.genevaID])
        let sender = try #require(harness.factory.latest(Devices.genevaID))
        let coreAudio = StubCoreAudioRestarter()
        let lifecycle = lifecycle(harness, coreAudio: coreAudio)

        var replies = 0
        #expect(lifecycle.handleTerminationRequest { replies += 1 } == .terminateLater)
        // Une seconde demande (`terminate` répété, SIGTERM) n'en lance pas une seconde.
        #expect(lifecycle.handleTerminationRequest { replies += 1 } == .terminateLater)
        #expect(await eventually { replies == 1 })
        #expect(await sender.stopCount >= 1)
        #expect(harness.state.streamingPhase == .idle)
        #expect(await staysFalse { replies > 1 })
        #expect(coreAudio.restartCount == 1)
    }

    /// L'ordre voulu par Baptiste, de bout en bout : le vrai moteur, des senders et une capture sans
    /// matériel qui notent leur arrêt, un volume du Mac sans Core Audio.
    @Test("Quitter en diffusion : TEARDOWN, arrêt de la capture, son du Mac rendu, relance, réponse")
    func quitOrder() async throws {
        let system = FakeSystemVolume()
        let harness = BridgeHarness(systemVolume: system)
        await harness.discover(raop: [Devices.genevaRAOP], airplay2: [Devices.left])
        await harness.startStreaming(expecting: [Devices.genevaID, Devices.leftID])
        #expect(await eventually { system.current?.volume == 0.6 })
        let coreAudio = StubCoreAudioRestarter()
        var macRestoredAtRestart = false
        coreAudio.onRestart = {
            harness.stopOrder.record("relance")
            macRestoredAtRestart = system.current == FakeSystemVolume.Device.speakers
        }
        let lifecycle = lifecycle(harness, coreAudio: coreAudio)

        var replies = 0
        let request = lifecycle.handleTerminationRequest {
            harness.stopOrder.record("réponse")
            replies += 1
        }
        #expect(request == .terminateLater)
        #expect(await eventually { replies == 1 })

        let events = harness.stopOrder.events
        let capture = try #require(events.firstIndex(of: "capture"), "\(events)")
        #expect(
            Set(events[..<capture])
                == ["TEARDOWN \(Devices.genevaID)", "TEARDOWN \(Devices.leftID)"],
            "\(events)"
        )
        #expect(Array(events[capture...]) == ["capture", "relance", "réponse"])
        #expect(macRestoredAtRestart)
    }

    @Test("Sans la règle sudoers, la relance échoue et l'app quitte quand même")
    func failedRestartStillQuits() async throws {
        let harness = BridgeHarness()
        await harness.discover(raop: [Devices.genevaRAOP])
        await harness.startStreaming(expecting: [Devices.genevaID])
        let sender = try #require(harness.factory.latest(Devices.genevaID))
        let coreAudio = StubCoreAudioRestarter(.answer(.exited(status: 1)))
        let lifecycle = lifecycle(harness, coreAudio: coreAudio)

        var replies = 0
        #expect(lifecycle.handleTerminationRequest { replies += 1 } == .terminateLater)
        #expect(await eventually { replies == 1 })
        #expect(await sender.stopCount >= 1)
        #expect(coreAudio.restartCount == 1)
    }

    @Test("Une relance figée ne retient la fermeture que le temps de sa part de la borne")
    func silentRestartIsBounded() async {
        let harness = BridgeHarness()
        let coreAudio = StubCoreAudioRestarter(.hang)
        let budget = QuitSequence.Budget(
            outputs: .milliseconds(300), coreAudioRestart: .milliseconds(100)
        )
        let lifecycle = lifecycle(harness, coreAudio: coreAudio, budget: budget)

        var replies = 0
        let start = ContinuousClock.now
        #expect(lifecycle.handleTerminationRequest { replies += 1 } == .terminateLater)
        #expect(await eventually(timeout: .seconds(3)) { replies == 1 })
        let elapsed = start.duration(to: .now)
        #expect(elapsed >= budget.coreAudioRestart)
        #expect(elapsed < budget.total + .milliseconds(500))
        #expect(coreAudio.timeouts == [budget.coreAudioRestart])
        coreAudio.release()
    }

    @Test("Un récepteur muet ne retient pas la fermeture au-delà de la borne")
    func shutdownIsBounded() async throws {
        var tuning = BridgeHarness.fastTuning
        tuning.stopTimeout = .seconds(30)
        let harness = BridgeHarness(tuning: tuning)
        await harness.discover(raop: [Devices.genevaRAOP])
        harness.factory.makeStopHang(Devices.genevaID)
        await harness.startStreaming(expecting: [Devices.genevaID])
        let sender = try #require(harness.factory.latest(Devices.genevaID))

        let elapsed = await ContinuousClock().measure {
            await harness.state.shutdown(timeout: .milliseconds(100))
        }
        #expect(elapsed < .seconds(2))
        await sender.releaseStop()
    }

    @Test("L'arrêt coupe aussi la recherche périodique")
    func shutdownStopsBackgroundWork() async {
        var timing = BridgeEnvironment.Timing.fast
        timing.discoveryInterval = .milliseconds(5)
        let harness = BridgeHarness(timing: timing)
        harness.state.startBackgroundWork()
        #expect(await eventually { harness.discovery.roundCount >= 1 })
        await harness.state.shutdown(timeout: .seconds(1))
        try? await Task.sleep(for: .milliseconds(10))
        let rounds = harness.discovery.roundCount
        #expect(await staysFalse { harness.discovery.roundCount > rounds })
    }
}
