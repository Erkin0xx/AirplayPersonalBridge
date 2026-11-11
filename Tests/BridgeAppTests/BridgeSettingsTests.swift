import Foundation
import Testing

@testable import BridgeApp

@Suite("Réglages — fichier")
struct BridgeSettingsFileTests {
    /// Un dossier propre à chaque test, jamais les réglages de la machine.
    private func makeStore() throws -> (store: FileSettingsStore, directory: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "bridge-settings-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (FileSettingsStore(url: directory.appending(path: "settings.json")), directory)
    }

    private func siblings(of store: FileSettingsStore, in directory: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false))
            .filter { $0 != store.url.lastPathComponent && !$0.hasPrefix(".") }
    }

    @Test("Aller-retour complet")
    func roundTrip() throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        var settings = BridgeSettings()
        settings.masterVolumeDB = -31
        settings.isMuted = true
        settings.sourceID = "app-com.apple.Music"
        settings.muteLocalOutput = true
        settings.outputs["raop/A@Geneva"] = BridgeSettings.Output(
            isEnabled: false, trimDB: -3.5, delayMS: 25, bassBoostDB: 6, trebleCutDB: -4.5,
            displayName: "Geneva"
        )
        #expect(store.save(settings))
        #expect(store.load() == settings)
        #expect(try siblings(of: store, in: directory).isEmpty)
    }

    @Test("Sans fichier, les valeurs par défaut")
    func missingFile() throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let loaded = store.load()
        #expect(loaded == BridgeSettings())
        #expect(loaded.masterVolumeDB == BridgeState.defaultMasterVolumeDB)
        #expect(!loaded.muteLocalOutput)
    }

    @Test("Un dossier absent ne fait pas échouer la sauvegarde")
    func createsDirectory() throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let nested = FileSettingsStore(
            url: directory.appending(path: "sous-dossier").appending(path: "settings.json")
        )
        #expect(nested.save(BridgeSettings()))
        #expect(store.load() == BridgeSettings())
    }

    @Test("Un champ absent prend sa valeur par défaut, sans alerte")
    func missingFieldIsDefault() throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data(#"{"isMuted": true, "outputs": {"raop/A@B": {"trimDB": 2}}}"#.utf8)
            .write(to: store.url)

        let loaded = store.load()
        #expect(loaded.isMuted)
        #expect(loaded.masterVolumeDB == BridgeState.defaultMasterVolumeDB)
        #expect(loaded.outputs["raop/A@B"]?.trimDB == 2)
        #expect(loaded.outputs["raop/A@B"]?.isEnabled == true)
        // Un fichier d'avant les aigus se relit tel quel : la coupe y vaut 0 dB.
        #expect(loaded.outputs["raop/A@B"]?.trebleCutDB == 0)
        // Rien n'a été perdu : pas de copie.
        #expect(try siblings(of: store, in: directory).isEmpty)
    }

    @Test("Un champ inconnu est ignoré : une version ultérieure ne casse pas celle-ci")
    func unknownFieldIsIgnored() throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data(#"{"isMuted": true, "futur": {"a": 1}}"#.utf8).write(to: store.url)
        #expect(store.load().isMuted)
    }

    @Test("Un fichier illisible est préservé à côté, et ne bloque pas le lancement")
    func unreadableFileIsPreserved() throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let garbage = Data("{ ceci n'est pas du JSON".utf8)
        try garbage.write(to: store.url)

        #expect(store.load() == BridgeSettings())
        let copies = try siblings(of: store, in: directory)
        #expect(copies.count == 1)
        let copy = try #require(copies.first)
        #expect(copy.contains("illisible"))
        #expect(try Data(contentsOf: directory.appending(path: copy)) == garbage)

        // La sauvegarde suivante peut alors écraser sans rien détruire, et relire le même fichier
        // abîmé ne multiplie pas les copies.
        _ = store.load()
        #expect(try siblings(of: store, in: directory).count == 1)
    }

    @Test("Un fichier lu en partie est préservé aussi : c'est le cas le plus traître")
    func partialFileIsPreserved() throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let json = """
            {
              "masterVolumeDB": "fort",
              "isMuted": true,
              "outputs": {
                "raop/A@Geneva": {"trimDB": 3},
                "raop/B@Abimee": "pas un objet",
                "raop/C@Autre": {"trimDB": "beaucoup", "delayMS": 12}
              }
            }
            """
        try Data(json.utf8).write(to: store.url)

        let loaded = store.load()
        #expect(loaded.isMuted)
        #expect(loaded.masterVolumeDB == BridgeState.defaultMasterVolumeDB)
        #expect(loaded.outputs["raop/A@Geneva"]?.trimDB == 3)
        #expect(loaded.outputs["raop/B@Abimee"] == nil)
        #expect(loaded.outputs["raop/C@Autre"]?.trimDB == 0)
        #expect(loaded.outputs["raop/C@Autre"]?.delayMS == 12)
        #expect(try siblings(of: store, in: directory).count == 1)
    }

    @Test("Un fichier retouché à la main revient dans les bornes des curseurs")
    func valuesAreClamped() throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let json = """
            {
              "masterVolumeDB": 40,
              "outputs": {
                "raop/A@B": {"trimDB": 99, "delayMS": -9000, "bassBoostDB": 200, "trebleCutDB": -40},
                "raop/C@D": {"trebleCutDB": 6}
              }
            }
            """
        try Data(json.utf8).write(to: store.url)

        let loaded = store.load()
        #expect(loaded.masterVolumeDB == 0)
        let output = try #require(loaded.outputs["raop/A@B"])
        #expect(output.trimDB == BridgeSettings.Limits.trimDB.upperBound)
        #expect(output.delayMS == BridgeSettings.Limits.delayMS.lowerBound)
        #expect(output.bassBoostDB == BridgeSettings.Limits.bassBoostDB.upperBound)
        #expect(output.trebleCutDB == BridgeSettings.Limits.trebleCutDB.lowerBound)
        // Une coupe seulement : une valeur positive ne devient pas un renfort des aigus.
        #expect(loaded.outputs["raop/C@D"]?.trebleCutDB == 0)
    }

    @Test("Un fichier qui n'est pas un objet est illisible, pas une exception")
    func wrongShape() throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("[1, 2, 3]".utf8).write(to: store.url)
        #expect(store.load() == BridgeSettings())
        #expect(try siblings(of: store, in: directory).count == 1)
    }
}

@Suite("Réglages — persistance de l'état")
struct BridgeStatePersistenceTests {
    @Test("Les réglages partent différés : plusieurs gestes, une écriture")
    func saveIsDeferred() async {
        let harness = BridgeHarness()
        let state = harness.state
        for value in stride(from: -30.0, through: -20.0, by: 1) {
            state.masterVolumeDB = value
        }
        #expect(harness.store.saveCount == 0)
        #expect(await eventually { harness.store.saveCount == 1 })
        #expect(harness.store.stored.masterVolumeDB == -20)
        // Plus rien ne bouge : plus aucune écriture.
        #expect(await staysFalse { harness.store.saveCount > 1 })
    }

    @Test("Tout ce qui doit l'être est conservé")
    func everythingIsPersisted() async throws {
        let harness = BridgeHarness()
        await harness.discover(raop: [Devices.genevaRAOP], airplay2: [Devices.genevaAirPlay2])
        let geneva = try #require(harness.output(Devices.genevaID))
        geneva.isEnabled = false
        geneva.trimDB = -4
        geneva.delayMS = 30
        geneva.bassBoostDB = 8
        geneva.trebleCutDB = -4.5
        harness.state.isMuted = true
        harness.state.muteLocalOutput = true
        harness.state.selectSource(id: CaptureSource.inputDevice.id)
        harness.state.flushSettings()

        let saved = harness.store.stored
        #expect(saved.isMuted)
        #expect(saved.muteLocalOutput)
        #expect(saved.sourceID == CaptureSource.inputDevice.id)
        let record = try #require(saved.outputs[Devices.genevaID])
        #expect(!record.isEnabled)
        #expect(record.trimDB == -4)
        #expect(record.delayMS == 30)
        #expect(record.bassBoostDB == 8)
        #expect(record.trebleCutDB == -4.5)
        #expect(record.displayName == "Geneva")
    }

    @Test("Au lancement, les réglages reviennent, et une sortie cochée est visible aussitôt")
    func settingsComeBack() async throws {
        var settings = BridgeSettings()
        settings.masterVolumeDB = -18
        settings.isMuted = true
        settings.muteLocalOutput = true
        settings.sourceID = CaptureSource.inputDevice.id
        settings.outputs[Devices.genevaID] = BridgeSettings.Output(
            isEnabled: true, trimDB: 2, delayMS: 15, bassBoostDB: 4, trebleCutDB: -3,
            displayName: "Geneva"
        )
        settings.outputs[Devices.rightID] = BridgeSettings.Output(
            isEnabled: false, trimDB: -1, displayName: "Salon (2)"
        )
        let harness = BridgeHarness(settings: settings)
        let state = harness.state

        #expect(state.masterVolumeDB == -18)
        #expect(state.isMuted)
        #expect(state.muteLocalOutput)
        #expect(state.selectedSource == .inputDevice)

        // Les deux attendent d'être revues : cochée ou seulement réglée, une enceinte dont on se sert
        // garde sa place.
        #expect(state.outputs.map(\.id) == [Devices.genevaID, Devices.rightID])
        #expect(harness.output(Devices.rightID)?.isEnabled == false)
        let restored = try #require(harness.output(Devices.genevaID))
        #expect(restored.presence == .unknown)
        #expect(restored.trimDB == 2)
        #expect(restored.bassBoostDB == 4)
        #expect(restored.trebleCutDB == -3)

        await harness.discover(
            raop: [Devices.genevaRAOP, Devices.rightRAOP],
            airplay2: [Devices.genevaAirPlay2, Devices.right]
        )
        // Toujours le même objet : la fenêtre et le panneau n'ont pas à le savoir.
        #expect(harness.output(Devices.genevaID) === restored)
        #expect(restored.presence == .online)
        #expect(restored.host == "192.168.1.42")

        let right = try #require(harness.output(Devices.rightID))
        #expect(!right.isEnabled)
        #expect(right.trimDB == -1)
    }

    @Test("Une sortie décochée dont on s'est servi reste en grisé quand elle s'éteint, avec ses réglages")
    func reappearingOutputKeepsSettings() async throws {
        let harness = BridgeHarness()
        await harness.discover(airplay2: [Devices.left])
        let left = try #require(harness.output(Devices.leftID))
        left.isEnabled = false
        left.trimDB = 5
        left.delayMS = 40

        await harness.discover()
        await harness.discover()
        // Éteinte : elle garde sa place, hors ligne, et ne se recoche pas toute seule.
        #expect(harness.output(Devices.leftID)?.presence == .offline)
        #expect(harness.output(Devices.leftID)?.isEnabled == false)

        await harness.discover(airplay2: [Devices.left])
        let back = try #require(harness.output(Devices.leftID))
        #expect(!back.isEnabled)
        #expect(back.trimDB == 5)
        #expect(back.delayMS == 40)
    }

    @Test("Une enceinte seulement aperçue, jamais cochée ni réglée, disparaît quand elle s'éteint")
    func unusedOutputLeavesWhenItGoesAway() async throws {
        var settings = BridgeSettings()
        settings.outputs[Devices.rightID] = BridgeSettings.Output(isEnabled: true, displayName: "Salon (2)")
        let harness = BridgeHarness(settings: settings)
        await harness.discover(airplay2: [Devices.left, Devices.right])
        let left = try #require(harness.output(Devices.leftID))
        #expect(!left.isEnabled)
        #expect(!left.keepsPlace)

        await harness.discover(airplay2: [Devices.right])
        await harness.discover(airplay2: [Devices.right])
        #expect(harness.output(Devices.leftID) == nil)
    }

    @Test("Garder sa place : cochée, déjà cochée un jour, ou réglée ; un ancien fichier compte les réglages")
    func keepsPlaceRule() throws {
        #expect(BridgeSettings.Output(isEnabled: true).keepsPlace)
        #expect(!BridgeSettings.Output(isEnabled: false).keepsPlace)
        #expect(BridgeSettings.Output(isEnabled: false, bassBoostDB: 5.5).keepsPlace)
        #expect(BridgeSettings.Output(isEnabled: false, trimDB: -1).keepsPlace)
        var used = BridgeSettings.Output(isEnabled: false)
        used.wasUsed = true
        #expect(used.keepsPlace)
        let round = try JSONDecoder().decode(BridgeSettings.Output.self, from: JSONEncoder().encode(used))
        #expect(round.wasUsed)
        let old = try JSONDecoder().decode(
            BridgeSettings.Output.self, from: Data(#"{"isEnabled": false, "trimDB": 0}"#.utf8)
        )
        #expect(!old.wasUsed && !old.keepsPlace)
    }

    @Test("Les réglages d'une sortie absente ne sont pas perdus à la sauvegarde")
    func absentOutputsAreKeptInFile() async {
        var settings = BridgeSettings()
        settings.outputs["raop/ABCD@Ailleurs"] = BridgeSettings.Output(
            isEnabled: false, trimDB: 7, displayName: "Ailleurs"
        )
        let harness = BridgeHarness(settings: settings)
        harness.state.masterVolumeDB = -10
        harness.state.flushSettings()
        #expect(harness.store.stored.outputs["raop/ABCD@Ailleurs"]?.trimDB == 7)
        #expect(harness.store.stored.masterVolumeDB == -10)
    }

    @Test("Un fichier inchangé n'est pas réécrit")
    func noUselessWrite() {
        let harness = BridgeHarness()
        harness.state.flushSettings()
        #expect(harness.store.saveCount == 0)
    }
}
