import AudioCore
import CoreAudio
import Foundation
import Testing

@testable import BridgeApp

// Le volume général des enceintes relié aux touches de volume et de silence du Mac pendant une
// diffusion (`SystemVolumeLink`), jusqu'au moteur : le vrai `BridgeEngine`, des senders sans réseau
// (`BridgeStateTestSupport`), et un volume du Mac sans Core Audio (`FakeSystemVolume`).

/// Le volume du Mac, sans Core Audio : ce que feraient les touches, et ce que l'app écrit.
///
/// Comme Core Audio, il notifie toute modification de la sortie par défaut, celles de l'app comprises,
/// un peu plus tard et sur le MainActor : c'est ce qui rend une boucle possible, et ce que la liaison
/// doit déjouer. Plusieurs sorties peuvent être branchées : seule la sortie par défaut est observée.
final class FakeSystemVolume: SystemVolumeControlling {
    struct Device: Equatable {
        var id: AudioObjectID
        var uid: String
        var name: String
        var volume: Float?
        var isMuted: Bool?

        /// L'état relevé sur le Mac de Baptiste : 0 % et coupé.
        static let speakers = Device(
            id: 83, uid: "BuiltInSpeakerDevice", name: "Haut-parleurs MacBook Pro", volume: 0,
            isMuted: true
        )
        static let headphones = Device(
            id: 120, uid: "Headphones", name: "Casque", volume: 0.25, isMuted: false
        )
        static let hdmi = Device(id: 140, uid: "HDMI", name: "HDMI", volume: nil, isMuted: nil)
    }

    private(set) var devices: [Device] = []
    private(set) var defaultUID: String?
    private(set) var reads = 0
    private(set) var volumeWrites: [Float] = []
    private(set) var muteWrites: [Bool] = []
    private(set) var isObserving = false
    private(set) var observeCount = 0
    /// Appelé juste avant chaque écriture : ce que l'app a persisté à cet instant.
    var beforeWrite: () -> Void = {}
    private var onChange: (@MainActor () -> Void)?

    init(_ device: Device? = .speakers) {
        if let device { plug(device, notifying: false) }
    }

    var current: Device? { devices.first { $0.uid == defaultUID } }

    func device(_ uid: String) -> Device? { devices.first { $0.uid == uid } }

    func startObserving(_ onChange: @escaping @MainActor () -> Void) {
        isObserving = true
        observeCount += 1
        self.onChange = onChange
    }

    func stopObserving() {
        isObserving = false
        onChange = nil
    }

    func read() -> SystemOutputVolume.Reading? {
        reads += 1
        return current.map {
            SystemOutputVolume.Reading(
                deviceID: $0.id, deviceUID: $0.uid, deviceName: $0.name, volume: $0.volume,
                isMuted: $0.isMuted
            )
        }
    }

    func device(forUID uid: String) -> AudioObjectID? { device(uid)?.id }

    func setVolume(_ scalar: Float, on id: AudioObjectID) -> Bool {
        guard let index = devices.firstIndex(where: { $0.id == id }), devices[index].volume != nil
        else { return false }
        beforeWrite()
        volumeWrites.append(scalar)
        devices[index].volume = scalar
        if devices[index].uid == defaultUID { notify() }
        return true
    }

    func setMuted(_ muted: Bool, on id: AudioObjectID) -> Bool {
        guard let index = devices.firstIndex(where: { $0.id == id }), devices[index].isMuted != nil
        else { return false }
        beforeWrite()
        muteWrites.append(muted)
        devices[index].isMuted = muted
        if devices[index].uid == defaultUID { notify() }
        return true
    }

    /// Une touche de volume, la touche silence ou le curseur du Centre de contrôle.
    func press(volume: Float? = nil, muted: Bool? = nil) {
        guard let index = devices.firstIndex(where: { $0.uid == defaultUID }) else { return }
        if let volume, devices[index].volume != nil { devices[index].volume = volume }
        if let muted, devices[index].isMuted != nil { devices[index].isMuted = muted }
        notify()
    }

    /// Une sortie branchée, qui devient la sortie par défaut ; déjà connue, elle garde son état.
    func plug(_ device: Device, notifying: Bool = true) {
        if !devices.contains(where: { $0.uid == device.uid }) { devices.append(device) }
        defaultUID = device.uid
        if notifying { notify() }
    }

    /// Une sortie débranchée.
    func unplug(_ uid: String, fallingBackTo fallback: String? = nil) {
        devices.removeAll { $0.uid == uid }
        if defaultUID == uid { defaultUID = fallback }
        notify()
    }

    private func notify() {
        Task { @MainActor [weak self] in self?.onChange?() }
    }
}

/// Le volume du Mac à un cran donné des touches.
private func notch(_ step: Int) -> Float { Float(step) / 16 }

@Suite("Volume du Mac — correspondance")
struct SystemVolumeMappingTests {
    @Test("Aux bornes : 0 vaut le silence, 1 le volume maximal, sur le master comme sur le fil")
    func bounds() {
        #expect(SystemVolumeLink.masterDB(forScalar: 0) == -60)
        #expect(SystemVolumeLink.masterDB(forScalar: 1) == 0)
        #expect(SystemVolumeLink.scalar(forMasterDB: -60) == 0)
        #expect(SystemVolumeLink.scalar(forMasterDB: 0) == 1)
        let wire = { (scalar: Double) in
            BridgeState.receiverVolume(forGainDB: SystemVolumeLink.masterDB(forScalar: scalar))
        }
        #expect(wire(0) == -144)
        #expect(wire(1) == 0)
        // Hors course : bornée, jamais au-delà de ce que le curseur permet.
        #expect(SystemVolumeLink.masterDB(forScalar: -0.2) == -60)
        #expect(SystemVolumeLink.masterDB(forScalar: 1.5) == 0)
        #expect(SystemVolumeLink.scalar(forMasterDB: -90) == 0)
        #expect(SystemVolumeLink.scalar(forMasterDB: 6) == 1)
    }

    /// L'échelle même de l'AirPlay natif : macOS envoie `−30 + 30·s` à un récepteur choisi comme sortie.
    @Test("Les 16 crans des touches : 3,75 dB sur le master, 1,875 dB sur le fil, aller-retour exact")
    func sixteenNotches() {
        for step in 0...16 {
            let scalar = Double(step) / 16
            let master = SystemVolumeLink.masterDB(forScalar: scalar)
            #expect(master == -60 + 3.75 * Double(step), "cran \(step)")
            #expect(SystemVolumeLink.scalar(forMasterDB: master) == scalar, "cran \(step)")
            let wire = BridgeState.receiverVolume(forGainDB: master)
            #expect(wire == (step == 0 ? -144 : Float(-30 + 1.875 * Double(step))), "cran \(step)")
        }
        // Le défaut d'écoute (−24 dB) tombe entre deux crans, à 60 %.
        #expect(SystemVolumeLink.scalar(forMasterDB: BridgeState.defaultMasterVolumeDB) == 0.6)
        // Le cran le plus fin (Option-Maj, 1/64) reste au-dessus de la tolérance.
        #expect(SystemVolumeLink.tolerance < 1.0 / 64)
    }
}

@Suite("Volume du Mac — le temps d'une diffusion")
struct SystemVolumeSessionTests {
    private let ids = [Devices.genevaID, Devices.leftID, Devices.rightID]

    @Test("Hors diffusion, rien n'est lu ni écrit, et les touches ne règlent rien")
    func nothingOutsideStreaming() async {
        let system = FakeSystemVolume()
        let harness = BridgeHarness(systemVolume: system)
        harness.state.startBackgroundWork()
        harness.state.masterVolumeDB = -12
        harness.state.isMuted = true
        harness.state.isMuted = false
        system.press(volume: notch(14), muted: false)
        #expect(await staysFalse(during: .milliseconds(100)) { harness.state.masterVolumeDB != -12 })
        #expect(system.reads == 0)
        #expect(system.volumeWrites.isEmpty && system.muteWrites.isEmpty)
        #expect(!system.isObserving)
        #expect(harness.store.stored.systemVolumeMemory == nil)
    }

    @Test("Au démarrage : le Mac est mémorisé et persisté avant d'être réglé sur le master, son local coupé")
    func startMemorizesAndAligns() async throws {
        let system = FakeSystemVolume()
        let harness = BridgeHarness(systemVolume: system)
        var persistedAtFirstWrite: [SystemVolumeMemory?] = []
        let store = harness.store
        system.beforeWrite = { persistedAtFirstWrite.append(store.stored.systemVolumeMemory) }
        await harness.discover(raop: [Devices.genevaRAOP])
        await harness.startStreaming(expecting: [Devices.genevaID])

        let expected = SystemVolumeMemory(
            deviceUID: "BuiltInSpeakerDevice", deviceName: "Haut-parleurs MacBook Pro", volume: 0,
            isMuted: true
        )
        #expect(await eventually { harness.store.stored.systemVolumeMemory == expected })
        // Écrite avant toute écriture sur le Mac : un plantage juste après la retrouve.
        #expect(persistedAtFirstWrite.first == .some(expected))
        // Le Mac suit le master (−24 dB, 60 %) et le silence des enceintes (non coupé).
        #expect(system.current?.volume == 0.6)
        #expect(system.current?.isMuted == false)
        #expect(harness.state.masterVolumeDB == BridgeState.defaultMasterVolumeDB)
        let sender = try #require(harness.factory.latest(Devices.genevaID))
        #expect(await sender.startedVolume == -12)
        // Le son local est coupé par le tap, sans toucher au réglage de l'utilisateur.
        #expect(harness.captures.last?.options.muteLocalOutput == true)
        #expect(!harness.state.muteLocalOutput)
        harness.state.flushSettings()
        #expect(harness.store.stored.muteLocalOutput == false)
        await harness.stopStreaming()
    }

    @Test("Une touche déplace le master et le volume poussé aux enceintes, sans repartir vers le Mac")
    func keyMovesMasterAndEngine() async throws {
        let system = FakeSystemVolume()
        let harness = BridgeHarness(systemVolume: system)
        await harness.discover(raop: [Devices.genevaRAOP], airplay2: [Devices.left])
        harness.state.masterVolumeDB = -30
        await harness.startStreaming(expecting: [Devices.genevaID, Devices.leftID])
        let geneva = try #require(harness.factory.latest(Devices.genevaID))
        let left = try #require(harness.factory.latest(Devices.leftID))
        #expect(await geneva.startedVolume == -15)
        #expect(await eventually { system.current?.volume == 0.5 })
        let writes = system.volumeWrites.count

        // Quatre crans vers le haut, un à la fois.
        for step in 9...12 {
            system.press(volume: notch(step))
            let master = -60 + 3.75 * Double(step)
            #expect(await eventually { harness.state.masterVolumeDB == master }, "cran \(step)")
        }
        #expect(await eventually { await geneva.pushedVolumes.last == -7.5 })
        #expect(await eventually { await left.pushedVolumes.last == -7.5 })
        #expect(system.volumeWrites.count == writes)
        #expect(await geneva.stopCount == 0)
        #expect(harness.factory.createdCount == 2)
        await harness.stopStreaming()
    }

    @Test("À l'arrêt : le Mac retrouve son volume et son silence, la mémoire est effacée")
    func stopRestores() async {
        let system = FakeSystemVolume()
        let harness = BridgeHarness(systemVolume: system)
        await harness.discover(raop: [Devices.genevaRAOP])
        await harness.startStreaming(expecting: [Devices.genevaID])
        #expect(await eventually { system.current?.volume == 0.6 })
        system.press(volume: notch(12))
        #expect(await eventually { harness.state.masterVolumeDB == -15 })

        await harness.stopStreaming()
        #expect(system.current == FakeSystemVolume.Device.speakers)
        #expect(!system.isObserving)
        #expect(await eventually { harness.store.stored.systemVolumeMemory == nil })
        // Le master reste celui de l'app, tel que la diffusion l'a laissé, et ne suit plus le Mac.
        #expect(harness.state.masterVolumeDB == -15)
        let reads = system.reads
        system.press(volume: notch(4))
        #expect(await staysFalse { harness.state.masterVolumeDB != -15 })
        #expect(system.reads == reads)
    }

    @Test("Une mémoire trouvée au lancement est rendue au Mac, puis effacée")
    func leftoverMemoryIsRestoredAtLaunch() async {
        var settings = BridgeSettings()
        settings.systemVolumeMemory = SystemVolumeMemory(
            deviceUID: "BuiltInSpeakerDevice", deviceName: "Haut-parleurs MacBook Pro", volume: 0.3,
            isMuted: true
        )
        // Le Mac tel qu'une diffusion interrompue l'a laissé.
        var left = FakeSystemVolume.Device.speakers
        left.volume = 0.6
        left.isMuted = false
        let system = FakeSystemVolume(left)
        let harness = BridgeHarness(settings: settings, systemVolume: system)
        harness.state.startBackgroundWork()

        #expect(system.current?.volume == 0.3)
        #expect(system.current?.isMuted == true)
        #expect(harness.store.stored.systemVolumeMemory == nil)
        #expect(!system.isObserving)
    }

    @Test("Une mémoire dont la sortie a disparu est abandonnée sans rien écrire")
    func leftoverMemoryForAbsentDevice() async {
        var settings = BridgeSettings()
        settings.systemVolumeMemory = SystemVolumeMemory(
            deviceUID: "Headphones", deviceName: "Casque", volume: 0.3, isMuted: false
        )
        let system = FakeSystemVolume()
        let harness = BridgeHarness(settings: settings, systemVolume: system)
        harness.state.startBackgroundWork()
        #expect(system.volumeWrites.isEmpty && system.muteWrites.isEmpty)
        #expect(harness.store.stored.systemVolumeMemory == nil)
    }

    @Test("Un casque branché en diffusion : l'ancienne sortie est rendue, la nouvelle s'aligne, le master reste")
    func deviceChangeDuringStreaming() async {
        let system = FakeSystemVolume()
        let harness = BridgeHarness(systemVolume: system)
        await harness.discover(raop: [Devices.genevaRAOP])
        await harness.startStreaming(expecting: [Devices.genevaID])
        #expect(await eventually { system.current?.volume == 0.6 })

        system.plug(.headphones)
        #expect(await eventually { system.current?.volume == 0.6 })
        #expect(system.device("BuiltInSpeakerDevice") == FakeSystemVolume.Device.speakers)
        #expect(harness.store.stored.systemVolumeMemory?.deviceUID == "Headphones")
        #expect(harness.store.stored.systemVolumeMemory?.volume == 0.25)
        #expect(harness.state.masterVolumeDB == BridgeState.defaultMasterVolumeDB)

        // Les touches règlent désormais les enceintes par le casque.
        system.press(volume: notch(8))
        #expect(await eventually { harness.state.masterVolumeDB == -30 })

        await harness.stopStreaming()
        #expect(system.current == FakeSystemVolume.Device.headphones)
        #expect(await eventually { harness.store.stored.systemVolumeMemory == nil })
    }

    @Test("Le casque débranché en diffusion : rien n'est écrit sur la sortie disparue")
    func previousDeviceGone() async {
        let system = FakeSystemVolume(.headphones)
        system.plug(.speakers, notifying: false)
        system.plug(.headphones, notifying: false)
        let harness = BridgeHarness(systemVolume: system)
        await harness.discover(raop: [Devices.genevaRAOP])
        await harness.startStreaming(expecting: [Devices.genevaID])
        #expect(await eventually { system.current?.volume == 0.6 })

        system.unplug("Headphones", fallingBackTo: "BuiltInSpeakerDevice")
        #expect(await eventually { harness.store.stored.systemVolumeMemory?.deviceUID == "BuiltInSpeakerDevice" })
        #expect(await eventually { system.current?.volume == 0.6 })
        await harness.stopStreaming()
        #expect(system.current == FakeSystemVolume.Device.speakers)
    }

    @Test("Le curseur de l'app règle le Mac une fois, sans que l'écho le fasse bouger, silence compris")
    func sliderSetsSystemVolume() async {
        let system = FakeSystemVolume()
        let harness = BridgeHarness(systemVolume: system)
        await harness.discover(raop: [Devices.genevaRAOP])
        await harness.startStreaming(expecting: [Devices.genevaID])
        #expect(await eventually { system.current?.volume == 0.6 })
        let volumes = system.volumeWrites.count
        let mutes = system.muteWrites.count

        harness.state.masterVolumeDB = -15
        #expect(await eventually { system.volumeWrites.count == volumes + 1 })
        #expect(system.current?.volume == 0.75)
        #expect(await staysFalse(during: .milliseconds(100)) {
            system.volumeWrites.count > volumes + 1 || harness.state.masterVolumeDB != -15
        })

        harness.state.isMuted = true
        #expect(await eventually { system.current?.isMuted == true })
        harness.state.isMuted = false
        #expect(await eventually { system.current?.isMuted == false })
        #expect(await staysFalse(during: .milliseconds(100)) {
            system.muteWrites.count > mutes + 2 || harness.state.isMuted
        })
        await harness.stopStreaming()
    }

    /// La tolérance ne vaut que pour ce qui revient du Mac : un geste de l'app plus fin qu'un demi-cran
    /// doit arriver, sans quoi un glissement fini au maximum laisserait le Mac à 99 %.
    @Test("Un réglage plus fin que la tolérance atteint quand même le Mac, jusqu'aux bornes")
    func fineGestureReachesTheMac() async {
        let system = FakeSystemVolume()
        let harness = BridgeHarness(systemVolume: system)
        harness.state.masterVolumeDB = -0.3
        await harness.discover(raop: [Devices.genevaRAOP])
        await harness.startStreaming(expecting: [Devices.genevaID])
        #expect(await eventually { abs((system.current?.volume ?? 0) - 0.995) < 1e-6 })

        harness.state.masterVolumeDB = 0
        #expect(await eventually { system.current?.volume == 1 })
        harness.state.masterVolumeDB = -0.2
        let target = Float(1 - 0.2 / 60)
        #expect(await eventually { abs((system.current?.volume ?? 0) - target) < 1e-6 })
        #expect(await staysFalse(during: .milliseconds(60)) { harness.state.masterVolumeDB != -0.2 })
        await harness.stopStreaming()
    }

    /// Un glissement réel, étalé dans le temps : au plus une écriture par tour de la boucle, quelle
    /// que soit la cadence du curseur. La borne ne fait que baisser si la machine est chargée.
    @Test("Un glissement du curseur règle le Mac au plus une fois par tour de la boucle")
    func sliderIsRateLimited() async throws {
        var timing = BridgeEnvironment.Timing.fast
        timing.pollInterval = .milliseconds(40)
        let system = FakeSystemVolume()
        let harness = BridgeHarness(timing: timing, systemVolume: system)
        harness.state.masterVolumeDB = -30
        await harness.discover(raop: [Devices.genevaRAOP])
        await harness.startStreaming(expecting: [Devices.genevaID])
        #expect(await eventually { system.current?.volume == 0.5 })
        let before = system.volumeWrites.count

        let clock = ContinuousClock()
        let start = clock.now
        var gestures = 0
        for step in 0...240 {
            harness.state.masterVolumeDB = -30 + Double(step) / 8
            gestures += 1
            try await Task.sleep(for: .milliseconds(1))
        }
        let elapsed = start.duration(to: clock.now)
        #expect(await eventually { system.volumeWrites.last == 1 })

        let writes = system.volumeWrites.count - before
        let rounds = Int(elapsed / timing.pollInterval) + 2
        #expect(writes <= rounds, "\(writes) écritures pour \(gestures) gestes en \(elapsed)")
        #expect(writes >= 2, "le Mac suit pendant le geste, pas seulement à la fin")
        #expect(await staysFalse(during: .milliseconds(150)) { harness.state.masterVolumeDB != 0 })
        await harness.stopStreaming()
    }

    /// Comme le bouton du panneau (commit 213cf2c) : le silence n'est qu'une consigne de volume.
    @Test("La touche silence bascule le silence des enceintes, sans arrêt, retrait ni relance")
    func muteKeyKeepsSessions() async throws {
        let system = FakeSystemVolume()
        let harness = BridgeHarness(systemVolume: system)
        await harness.discover(raop: [Devices.genevaRAOP], airplay2: [Devices.left, Devices.right])
        await harness.startStreaming(expecting: ids)
        #expect(await eventually { system.current?.isMuted == false })
        let senders = try ids.map { try #require(harness.factory.latest($0)) }
        let created = harness.factory.createdCount
        let mutes = system.muteWrites.count

        for _ in 0..<3 {
            system.press(muted: true)
            #expect(await eventually { harness.state.isMuted })
            for sender in senders {
                #expect(await eventually { await sender.pushedVolumes.last == -144 })
            }
            system.press(muted: false)
            #expect(await eventually { !harness.state.isMuted })
            for sender in senders {
                let started = try #require(await sender.startedVolume)
                #expect(await eventually { await sender.pushedVolumes.last == started })
            }
        }

        #expect(await staysFalse { harness.factory.createdCount != created })
        #expect(harness.captures.count == 1)
        for sender in senders {
            #expect(await sender.stopCount == 0)
            #expect(await sender.pushedVolumes.count == 6)
        }
        for id in ids { #expect(harness.output(id)?.connection == .streaming) }
        // Rien n'est reparti vers le Mac : c'est lui qui avait parlé.
        #expect(system.muteWrites.count == mutes)
        await harness.stopStreaming()
    }

    /// La fenêtre d'écho écarte un relevé périmé, mais pas une vraie touche : celle-ci est rattrapée
    /// par le relevé qui clôt la fenêtre.
    @Test("Une touche pressée juste après un réglage de l'app est rattrapée")
    func keyDuringEchoWindowIsCaughtUp() async {
        var timing = BridgeEnvironment.Timing.fast
        timing.pollInterval = .milliseconds(30)
        let system = FakeSystemVolume()
        let harness = BridgeHarness(timing: timing, systemVolume: system)
        await harness.discover(raop: [Devices.genevaRAOP])
        await harness.startStreaming(expecting: [Devices.genevaID])
        #expect(await eventually { system.current?.volume == 0.6 })
        try? await Task.sleep(for: .milliseconds(80))
        let writes = system.volumeWrites.count

        harness.state.masterVolumeDB = -15
        #expect(await eventually { system.volumeWrites.count == writes + 1 })
        system.press(volume: notch(4))
        #expect(await eventually { harness.state.masterVolumeDB == -45 })
        #expect(system.volumeWrites.count == writes + 1)
        await harness.stopStreaming()
    }
}

@Suite("Volume du Mac — option, source et réglages")
struct SystemVolumeOptionTests {
    @Test("Désactivée en diffusion : le Mac est rendu sans relance ; réactivée, le lien reprend sur place")
    func disabledDuringStreaming() async {
        let system = FakeSystemVolume()
        let harness = BridgeHarness(systemVolume: system)
        await harness.discover(raop: [Devices.genevaRAOP])
        await harness.startStreaming(expecting: [Devices.genevaID])
        #expect(await eventually { system.current?.volume == 0.6 })

        harness.state.followsSystemVolume = false
        #expect(system.current == FakeSystemVolume.Device.speakers)
        #expect(!system.isObserving)
        #expect(await eventually { harness.store.stored.systemVolumeMemory == nil })
        system.press(volume: notch(14))
        harness.state.masterVolumeDB = -6
        #expect(await staysFalse(during: .milliseconds(100)) {
            harness.state.masterVolumeDB != -6 || system.current?.volume != notch(14)
        })
        #expect(harness.captures.count == 1)
        harness.state.flushSettings()
        #expect(harness.store.stored.followsSystemVolume == false)

        // Le tap coupe encore le son local : le lien repart sans relance.
        harness.state.followsSystemVolume = true
        #expect(harness.store.stored.systemVolumeMemory?.volume == notch(14))
        #expect(await eventually { system.current?.volume == 0.9 })
        #expect(harness.captures.count == 1)
        await harness.stopStreaming()
        #expect(system.current?.volume == notch(14))
    }

    @Test("Activée en diffusion sans silence local : la capture est relancée une fois, son local coupé")
    func enabledDuringStreaming() async {
        var settings = BridgeSettings()
        settings.followsSystemVolume = false
        let system = FakeSystemVolume()
        let harness = BridgeHarness(settings: settings, systemVolume: system)
        await harness.discover(raop: [Devices.genevaRAOP])
        await harness.startStreaming(expecting: [Devices.genevaID])
        #expect(harness.captures.last?.options.muteLocalOutput == false)
        #expect(system.reads == 0)

        harness.state.followsSystemVolume = true
        #expect(await eventually { harness.captures.count == 2 })
        #expect(harness.captures.last?.options.muteLocalOutput == true)
        #expect(await eventually { system.current?.volume == 0.6 })
        #expect(harness.store.stored.systemVolumeMemory?.deviceUID == "BuiltInSpeakerDevice")
        #expect(!harness.state.muteLocalOutput)
        #expect(await staysFalse { harness.captures.count > 2 })
        await harness.stopStreaming()
        #expect(system.current == FakeSystemVolume.Device.speakers)
    }

    @Test("« Couper le son du Mac » touché pendant le lien : réglage gardé, aucune relance inutile")
    func userLocalMuteIsNeverRewritten() async {
        let system = FakeSystemVolume()
        let harness = BridgeHarness(systemVolume: system)
        await harness.discover(raop: [Devices.genevaRAOP])
        await harness.startStreaming(expecting: [Devices.genevaID])
        #expect(await eventually { system.current?.volume == 0.6 })

        harness.state.muteLocalOutput = true
        #expect(await staysFalse { harness.captures.count > 1 })
        harness.state.muteLocalOutput = false
        #expect(await staysFalse { harness.captures.count > 1 })
        harness.state.flushSettings()
        #expect(harness.store.stored.muteLocalOutput == false)
        await harness.stopStreaming()
        #expect(!harness.state.muteLocalOutput)
    }

    @Test("Option désactivée au démarrage : ni lecture, ni silence local forcé")
    func disabledAtStart() async {
        var settings = BridgeSettings()
        settings.followsSystemVolume = false
        let system = FakeSystemVolume()
        let harness = BridgeHarness(settings: settings, systemVolume: system)
        await harness.discover(raop: [Devices.genevaRAOP])
        await harness.startStreaming(expecting: [Devices.genevaID])
        system.press(volume: notch(14))
        #expect(await staysFalse { harness.state.masterVolumeDB != BridgeState.defaultMasterVolumeDB })
        #expect(system.reads == 0)
        #expect(harness.captures.last?.options.muteLocalOutput == false)
        await harness.stopStreaming()
    }

    @Test("Une sortie sans volume réglable : pas de lien, pas de silence local forcé, et le panneau sait pourquoi")
    func deviceWithoutVolume() async {
        let system = FakeSystemVolume(.hdmi)
        let harness = BridgeHarness(systemVolume: system)
        await harness.discover(raop: [Devices.genevaRAOP])
        await harness.startStreaming(expecting: [Devices.genevaID])
        #expect(harness.state.systemVolume.inoperativeDeviceName == "HDMI")
        #expect(harness.captures.last?.options.muteLocalOutput == false)
        harness.state.masterVolumeDB = -12
        #expect(await staysFalse { !system.volumeWrites.isEmpty || !system.muteWrites.isEmpty })
        #expect(harness.store.stored.systemVolumeMemory == nil)
        await harness.stopStreaming()
        #expect(harness.state.systemVolume.inoperativeDeviceName == nil)
    }

    @Test("Avec une autre source que le son système global, le Mac n'est ni lu ni réglé")
    func onlyWithSystemWideSource() async {
        let system = FakeSystemVolume()
        let harness = BridgeHarness(systemVolume: system)
        harness.state.selectSource(id: CaptureSource.inputDevice.id)
        await harness.discover(raop: [Devices.genevaRAOP])
        await harness.startStreaming(expecting: [Devices.genevaID])
        #expect(!harness.state.sourceAllowsSystemVolumeLink)
        #expect(system.reads == 0)
        #expect(harness.captures.last?.options.muteLocalOutput == false)
        await harness.stopStreaming()
    }

    @Test("Un fichier d'avant l'option la laisse activée ; la mémoire se relit, ou s'écarte si elle est abîmée")
    func settingsDecoding() throws {
        #expect(BridgeSettings().followsSystemVolume)
        #expect(BridgeSettings().systemVolumeMemory == nil)
        let old = try JSONDecoder().decode(
            BridgeSettings.self, from: Data(#"{"isMuted": false, "masterVolumeDB": -30}"#.utf8)
        )
        #expect(old.followsSystemVolume)
        #expect(old.systemVolumeMemory == nil)
        let off = try JSONDecoder().decode(
            BridgeSettings.self, from: Data(#"{"followsSystemVolume": false}"#.utf8)
        )
        #expect(!off.followsSystemVolume)
        let garbled = try JSONDecoder().decode(
            BridgeSettings.self,
            from: Data(#"{"followsSystemVolume": "peut-être", "systemVolumeMemory": 3}"#.utf8)
        )
        #expect(garbled.followsSystemVolume)
        #expect(garbled.systemVolumeMemory == nil)

        var settings = BridgeSettings()
        settings.followsSystemVolume = false
        settings.systemVolumeMemory = SystemVolumeMemory(
            deviceUID: "BuiltInSpeakerDevice", deviceName: "Haut-parleurs", volume: 0, isMuted: true
        )
        let roundTrip = try JSONDecoder().decode(
            BridgeSettings.self, from: JSONEncoder().encode(settings)
        )
        #expect(roundTrip == settings)
    }

    @Test("Le libellé de l'option et son détail")
    func optionText() {
        #expect(PanelSystemVolumeOption.title == "Touches de volume du Mac → enceintes")
        #expect(
            PanelSystemVolumeOption.detail
                == "Pendant la diffusion. Le Mac se tait et retrouve son volume à l'arrêt."
        )
        #expect(!PanelSystemVolumeOption.accessibilityTitle.contains("→"))
    }
}
