import AudioCore
import Foundation
import Testing

@testable import BridgeApp

@Suite("Catalogue des sorties — dédoublonnage")
struct OutputCatalogMergeTests {
    @Test("Une ligne par appareil, quel que soit le nombre d'annonces")
    func oneRowPerDevice() {
        let merged = OutputCatalog.merge(raop: Devices.allRAOP, airplay2: Devices.allAirPlay2)
        #expect(merged.map(\.id) == [
            Devices.appleTVRaopID, Devices.genevaID, Devices.leftID, Devices.rightID,
        ])
    }

    /// Le cas qu'il ne fallait pas casser : la Geneva s'annonce sur `_airplay._tcp`, sans bit de
    /// pairing. Elle n'exige rien, et reste jouable en RAOP.
    @Test("La Geneva reste une sortie AirPlay 1 jouable")
    func genevaStaysPlayable() throws {
        let merged = OutputCatalog.merge(
            raop: [Devices.genevaRAOP], airplay2: [Devices.genevaAirPlay2]
        )
        let geneva = try #require(merged.first)
        #expect(merged.count == 1)
        #expect(geneva.id == Devices.genevaID)
        #expect(geneva.proto == .raop)
        #expect(geneva.displayName == "Geneva")
        #expect(geneva.unavailability == nil)
    }

    @Test("Un HomePod passe en AirPlay 2, même s'il propose aussi l'appairage système")
    func homePodIsPlayableInAirPlay2() throws {
        let merged = OutputCatalog.merge(raop: [Devices.leftRAOP], airplay2: [Devices.left])
        let homePod = try #require(merged.first)
        #expect(merged.count == 1)
        #expect(homePod.id == Devices.leftID)
        #expect(homePod.proto == .airplay2)
        #expect(homePod.unavailability == nil)
    }

    /// Le nom ne peut pas servir de clé : les deux HomePod s'appellent « Salon » en RAOP.
    @Test("Deux HomePod au même nom RAOP restent deux lignes, sans doublon")
    func twinHomePodsKeepTheirIdentity() {
        let merged = OutputCatalog.merge(
            raop: [Devices.leftRAOP, Devices.rightRAOP], airplay2: [Devices.left, Devices.right]
        )
        #expect(merged.map(\.id) == [Devices.leftID, Devices.rightID])
    }

    @Test("Un Apple TV sans le bit 48 est signalé sur sa ligne RAOP")
    func appleTVWithoutTransient() throws {
        let merged = OutputCatalog.merge(
            raop: [Devices.appleTVRAOP], airplay2: [Devices.appleTVPairingOnly]
        )
        let appleTV = try #require(merged.first)
        #expect(merged.count == 1)
        #expect(appleTV.id == Devices.appleTVRaopID)
        #expect(appleTV.unavailability == .pairingRequired)
    }

    /// Mesuré sur le matériel (commit 4d1fb75) : un Apple TV refuse le transitoire en `470`. Le
    /// bit 48 ne suffit donc pas à le déclarer jouable.
    @Test("Un Apple TV annonçant le bit 48 reste signalé")
    func appleTVAnnouncingTransient() throws {
        let merged = OutputCatalog.merge(
            raop: [Devices.appleTVRAOP], airplay2: [Devices.appleTVAnnouncingTransient]
        )
        let appleTV = try #require(merged.first)
        #expect(merged.count == 1)
        #expect(appleTV.id == Devices.appleTVAirPlay2ID)
        #expect(appleTV.unavailability == .pairingRequired)
    }

    @Test("Un appareil qui n'annonce qu'AirPlay 2 et exige un appairage reste visible")
    func pairingOnlyDeviceWithoutRAOP() throws {
        let merged = OutputCatalog.merge(raop: [], airplay2: [Devices.appleTVPairingOnly])
        let appleTV = try #require(merged.first)
        #expect(appleTV.id == Devices.appleTVAirPlay2ID)
        #expect(appleTV.unavailability == .pairingRequired)
    }

    @Test("Un TXT illisible ne fait disparaître ni ne condamne un appareil seul à s'annoncer")
    func unreadableTXTStaysProposed() throws {
        let device = AirPlay2Device(serviceName: "Inconnu", host: "192.168.1.9", port: 7000, txt: [:])
        let merged = OutputCatalog.merge(raop: [], airplay2: [device])
        let output = try #require(merged.first)
        #expect(output.proto == .airplay2)
        #expect(output.unavailability == nil)
    }

    @Test("Ce qu'annonce le TXT RAOP suffit à signaler ce qui ne jouera pas")
    func raopCapabilities() {
        func reason(_ txt: [String: String]) -> OutputUnavailability? {
            let device = RAOPDevice(serviceName: "A@B", host: "10.0.0.1", port: 7000, txt: txt)
            return OutputCatalog.merge(raop: [device], airplay2: []).first?.unavailability
        }
        #expect(reason(["pw": "true"]) == .passwordRequired)
        #expect(reason(["et": "3,4"]) == .unsupportedEncryption)
        #expect(reason(["et": "0", "cn": "2,3"]) == .unsupportedFormat)
        // Sans TXT, on tente : c'est ce que fait pyatv, et un récepteur qui refuse le dira.
        #expect(reason([:]) == nil)
        #expect(reason(["et": "0,4", "cn": "0,1"]) == nil)
    }

    @Test("Le second mot des bits de fonctionnalité est celui de poids fort")
    func featureBitsMatchTheCriterion() {
        #expect(!OutputCatalog.requiresPairing(Devices.genevaAirPlay2))
        #expect(!OutputCatalog.requiresPairing(Devices.left))
        #expect(OutputCatalog.requiresPairing(Devices.appleTVPairingOnly))
        #expect(OutputCatalog.requiresPairing(Devices.appleTVAnnouncingTransient))
        let mock = AirPlay2Device(
            serviceName: "ApTV-HomePod-Mock", host: "127.0.0.1", port: 7000,
            txt: ["features": Devices.transientFeatures, "model": "Airplay2-Receiver"]
        )
        #expect(!OutputCatalog.requiresPairing(mock))
    }
}

@Suite("Catalogue des sorties — réconciliation")
struct OutputCatalogReconcileTests {
    private func discovered(
        _ id: String, name: String? = nil, host: String = "10.0.0.1",
        proto: OutputProtocol = .airplay2, confirmed: Bool = false
    ) -> DiscoveredOutput {
        DiscoveredOutput(
            id: id, displayName: name ?? id, host: host, port: 7000, proto: proto,
            confirmsTransientPairing: confirmed
        )
    }

    private func entry(
        _ id: String, name: String? = nil, host: String = "10.0.0.1",
        proto: OutputProtocol = .airplay2, presence: OutputPresence = .online, missed: Int = 0,
        retained: Bool = false, inSession: Bool = false, confirmed: Bool = false
    ) -> OutputCatalog.Entry {
        OutputCatalog.Entry(
            id: id, displayName: name ?? id, host: host, proto: proto, presence: presence,
            missedRounds: missed, isRetained: retained, isInSession: inSession,
            confirmsTransientPairing: confirmed
        )
    }

    @Test("Une sortie revue n'est pas recréée")
    func seenIsNotAdded() {
        let result = OutputCatalog.reconcile(
            current: [entry("a")], discovered: [discovered("a"), discovered("b", host: "10.0.0.2")]
        )
        #expect(result.added.map(\.id) == ["b"])
        #expect(result.seen.map(\.id) == ["a"])
        #expect(result.order == ["a", "b"])
        #expect(result.removed.isEmpty)
    }

    @Test("L'ordre reste alphabétique, quel que soit l'ordre de la découverte")
    func orderIsStable() {
        let list = [
            discovered("c", host: "1"), discovered("a", host: "2"), discovered("b", host: "3"),
        ]
        let first = OutputCatalog.reconcile(current: [], discovered: list)
        let second = OutputCatalog.reconcile(
            current: [entry("a", host: "2"), entry("b", host: "3"), entry("c", host: "1")],
            discovered: list.reversed()
        )
        #expect(first.order == ["a", "b", "c"])
        #expect(second.order == ["a", "b", "c"])
    }

    /// `NWBrowser` peut rendre une liste vide au premier passage et la bonne au suivant.
    @Test("Une seule recherche manquée ne change rien")
    func oneMissedRoundIsTolerated() {
        let result = OutputCatalog.reconcile(current: [entry("a")], discovered: [])
        #expect(result.order == ["a"])
        #expect(result.presence["a"] == .online)
        #expect(result.missedRounds["a"] == 1)
        #expect(result.removed.isEmpty)
    }

    @Test("Une sortie ni cochée ni en diffusion disparaît au second passage")
    func uncheckedDisappears() {
        let result = OutputCatalog.reconcile(current: [entry("a", missed: 1)], discovered: [])
        #expect(result.removed == ["a"])
        #expect(result.order.isEmpty)
    }

    @Test("Une sortie cochée reste affichée, hors ligne")
    func retainedGoesOffline() {
        let result = OutputCatalog.reconcile(
            current: [entry("a", missed: 1, retained: true)], discovered: []
        )
        #expect(result.order == ["a"])
        #expect(result.presence["a"] == .offline)
        #expect(result.removed.isEmpty)
    }

    @Test("Une sortie qui réapparaît repasse en ligne, sans recréation")
    func offlineComesBack() {
        let result = OutputCatalog.reconcile(
            current: [entry("a", presence: .offline, missed: 4, retained: true)],
            discovered: [discovered("a")]
        )
        #expect(result.presence["a"] == .online)
        #expect(result.missedRounds["a"] == 0)
        #expect(result.added.isEmpty)
    }

    @Test("Une sortie restaurée, pas encore vue, reste « à vérifier » au premier passage")
    func restoredStaysUnknownAtFirst() {
        let restored = entry("a", host: "", presence: .unknown, retained: true)
        let first = OutputCatalog.reconcile(current: [restored], discovered: [])
        #expect(first.presence["a"] == .unknown)

        let second = OutputCatalog.reconcile(
            current: [entry("a", host: "", presence: .unknown, missed: 1, retained: true)],
            discovered: []
        )
        #expect(second.presence["a"] == .offline)
    }

    /// Le TXT d'un HomePod se perd le temps d'une recherche : sans bit 48, la fusion le rend en
    /// RAOP. Il ne doit ni passer hors ligne, ni apparaître une seconde fois.
    @Test("Un HomePod rendu en RAOP à cause d'un TXT perdu reste une seule ligne, en ligne")
    func lostTXTDoesNotDuplicate() {
        let result = OutputCatalog.reconcile(
            current: [
                entry("airplay2/Salon", name: "Salon", host: "10.0.0.5", retained: true, confirmed: true)
            ],
            discovered: [
                discovered("raop/1@Salon", name: "Salon", host: "10.0.0.5", proto: .raop)
            ]
        )
        #expect(result.order == ["airplay2/Salon"])
        #expect(result.added.isEmpty)
        #expect(result.presence["airplay2/Salon"] == .online)
        #expect(result.missedRounds["airplay2/Salon"] == 0)
    }

    @Test("Une ligne RAOP s'efface quand la même adresse confirme le bit 48")
    func airPlay2SupersedesRAOP() {
        let result = OutputCatalog.reconcile(
            current: [
                entry("raop/1@Salon", name: "Salon", host: "10.0.0.5", proto: .raop, retained: true)
            ],
            discovered: [
                discovered("airplay2/Salon", name: "Salon", host: "10.0.0.5", confirmed: true)
            ]
        )
        #expect(result.removed == ["raop/1@Salon"])
        #expect(result.superseded == ["raop/1@Salon"])
        #expect(result.order == ["airplay2/Salon"])
    }

    /// Une seule recherche où la Geneva manquait en RAOP et perdait son TXT supprimait sa ligne
    /// cochée, ses réglages avec, et créait une ligne AirPlay 2 injouable.
    @Test("Une annonce sans le bit 48 ne remplace pas une ligne RAOP, et n'en crée pas d'autre")
    func unconfirmedDoesNotSupersede() {
        let result = OutputCatalog.reconcile(
            current: [
                entry("raop/1@Geneva", name: "Geneva", host: "10.0.0.5", proto: .raop, retained: true)
            ],
            discovered: [discovered("airplay2/Geneva", name: "Geneva", host: "10.0.0.5")]
        )
        #expect(result.removed.isEmpty)
        #expect(result.superseded.isEmpty)
        #expect(result.added.isEmpty)
        #expect(result.order == ["raop/1@Geneva"])
        // L'adresse répond : l'appareil est là, même absent de cette recherche en RAOP.
        #expect(result.presence["raop/1@Geneva"] == .online)
        #expect(result.missedRounds["raop/1@Geneva"] == 0)
    }

    /// L'autre moitié du même défaut : une ligne AirPlay 2 jamais confirmée absorbait ensuite la vraie
    /// annonce RAOP, à chaque recherche, et la Geneva restait injouable.
    @Test("Une ligne AirPlay 2 jamais confirmée n'absorbe pas la vraie annonce RAOP")
    func unconfirmedDoesNotAbsorb() {
        let result = OutputCatalog.reconcile(
            current: [entry("airplay2/Geneva", name: "Geneva", host: "10.0.0.5")],
            discovered: [
                discovered("raop/1@Geneva", name: "Geneva", host: "10.0.0.5", proto: .raop)
            ]
        )
        #expect(result.added.map(\.id) == ["raop/1@Geneva"])
        #expect(result.missedRounds["airplay2/Geneva"] == 1)
    }

    @Test("Un appareil annoncé sans le bit 48, sans ligne RAOP, reste proposé")
    func unconfirmedAloneIsAdded() {
        let result = OutputCatalog.reconcile(
            current: [], discovered: [discovered("airplay2/Inconnu", host: "10.0.0.9")]
        )
        #expect(result.added.map(\.id) == ["airplay2/Inconnu"])
    }

    @Test("Une ligne RAOP que le moteur fait vivre n'est pas retirée sous ses pieds")
    func sessionIsNotSuperseded() {
        let result = OutputCatalog.reconcile(
            current: [
                entry(
                    "raop/1@Salon", name: "Salon", host: "10.0.0.5", proto: .raop, retained: true,
                    inSession: true
                )
            ],
            discovered: [
                discovered("airplay2/Salon", name: "Salon", host: "10.0.0.5", confirmed: true)
            ]
        )
        #expect(result.removed.isEmpty)
        #expect(result.order.contains("raop/1@Salon"))
    }
}
