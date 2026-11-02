import AudioCore
import CoreAudio
import Foundation
import Testing

@testable import BridgeApp

// Le volume général des enceintes relié aux touches de volume et de silence du Mac
// (`SystemVolumeLink`), jusqu'au moteur : le vrai `BridgeEngine`, des senders sans réseau
// (`BridgeStateTestSupport`), et un volume du Mac sans Core Audio (`FakeSystemVolume`).

/// Le volume du Mac, sans Core Audio : ce que feraient les touches, et ce que l'app écrit.
///
/// Comme Core Audio, il notifie toute modification, celles de l'app comprises, un peu plus tard et sur
/// le MainActor : c'est ce qui rend une boucle possible, et ce que la liaison doit déjouer.
final class FakeSystemVolume: SystemVolumeControlling {
    struct Device {
        var id: AudioObjectID
        var name: String
        var volume: Float?
        var isMuted: Bool?

        static let speakers = Device(
            id: 83, name: "Haut-parleurs MacBook Pro", volume: 0.5, isMuted: false
        )
        static let headphones = Device(id: 120, name: "Casque", volume: 0.25, isMuted: false)
        static let hdmi = Device(id: 140, name: "HDMI", volume: nil, isMuted: nil)
    }

    private(set) var device: Device?
    private(set) var volumeWrites: [Float] = []
    private(set) var muteWrites: [Bool] = []
    private(set) var isObserving = false
    private(set) var observeCount = 0
    private var onChange: (@MainActor () -> Void)?

    init(_ device: Device? = .speakers) {
        self.device = device
    }

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
        device.map {
            SystemOutputVolume.Reading(
                deviceID: $0.id, deviceName: $0.name, volume: $0.volume, isMuted: $0.isMuted
            )
        }
    }

    func setVolume(_ scalar: Float, on id: AudioObjectID) -> Bool {
        guard var current = device, current.id == id, current.volume != nil else { return false }
        volumeWrites.append(scalar)
        current.volume = scalar
        device = current
        notify()
        return true
    }

    func setMuted(_ muted: Bool, on id: AudioObjectID) -> Bool {
        guard var current = device, current.id == id, current.isMuted != nil else { return false }
        muteWrites.append(muted)
        current.isMuted = muted
        device = current
        notify()
        return true
    }

    /// Une touche de volume, la touche silence ou le curseur du Centre de contrôle.
    func press(volume: Float? = nil, muted: Bool? = nil) {
        guard var current = device else { return }
        if let volume, current.volume != nil { current.volume = volume }
        if let muted, current.isMuted != nil { current.isMuted = muted }
        device = current
        notify()
    }

    /// Une autre sortie par défaut : un casque branché, par exemple.
    func plug(_ device: Device) {
        self.device = device
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

@Suite("Volume du Mac — des touches aux enceintes")
struct SystemVolumeKeysTests {
    private let ids = [Devices.genevaID, Devices.leftID, Devices.rightID]

    @Test("Au lancement, le master adopte le volume et le silence du Mac")
    func launchAdoptsSystemVolume() async {
        let system = FakeSystemVolume(
            FakeSystemVolume.Device(id: 83, name: "Haut-parleurs", volume: 0.25, isMuted: true)
        )
        let harness = BridgeHarness(systemVolume: system)
        #expect(harness.state.masterVolumeDB == BridgeState.defaultMasterVolumeDB)
        #expect(!harness.state.isMuted)
        #expect(!system.isObserving)

        // C'est le lancement de l'app qui l'arme, fenêtre ou non.
        harness.state.startBackgroundWork()
        #expect(system.isObserving)
        #expect(harness.state.masterVolumeDB == -45)
        #expect(harness.state.isMuted)
        // Adopter n'est pas un geste : rien ne repart vers le Mac.
        #expect(await staysFalse { !system.volumeWrites.isEmpty || !system.muteWrites.isEmpty })
        #expect(await eventually { harness.store.stored.masterVolumeDB == -45 })
    }

    @Test("Une touche déplace le master et le volume poussé aux enceintes, sans repartir vers le Mac")
    func keyMovesMasterAndEngine() async throws {
        let system = FakeSystemVolume()
        let harness = BridgeHarness(systemVolume: system)
        await harness.discover(raop: [Devices.genevaRAOP], airplay2: [Devices.left])
        harness.state.startFollowingSystemVolume()
        #expect(harness.state.masterVolumeDB == -30)
        await harness.startStreaming(expecting: [Devices.genevaID, Devices.leftID])
        let geneva = try #require(harness.factory.latest(Devices.genevaID))
        let left = try #require(harness.factory.latest(Devices.leftID))
        #expect(await geneva.startedVolume == -15)

        // Quatre crans vers le haut, un à la fois.
        for step in 9...12 {
            system.press(volume: notch(step))
            let master = -60 + 3.75 * Double(step)
            #expect(await eventually { harness.state.masterVolumeDB == master }, "cran \(step)")
        }
        #expect(await eventually { await geneva.pushedVolumes.last == -7.5 })
        #expect(await eventually { await left.pushedVolumes.last == -7.5 })
        #expect(system.volumeWrites.isEmpty)
        #expect(await geneva.stopCount == 0)
        #expect(harness.factory.createdCount == 2)
        await harness.stopStreaming()
    }

    @Test("Le curseur de l'app règle le volume du Mac, une fois, sans que l'écho le fasse bouger")
    func sliderSetsSystemVolume() async {
        let system = FakeSystemVolume()
        let harness = BridgeHarness(systemVolume: system)
        harness.state.startFollowingSystemVolume()
        #expect(harness.state.masterVolumeDB == -30)

        harness.state.masterVolumeDB = -15
        #expect(await eventually { system.volumeWrites == [0.75] })
        // L'écho de cette écriture revient par l'écouteur : ni seconde écriture, ni master déplacé.
        #expect(await staysFalse(during: .milliseconds(100)) {
            system.volumeWrites.count > 1 || harness.state.masterVolumeDB != -15
        })

        // Le bouton de silence de l'app positionne le silence du Mac.
        harness.state.isMuted = true
        #expect(await eventually { system.muteWrites == [true] })
        harness.state.isMuted = false
        #expect(await eventually { system.muteWrites == [true, false] })
        #expect(await staysFalse(during: .milliseconds(100)) {
            system.muteWrites.count > 2 || harness.state.isMuted
        })
        #expect(system.volumeWrites == [0.75])
    }

    /// Un glissement réel, étalé dans le temps : au plus une écriture par tour de la boucle, quelle
    /// que soit la cadence du curseur. La borne ne fait que baisser si la machine est chargée.
    @Test("Un glissement du curseur règle le Mac au plus une fois par tour de la boucle")
    func sliderIsRateLimited() async throws {
        var timing = BridgeEnvironment.Timing.fast
        timing.pollInterval = .milliseconds(40)
        let system = FakeSystemVolume()
        let harness = BridgeHarness(timing: timing, systemVolume: system)
        harness.state.startFollowingSystemVolume()

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

        let rounds = Int(elapsed / timing.pollInterval) + 2
        #expect(
            system.volumeWrites.count <= rounds,
            "\(system.volumeWrites.count) écritures pour \(gestures) gestes en \(elapsed)"
        )
        #expect(system.volumeWrites.count >= 2, "le Mac suit pendant le geste, pas seulement à la fin")
        // Les échos du glissement n'ont pas ramené le curseur en arrière.
        #expect(await staysFalse(during: .milliseconds(150)) { harness.state.masterVolumeDB != 0 })
    }

    /// La tolérance ne vaut que pour ce qui revient du Mac : un geste de l'app plus fin qu'un demi-cran
    /// doit arriver, sans quoi un glissement fini au maximum laisserait le Mac à 99 %.
    @Test("Un réglage plus fin que la tolérance atteint quand même le Mac, jusqu'aux bornes")
    func fineGestureReachesTheMac() async {
        let system = FakeSystemVolume(
            FakeSystemVolume.Device(id: 83, name: "Haut-parleurs", volume: 0.995, isMuted: false)
        )
        let harness = BridgeHarness(systemVolume: system)
        harness.state.startFollowingSystemVolume()
        #expect(abs(harness.state.masterVolumeDB - -0.3) < 1e-4)

        harness.state.masterVolumeDB = 0
        #expect(await eventually { system.volumeWrites == [1] })
        harness.state.masterVolumeDB = -0.2
        let target = 1 - 0.2 / 60
        #expect(await eventually {
            system.volumeWrites.count == 2 && abs(Double(system.volumeWrites.last ?? 0) - target) < 1e-6
        })
        // L'écho de ces écritures n'a rien déplacé.
        #expect(await staysFalse(during: .milliseconds(60)) { harness.state.masterVolumeDB != -0.2 })
    }

    /// Comme le bouton du panneau (commit 213cf2c) : le silence n'est qu'une consigne de volume.
    @Test("La touche silence bascule le silence des enceintes, sans arrêt, retrait ni relance")
    func muteKeyKeepsSessions() async throws {
        let system = FakeSystemVolume()
        let harness = BridgeHarness(systemVolume: system)
        await harness.discover(raop: [Devices.genevaRAOP], airplay2: [Devices.left, Devices.right])
        harness.state.startFollowingSystemVolume()
        await harness.startStreaming(expecting: ids)
        let senders = try ids.map { try #require(harness.factory.latest($0)) }
        let created = harness.factory.createdCount

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
        #expect(harness.state.masterVolumeDB == -30)
        // Rien n'est reparti vers le Mac : c'est lui qui avait parlé.
        #expect(system.muteWrites.isEmpty)
        #expect(system.volumeWrites.isEmpty)
        await harness.stopStreaming()
    }

    @Test("Un casque branché : le master adopte son volume, et chaque sortie garde le sien")
    func deviceChangeAdoptsItsVolume() async {
        let system = FakeSystemVolume()
        let harness = BridgeHarness(systemVolume: system)
        harness.state.startFollowingSystemVolume()
        #expect(harness.state.masterVolumeDB == -30)

        system.plug(.headphones)
        #expect(await eventually { harness.state.masterVolumeDB == -45 })
        // Le curseur règle désormais le casque.
        harness.state.masterVolumeDB = -37.5
        #expect(await eventually { system.device?.volume == 0.375 })
        #expect(system.device?.id == FakeSystemVolume.Device.headphones.id)

        // Retour aux haut-parleurs, restés à leur volume, et coupés entre-temps.
        var speakers = FakeSystemVolume.Device.speakers
        speakers.isMuted = true
        system.plug(speakers)
        #expect(await eventually { harness.state.masterVolumeDB == -30 })
        #expect(harness.state.isMuted)
        #expect(system.volumeWrites == [0.375])
    }

    /// La fenêtre d'écho écarte un relevé périmé, mais pas une vraie touche : celle-ci est rattrapée
    /// par le relevé qui clôt la fenêtre.
    @Test("Une touche pressée juste après un réglage de l'app est rattrapée")
    func keyDuringEchoWindowIsCaughtUp() async {
        var timing = BridgeEnvironment.Timing.fast
        timing.pollInterval = .milliseconds(30)
        let system = FakeSystemVolume()
        let harness = BridgeHarness(timing: timing, systemVolume: system)
        harness.state.startFollowingSystemVolume()

        harness.state.masterVolumeDB = -15
        #expect(await eventually { system.volumeWrites == [0.75] })
        system.press(volume: notch(4))
        #expect(await eventually { harness.state.masterVolumeDB == -45 })
        #expect(system.volumeWrites == [0.75])
    }

    @Test("Avec « Couper le son du Mac », les touches ne règlent que les enceintes, sans relance")
    func compatibleWithLocalMute() async throws {
        let system = FakeSystemVolume()
        let harness = BridgeHarness(systemVolume: system)
        harness.state.muteLocalOutput = true
        await harness.discover(raop: [Devices.genevaRAOP])
        harness.state.startFollowingSystemVolume()
        await harness.startStreaming(expecting: [Devices.genevaID])
        let sender = try #require(harness.factory.latest(Devices.genevaID))
        #expect(harness.captures.last?.options.muteLocalOutput == true)

        system.press(volume: notch(14))
        #expect(await eventually { await sender.pushedVolumes.last == -3.75 })
        system.press(muted: true)
        #expect(await eventually { await sender.pushedVolumes.last == -144 })

        #expect(harness.captures.count == 1)
        #expect(!harness.state.isRestarting)
        #expect(await sender.stopCount == 0)
        #expect(harness.state.muteLocalOutput)
        await harness.stopStreaming()
    }
}

@Suite("Volume du Mac — option et sorties sans volume")
struct SystemVolumeOptionTests {
    @Test("Option désactivée : plus rien n'est lié, dans aucun sens, et c'est sauvegardé")
    func disabledLinksNothing() async {
        let system = FakeSystemVolume()
        let harness = BridgeHarness(systemVolume: system)
        harness.state.startFollowingSystemVolume()
        #expect(harness.state.masterVolumeDB == -30)

        harness.state.followsSystemVolume = false
        #expect(!system.isObserving)
        system.press(volume: notch(14), muted: true)
        harness.state.masterVolumeDB = -6
        harness.state.isMuted = true
        #expect(await staysFalse(during: .milliseconds(100)) {
            !system.volumeWrites.isEmpty || !system.muteWrites.isEmpty
                || harness.state.masterVolumeDB != -6
        })
        harness.state.flushSettings()
        #expect(harness.store.stored.followsSystemVolume == false)

        // Réactivée, elle adopte de nouveau le Mac, là où il en est.
        harness.state.followsSystemVolume = true
        #expect(system.isObserving)
        #expect(harness.state.masterVolumeDB == -7.5)
        #expect(harness.state.isMuted)
    }

    @Test("Désactivée dans les réglages, le lancement ne lit même pas le Mac")
    func disabledAtLaunch() async {
        var settings = BridgeSettings()
        settings.followsSystemVolume = false
        settings.masterVolumeDB = -18
        let system = FakeSystemVolume()
        let harness = BridgeHarness(settings: settings, systemVolume: system)
        #expect(!harness.state.followsSystemVolume)
        harness.state.startFollowingSystemVolume()
        #expect(system.observeCount == 0)
        #expect(harness.state.masterVolumeDB == -18)
    }

    @Test("Une sortie sans volume réglable : rien ne bouge, et le panneau sait pourquoi")
    func deviceWithoutVolume() async {
        let system = FakeSystemVolume(.hdmi)
        let harness = BridgeHarness(systemVolume: system)
        harness.state.startFollowingSystemVolume()
        #expect(harness.state.systemVolume.inoperativeDeviceName == "HDMI")
        #expect(harness.state.masterVolumeDB == BridgeState.defaultMasterVolumeDB)
        #expect(!harness.state.isMuted)

        system.press(volume: notch(16), muted: true)
        harness.state.masterVolumeDB = -12
        harness.state.isMuted = true
        harness.state.isMuted = false
        #expect(await staysFalse(during: .milliseconds(100)) {
            !system.volumeWrites.isEmpty || !system.muteWrites.isEmpty
                || harness.state.masterVolumeDB != -12 || harness.state.isMuted
        })

        // Une sortie qui a un volume revient : la liaison reprend.
        system.plug(.speakers)
        #expect(await eventually { harness.state.masterVolumeDB == -30 })
        #expect(harness.state.systemVolume.inoperativeDeviceName == nil)
    }

    @Test("Sans aucune sortie sur le Mac, rien ne bouge")
    func noOutputAtAll() async {
        let system = FakeSystemVolume(nil)
        let harness = BridgeHarness(systemVolume: system)
        harness.state.startFollowingSystemVolume()
        harness.state.masterVolumeDB = -12
        #expect(await staysFalse { !system.volumeWrites.isEmpty })
        #expect(harness.state.masterVolumeDB == -12)
    }

    @Test("Un fichier d'avant l'option la laisse activée ; désactivée, elle se relit")
    func settingsDecoding() throws {
        #expect(BridgeSettings().followsSystemVolume)
        let old = try JSONDecoder().decode(
            BridgeSettings.self, from: Data(#"{"isMuted": false, "masterVolumeDB": -30}"#.utf8)
        )
        #expect(old.followsSystemVolume)
        let off = try JSONDecoder().decode(
            BridgeSettings.self, from: Data(#"{"followsSystemVolume": false}"#.utf8)
        )
        #expect(!off.followsSystemVolume)
        let garbled = try JSONDecoder().decode(
            BridgeSettings.self, from: Data(#"{"followsSystemVolume": "peut-être"}"#.utf8)
        )
        #expect(garbled.followsSystemVolume)

        var settings = BridgeSettings()
        settings.followsSystemVolume = false
        let roundTrip = try JSONDecoder().decode(
            BridgeSettings.self, from: JSONEncoder().encode(settings)
        )
        #expect(roundTrip == settings)
    }

    @Test("Le libellé de l'option et son détail")
    func optionText() {
        #expect(PanelSystemVolumeOption.title == "Touches de volume du Mac → enceintes")
        #expect(!PanelSystemVolumeOption.accessibilityTitle.contains("→"))
    }
}
