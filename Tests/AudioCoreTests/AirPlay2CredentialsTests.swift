import Foundation
import Testing

@testable import AudioCore

@Suite("Credentials d'appairage système")
struct HapCredentialsTests {
    private static let ltpk = String(repeating: "ab", count: 32)
    private static let ltsk = String(repeating: "cd", count: 32)
    private static let valid = "\(ltpk):\(ltsk):\("device".hexOf):\("client".hexOf)"

    private func tempFile(_ contents: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("credentials-\(UUID().uuidString).txt")
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @Test("Le format de pyatv se relit, et se réécrit à l'identique")
    func allerRetour() throws {
        let credentials = try HapCredentials(serialized: Self.valid)
        #expect(credentials.receiverPublicKey.count == 32)
        #expect(credentials.clientSecretSeed.count == 32)
        #expect(credentials.receiverIdentifier == Data("device".utf8))
        #expect(credentials.clientIdentifier == Data("client".utf8))
        #expect(credentials.serialized == Self.valid)
    }

    @Test("Un format invalide est refusé", arguments: [
        "",
        "aa:bb",
        "aa:bb:cc",
        "aa:bb:cc:dd:ee",
        // Clés de la mauvaise taille.
        "aa:\(ltsk):aa:bb",
        "\(ltpk):aa:aa:bb",
        // Hexadécimal invalide, dont le signe qu'accepte `UInt8(_:radix:)`.
        "\(ltpk):\(ltsk):zz:bb",
        "\(ltpk):\(ltsk):+a:bb",
        "\(ltpk):\(ltsk):abc:bb",
        // Champ vide.
        "\(ltpk):\(ltsk)::bb",
    ])
    func formatInvalide(text: String) {
        #expect(throws: HapCredentials.Failure.self) {
            _ = try HapCredentials(serialized: text)
        }
    }

    /// `String(describing:)` finit dans les journaux, où les erreurs sont en `privacy: .public`.
    @Test("La description des credentials ne révèle aucune clé")
    func descriptionSansSecret() throws {
        let credentials = try HapCredentials(serialized: Self.valid)
        #expect(!String(describing: credentials).contains(Self.ltsk))
        #expect(!String(reflecting: credentials).contains(Self.ltsk))
    }

    /// Le message d'erreur finit dans le journal et à l'écran.
    @Test("Une erreur de format ne cite jamais le contenu")
    func erreurSansSecret() {
        do {
            _ = try HapCredentials(serialized: "\(Self.ltpk):\(Self.ltsk):zz:bb")
            Issue.record("aurait dû échouer")
        } catch {
            #expect(!String(describing: error).contains(Self.ltsk))
        }
    }

    @Test("Un fichier absent donne un message lisible, avec son chemin")
    func fichierAbsent() {
        let url = URL(fileURLWithPath: "/tmp/absent-\(UUID().uuidString).txt")
        do {
            _ = try HapCredentials.load(contentsOf: url)
            Issue.record("aurait dû échouer")
        } catch let HapCredentials.Failure.unreadable(path) {
            #expect(path == url.path)
        } catch {
            Issue.record("mauvaise erreur : \(error)")
        }
    }

    @Test("Commentaires et lignes vides sont ignorés")
    func fichierCommente() throws {
        let url = try tempFile("# Apple TV Salon\n\n  \(Self.valid)  \n# fin\n")
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(try HapCredentials.load(contentsOf: url).serialized == Self.valid)
    }

    /// En Swift `\r\n` est **un seul** caractère : un découpage sur `"\n"` ne le voyait pas, et tout
    /// le fichier passait pour une seule ligne.
    @Test("Un fichier aux fins de ligne Windows se lit aussi")
    func finsDeLigneWindows() throws {
        let url = try tempFile("# Apple TV Salon\r\n\(Self.valid)\r\n")
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(try HapCredentials.load(contentsOf: url).serialized == Self.valid)
    }

    @Test("Un fichier sans ligne exploitable est refusé")
    func fichierVide() throws {
        let url = try tempFile("# rien\n\n")
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(throws: HapCredentials.Failure.self) {
            _ = try HapCredentials.load(contentsOf: url)
        }
    }
}

extension String {
    fileprivate var hexOf: String { Data(utf8).hexEncoded }
}

@Suite("Wrappers crypto — tailles vérifiées avant l'appel C")
struct CryptoWrapperBoundsTests {

    private func challenged() throws -> SRPClient {
        let server = try SRPTestServer(username: SRPClient.pairSetupUsername, password: "3939")
        let client = try SRPClient(password: "3939")
        let publicA = try client.startAuthentication()
        let (salt, publicB) = try server.challenge(forClientPublicKey: publicA)
        _ = try client.processChallenge(salt: salt, serverPublicKey: publicB)
        return client
    }

    /// `srp_user_verify_session` lit 64 octets sans connaître la taille du tampon. Ces valeurs
    /// viennent du réseau : une preuve vide faisait planter le processus sur un pointeur nul.
    @Test("Une preuve de la mauvaise taille est refusée sans toucher à la mémoire", arguments: [
        0, 1, 32, 63, 65, 128,
    ])
    func preuveMauvaiseTaille(length: Int) throws {
        let client = try challenged()
        #expect(throws: SRPClient.Failure.serverProofRejected) {
            try client.verifyServerProof(Data(repeating: 0xAA, count: length))
        }
    }

    /// La preuve ci-dessus n'établit pas grand-chose à elle seule : une lecture hors limites ne
    /// plante pas forcément, et `memcmp` s'arrête au premier écart. Ici la preuve est tronquée mais
    /// **juste sur toute sa longueur**, et posée contre une page protégée : lire un octet de plus
    /// tue le processus.
    @Test("Une preuve tronquée n'est jamais lue au-delà de sa longueur")
    func preuveTronqueeContrePageProtegee() throws {
        let server = try SRPTestServer(username: SRPClient.pairSetupUsername, password: "3939")
        let client = try SRPClient(password: "3939")
        let publicA = try client.startAuthentication()
        let (salt, publicB) = try server.challenge(forClientPublicKey: publicA)
        let clientProof = try client.processChallenge(salt: salt, serverPublicKey: publicB)
        let serverProof = try server.verify(clientProof: clientProof)

        let pageSize = Int(getpagesize())
        let region = try #require(
            mmap(nil, pageSize * 2, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0))
        try #require(region != MAP_FAILED)
        defer { munmap(region, pageSize * 2) }
        try #require(mprotect(region + pageSize, pageSize, PROT_NONE) == 0)

        // 32 octets : au-delà de ce qu'un `Data` recopie dans sa représentation en ligne.
        let length = 32
        let start = region + pageSize - length
        serverProof.copyBytes(to: start.assumingMemoryBound(to: UInt8.self), count: length)
        let truncated = Data(bytesNoCopy: start, count: length, deallocator: .none)

        #expect(throws: SRPClient.Failure.serverProofRejected) {
            try client.verifyServerProof(truncated)
        }
        // La preuve entière, elle, passe : le test ne réussit pas pour une autre raison.
        try client.verifyServerProof(serverProof)
    }

    @Test("Une preuve de la bonne taille mais fausse est refusée")
    func preuveFausse() throws {
        let client = try challenged()
        #expect(throws: SRPClient.Failure.serverProofRejected) {
            try client.verifyServerProof(Data(repeating: 0xAA, count: 64))
        }
        #expect(throws: SRPClient.Failure.sessionNotEstablished) {
            _ = try client.sessionKey()
        }
    }

    @Test("Un sel ou une clé publique vides sont refusés")
    func defiVide() throws {
        let client = try SRPClient(password: "3939")
        _ = try client.startAuthentication()
        #expect(throws: SRPClient.Failure.invalidServerPublicKey) {
            _ = try client.processChallenge(salt: Data(), serverPublicKey: Data([1]))
        }
        #expect(throws: SRPClient.Failure.invalidServerPublicKey) {
            _ = try client.processChallenge(salt: Data([1]), serverPublicKey: Data())
        }
    }

    /// `B` multiple de N : SRP-6a impose de le refuser, sans quoi le secret est connu de tous.
    @Test("Une clé publique nulle ou démesurée du serveur est refusée")
    func clePubliqueServeur() throws {
        let client = try SRPClient(password: "3939")
        _ = try client.startAuthentication()
        #expect(throws: SRPClient.Failure.invalidServerPublicKey) {
            _ = try client.processChallenge(salt: Data([1]), serverPublicKey: Data(repeating: 0, count: 384))
        }

        let other = try SRPClient(password: "3939")
        _ = try other.startAuthentication()
        #expect(throws: SRPClient.Failure.invalidServerPublicKey) {
            _ = try other.processChallenge(salt: Data([1]), serverPublicKey: Data(repeating: 0xFF, count: 1_000))
        }
    }

    /// Les points d'ordre faible : le secret partagé serait nul, quelle que soit notre clé.
    /// `cryptography`, sur laquelle pyatv s'appuie, les refuse aussi.
    @Test("Une clé publique X25519 d'ordre faible est refusée")
    func ordreFaible() throws {
        let keyPair = try Curve25519KeyPair()
        #expect(throws: Curve25519KeyPair.Failure.computationFailed) {
            _ = try keyPair.sharedSecret(withPublicKey: Data(repeating: 0, count: 32))
        }
    }

    @Test("Les longueurs invalides sont refusées avant la bibliothèque C")
    func longueurs() throws {
        #expect(throws: Curve25519KeyPair.Failure.invalidKeyLength(31)) {
            _ = try Curve25519KeyPair(privateKey: Data(count: 31))
        }
        #expect(throws: Ed25519KeyPair.Failure.invalidSeedLength(0)) {
            _ = try Ed25519KeyPair(seed: Data())
        }
        #expect(throws: Ed25519KeyPair.Failure.invalidSignatureLength(63)) {
            _ = try Ed25519KeyPair.verify(
                signature: Data(count: 63), message: Data(), publicKey: Data(count: 32))
        }
        #expect(throws: Ed25519KeyPair.Failure.invalidKeyLength(31)) {
            _ = try Ed25519KeyPair.verify(
                signature: Data(count: 64), message: Data(), publicKey: Data(count: 31))
        }
        let cipher = try ChaChaPoly1305(key: Data(count: 32))
        #expect(throws: ChaChaPoly1305.Failure.invalidNonceLength(8)) {
            _ = try cipher.seal(Data(), nonce: Data(count: 8))
        }
        #expect(throws: ChaChaPoly1305.Failure.authenticationFailed) {
            _ = try cipher.open(Data(count: 15), nonce: Data(count: 12))
        }
    }

    @Test("Un texte clair vide produit une étiquette seule, et se relit")
    func texteClairVide() throws {
        let cipher = try ChaChaPoly1305(key: Data(count: 32))
        let sealed = try cipher.seal(Data(), nonce: Data(count: 12), additionalData: Data([1, 2]))
        #expect(sealed.count == 16)
        #expect(try cipher.open(sealed, nonce: Data(count: 12), additionalData: Data([1, 2])).isEmpty)
    }

    @Test("L'hexadécimal strict refuse tout ce qui n'en est pas")
    func hexStrict() {
        #expect(Data(hexEncoded: "aB01") == Data([0xAB, 0x01]))
        #expect(Data(hexEncoded: "") == Data())
        #expect(Data(hexEncoded: "+a") == nil)
        #expect(Data(hexEncoded: "-1") == nil)
        #expect(Data(hexEncoded: "0") == nil)
        #expect(Data(hexEncoded: "é") == nil)
        #expect(Data(hexEncoded: "0x") == nil)
    }
}
