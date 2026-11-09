import AudioCore
import Foundation
import Testing

@testable import BridgeApp

// L'image des vidéos calée sur les enceintes : la sortie virtuelle faite sortie par défaut du Mac le temps
// d'une diffusion (`VideoSyncSwitch`), jusqu'au moteur. Le vrai `BridgeEngine`, des senders et une
// capture sans matériel (`BridgeStateTestSupport`), et un Mac sans Core Audio (`FakeSystemVolume`), le
// même pour le lien du volume et pour la bascule : aucun test ne change la vraie sortie du Mac.

private let bridgeUID = VirtualOutputDevice.deviceUID

/// Le Mac de Baptiste : haut-parleurs à 0 % et coupés en sortie par défaut, pilote installé.
private func macWithDriver(_ origin: FakeSystemVolume.Device = .speakers) -> FakeSystemVolume {
    let mac = FakeSystemVolume(.speakers)
    mac.plug(origin, notifying: false)
    mac.add(.bridge)
    return mac
}

private func harness(
    _ mac: FakeSystemVolume, settings: BridgeSettings = BridgeSettings()
) -> BridgeHarness {
    BridgeHarness(settings: settings, systemVolume: mac, outputSwitch: mac)
}

private let speakersMemory = VideoSyncMemory(
    deviceUID: "BuiltInSpeakerDevice", deviceName: "Haut-parleurs MacBook Pro", volume: 0, isMuted: true
)

/// Le volume du Mac à un cran donné des touches.
private func notch(_ step: Int) -> Float { Float(step) / 16 }

@Suite("Calage vidéo — le temps d'une diffusion")
struct VideoSyncSessionTests {
    @Test("Au démarrage : mémoire persistée, puis latence du pilote, puis bascule, puis capture")
    func startOrder() async {
        let mac = macWithDriver()
        let harness = harness(mac)
        var atLatency: (memory: VideoSyncMemory?, captures: Int)?
        var atSwitch: (latencies: Int, captures: Int)?
        mac.beforeSwitch = { write in
            if write == "latence" {
                atLatency = (harness.store.stored.videoSyncMemory, harness.captures.count)
            } else if write == "défaut \(bridgeUID)" {
                atSwitch = (mac.latencyWrites.count, harness.captures.count)
            }
        }
        await harness.discover(raop: [Devices.genevaRAOP])
        await harness.startStreaming(expecting: [Devices.genevaID])

        // Persistée avant toute écriture : un plantage juste après la retrouve.
        #expect(atLatency?.memory == speakersMemory)
        #expect(atLatency?.captures == 0)
        // La latence avant la bascule, la bascule avant la capture, qui prend la sortie par défaut
        // pour horloge.
        #expect(atSwitch?.latencies == 1)
        #expect(atSwitch?.captures == 0)
        #expect(mac.latencyWrites == [VideoSyncLatency.frames()])
        #expect(mac.defaultWrites == [bridgeUID])
        #expect(harness.captures.count == 1)
        #expect(harness.state.videoSync.isActive)
        // Le lien du volume, démarré après la capture, a trouvé le pilote : c'est lui qu'il a mémorisé
        // et réglé sur le master. Les haut-parleurs n'ont pas bougé.
        #expect(harness.store.stored.systemVolumeMemory?.deviceUID == bridgeUID)
        #expect(await eventually { mac.device(bridgeUID)?.volume == 0.6 })
        #expect(mac.device("BuiltInSpeakerDevice") == FakeSystemVolume.Device.speakers)
        await harness.stopStreaming()
    }

    @Test("À l'arrêt : volume du Mac rendu, puis moteur arrêté, puis sortie d'origine rendue")
    func stopOrder() async throws {
        let mac = macWithDriver()
        let harness = harness(mac)
        await harness.discover(raop: [Devices.genevaRAOP])
        await harness.startStreaming(expecting: [Devices.genevaID])
        #expect(await eventually { mac.device(bridgeUID)?.volume == 0.6 })
        mac.journal = harness.stopOrder

        await harness.stopStreaming()
        let events = harness.stopOrder.events
        let volume = try #require(
            events.lastIndex { $0 == "volume \(bridgeUID)" || $0 == "silence \(bridgeUID)" },
            "\(events)"
        )
        let capture = try #require(events.firstIndex(of: "capture"), "\(events)")
        let restored = try #require(events.firstIndex(of: "défaut BuiltInSpeakerDevice"), "\(events)")
        #expect(volume < capture, "\(events)")
        #expect(capture < restored, "\(events)")
        #expect(mac.current == FakeSystemVolume.Device.speakers)
        #expect(mac.device(bridgeUID) == FakeSystemVolume.Device.bridge)
        #expect(harness.store.stored.videoSyncMemory == nil)
        #expect(!harness.state.videoSync.isActive)
    }

    @Test("Les touches du Mac règlent le master par le pilote, et le master règle le pilote")
    func macKeysDriveTheDriver() async throws {
        let mac = macWithDriver()
        let harness = harness(mac)
        await harness.discover(raop: [Devices.genevaRAOP])
        harness.state.masterVolumeDB = -30
        await harness.startStreaming(expecting: [Devices.genevaID])
        let sender = try #require(harness.factory.latest(Devices.genevaID))
        #expect(await eventually { mac.current?.uid == bridgeUID && mac.current?.volume == 0.5 })

        // Du Mac vers les enceintes : un cran des touches, puis la touche silence.
        mac.press(volume: notch(12))
        #expect(await eventually { harness.state.masterVolumeDB == -15 })
        #expect(await eventually { await sender.pushedVolumes.last == -7.5 })
        mac.press(muted: true)
        #expect(await eventually { harness.state.isMuted })
        mac.press(muted: false)
        #expect(await eventually { !harness.state.isMuted })

        // Des enceintes vers le Mac : le curseur du panneau règle le pilote.
        harness.state.masterVolumeDB = -45
        #expect(await eventually { mac.device(bridgeUID)?.volume == 0.25 })
        #expect(mac.device("BuiltInSpeakerDevice") == FakeSystemVolume.Device.speakers)
        await harness.stopStreaming()
        #expect(mac.current == FakeSystemVolume.Device.speakers)
    }

    /// Sans volume réglable sur la sortie d'origine, le lien n'aurait rien à piloter : c'est le pilote,
    /// trouvé en place au moment de décider, qui le rend possible.
    @Test("Depuis une sortie sans volume (HDMI), les touches pilotent quand même par le pilote")
    func macKeysFromHDMI() async {
        let mac = macWithDriver(.hdmi)
        let harness = harness(mac)
        await harness.discover(raop: [Devices.genevaRAOP])
        await harness.startStreaming(expecting: [Devices.genevaID])
        #expect(harness.state.systemVolume.isActive)
        #expect(harness.state.systemVolume.inoperativeDeviceName == nil)
        #expect(harness.captures.last?.options.muteLocalOutput == true)
        #expect(await eventually { mac.device(bridgeUID)?.volume == 0.6 })

        mac.press(volume: notch(8))
        #expect(await eventually { harness.state.masterVolumeDB == -30 })
        await harness.stopStreaming()
        #expect(mac.current == FakeSystemVolume.Device.hdmi)
    }

    @Test("Au lancement après un plantage : la sortie mémorisée est rendue, volume et silence compris")
    func leftoverMemoryIsRestoredAtLaunch() async {
        var settings = BridgeSettings()
        settings.videoSyncMemory = speakersMemory
        // Le Mac tel qu'une diffusion interrompue l'a laissé : sur le pilote, et des haut-parleurs que
        // quelque chose a réglés entre-temps.
        var speakers = FakeSystemVolume.Device.speakers
        speakers.volume = 0.5
        speakers.isMuted = false
        let mac = FakeSystemVolume(speakers)
        mac.plug(.bridge, notifying: false)
        mac.journal = StopOrder()
        let harness = harness(mac, settings: settings)
        harness.state.startBackgroundWork()

        #expect(mac.current == FakeSystemVolume.Device.speakers)
        // Couper, régler, puis seulement en faire la sortie : jamais un éclat.
        #expect(
            mac.journal?.events == [
                "silence BuiltInSpeakerDevice", "volume BuiltInSpeakerDevice",
                "défaut BuiltInSpeakerDevice",
            ]
        )
        #expect(harness.store.stored.videoSyncMemory == nil)
        #expect(mac.latencyWrites.isEmpty)
    }

    @Test("Au lancement, une sortie choisie depuis le plantage est laissée, la mémoire oubliée")
    func leftoverMemoryWhenUserMovedOn() async {
        var settings = BridgeSettings()
        settings.videoSyncMemory = speakersMemory
        let mac = macWithDriver(.headphones)
        let harness = harness(mac, settings: settings)
        harness.state.startBackgroundWork()
        #expect(mac.current == FakeSystemVolume.Device.headphones)
        #expect(mac.defaultWrites.isEmpty)
        #expect(mac.volumeWrites.isEmpty && mac.muteWrites.isEmpty)
        #expect(harness.store.stored.videoSyncMemory == nil)
    }

    @Test("Au lancement, le pilote laissé en sortie par défaut sans mémoire cède la place")
    func driverLeftWithoutMemoryAtLaunch() async {
        // Le casque vient avant les haut-parleurs dans la liste de Core Audio.
        let mac = FakeSystemVolume(.headphones)
        mac.add(.speakers)
        mac.plug(.bridge, notifying: false)
        let harness = harness(mac)
        harness.state.startBackgroundWork()
        // La sortie intégrée d'abord.
        #expect(mac.current == FakeSystemVolume.Device.speakers)
        #expect(harness.store.stored.videoSyncMemory == nil)
    }

    @Test("Le pilote déjà sortie par défaut au démarrage : la sortie de repli est mémorisée, jamais lui")
    func driverAlreadyDefaultAtStart() async {
        let mac = macWithDriver()
        mac.plug(.bridge, notifying: false)
        let harness = harness(mac)
        await harness.discover(raop: [Devices.genevaRAOP])
        await harness.startStreaming(expecting: [Devices.genevaID])
        #expect(harness.store.stored.videoSyncMemory == speakersMemory)
        #expect(mac.latencyWrites == [VideoSyncLatency.frames()])
        #expect(mac.defaultWrites.isEmpty)
        await harness.stopStreaming()
        #expect(mac.current == FakeSystemVolume.Device.speakers)
        #expect(harness.store.stored.videoSyncMemory == nil)
    }

    @Test("Un échec du démarrage rend aussitôt la sortie d'origine")
    func failedStartRestores() async {
        let mac = macWithDriver()
        let harness = harness(mac)
        harness.captures.failNextCaptures(true)
        await harness.discover(raop: [Devices.genevaRAOP])
        harness.state.toggleStreaming()
        #expect(await eventually { harness.state.startFailure != nil })
        #expect(harness.state.streamingPhase == .idle)
        #expect(mac.defaultWrites == [bridgeUID, "BuiltInSpeakerDevice"])
        #expect(mac.current == FakeSystemVolume.Device.speakers)
        #expect(harness.store.stored.videoSyncMemory == nil)
    }

    @Test("Latence refusée par le pilote : la sortie du Mac ne change pas")
    func refusedLatencyKeepsOutput() async {
        let mac = macWithDriver()
        mac.acceptsLatency = false
        let harness = harness(mac)
        await harness.discover(raop: [Devices.genevaRAOP])
        await harness.startStreaming(expecting: [Devices.genevaID])
        #expect(mac.defaultWrites.isEmpty)
        #expect(!harness.state.videoSync.isActive)
        #expect(harness.store.stored.videoSyncMemory == nil)
        await harness.stopStreaming()
        #expect(mac.current == FakeSystemVolume.Device.speakers)
    }
}

@Suite("Calage vidéo — le choix de l'utilisateur et les replis")
struct VideoSyncEdgeTests {
    @Test("Un casque choisi en pleine diffusion est respecté : ni retour au pilote, ni sortie imposée")
    func userChoiceIsRespected() async {
        let mac = macWithDriver()
        let harness = harness(mac)
        await harness.discover(raop: [Devices.genevaRAOP])
        await harness.startStreaming(expecting: [Devices.genevaID])
        #expect(mac.current?.uid == bridgeUID)

        mac.plug(.headphones)
        // Le lien du volume suit le casque ; personne ne rebascule.
        #expect(await eventually { harness.store.stored.systemVolumeMemory?.deviceUID == "Headphones" })
        #expect(await staysFalse(during: .milliseconds(100)) { mac.current?.uid != "Headphones" })
        #expect(mac.defaultWrites == [bridgeUID])

        await harness.stopStreaming()
        #expect(mac.current == FakeSystemVolume.Device.headphones)
        #expect(mac.defaultWrites == [bridgeUID])
        #expect(harness.store.stored.videoSyncMemory == nil)
        #expect(harness.state.videoSync.userChosenOutputName == "Casque")

        // Une nouvelle diffusion demandée rebascule, et mémorise le casque.
        await harness.startStreaming(expecting: [Devices.genevaID])
        #expect(mac.current?.uid == bridgeUID)
        #expect(harness.store.stored.videoSyncMemory?.deviceUID == "Headphones")
        #expect(harness.state.videoSync.userChosenOutputName == nil)
        await harness.stopStreaming()
        #expect(mac.current == FakeSystemVolume.Device.headphones)
    }

    @Test("Après un choix de l'utilisateur, une relance en pleine diffusion ne rebascule pas")
    func restartKeepsUserChoice() async {
        let mac = macWithDriver()
        let harness = harness(mac)
        let music = CaptureSource.application(pids: [501], name: "Music", bundleID: "com.apple.Music")
        harness.sources = [.systemWide, music, .inputDevice]
        harness.state.refreshSources()
        await harness.discover(raop: [Devices.genevaRAOP])
        await harness.startStreaming(expecting: [Devices.genevaID])
        mac.plug(.headphones)
        #expect(await eventually { harness.store.stored.systemVolumeMemory?.deviceUID == "Headphones" })

        harness.state.selectSource(id: music.id)
        #expect(await eventually { harness.captures.count == 2 && harness.state.isStreaming })
        #expect(await staysFalse(during: .milliseconds(100)) { mac.current?.uid != "Headphones" })
        #expect(mac.defaultWrites == [bridgeUID])
        #expect(PanelVideoSyncOption.detail(for: harness.state) == PanelVideoSyncOption.userChoiceDetail("Casque"))
        await harness.stopStreaming()
        #expect(mac.current?.uid == "Headphones")
    }

    @Test("La sortie d'origine débranchée pendant la diffusion : repli sur la sortie intégrée")
    func originGoneFallsBackToBuiltIn() async {
        let mac = macWithDriver(.headphones)
        let harness = harness(mac)
        await harness.discover(raop: [Devices.genevaRAOP])
        await harness.startStreaming(expecting: [Devices.genevaID])
        #expect(harness.store.stored.videoSyncMemory?.deviceUID == "Headphones")

        mac.unplug("Headphones", fallingBackTo: bridgeUID)
        await harness.stopStreaming()
        #expect(mac.current == FakeSystemVolume.Device.speakers)
        #expect(harness.store.stored.videoSyncMemory == nil)
    }

    @Test("Sans sortie intégrée, le repli est la première autre sortie, jamais le pilote")
    func originGoneWithoutBuiltIn() async {
        let dac = FakeSystemVolume.Device(
            id: 160, uid: "USB-DAC", name: "DAC USB", volume: 0.5, isMuted: false
        )
        let mac = FakeSystemVolume(.bridge)
        mac.add(dac)
        mac.plug(.headphones, notifying: false)
        mac.builtInUIDs = []
        let harness = harness(mac)
        await harness.discover(raop: [Devices.genevaRAOP])
        await harness.startStreaming(expecting: [Devices.genevaID])
        mac.unplug("Headphones", fallingBackTo: bridgeUID)
        await harness.stopStreaming()
        #expect(mac.current?.uid == "USB-DAC")
        #expect(harness.store.stored.videoSyncMemory == nil)
    }

    @Test("Sans pilote installé, l'option est sans effet : rien n'est lu ni écrit, le panneau dit quoi faire")
    func noDriver() async {
        let mac = FakeSystemVolume()
        let harness = harness(mac)
        harness.state.panelDidOpen()
        #expect(!harness.state.videoSync.isDriverInstalled)
        #expect(harness.state.syncsVideo)
        #expect(
            PanelVideoSyncOption.detail(for: harness.state) == PanelVideoSyncOption.missingDriverDetail
        )
        await harness.discover(raop: [Devices.genevaRAOP])
        await harness.startStreaming(expecting: [Devices.genevaID])
        #expect(mac.switchReads == 0)
        #expect(mac.latencyWrites.isEmpty && mac.defaultWrites.isEmpty)
        #expect(harness.store.stored.videoSyncMemory == nil)
        #expect(!harness.state.videoSync.isActive)
        await harness.stopStreaming()
        #expect(mac.current == FakeSystemVolume.Device.speakers)

        // Installé ensuite : l'ouverture du panneau le voit.
        mac.add(.bridge)
        harness.state.panelDidOpen()
        #expect(harness.state.videoSync.isDriverInstalled)
        #expect(PanelVideoSyncOption.detail(for: harness.state) == PanelVideoSyncOption.detail)
    }

    @Test("Avec l'entrée physique, rien ne bascule")
    func inputDeviceNeverSwitches() async {
        let mac = macWithDriver()
        let harness = harness(mac)
        harness.state.selectSource(id: CaptureSource.inputDevice.id)
        await harness.discover(raop: [Devices.genevaRAOP])
        await harness.startStreaming(expecting: [Devices.genevaID])
        #expect(!harness.state.sourceAllowsVideoSync)
        #expect(mac.switchReads == 0)
        #expect(mac.latencyWrites.isEmpty && mac.defaultWrites.isEmpty)
        harness.state.panelDidOpen()
        #expect(
            PanelVideoSyncOption.detail(for: harness.state) == PanelVideoSyncOption.inputSourceDetail
        )
        await harness.stopStreaming()
        #expect(mac.current == FakeSystemVolume.Device.speakers)
    }

    @Test("Avec une application pour source, la bascule a lieu, et le panneau dit que les autres se taisent")
    func applicationSourceSwitches() async {
        let mac = macWithDriver()
        let harness = harness(mac)
        let music = CaptureSource.application(pids: [501], name: "Music", bundleID: "com.apple.Music")
        harness.sources = [.systemWide, music, .inputDevice]
        harness.state.refreshSources()
        harness.state.selectSource(id: music.id)
        harness.state.panelDidOpen()
        #expect(
            PanelVideoSyncOption.detail(for: harness.state)
                == PanelVideoSyncOption.otherApplicationsDetail
        )
        await harness.discover(raop: [Devices.genevaRAOP])
        await harness.startStreaming(expecting: [Devices.genevaID])
        #expect(mac.current?.uid == bridgeUID)
        await harness.stopStreaming()
        #expect(mac.current == FakeSystemVolume.Device.speakers)
    }
}

@Suite("Calage vidéo — l'option en pleine diffusion")
struct VideoSyncOptionTests {
    @Test("Désactivée en diffusion : la sortie d'origine est rendue aussitôt, sans relance")
    func disabledDuringStreaming() async {
        let mac = macWithDriver()
        let harness = harness(mac)
        await harness.discover(raop: [Devices.genevaRAOP])
        await harness.startStreaming(expecting: [Devices.genevaID])
        #expect(mac.current?.uid == bridgeUID)

        harness.state.syncsVideo = false
        #expect(mac.current?.uid == "BuiltInSpeakerDevice")
        #expect(harness.store.stored.videoSyncMemory == nil)
        #expect(!harness.state.videoSync.isActive)
        // Le lien du volume suit la sortie rendue ; la capture se reconstruira seule, sans relance.
        #expect(await eventually { harness.store.stored.systemVolumeMemory?.deviceUID == "BuiltInSpeakerDevice" })
        #expect(await staysFalse { harness.captures.count > 1 || mac.current?.uid != "BuiltInSpeakerDevice" })
        harness.state.flushSettings()
        #expect(harness.store.stored.syncsVideo == false)

        await harness.stopStreaming()
        #expect(mac.current == FakeSystemVolume.Device.speakers)
        #expect(mac.device(bridgeUID) == FakeSystemVolume.Device.bridge)
        #expect(mac.defaultWrites == [bridgeUID, "BuiltInSpeakerDevice"])
    }

    @Test("Activée en diffusion : bascule sur place ; à l'arrêt, le Mac retrouve 0 % et le silence")
    func enabledDuringStreaming() async {
        var settings = BridgeSettings()
        settings.syncsVideo = false
        let mac = macWithDriver()
        let harness = harness(mac, settings: settings)
        await harness.discover(raop: [Devices.genevaRAOP])
        await harness.startStreaming(expecting: [Devices.genevaID])
        #expect(mac.switchReads == 0)
        // Le lien du volume tient les haut-parleurs, réglés sur le master.
        #expect(await eventually { mac.current?.volume == 0.6 && mac.current?.isMuted == false })

        harness.state.syncsVideo = true
        #expect(mac.current?.uid == bridgeUID)
        #expect(mac.latencyWrites == [VideoSyncLatency.frames()])
        #expect(harness.store.stored.videoSyncMemory?.deviceUID == "BuiltInSpeakerDevice")
        #expect(await eventually { mac.device(bridgeUID)?.volume == 0.6 })
        // Le lien a rendu aux haut-parleurs leur volume en passant au pilote.
        #expect(mac.device("BuiltInSpeakerDevice") == FakeSystemVolume.Device.speakers)
        #expect(await staysFalse { harness.captures.count > 1 })

        await harness.stopStreaming()
        #expect(mac.current == FakeSystemVolume.Device.speakers)
        #expect(mac.device(bridgeUID) == FakeSystemVolume.Device.bridge)
        #expect(harness.store.stored.videoSyncMemory == nil)
    }

    @Test("Hors diffusion, basculer l'option ne touche à rien")
    func toggledWhileIdle() async {
        let mac = macWithDriver()
        let harness = harness(mac)
        harness.state.syncsVideo = false
        harness.state.syncsVideo = true
        #expect(mac.switchReads == 0)
        #expect(mac.defaultWrites.isEmpty && mac.latencyWrites.isEmpty)
    }
}

@Suite("Calage vidéo — fermeture et réglages")
struct VideoSyncQuitAndSettingsTests {
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

    @Test("Quitter en diffusion : TEARDOWN, capture, sortie rendue, relance, réponse ; puis plus rien")
    func quitOrder() async throws {
        let mac = macWithDriver()
        let harness = harness(mac)
        await harness.discover(raop: [Devices.genevaRAOP])
        await harness.startStreaming(expecting: [Devices.genevaID])
        #expect(await eventually { mac.device(bridgeUID)?.volume == 0.6 })
        mac.journal = harness.stopOrder
        let coreAudio = StubCoreAudioRestarter()
        coreAudio.onRestart = { harness.stopOrder.record("relance") }
        var replies = 0
        let request = lifecycle(harness, coreAudio: coreAudio).handleTerminationRequest {
            harness.stopOrder.record("réponse")
            replies += 1
        }
        #expect(request == .terminateLater)
        #expect(await eventually { replies == 1 })

        let events = harness.stopOrder.events
        let capture = try #require(events.firstIndex(of: "capture"), "\(events)")
        #expect(
            Array(events[capture...])
                == ["capture", "défaut BuiltInSpeakerDevice", "relance", "réponse"],
            "\(events)"
        )
        #expect(mac.current == FakeSystemVolume.Device.speakers)

        // Idempotent : un second rendu ne lit ni n'écrit rien.
        let reads = mac.switchReads
        harness.state.restoreSystemOutput()
        #expect(mac.switchReads == reads)
        #expect(mac.defaultWrites == [bridgeUID, "BuiltInSpeakerDevice"])
    }

    /// La borne a interrompu l'arrêt : c'est l'étape 3 de la fermeture qui rend la sortie, avant que
    /// coreaudiod reparte.
    @Test("Un arrêt interrompu par la borne : la sortie est rendue avant la relance de coreaudiod")
    func interruptedStopStillRestores() async throws {
        var tuning = BridgeHarness.fastTuning
        tuning.stopTimeout = .seconds(30)
        let mac = macWithDriver()
        let harness = BridgeHarness(tuning: tuning, systemVolume: mac, outputSwitch: mac)
        await harness.discover(raop: [Devices.genevaRAOP])
        harness.factory.makeStopHang(Devices.genevaID)
        await harness.startStreaming(expecting: [Devices.genevaID])
        let sender = try #require(harness.factory.latest(Devices.genevaID))
        let coreAudio = StubCoreAudioRestarter()
        var outputAtRestart: String?
        coreAudio.onRestart = { outputAtRestart = mac.current?.uid }
        let budget = QuitSequence.Budget(
            outputs: .milliseconds(100), coreAudioRestart: .milliseconds(100)
        )
        var replies = 0
        _ = lifecycle(harness, coreAudio: coreAudio, budget: budget).handleTerminationRequest {
            replies += 1
        }
        #expect(await eventually { replies == 1 })
        #expect(outputAtRestart == "BuiltInSpeakerDevice")
        #expect(harness.store.stored.videoSyncMemory == nil)

        // L'arrêt finit plus tard : rien n'est rendu deux fois.
        await sender.releaseStop()
        #expect(await eventually { harness.state.streamingPhase == .idle })
        #expect(mac.defaultWrites == [bridgeUID, "BuiltInSpeakerDevice"])
    }

    @Test("Un fichier d'avant l'option la laisse activée ; la mémoire se relit, ou s'écarte si elle est abîmée")
    func settingsDecoding() throws {
        #expect(BridgeSettings().syncsVideo)
        #expect(BridgeSettings().videoSyncMemory == nil)
        let old = try JSONDecoder().decode(
            BridgeSettings.self, from: Data(#"{"isMuted": false, "followsSystemVolume": false}"#.utf8)
        )
        #expect(old.syncsVideo)
        #expect(old.videoSyncMemory == nil)
        let off = try JSONDecoder().decode(BridgeSettings.self, from: Data(#"{"syncsVideo": false}"#.utf8))
        #expect(!off.syncsVideo)
        let garbled = try JSONDecoder().decode(
            BridgeSettings.self, from: Data(#"{"syncsVideo": "oui", "videoSyncMemory": [1]}"#.utf8)
        )
        #expect(garbled.syncsVideo)
        #expect(garbled.videoSyncMemory == nil)

        var settings = BridgeSettings()
        settings.syncsVideo = false
        settings.videoSyncMemory = VideoSyncMemory(
            deviceUID: "Headphones", deviceName: "Casque", volume: nil, isMuted: nil
        )
        let roundTrip = try JSONDecoder().decode(BridgeSettings.self, from: JSONEncoder().encode(settings))
        #expect(roundTrip == settings)
    }

    @Test("Le libellé de l'option, ses détails et son aide")
    func optionText() {
        #expect(PanelVideoSyncOption.title == "Caler l'image des vidéos")
        #expect(PanelVideoSyncOption.missingDriverDetail.contains("Drivers/APBOutput/build.sh"))
        #expect(PanelVideoSyncOption.missingDriverDetail.contains("sudo scripts/install-driver.sh"))
        // Rien ne promet de caler une vidéo déjà ouverte.
        #expect(PanelVideoSyncOption.detail.contains("rechargées"))
        #expect(PanelVideoSyncOption.help.contains("rechargée"))
        #expect(PanelVideoSyncOption.help.contains("les autres applications se taisent"))
    }
}
