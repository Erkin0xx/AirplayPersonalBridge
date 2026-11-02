import AudioCore
import Foundation
import Testing

@testable import BridgeApp

// Ce que règlent le bouton de silence et le tiroir des basses du panneau, jusqu'au moteur : le vrai
// `BridgeEngine`, avec des senders sans réseau (`BridgeStateTestSupport`).

@Suite("État — silence des enceintes")
struct BridgeStateMuteTests {
    private let ids = [Devices.genevaID, Devices.leftID, Devices.rightID]

    /// Le silence est une consigne de volume, et rien d'autre : couper puis rétablir ne doit coûter
    /// aucune session, sans quoi rétablir le son reprendrait la négociation de chaque enceinte.
    @Test("Basculer le silence ne touche qu'aux volumes : aucune sortie n'entre ni ne sort du moteur")
    func muteKeepsSessions() async throws {
        let harness = BridgeHarness()
        await harness.discover(raop: [Devices.genevaRAOP], airplay2: [Devices.left, Devices.right])
        try #require(harness.output(Devices.genevaID)).bassBoostDB = 6
        try #require(harness.output(Devices.rightID)).trimDB = 1.5
        await harness.startStreaming(expecting: ids)
        let senders = try ids.map { try #require(harness.factory.latest($0)) }
        let created = harness.factory.createdCount
        var bassBefore: [[Float]] = []
        for sender in senders { bassBefore.append(await sender.pushedBass) }

        for _ in 0..<3 {
            harness.state.isMuted = true
            for sender in senders {
                #expect(await eventually { await sender.pushedVolumes.last == -144 })
            }
            harness.state.isMuted = false
            for sender in senders {
                let started = try #require(await sender.startedVolume)
                #expect(await eventually { await sender.pushedVolumes.last == started })
            }
        }

        // Ni ajout, ni retrait, ni arrêt, ni relance de la capture : les mêmes senders, intacts.
        #expect(await staysFalse { harness.factory.createdCount != created })
        #expect(harness.captures.count == 1)
        for (index, sender) in senders.enumerated() {
            #expect(await sender.stopCount == 0)
            #expect(await sender.pushedDelays.isEmpty)
            #expect(await sender.pushedBass == bassBefore[index])
            #expect(await sender.pushedVolumes.count == 6)
        }
        for id in ids { #expect(harness.output(id)?.connection == .streaming) }
        await harness.stopStreaming()
    }

    @Test("Le son rétabli rend le volume d'avant le silence, master et trim compris")
    func unmuteRestoresPreviousVolume() async throws {
        let harness = BridgeHarness()
        await harness.discover(raop: [Devices.genevaRAOP], airplay2: [Devices.left, Devices.right])
        let right = try #require(harness.output(Devices.rightID))
        right.trimDB = 1.5
        await harness.startStreaming(expecting: ids)
        let geneva = try #require(harness.factory.latest(Devices.genevaID))
        let rightSender = try #require(harness.factory.latest(Devices.rightID))

        // Un réglage fait pendant la diffusion, puis le silence par-dessus.
        harness.state.masterVolumeDB = -30
        #expect(await eventually { await geneva.pushedVolumes.last == -15 })
        #expect(await eventually { await rightSender.pushedVolumes.last == -14.25 })
        harness.state.isMuted = true
        #expect(await eventually { await geneva.pushedVolumes.last == -144 })
        #expect(await eventually { await rightSender.pushedVolumes.last == -144 })
        #expect(harness.state.masterVolumeDB == -30)

        harness.state.isMuted = false
        #expect(await eventually { await geneva.pushedVolumes.last == -15 })
        #expect(await eventually { await rightSender.pushedVolumes.last == -14.25 })
        await harness.stopStreaming()
    }

    @Test("Un silence gardé d'une session à l'autre part muet, et se lève sans relancer")
    func persistedMuteStartsSilentAndLiftsInPlace() async throws {
        var settings = BridgeSettings()
        settings.isMuted = true
        let harness = BridgeHarness(settings: settings)
        await harness.discover(raop: [Devices.genevaRAOP])
        await harness.startStreaming(expecting: [Devices.genevaID])
        let sender = try #require(harness.factory.latest(Devices.genevaID))
        #expect(await sender.startedVolume == -144)

        harness.state.isMuted = false
        #expect(await eventually { await sender.pushedVolumes.last == -12 })
        #expect(await sender.stopCount == 0)
        #expect(harness.factory.createdCount == 1)
        await harness.stopStreaming()
    }
}

@Suite("Panneau — tiroir des basses", .serialized)
struct PanelSpeakerRowBassTests {
    @Test("Le curseur arrondit au demi-décibel, et borne à la plage du filtre")
    func rounding() {
        let geneva = OutputState(
            id: Devices.genevaID, displayName: "Geneva", host: "h", port: 1, proto: .raop
        )
        PanelBassControl.set(7.3, on: geneva)
        #expect(geneva.bassBoostDB == 7.5)
        PanelBassControl.set(14, on: geneva)
        #expect(geneva.bassBoostDB == 12)
        PanelBassControl.set(-3, on: geneva)
        #expect(geneva.bassBoostDB == 0)
        PanelBassControl.set(4.2, on: geneva)
        PanelBassControl.reset(geneva)
        #expect(geneva.bassBoostDB == 0)
    }

    @Test("Un réglage du tiroir atteint la Geneva, et elle seule")
    func reachesTheRightOutput() async throws {
        let harness = BridgeHarness()
        await harness.discover(raop: [Devices.genevaRAOP], airplay2: [Devices.left, Devices.right])
        let ids = [Devices.genevaID, Devices.leftID, Devices.rightID]
        await harness.startStreaming(expecting: ids)
        let geneva = try #require(harness.output(Devices.genevaID))
        let left = try #require(harness.output(Devices.leftID))
        let genevaSender = try #require(harness.factory.latest(Devices.genevaID))
        let homePods = try [Devices.leftID, Devices.rightID].map { try #require(harness.factory.latest($0)) }

        PanelBassControl.set(7.3, on: geneva)
        #expect(await eventually { await genevaSender.pushedBass.last == 7.5 })
        // Une sortie AirPlay 2 n'a pas de tiroir : un appel égaré n'y écrit rien.
        PanelBassControl.set(6, on: left)
        #expect(left.bassBoostDB == 0)
        for sender in homePods {
            #expect(await staysFalse { await !sender.pushedBass.isEmpty })
        }

        PanelBassControl.reset(geneva)
        #expect(await eventually { await genevaSender.pushedBass.last == 0 })
        #expect(await genevaSender.stopCount == 0)
        #expect(await genevaSender.pushedVolumes.isEmpty)
        await harness.stopStreaming()
    }

    /// Tout ce qui se règle d'un même tour n'atteint le moteur qu'une fois, à sa dernière valeur.
    @Test("Une rafale de réglages entre deux tours de la boucle ne pousse que la dernière valeur")
    func burstPushesOnce() async throws {
        let harness = BridgeHarness()
        await harness.discover(raop: [Devices.genevaRAOP])
        await harness.startStreaming(expecting: [Devices.genevaID])
        let geneva = try #require(harness.output(Devices.genevaID))
        let sender = try #require(harness.factory.latest(Devices.genevaID))
        let before = await sender.pushedBass.count

        for step in 0...120 { PanelBassControl.set(Double(step) / 10, on: geneva) }

        #expect(await eventually { await sender.pushedBass.last == 12 })
        #expect(await staysFalse { await sender.pushedBass.count > before + 1 })
        await harness.stopStreaming()
    }

    /// Un glissement réel, étalé dans le temps : au plus une poussée par tour de la boucle, quelle que
    /// soit la cadence du curseur. La borne ne fait que baisser si la machine est chargée.
    @Test("Un glissement du curseur pousse au plus un réglage par tour de la boucle")
    func dragIsRateLimited() async throws {
        var timing = BridgeEnvironment.Timing.fast
        timing.pollInterval = .milliseconds(40)
        let harness = BridgeHarness(timing: timing)
        await harness.discover(raop: [Devices.genevaRAOP])
        await harness.startStreaming(expecting: [Devices.genevaID])
        let geneva = try #require(harness.output(Devices.genevaID))
        let sender = try #require(harness.factory.latest(Devices.genevaID))
        let before = await sender.pushedBass.count

        let clock = ContinuousClock()
        let start = clock.now
        var writes = 0
        for step in 0...240 {
            PanelBassControl.set(Double(step) / 20, on: geneva)
            writes += 1
            try await Task.sleep(for: .milliseconds(1))
        }
        let elapsed = start.duration(to: clock.now)
        #expect(await eventually { await sender.pushedBass.last == 12 })

        let pushes = await sender.pushedBass.count - before
        let rounds = Int(elapsed / timing.pollInterval) + 2
        #expect(pushes <= rounds, "\(pushes) poussées pour \(writes) gestes en \(elapsed)")
        #expect(pushes <= 25, "jamais plus que de valeurs distinctes au demi-décibel")
        await harness.stopStreaming()
    }

    @Test("Décochée, la Geneva garde le réglage du tiroir, le sauvegarde, et part avec en diffusion")
    func appliesWhileUnchecked() async throws {
        let harness = BridgeHarness()
        await harness.discover(raop: [Devices.genevaRAOP], airplay2: [Devices.left])
        let geneva = try #require(harness.output(Devices.genevaID))
        geneva.isEnabled = false
        await harness.startStreaming(expecting: [Devices.leftID])

        PanelBassControl.set(9, on: geneva)
        #expect(await eventually { harness.store.stored.outputs[Devices.genevaID]?.bassBoostDB == 9 })
        #expect(harness.factory.senders(Devices.genevaID).isEmpty)

        geneva.isEnabled = true
        #expect(await eventually { geneva.connection == .streaming })
        #expect(harness.factory.lastRequest(Devices.genevaID)?.bassBoostDB == 9)
        let sender = try #require(harness.factory.latest(Devices.genevaID))
        #expect(await sender.startedBass == 9)
        await harness.stopStreaming()
    }
}
