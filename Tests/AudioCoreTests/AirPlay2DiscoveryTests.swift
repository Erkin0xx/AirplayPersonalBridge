import Foundation
import Testing
import dnssd

@testable import AudioCore

/// Parcours et résolution sont injectés : `AirPlay2Discovery()` interrogerait les appareils du
/// réseau, ce qu'aucun test ne doit faire.
@Suite("Découverte AirPlay 2")
struct AirPlay2DiscoveryTests {

    private typealias Service = AirPlay2Discovery.BrowsedService

    private func service(_ name: String) -> Service {
        Service(name: name, type: "_airplay._tcp", domain: "local.")
    }

    private static func device(_ name: String, txt: [String: String] = ["features": "0x1,0x10000"])
        -> AirPlay2Device
    {
        AirPlay2Device(serviceName: name, host: "192.0.2.1", port: 7000, txt: txt)
    }

    /// Mémorise ce que la découverte a fait, depuis ses fermetures `@Sendable`.
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var passesDone = 0
        private var resolvedNames: [String] = []

        func nextPass() -> Int {
            lock.withLock {
                defer { passesDone += 1 }
                return passesDone
            }
        }
        func noteResolved(_ name: String) { lock.withLock { resolvedNames.append(name) } }
        var passes: Int { lock.withLock { passesDone } }
        var resolved: [String] { lock.withLock { resolvedNames } }
    }

    private func discovery(
        passes: [[String]],
        recorder: Recorder = Recorder(),
        resolve: (@Sendable (Service) -> AirPlay2Device?)? = nil
    ) -> AirPlay2Discovery {
        AirPlay2Discovery(
            browser: { _ in
                let pass = recorder.nextPass()
                return passes[min(pass, passes.count - 1)].map {
                    Service(name: $0, type: "_airplay._tcp", domain: "local.")
                }
            },
            resolver: { service in
                recorder.noteResolved(service.name)
                return resolve?(service) ?? Self.device(service.name)
            }
        )
    }

    @Test("La correspondance exacte prime, sans tenir compte de la casse")
    func exacteDAbord() {
        let names = ["Salon (2)", "Salon"]
        #expect(AirPlay2Discovery.bestMatch(for: "salon", among: names, name: { $0 }) == "Salon")
        #expect(AirPlay2Discovery.bestMatch(for: "salon (2)", among: names, name: { $0 }) == "Salon (2)")
        #expect(AirPlay2Discovery.bestMatch(for: "sal", among: names, name: { $0 }) == "Salon (2)")
        #expect(AirPlay2Discovery.bestMatch(for: "cuisine", among: names, name: { $0 }) == nil)
    }

    /// Le défaut des deux sorties sur un seul HomePod, dans sa forme la plus sournoise : un
    /// parcours incomplet ne montre que « Salon (2) ». Le retenir aussitôt envoyait les deux
    /// sorties vers le même appareil.
    @Test("Une correspondance partielle attend un second passage")
    func partielleAttend() async throws {
        let recorder = Recorder()
        let finder = discovery(passes: [["Salon (2)"], ["Salon (2)", "Salon"]], recorder: recorder)

        let device = try await finder.find(named: "Salon", timeout: .milliseconds(1))

        #expect(device.serviceName == "Salon")
        #expect(recorder.passes == 2)
    }

    @Test("Une correspondance partielle reste valable si rien de mieux n'apparaît")
    func partielleRetenue() async throws {
        let recorder = Recorder()
        let finder = discovery(passes: [["ApTV-HomePod-Mock"]], recorder: recorder)

        let device = try await finder.find(named: "ApTV", timeout: .milliseconds(1))

        #expect(device.serviceName == "ApTV-HomePod-Mock")
        #expect(recorder.passes == 2)
    }

    @Test("Une correspondance exacte n'attend personne")
    func exacteImmediate() async throws {
        let recorder = Recorder()
        let finder = discovery(passes: [["Salon"]], recorder: recorder)

        _ = try await finder.find(named: "Salon", timeout: .milliseconds(1))

        #expect(recorder.passes == 1)
    }

    /// Chercher un récepteur n'a pas à interroger tous les autres, ni à attendre leurs délais.
    @Test("Seul le récepteur retenu est résolu")
    func seulLeRetenuEstResolu() async throws {
        let recorder = Recorder()
        let finder = discovery(
            passes: [["Salon", "Salon (2)", "Apple TV Salon", "Cuisine"]], recorder: recorder)

        _ = try await finder.find(named: "Salon", timeout: .milliseconds(1))

        #expect(recorder.resolved == ["Salon"])
    }

    @Test("Un TXT vide laisse une chance à un autre passage, sans être perdu")
    func txtVideRetente() async throws {
        let recorder = Recorder()
        let bonTXT = LockedFlag()
        let finder = discovery(passes: [["Salon"]], recorder: recorder) { service in
            defer { bonTXT.set() }
            return Self.device(service.name, txt: bonTXT.value ? ["features": "0x0,0x10000"] : [:])
        }

        let device = try await finder.find(named: "Salon", timeout: .milliseconds(1))

        #expect(device.supportsTransientPairing)
        #expect(recorder.passes == 2)
    }

    @Test("À défaut de TXT, un appareil résolu vaut mieux que rien")
    func txtVideDefinitif() async throws {
        let finder = discovery(passes: [["Salon"]]) { service in
            Self.device(service.name, txt: [:])
        }

        let device = try await finder.find(named: "Salon", timeout: .milliseconds(1), attempts: 2)

        #expect(device.txt.isEmpty)
    }

    @Test("L'erreur cite tout ce qui a été vu")
    func introuvable() async {
        let finder = discovery(passes: [["Cuisine"], ["Salon"], ["Cuisine", "Bureau"]])

        do {
            _ = try await finder.find(named: "Grenier", timeout: .milliseconds(1))
            Issue.record("aurait dû échouer")
        } catch let AirPlay2DiscoveryError.notFound(name, seen) {
            #expect(name == "Grenier")
            #expect(seen == ["Bureau", "Cuisine", "Salon"])
        } catch {
            Issue.record("mauvaise erreur : \(error)")
        }
    }

    /// Le moteur attend ses sorties à l'arrêt : une recherche en cours ne doit pas le retenir.
    @Test("Annuler une recherche rend la main sans attendre la fin du parcours")
    func annulationRecherche() async throws {
        let finder = AirPlay2Discovery(
            browser: { _ in
                try? await Task.sleep(for: .seconds(30))
                return []
            },
            resolver: { _ in nil }
        )

        let task = Task { try await finder.find(named: "Salon") }
        try await Task.sleep(for: .milliseconds(50))

        let start = ContinuousClock.now
        task.cancel()
        let result = await task.result
        #expect(ContinuousClock.now - start < .seconds(1))
        #expect(throws: CancellationError.self) { try result.get() }
    }

    @Test("browse résout tout en parallèle et garde l'ordre")
    func browseParallele() async {
        let finder = AirPlay2Discovery(
            browser: { [self] _ in ["A", "B", "C"].map(service) },
            resolver: { service in
                // Le premier est le plus lent : l'ordre doit tenir quand même.
                if service.name == "A" { try? await Task.sleep(for: .milliseconds(100)) }
                return service.name == "B" ? nil : Self.device(service.name)
            }
        )

        let start = ContinuousClock.now
        let devices = await finder.browse(timeout: .milliseconds(1))

        #expect(devices.map(\.serviceName) == ["A", "C"])
        #expect(ContinuousClock.now - start < .seconds(5))
    }
}

@Suite("Découverte AirPlay 2 — lecture du TXT")
struct AirPlay2TXTTests {

    private func device(_ txt: [String: String]) -> AirPlay2Device {
        AirPlay2Device(serviceName: "T", host: "192.0.2.1", port: 7000, txt: txt)
    }

    @Test("Un mot de features à une seule valeur est accepté")
    func motUnique() {
        // Geneva : 0x444c0a00, sans mot de poids fort, donc sans aucun bit de pairing.
        let single = device(["features": "0x444c0a00"])
        #expect(single.features == 0x444C_0A00)
        #expect(!single.supportsTransientPairing)
        #expect(!single.requiresSystemPairing)
    }

    @Test("Les bits de pairing se lisent dans le mot de poids fort")
    func bitsDePairing() {
        let homePod = device(["features": "0x4A7FDFD5,0x3C155FDE"])
        #expect(homePod.features == 0x3C15_5FDE_4A7F_DFD5)
        #expect(homePod.supportsTransientPairing)
    }

    @Test("La clé ft sert de repli, comme chez pyatv")
    func repliFt() {
        #expect(device(["ft": "0x0,0x10000"]).supportsTransientPairing)
        #expect(device(["features": "0x0,0x0", "ft": "0x0,0x10000"]).supportsTransientPairing == false)
    }

    @Test("Des features illisibles valent zéro sans planter", arguments: [
        "", ",", "zzz", "0x", "0x1,zzz", "-1",
    ])
    func featuresIllisibles(text: String) {
        #expect(device(["features": text]).supportsTransientPairing == false)
    }

    @Test("Une clé publique malformée est écartée", arguments: [
        "abc", String(repeating: "z", count: 64), String(repeating: "a", count: 63),
        "+" + String(repeating: "a", count: 63),
    ])
    func clePubliqueMalformee(text: String) {
        #expect(device(["pk": text]).publicKey == nil)
    }

    @Test("Le décodage du format TXT résiste aux enregistrements malformés")
    func decodageTXT() {
        func record(_ entries: String...) -> Data {
            var data = Data()
            for entry in entries {
                data.append(UInt8(entry.utf8.count))
                data.append(contentsOf: entry.utf8)
            }
            return data
        }

        #expect(BonjourTXTQuery.parse(record: record("A=1", "b=2")) == ["a": "1", "b": "2"])
        // La casse de la valeur est conservée, celle de la clé non.
        #expect(BonjourTXTQuery.parse(record: record("PK=AbC")) == ["pk": "AbC"])
        // Clé sans valeur, et valeur contenant un signe égal.
        #expect(BonjourTXTQuery.parse(record: record("flag", "x=a=b")) == ["flag": "", "x": "a=b"])
        // Longueur qui dépasse : ce qui précède reste lisible.
        var truncated = record("a=1")
        truncated.append(contentsOf: [0xFF, 0x41])
        #expect(BonjourTXTQuery.parse(record: truncated) == ["a": "1"])
        // Chaîne vide : ignorée sans interrompre la lecture, RFC 6763 §6.1.
        var withEmpty = Data([0])
        withEmpty.append(record("a=1"))
        #expect(BonjourTXTQuery.parse(record: withEmpty) == ["a": "1"])
        // Enregistrement entièrement vide.
        #expect(BonjourTXTQuery.parse(record: Data()).isEmpty)
    }

    /// Une concaténation donnait un nom introuvable dès qu'un point figurait dans le nom
    /// d'instance, et le TXT revenait vide sans erreur.
    @Test("Le nom pleinement qualifié échappe ce qui doit l'être")
    func nomQualifie() throws {
        #expect(
            BonjourTXTQuery.fullName(instance: "Mock", type: "_airplay._tcp", domain: "local.")
                == "Mock._airplay._tcp.local.")
        // `NWEndpoint` rend le type sans point final et le domaine avec : le piège du jalon 3.
        #expect(
            BonjourTXTQuery.fullName(instance: "Mock", type: "_airplay._tcp.", domain: "local")
                == "Mock._airplay._tcp.local.")
        #expect(
            BonjourTXTQuery.fullName(instance: "St. Louis", type: "_airplay._tcp", domain: "local.")
                == "St\\.\\032Louis._airplay._tcp.local.")
    }

    /// De bout en bout contre `mDNSResponder`, sans rien émettre sur le réseau : le service est
    /// enregistré sur l'interface locale seule, sous un type que rien d'autre n'utilise.
    @Test("Un TXT réel se relit, y compris pour un nom contenant point et espace")
    func lectureReelle() throws {
        var txt = Data()
        for entry in ["features=0x1,0x10000", "pi=test"] {
            txt.append(UInt8(entry.utf8.count))
            txt.append(contentsOf: entry.utf8)
        }

        var registration: DNSServiceRef?
        let name = "St. Louis (2) \(UInt16.random(in: 0...UInt16.max))"
        let status = txt.withUnsafeBytes { bytes in
            DNSServiceRegister(
                &registration, 0, UInt32(kDNSServiceInterfaceIndexLocalOnly),
                name, "_apbtest._tcp", nil, nil, UInt16(49_999).bigEndian,
                UInt16(txt.count), bytes.baseAddress, nil, nil
            )
        }
        try #require(status == kDNSServiceErr_NoError)
        let registered = try #require(registration)
        defer { DNSServiceRefDeallocate(registered) }

        let fullName = try #require(
            BonjourTXTQuery.fullName(instance: name, type: "_apbtest._tcp", domain: "local."))
        var read: [String: String] = [:]
        for _ in 0..<5 where read.isEmpty {
            read = BonjourTXTQuery.lookup(fullName: fullName, timeout: 1)
        }
        #expect(read["features"] == "0x1,0x10000")
        #expect(read["pi"] == "test")
    }

    /// Une échéance sous la seconde ne doit pas être arrondie à zéro.
    @Test("Une requête sans réponse respecte son échéance")
    func echeanceRespectee() {
        let start = Date()
        let txt = BonjourTXTQuery.lookup(
            fullName: "absent-\(UInt32.random(in: 0...UInt32.max))._apbtest._tcp.local.",
            timeout: 0.4
        )
        let elapsed = Date().timeIntervalSince(start)
        #expect(txt.isEmpty)
        #expect(elapsed < 2)
    }
}
