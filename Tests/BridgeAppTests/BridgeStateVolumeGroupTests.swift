import AudioCore
import Foundation
import Testing

@testable import BridgeApp

// Les groupes de volume et le silence par enceinte, de `BridgeState` jusqu'aux senders : le vrai
// `BridgeEngine`, avec des senders sans réseau (`BridgeStateTestSupport`).

/// La paire stéréo de Baptiste : même `tsid` sur les deux HomePod.
enum PairDevices {
    static let tsid = "4C3A4D8B-1F2E-4E77-9B0A-PAIRE-SALON"

    static let left = AirPlay2Device(
        serviceName: "Salon", host: "192.168.1.158", port: 7000,
        txt: [
            "features": Devices.homePodFeatures, "model": "AudioAccessory5,1", "tsid": tsid,
        ]
    )
    static let right = AirPlay2Device(
        serviceName: "Salon (2)", host: "192.168.1.88", port: 7000,
        txt: [
            "features": Devices.homePodFeatures, "model": "AudioAccessory5,1", "tsid": tsid,
        ]
    )

    /// Le volume du fil qu'aurait une sortie seule, au master par défaut (−24 dB).
    static func soloVolume(trim: Double, master: Double = BridgeState.defaultMasterVolumeDB) -> Float {
        BridgeState.receiverVolume(forGainDB: min(max(master + trim, -60), 0))
    }
}

/// Le banc de la paire, réglée comme chez Baptiste : Salon +0,5 dB, Salon (2) −11,5 dB.
@MainActor
private func pairHarness(
    settings: BridgeSettings = BridgeSettings(), withGeneva: Bool = true
) async throws -> (BridgeHarness, left: OutputState, right: OutputState) {
    let harness = BridgeHarness(settings: settings)
    await harness.discover(
        raop: withGeneva ? [Devices.genevaRAOP] : [],
        airplay2: [PairDevices.left, PairDevices.right]
    )
    let left = try #require(harness.output(Devices.leftID))
    let right = try #require(harness.output(Devices.rightID))
    left.trimDB = 0.5
    right.trimDB = -11.5
    return (harness, left, right)
}

@Suite("Groupes de volume — le calcul")
struct VolumeGroupsComputationTests {
    private func member(
        _ id: String, _ group: String, trim: Double, muted: Bool = false
    ) -> VolumeGroups.Member {
        VolumeGroups.Member(id: id, groupKey: group, trimDB: trim, isMuted: muted)
    }

    @Test("Même tsid, +0,5 et −11,5 : même volume, gains 0 et −6 dB (l'écart sur l'échelle du fil)")
    func pairSharesVolume() throws {
        let plan = VolumeGroups.settings(
            for: [member("g", "g", trim: 0.5), member("d", "g", trim: -11.5)],
            masterVolumeDB: -24, isMuted: false
        )
        let left = try #require(plan["g"])
        let right = try #require(plan["d"])
        #expect(left.volumeDB == -11.75)
        #expect(right.volumeDB == -11.75)
        #expect(left.level == .unity)
        #expect(right.level == OutputLevel(gainDB: -6))
        // Ce que chacun entend : exactement ce que son propre volume lui aurait donné.
        #expect(right.volumeDB + right.level.gainDB == PairDevices.soloVolume(trim: -11.5))
    }

    @Test("Près de 0 dB, le niveau de chacun reste celui qu'il aurait seul")
    func clampingKeepsSoloLevels() throws {
        let plan = VolumeGroups.settings(
            for: [member("g", "g", trim: 12), member("d", "g", trim: -11.5)],
            masterVolumeDB: -5, isMuted: false
        )
        let right = try #require(plan["d"])
        #expect(right.volumeDB == 0)
        #expect(right.volumeDB + right.level.gainDB == PairDevices.soloVolume(trim: -11.5, master: -5))
    }

    @Test("Seul sous le plancher de l'échelle, un membre est réduit au silence, numériquement")
    func belowFloorIsDigitalSilence() throws {
        let plan = VolumeGroups.settings(
            for: [member("g", "g", trim: 0.5), member("d", "g", trim: -11.5)],
            masterVolumeDB: -50, isMuted: false
        )
        #expect(plan["d"]?.volumeDB == plan["g"]?.volumeDB)
        #expect(plan["d"]?.level.isMuted == true)
        #expect(plan["g"]?.level == .unity)
    }

    @Test("Le silence général passe par le volume, sans toucher aux gains")
    func globalMuteKeepsGains() {
        let members = [member("g", "g", trim: 0.5), member("d", "g", trim: -11.5)]
        let audible = VolumeGroups.settings(for: members, masterVolumeDB: -24, isMuted: false)
        let muted = VolumeGroups.settings(for: members, masterVolumeDB: -24, isMuted: true)
        #expect(muted["g"]?.volumeDB == -144)
        #expect(muted["d"]?.volumeDB == -144)
        #expect(muted["d"]?.level == audible["d"]?.level)
        // Master au minimum : silence quel que soit le trim, comme avant.
        let minimum = VolumeGroups.settings(for: members, masterVolumeDB: -60, isMuted: false)
        #expect(minimum["g"]?.volumeDB == -144)
    }

    @Test("Un membre coupé sort du plus fort ; tout le groupe coupé garde son volume")
    func mutedMemberLeavesReference() {
        let oneMuted = VolumeGroups.settings(
            for: [member("g", "g", trim: 0.5, muted: true), member("d", "g", trim: -11.5)],
            masterVolumeDB: -24, isMuted: false
        )
        #expect(oneMuted["d"]?.volumeDB == PairDevices.soloVolume(trim: -11.5))
        #expect(oneMuted["d"]?.level == .unity)
        #expect(oneMuted["g"]?.volumeDB == PairDevices.soloVolume(trim: -11.5))
        #expect(oneMuted["g"]?.level == OutputLevel(gainDB: 0, isMuted: true))

        let allMuted = VolumeGroups.settings(
            for: [member("g", "g", trim: 0.5, muted: true), member("d", "g", trim: -11.5, muted: true)],
            masterVolumeDB: -24, isMuted: false
        )
        #expect(allMuted["g"]?.volumeDB == -11.75)
        #expect(allMuted["d"]?.level == OutputLevel(gainDB: -6, isMuted: true))
    }

    @Test("Seule dans son groupe, une sortie garde exactement le comportement d'avant")
    func soloIsUnchanged() {
        for trim in stride(from: -12.0, through: 12, by: 0.5) {
            for master in [-60.0, -59, -45, -24, -6, 0] {
                for isMuted in [false, true] {
                    let plan = VolumeGroups.settings(
                        for: [member("geneva", "geneva", trim: trim)],
                        masterVolumeDB: master, isMuted: isMuted
                    )
                    let before: Float =
                        isMuted || master <= -60
                        ? -144 : BridgeState.receiverVolume(forGainDB: min(max(master + trim, -60), 0))
                    #expect(plan["geneva"]?.volumeDB == before)
                    #expect(plan["geneva"]?.level == .unity)
                }
            }
        }
    }
}

@Suite("État — groupes de volume d'une paire stéréo")
struct BridgeStateVolumeGroupTests {
    @Test("Même tsid : le même volume AirPlay part vers les deux, avec des gains de 0 et −6 dB")
    func pairStartsOnCommonVolume() async throws {
        let (harness, _, _) = try await pairHarness(withGeneva: false)
        await harness.startStreaming(expecting: [Devices.leftID, Devices.rightID])
        let leftSender = try #require(harness.factory.latest(Devices.leftID))
        let rightSender = try #require(harness.factory.latest(Devices.rightID))

        #expect(await leftSender.startedVolume == -11.75)
        #expect(await rightSender.startedVolume == -11.75)
        #expect(await leftSender.startedLevel == .unity)
        #expect(await rightSender.startedLevel == OutputLevel(gainDB: -6))
        // Rien à repousser tant que rien ne bouge.
        #expect(await staysFalse { await !rightSender.pushedVolumes.isEmpty })
        #expect(await rightSender.pushedLevels.count == 1)
        await harness.stopStreaming()
    }

    @Test("Bouger le trim du moins fort ne change que son gain")
    func quieterTrimMovesOnlyItsGain() async throws {
        let (harness, _, right) = try await pairHarness(withGeneva: false)
        await harness.startStreaming(expecting: [Devices.leftID, Devices.rightID])
        let leftSender = try #require(harness.factory.latest(Devices.leftID))
        let rightSender = try #require(harness.factory.latest(Devices.rightID))

        right.trimDB = -8
        #expect(await eventually { await rightSender.pushedLevels.last == OutputLevel(gainDB: -4.25) })
        #expect(await staysFalse { await !leftSender.pushedVolumes.isEmpty })
        #expect(await rightSender.pushedVolumes.isEmpty)
        #expect(await leftSender.pushedLevels.count == 1)
        await harness.stopStreaming()
    }

    @Test("Bouger le trim du plus fort change le volume commun, et l'autre garde son niveau")
    func loudestTrimMovesCommonVolume() async throws {
        let (harness, left, _) = try await pairHarness(withGeneva: false)
        await harness.startStreaming(expecting: [Devices.leftID, Devices.rightID])
        let leftSender = try #require(harness.factory.latest(Devices.leftID))
        let rightSender = try #require(harness.factory.latest(Devices.rightID))

        left.trimDB = 2.5
        #expect(await eventually { await leftSender.pushedVolumes.last == -10.75 })
        #expect(await eventually { await rightSender.pushedVolumes.last == -10.75 })
        #expect(await eventually { await rightSender.pushedLevels.last == OutputLevel(gainDB: -7) })
        // Salon (2) entend toujours −17,75 dB, ce que son propre volume lui donnerait.
        let rightLevel = try #require(await rightSender.pushedLevels.last)
        #expect(-10.75 + rightLevel.gainDB == PairDevices.soloVolume(trim: -11.5))
        // Le plus fort reste à 0 dB : rien à lui pousser de ce côté.
        #expect(await leftSender.pushedLevels == [.unity])
        await harness.stopStreaming()
    }

    @Test("La Geneva, sans tsid, garde exactement le comportement d'avant")
    func genevaIsUnchanged() async throws {
        let (harness, left, _) = try await pairHarness()
        let geneva = try #require(harness.output(Devices.genevaID))
        geneva.trimDB = -2
        await harness.startStreaming(expecting: [Devices.genevaID, Devices.leftID, Devices.rightID])
        let sender = try #require(harness.factory.latest(Devices.genevaID))
        #expect(await sender.startedVolume == PairDevices.soloVolume(trim: -2))
        #expect(await sender.startedLevel == .unity)

        // Ce qui bouge dans la paire ne la concerne pas.
        left.trimDB = 3
        try #require(harness.output(Devices.rightID)).isMuted = true
        #expect(await staysFalse(during: .milliseconds(100)) { await !sender.pushedVolumes.isEmpty })

        // Son trim passe tout entier dans son volume AirPlay, et jamais par un gain.
        geneva.trimDB = 4
        #expect(await eventually { await sender.pushedVolumes.last == PairDevices.soloVolume(trim: 4) })
        harness.state.masterVolumeDB = -30
        #expect(await eventually { await sender.pushedVolumes.last == PairDevices.soloVolume(trim: 4, master: -30) })
        #expect(await sender.pushedLevels == [.unity])
        await harness.stopStreaming()
    }

    @Test("Le master ne bouge que le volume commun, jamais les gains")
    func masterMovesOnlyVolume() async throws {
        let (harness, _, _) = try await pairHarness(withGeneva: false)
        await harness.startStreaming(expecting: [Devices.leftID, Devices.rightID])
        let leftSender = try #require(harness.factory.latest(Devices.leftID))
        let rightSender = try #require(harness.factory.latest(Devices.rightID))

        harness.state.masterVolumeDB = -30
        #expect(await eventually { await leftSender.pushedVolumes.last == -14.75 })
        #expect(await eventually { await rightSender.pushedVolumes.last == -14.75 })
        harness.state.isMuted = true
        #expect(await eventually { await rightSender.pushedVolumes.last == -144 })
        harness.state.isMuted = false
        #expect(await eventually { await rightSender.pushedVolumes.last == -14.75 })
        #expect(await rightSender.pushedLevels == [OutputLevel(gainDB: -6)])
        #expect(await leftSender.pushedLevels == [.unity])
        await harness.stopStreaming()
    }

    @Test("Un membre décoché rend l'autre à lui seul : son trim repasse dans son volume")
    func uncheckingDissolvesGroup() async throws {
        let (harness, left, _) = try await pairHarness(withGeneva: false)
        await harness.startStreaming(expecting: [Devices.leftID, Devices.rightID])
        let rightSender = try #require(harness.factory.latest(Devices.rightID))

        left.isEnabled = false
        #expect(await eventually { await rightSender.pushedVolumes.last == PairDevices.soloVolume(trim: -11.5) })
        #expect(await eventually { await rightSender.pushedLevels.last == .unity })

        left.isEnabled = true
        #expect(await eventually { left.connection == .streaming })
        #expect(await eventually { await rightSender.pushedVolumes.last == -11.75 })
        #expect(await eventually { await rightSender.pushedLevels.last == OutputLevel(gainDB: -6) })
        let leftSender = try #require(harness.factory.latest(Devices.leftID))
        #expect(await leftSender.startedVolume == -11.75)
        await harness.stopStreaming()
    }

    @Test("Le tsid découvert en pleine diffusion regroupe les volumes, sans relancer personne")
    func tsidDiscoveredDuringSession() async throws {
        let harness = BridgeHarness()
        await harness.discover(airplay2: [Devices.left, Devices.right])
        try #require(harness.output(Devices.leftID)).trimDB = 0.5
        try #require(harness.output(Devices.rightID)).trimDB = -11.5
        await harness.startStreaming(expecting: [Devices.leftID, Devices.rightID])
        let rightSender = try #require(harness.factory.latest(Devices.rightID))
        #expect(await rightSender.startedVolume == PairDevices.soloVolume(trim: -11.5))

        await harness.discover(airplay2: [PairDevices.left, PairDevices.right])
        #expect(await eventually { await rightSender.pushedVolumes.last == -11.75 })
        #expect(await eventually { await rightSender.pushedLevels.last == OutputLevel(gainDB: -6) })
        #expect(harness.factory.createdCount == 2)
        #expect(await rightSender.stopCount == 0)

        // Une annonce sans TXT ne prouve pas que la paire a disparu.
        let bare = [PairDevices.left, PairDevices.right].map {
            AirPlay2Device(serviceName: $0.serviceName, host: $0.host, port: $0.port, txt: [:])
        }
        await harness.discover(airplay2: bare)
        #expect(harness.output(Devices.rightID)?.tightSyncIdentifier == PairDevices.tsid)
        await harness.stopStreaming()
    }
}

@Suite("État — silence par enceinte")
struct BridgeStateSpeakerMuteTests {
    @Test("Couper le plus fort : il reste dans le moteur, seuls son gain et le volume du groupe bougent")
    func mutingLoudestKeepsSession() async throws {
        let (harness, left, _) = try await pairHarness()
        let ids = [Devices.genevaID, Devices.leftID, Devices.rightID]
        await harness.startStreaming(expecting: ids)
        let senders = try ids.map { try #require(harness.factory.latest($0)) }
        let (genevaSender, leftSender, rightSender) = (senders[0], senders[1], senders[2])
        let created = harness.factory.createdCount

        left.isMuted = true
        #expect(await eventually {
            await leftSender.pushedLevels.last == OutputLevel(gainDB: 0, isMuted: true)
        })
        // Le coupé sort du plus fort : Salon (2) n'a plus de gain à porter, et son niveau ne bouge pas.
        let solo = PairDevices.soloVolume(trim: -11.5)
        #expect(await eventually { await rightSender.pushedVolumes.last == solo })
        #expect(await eventually { await leftSender.pushedVolumes.last == solo })
        #expect(await eventually { await rightSender.pushedLevels.last == .unity })
        // Jamais −144 : il couperait l'autre membre de la paire.
        #expect(await !leftSender.pushedVolumes.contains(-144))

        // Ni retrait, ni arrêt, ni relance : les mêmes senders, en diffusion, et la Geneva intacte.
        #expect(await staysFalse { harness.factory.createdCount != created })
        for sender in senders {
            #expect(await sender.stopCount == 0)
            #expect(await sender.pushedDelays.isEmpty)
        }
        #expect(await genevaSender.pushedVolumes.isEmpty)
        #expect(await genevaSender.pushedLevels == [.unity])
        #expect(left.isEnabled)
        #expect(left.connection == .streaming)
        #expect(harness.captures.count == 1)

        left.isMuted = false
        #expect(await eventually { await leftSender.pushedLevels.last == .unity })
        #expect(await eventually { await rightSender.pushedVolumes.last == -11.75 })
        #expect(await eventually { await rightSender.pushedLevels.last == OutputLevel(gainDB: -6) })
        #expect(harness.factory.createdCount == created)
        await harness.stopStreaming()
    }

    @Test("Couper le moins fort ne touche qu'à lui")
    func mutingQuieterTouchesOnlyIt() async throws {
        let (harness, _, right) = try await pairHarness(withGeneva: false)
        await harness.startStreaming(expecting: [Devices.leftID, Devices.rightID])
        let leftSender = try #require(harness.factory.latest(Devices.leftID))
        let rightSender = try #require(harness.factory.latest(Devices.rightID))

        right.isMuted = true
        #expect(await eventually {
            await rightSender.pushedLevels.last == OutputLevel(gainDB: -6, isMuted: true)
        })
        #expect(await staysFalse { await !leftSender.pushedVolumes.isEmpty })
        #expect(await rightSender.pushedVolumes.isEmpty)
        #expect(await leftSender.pushedLevels == [.unity])
        await harness.stopStreaming()
    }

    @Test("Une enceinte seule coupée garde son volume, et se tait par son gain")
    func soloMute() async throws {
        let harness = BridgeHarness()
        await harness.discover(raop: [Devices.genevaRAOP])
        await harness.startStreaming(expecting: [Devices.genevaID])
        let geneva = try #require(harness.output(Devices.genevaID))
        let sender = try #require(harness.factory.latest(Devices.genevaID))

        geneva.isMuted = true
        #expect(await eventually { await sender.pushedLevels.last == OutputLevel(isMuted: true) })
        #expect(await sender.pushedVolumes.isEmpty)
        #expect(harness.state.effectiveGainDB(for: geneva) == BridgeState.silenceDB)
        geneva.isMuted = false
        #expect(await eventually { await sender.pushedLevels.last == .unity })
        #expect(await sender.stopCount == 0)
        await harness.stopStreaming()
    }

    @Test("Coupée avant la diffusion, une enceinte part en silence, toujours dans le moteur")
    func startsMuted() async throws {
        let (harness, left, _) = try await pairHarness(withGeneva: false)
        left.isMuted = true
        await harness.startStreaming(expecting: [Devices.leftID, Devices.rightID])
        let leftSender = try #require(harness.factory.latest(Devices.leftID))
        let rightSender = try #require(harness.factory.latest(Devices.rightID))
        #expect(await leftSender.startedLevel == OutputLevel(gainDB: 0, isMuted: true))
        #expect(await rightSender.startedLevel == .unity)
        #expect(await rightSender.startedVolume == PairDevices.soloVolume(trim: -11.5))
        await harness.stopStreaming()
    }
}

@Suite("Réglages — silence par enceinte et paire")
struct BridgeSettingsSpeakerMuteTests {
    @Test("Le silence d'une enceinte et le tsid de sa paire sont sauvegardés, puis restaurés")
    func persists() async throws {
        let (harness, left, _) = try await pairHarness(withGeneva: false)
        left.isMuted = true
        #expect(await eventually { harness.store.stored.outputs[Devices.leftID]?.isMuted == true })
        let saved = harness.store.stored
        #expect(saved.outputs[Devices.rightID]?.isMuted == false)
        #expect(saved.outputs[Devices.leftID]?.tightSyncIdentifier == PairDevices.tsid)

        // Relancée, l'app retrouve l'enceinte coupée et sa paire avant même la première découverte.
        // Par le JSON, comme `settings.json`.
        let reloaded = try JSONDecoder().decode(
            BridgeSettings.self, from: try JSONEncoder().encode(saved)
        )
        let reopened = BridgeHarness(settings: reloaded)
        let restored = try #require(reopened.output(Devices.leftID))
        #expect(restored.isMuted)
        #expect(restored.tightSyncIdentifier == PairDevices.tsid)
        #expect(reopened.output(Devices.rightID)?.isMuted == false)
        await reopened.startStreaming(expecting: [Devices.leftID, Devices.rightID])
        let rightSender = try #require(reopened.factory.latest(Devices.rightID))
        #expect(await rightSender.startedVolume == PairDevices.soloVolume(trim: -11.5))
        await reopened.stopStreaming()
    }

    @Test("Un fichier ancien, sans ces champs, se relit : non coupée, sans paire")
    func oldFileWithoutFields() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "apb-mute-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileSettingsStore(url: directory.appending(path: "settings.json"))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(
            #"{"outputs": {"airplay2/Salon": {"trimDB": 0.5, "isEnabled": true}}}"#.utf8
        ).write(to: store.url)

        let loaded = store.load()
        let output = try #require(loaded.outputs["airplay2/Salon"])
        #expect(output.isMuted == false)
        #expect(output.tightSyncIdentifier == nil)
        #expect(output.trimDB == 0.5)
        // Lu sans perte : aucune copie de secours à côté.
        let siblings = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(siblings == ["settings.json"])
    }

    @Test("Un champ de silence illisible retombe sur « non coupée », sans perdre le reste")
    func tolerantDecoding() throws {
        let data = Data(
            #"{"outputs": {"airplay2/Salon": {"trimDB": -3, "isMuted": "oui", "tightSyncIdentifier": 4}}}"#
                .utf8
        )
        let loaded = try JSONDecoder().decode(BridgeSettings.self, from: data)
        let output = try #require(loaded.outputs["airplay2/Salon"])
        #expect(output.isMuted == false)
        #expect(output.tightSyncIdentifier == nil)
        #expect(output.trimDB == -3)
    }

    @Test("Aller-retour JSON")
    func roundTrip() throws {
        var settings = BridgeSettings()
        var output = BridgeSettings.Output(trimDB: -11.5)
        output.isMuted = true
        output.tightSyncIdentifier = PairDevices.tsid
        settings.outputs["airplay2/Salon (2)"] = output
        let data = try JSONEncoder().encode(settings)
        #expect(try JSONDecoder().decode(BridgeSettings.self, from: data) == settings)
    }
}
