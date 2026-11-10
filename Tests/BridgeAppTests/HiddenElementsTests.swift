import AudioCore
import Foundation
import Testing

@testable import BridgeApp

// Le masquage d'une enceinte ou d'un bloc de la fenêtre (`HiddenElements`) : ce qui s'enregistre, ce que
// les vues montrent, et ce qui ne doit surtout pas changer — ce qui joue.

@Suite("Masquage — réglages enregistrés")
struct HiddenElementsStorageTests {
    @Test("Les enceintes et les blocs masqués se relisent des réglages")
    func roundTrip() throws {
        var settings = BridgeSettings()
        settings.hiddenElements = HiddenElements(
            outputIDs: [Devices.appleTVRaopID, Devices.leftID], blocks: [.haloWaves, .masterVolume]
        )
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(BridgeSettings.self, from: data)
        #expect(decoded.hiddenElements == settings.hiddenElements)
        #expect(decoded == settings)
    }

    @Test("Le fichier ne change pas d'une écriture à l'autre : les listes sont triées")
    func encodingIsStable() throws {
        let hidden = HiddenElements(outputIDs: ["raop/b", "raop/c", "raop/a"], blocks: [.masterVolume, .haloWaves])
        let json = try #require(String(data: JSONEncoder().encode(hidden), encoding: .utf8))
        #expect(json.contains(#"["raop\/a","raop\/b","raop\/c"]"#))
        #expect(json.contains(#"["haloWaves","masterVolume"]"#))
    }

    @Test("Un fichier d'avant le masquage ne masque rien, et ne perd rien d'autre")
    func absentFieldHidesNothing() throws {
        let old = Data(#"{"masterVolumeDB": -31, "windowLayout": "console"}"#.utf8)
        let settings = try JSONDecoder().decode(BridgeSettings.self, from: old)
        #expect(settings.hiddenElements == HiddenElements())
        #expect(settings.masterVolumeDB == -31)
        #expect(settings.windowLayout == .console)
    }

    @Test("Un champ illisible ne masque rien, ne coûte pas les autres réglages, et se signale")
    func unreadableFieldFallsBack() throws {
        let broken = Data(#"{"masterVolumeDB": -31, "hiddenElements": "tout"}"#.utf8)
        let recorder = SettingsLossRecorder()
        let decoder = JSONDecoder()
        let key = try #require(SettingsLossRecorder.userInfoKey)
        decoder.userInfo[key] = recorder
        let settings = try decoder.decode(BridgeSettings.self, from: broken)
        #expect(settings.hiddenElements == HiddenElements())
        #expect(settings.masterVolumeDB == -31)
        #expect(recorder.hasLoss)
    }

    @Test("Un bloc inconnu est ignoré, les autres et les enceintes restent masqués")
    func unknownBlockIsIgnored() throws {
        let json = Data(
            #"{"hiddenElements": {"outputs": ["raop/x"], "blocks": ["hologramme", "haloWaves"]}}"#.utf8
        )
        let hidden = try JSONDecoder().decode(BridgeSettings.self, from: json).hiddenElements
        #expect(hidden.blocks == [.haloWaves])
        #expect(hidden.outputIDs == ["raop/x"])
    }

    @Test("Une liste illisible est vide, sans coûter l'autre")
    func oneUnreadableListSparesTheOther() throws {
        let json = Data(#"{"hiddenElements": {"outputs": 12, "blocks": ["listeningPlaces"]}}"#.utf8)
        let hidden = try JSONDecoder().decode(BridgeSettings.self, from: json).hiddenElements
        #expect(hidden.outputIDs.isEmpty)
        #expect(hidden.blocks == [.listeningPlaces])

        let other = Data(#"{"hiddenElements": {"outputs": ["raop/x"], "blocks": {"a": 1}}}"#.utf8)
        let fromOther = try JSONDecoder().decode(BridgeSettings.self, from: other).hiddenElements
        #expect(fromOther.outputIDs == ["raop/x"])
        #expect(fromOther.blocks.isEmpty)
    }

    @Test("Chaque bloc masquable se relit, a un titre, et se voit dans une vue au moins")
    func blocksAreDescribed() throws {
        for block in WindowBlock.allCases {
            let data = try JSONEncoder().encode(HiddenElements(blocks: [block]))
            #expect(try JSONDecoder().decode(HiddenElements.self, from: data).blocks == [block])
            #expect(!block.title.isEmpty)
            #expect(!block.detail.isEmpty)
            #expect(!block.layouts.isEmpty)
        }
        #expect(WindowBlock.haloWaves.layouts == [.halo])
        #expect(WindowBlock.listeningPlaces.layouts == [.console])
        #expect(WindowBlock.masterVolume.layouts == Set(WindowLayout.allCases))
    }
}

@Suite("Masquage — logique pure")
struct HiddenElementsLogicTests {
    @Test("Les éléments visibles gardent leur ordre, sans les masqués")
    func visibleKeepsOrder() {
        let hidden = HiddenElements(outputIDs: ["b", "absent"])
        #expect(hidden.visible(["a", "b", "c", "d"]) { $0 } == ["a", "c", "d"])
        #expect(HiddenElements().visible(["a", "b"]) { $0 } == ["a", "b"])
    }

    @Test("Un geste sur un membre d'une paire vise toute la paire, et elle seule")
    func targetsCarryThePair() {
        let pairKeys = ["gauche": "paire", "droite": "paire", "cuisine": "autre"]
        #expect(HiddenElements.targets(of: "gauche", pairKeys: pairKeys) == ["gauche", "droite"])
        #expect(HiddenElements.targets(of: "droite", pairKeys: pairKeys) == ["gauche", "droite"])
        #expect(HiddenElements.targets(of: "cuisine", pairKeys: pairKeys) == ["cuisine"])
        // Sans paire connue, ou avec un `tsid` vide : elle seule.
        #expect(HiddenElements.targets(of: "geneva", pairKeys: pairKeys) == ["geneva"])
        #expect(HiddenElements.targets(of: "a", pairKeys: ["a": "", "b": ""]) == ["a"])
    }

    @Test("Masquer puis réafficher un membre masque puis réaffiche les deux")
    func hidingCarriesThePair() {
        let pairKeys = ["gauche": "paire", "droite": "paire"]
        var hidden = HiddenElements(outputIDs: ["tv"])
        hidden.setHidden(true, outputID: "gauche", pairKeys: pairKeys)
        #expect(hidden.outputIDs == ["tv", "gauche", "droite"])
        hidden.setHidden(false, outputID: "droite", pairKeys: pairKeys)
        #expect(hidden.outputIDs == ["tv"])
    }

    @Test("Le libellé s'accorde, et se tait quand rien n'est masqué")
    func summaryAgrees() {
        #expect(HiddenElementsCopy.summary(speakers: 0, blocks: 0) == nil)
        #expect(HiddenElementsCopy.summary(speakers: 1, blocks: 0) == "1 enceinte masquée")
        #expect(HiddenElementsCopy.summary(speakers: 2, blocks: 0) == "2 enceintes masquées")
        #expect(HiddenElementsCopy.summary(speakers: 0, blocks: 1) == "1 élément masqué")
        #expect(HiddenElementsCopy.summary(speakers: 0, blocks: 3) == "3 éléments masqués")
        #expect(HiddenElementsCopy.summary(speakers: 1, blocks: 2) == "1 enceinte masquée · 2 éléments masqués")
    }

    @Test("La commande dit qu'elle emmène la paire, et qu'une enceinte cochée continue de jouer")
    func hideCommandWording() {
        #expect(HiddenElementsCopy.hideTitle(partners: []) == "Masquer cette enceinte")
        #expect(HiddenElementsCopy.hideTitle(partners: ["Salon (2)"]) == "Masquer la paire stéréo")
        let single = HiddenElementsCopy.hideHelp(name: "Geneva", partners: [], isEnabled: true)
        #expect(single.contains("Elle reste cochée et continue de jouer."))
        let pair = HiddenElementsCopy.hideHelp(name: "Salon", partners: ["Salon (2)"], isEnabled: true)
        #expect(pair.contains("Salon et Salon (2)"))
        #expect(pair.contains("Elles restent cochées et continuent de jouer."))
        let unticked = HiddenElementsCopy.hideHelp(name: "Apple TV Salon", partners: [], isEnabled: false)
        #expect(!unticked.contains("continue"))
        #expect(unticked.contains("Réglages"))
    }

    @Test("Les Réglages listent les enceintes de la liste, puis les masquées qu'elle n'a plus")
    func knownSpeakersList() {
        let known = KnownSpeaker.list(
            listed: [(id: "raop/geneva", name: "Geneva"), (id: "airplay2/tv", name: "Apple TV")],
            hidden: ["airplay2/tv", "raop/zoe", "raop/alto"],
            name: { $0 == "raop/zoe" ? "Zoé" : "alto" }
        )
        #expect(known.map(\.id) == ["raop/geneva", "airplay2/tv", "raop/alto", "raop/zoe"])
        #expect(known.map(\.isHidden) == [false, true, true, true])
        #expect(known.map(\.isListed) == [true, true, false, false])
        #expect(known.map(\.name) == ["Geneva", "Apple TV", "alto", "Zoé"])
    }

    @Test("Une enceinte absente qu'on vient de réafficher garde sa ligne dans les Réglages")
    func reshownSpeakerKeepsItsRow() {
        let known = [KnownSpeaker(id: "raop/geneva", name: "Geneva", isHidden: false, isListed: true)]
        let rows = SettingsView.rows(known: known, reshown: ["raop/zoe": "Zoé", "raop/geneva": "Geneva"])
        #expect(rows.map(\.id) == ["raop/geneva", "raop/zoe"])
        #expect(rows.last == KnownSpeaker(id: "raop/zoe", name: "Zoé", isHidden: false, isListed: false))
        #expect(SettingsView.rows(known: known, reshown: [:]) == known)
    }
}

@Suite("Masquage — état de l'app")
struct HiddenElementsStateTests {
    @Test("Masquer une enceinte la retire des vues sans rien changer à ce qui joue")
    func hidingIsVisualOnly() {
        let state = BridgeState.preview(.streaming)
        let geneva = state.outputs.first { $0.id == Devices.genevaID }
        let ids = state.outputs.map(\.id)
        let enabled = state.outputs.map(\.isEnabled)
        let gains = state.outputs.map { state.effectiveGainDB(for: $0) }
        let connections = state.outputs.map(\.connection)

        if let geneva { state.setHidden(true, for: geneva) }

        #expect(state.visibleOutputs.map(\.id) == ids.filter { $0 != Devices.genevaID })
        #expect(state.hiddenOutputCount == 1)
        #expect(geneva.map(state.isHidden) == true)
        // Rien de ce que le moteur lit n'a bougé.
        #expect(state.outputs.map(\.id) == ids)
        #expect(state.outputs.map(\.isEnabled) == enabled)
        #expect(state.outputs.map { state.effectiveGainDB(for: $0) } == gains)
        #expect(state.outputs.map(\.connection) == connections)
        #expect(state.streamingPhase == .running)
        #expect(state.isHaloAudible)

        if let geneva { state.setHidden(false, for: geneva) }
        #expect(state.visibleOutputs.map(\.id) == ids)
        #expect(state.hiddenSummary == nil)
    }

    @Test("Masquer un membre d'une paire stéréo masque les deux, et ne décoche personne")
    func hidingCarriesTheStereoPair() async throws {
        let harness = BridgeHarness()
        await harness.discover(raop: [Devices.genevaRAOP], airplay2: [PairDevices.left, PairDevices.right])
        let state = harness.state
        let left = try #require(harness.output(Devices.leftID))
        let right = try #require(harness.output(Devices.rightID))

        state.setHidden(true, for: left)
        #expect(state.hiddenElements.outputIDs == [Devices.leftID, Devices.rightID])
        #expect(state.visibleOutputs.map(\.id) == [Devices.genevaID])
        #expect(left.isEnabled)
        #expect(right.isEnabled)
        #expect(state.hiddenSummary == "2 enceintes masquées")

        // Réafficher l'autre membre ramène les deux.
        state.setHidden(false, for: right)
        #expect(state.hiddenElements.outputIDs.isEmpty)
    }

    @Test("Le masquage s'enregistre, et la coche d'une enceinte masquée reste enregistrée")
    func hidingIsSaved() async throws {
        let harness = BridgeHarness()
        await harness.discover(raop: [Devices.genevaRAOP], airplay2: [PairDevices.left, PairDevices.right])
        let state = harness.state
        let geneva = try #require(harness.output(Devices.genevaID))

        state.setHidden(true, for: geneva)
        state.setVisible(false, block: .haloWaves)
        state.flushSettings()

        let stored = harness.store.stored
        #expect(stored.hiddenElements == HiddenElements(outputIDs: [Devices.genevaID], blocks: [.haloWaves]))
        #expect(stored.outputs[Devices.genevaID]?.isEnabled == true)

        // Au lancement suivant, elle est encore cochée, toujours masquée.
        let relaunched = BridgeHarness(settings: stored).state
        #expect(relaunched.hiddenElements == stored.hiddenElements)
        #expect(relaunched.outputs.map(\.id).contains(Devices.genevaID))
        #expect(!relaunched.visibleOutputs.map(\.id).contains(Devices.genevaID))
        #expect(!relaunched.isVisible(.haloWaves))
        #expect(relaunched.isVisible(.masterVolume))
    }

    @Test("Un identifiant masqué qui ne correspond plus à aucune enceinte reste, sans gêner")
    func orphanIdentifierIsKept() async throws {
        var settings = BridgeSettings()
        settings.hiddenElements.outputIDs = ["raop/FFFFFFFFFFFF@Enceinte partie"]
        let harness = BridgeHarness(settings: settings)
        await harness.discover(raop: [Devices.genevaRAOP])
        let state = harness.state

        // Rien à signaler dans les vues : elle ne serait pas là de toute façon.
        #expect(state.visibleOutputs.map(\.id) == state.outputs.map(\.id))
        #expect(state.hiddenOutputCount == 0)
        #expect(state.hiddenSummary == nil)
        #expect(!state.hidesEverySpeaker)
        // Les Réglages la listent encore, après les enceintes présentes, sous un nom lisible.
        let known = state.knownSpeakers
        #expect(known.map(\.id) == [Devices.genevaID, "raop/FFFFFFFFFFFF@Enceinte partie"])
        #expect(known.last?.name == "Enceinte partie")
        #expect(known.last?.isListed == false)

        // Masquer autre chose ne l'efface pas, et elle survit à l'enregistrement.
        let geneva = try #require(harness.output(Devices.genevaID))
        state.setHidden(true, for: geneva)
        state.flushSettings()
        #expect(
            harness.store.stored.hiddenElements.outputIDs
                == [Devices.genevaID, "raop/FFFFFFFFFFFF@Enceinte partie"]
        )
    }

    @Test("Le membre d'une paire que la liste n'a plus suit par le tsid gardé dans les réglages")
    func unlistedPartnerFollows() async throws {
        var settings = BridgeSettings()
        var record = BridgeSettings.Output(isEnabled: false)
        record.tightSyncIdentifier = PairDevices.tsid
        settings.outputs[Devices.rightID] = record
        let harness = BridgeHarness(settings: settings)
        await harness.discover(airplay2: [PairDevices.left])
        let left = try #require(harness.output(Devices.leftID))
        #expect(harness.output(Devices.rightID) == nil)

        harness.state.setHidden(true, for: left)
        #expect(harness.state.hiddenElements.outputIDs == [Devices.leftID, Devices.rightID])
    }

    @Test("La ligne d'une vue ne compte que les blocs que cette vue montrerait")
    func summaryFollowsTheLayout() {
        let state = BridgeState.preview(.idle)
        state.setVisible(false, block: .haloWaves)
        state.windowLayout = .halo
        #expect(state.hiddenSummary == "1 élément masqué")
        state.windowLayout = .console
        #expect(state.hiddenSummary == nil)
        state.setVisible(false, block: .masterVolume)
        #expect(state.hiddenSummary == "1 élément masqué")
        state.windowLayout = .halo
        #expect(state.hiddenSummary == "2 éléments masqués")
        state.setVisible(true, block: .haloWaves)
        state.setVisible(true, block: .masterVolume)
        #expect(state.hiddenElements == HiddenElements())
    }

    @Test("Toutes masquées, la vue le dit au lieu de prétendre qu'il n'y a aucune enceinte")
    func everySpeakerHidden() {
        let state = BridgeState.preview(.idle)
        #expect(!state.hidesEverySpeaker)
        for output in state.outputs { state.setHidden(true, for: output) }
        #expect(state.hidesEverySpeaker)
        #expect(state.visibleOutputs.isEmpty)
        #expect(state.hiddenSummary == "4 enceintes masquées")
        #expect(!BridgeState.preview(.empty).hidesEverySpeaker)
    }

    @Test("Les avertissements d'une enceinte masquée restent dans la console")
    func hiddenSpeakerStillWarns() throws {
        let state = BridgeState.preview(.trouble)
        let before = ConsoleWarning.list(for: state, speakers: PanelSpeakerOrder.sorted(state.outputs))
        let failing = try #require(state.outputs.first { $0.id == Devices.rightID })
        #expect(before.contains { $0.id == "enceinte-\(Devices.rightID)" })
        state.setHidden(true, for: failing)
        // La vue passe toutes les enceintes, masquées comprises (`ConsoleView`).
        #expect(ConsoleWarning.list(for: state, speakers: PanelSpeakerOrder.sorted(state.outputs)) == before)
    }
}

@Suite("Masquage — fenêtre des réglages et icône du Dock")
struct SettingsWindowDockTests {
    @Test("L'icône du Dock reste tant qu'une des deux fenêtres est ouverte")
    func iconFollowsBothWindows() async {
        let presenter = StubPresenter()
        let dock = DockIconController(presenter: presenter)

        dock.windowDidOpen(.settings)
        #expect(presenter.dockIconVisible == [true])
        dock.windowDidOpen(.main)
        dock.windowWillClose(.main)
        // Les réglages sont encore ouverts : l'icône ne s'efface pas.
        #expect(await staysFalse { presenter.dockIconVisible.last == false })
        #expect(dock.isWindowOpen)

        dock.windowWillClose(.settings)
        #expect(await eventually { presenter.dockIconVisible.last == false })
        #expect(!dock.isWindowOpen)
    }

    @Test("Ouvrir les réglages depuis la barre de menus fait passer l'app devant avant d'ouvrir")
    func settingsOpenInFront() {
        let presenter = StubPresenter()
        let lifecycle = AppLifecycle(
            state: BridgeHarness().state,
            loginItem: LoginItemController(service: PreviewLoginItemService()),
            dock: DockIconController(presenter: presenter),
            coreAudio: StubCoreAudioRestarter()
        )
        var activationsAtOpen: Int?
        lifecycle.showSettingsWindow { activationsAtOpen = presenter.activateCount }
        #expect(activationsAtOpen == 1)
        #expect(presenter.dockIconVisible == [true])
    }
}
