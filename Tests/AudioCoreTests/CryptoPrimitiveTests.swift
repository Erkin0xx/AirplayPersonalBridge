import Foundation
import Testing

@testable import AudioCore

/// Tests des primitives cryptographiques du jalon 3, contre les **vecteurs de test des RFC
/// officiels** (CDC section 14 : ces tests doivent être verts avant toute intégration réseau).
///
/// L'enjeu est précis. Une erreur de portage sur ces primitives — endianness, off-by-one,
/// clamping oublié — ne produit pas de plantage : elle produit un handshake qui échoue sans
/// message exploitable, ou pire, un chiffrement affaibli qui « marche ». Le seul moyen fiable
/// de l'exclure est de comparer à des vecteurs publiés, calculés indépendamment de ce code.
///
/// C'est aussi la leçon du jalon 2, défaut n°2 : un test qui rejoue les hypothèses de son
/// propre encodeur valide n'importe quoi. Ici, aucune valeur attendue ne sort de ce projet.

// MARK: - Utilitaires

private func hexData(_ hex: String) -> Data {
    let cleaned = hex.filter { !$0.isWhitespace }
    var bytes = [UInt8]()
    bytes.reserveCapacity(cleaned.count / 2)
    var index = cleaned.startIndex
    while index < cleaned.endIndex {
        let next = cleaned.index(index, offsetBy: 2)
        guard let byte = UInt8(cleaned[index..<next], radix: 16) else {
            fatalError("vecteur de test hexadécimal invalide")  // erreur de programmation
        }
        bytes.append(byte)
        index = next
    }
    return Data(bytes)
}

private func hexString(_ data: Data) -> String {
    data.map { String(format: "%02x", $0) }.joined()
}

// MARK: - X25519 (RFC 7748)

@Suite("X25519 — vecteurs RFC 7748")
struct Curve25519Tests {

    /// RFC 7748 §6.1 : le couple (clé privée d'Alice → clé publique d'Alice).
    @Test("La clé publique d'Alice se déduit de sa clé privée")
    func clePubliqueAlice() throws {
        let privateKey = hexData("77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a")
        let expected = "8520f0098930a754748b7ddcb43ef75a0dbf3a0d26381af4eba4a98eaa9b4e6a"

        let pair = try Curve25519KeyPair(privateKey: privateKey)
        #expect(hexString(pair.publicKey) == expected)
    }

    /// RFC 7748 §6.1 : la clé publique de Bob.
    @Test("La clé publique de Bob se déduit de sa clé privée")
    func clePubliqueBob() throws {
        let privateKey = hexData("5dab087e624a8a4b79e17f8b83800ee66f3bb1292618b6fd1c2f8b27ff88e0eb")
        let expected = "de9edb7d7b7dc1b4d35b61c2ece435373f8343c85b78674dadfc7e146f882b4f"

        let pair = try Curve25519KeyPair(privateKey: privateKey)
        #expect(hexString(pair.publicKey) == expected)
    }

    /// RFC 7748 §6.1 : le secret partagé, identique des deux côtés.
    ///
    /// C'est le test qui compte pour AirPlay 2 : c'est ce secret qui alimente le HKDF du
    /// `pair-verify`. Le vérifier dans les deux sens exclut une asymétrie de clamping.
    @Test("Le secret partagé est identique des deux côtés")
    func secretPartage() throws {
        let alicePrivate = hexData("77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a")
        let bobPrivate = hexData("5dab087e624a8a4b79e17f8b83800ee66f3bb1292618b6fd1c2f8b27ff88e0eb")
        let expected = "4a5d9d5ba4ce2de1728e3bf480350f25e07e21c947d19e3376f09b3c1e161742"

        let alice = try Curve25519KeyPair(privateKey: alicePrivate)
        let bob = try Curve25519KeyPair(privateKey: bobPrivate)

        let aliceSide = try alice.sharedSecret(withPublicKey: bob.publicKey)
        let bobSide = try bob.sharedSecret(withPublicKey: alice.publicKey)

        #expect(hexString(aliceSide) == expected)
        #expect(aliceSide == bobSide)
    }

    @Test("Une clé de longueur invalide est refusée")
    func longueurInvalide() {
        #expect(throws: Curve25519KeyPair.Failure.invalidKeyLength(31)) {
            try Curve25519KeyPair(privateKey: Data(count: 31))
        }
    }
}

// MARK: - Ed25519 (RFC 8032)

@Suite("Ed25519 — vecteurs RFC 8032")
struct Ed25519Tests {

    /// RFC 8032 §7.1, TEST 1 : message vide.
    ///
    /// Le message vide est le cas limite le plus susceptible de casser un wrapper : `Data`
    /// vide donne un `baseAddress` nul, que la bibliothèque C déréférencerait.
    @Test("TEST 1 — message vide")
    func test1MessageVide() throws {
        let seed = hexData("9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60")
        let expectedPublic = "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a"
        let expectedSignature = """
            e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e06522490155\
            5fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b
            """

        let pair = try Ed25519KeyPair(seed: seed)
        #expect(hexString(pair.publicKey) == expectedPublic)

        let signature = pair.sign(Data())
        #expect(hexString(signature) == expectedSignature)
        #expect(try Ed25519KeyPair.verify(signature: signature, message: Data(), publicKey: pair.publicKey))
    }

    /// RFC 8032 §7.1, TEST 2 : message d'un octet (0x72).
    @Test("TEST 2 — message d'un octet")
    func test2UnOctet() throws {
        let seed = hexData("4ccd089b28ff96da9db6c346ec114e0f5b8a319f35aba624da8cf6ed4fb8a6fb")
        let message = hexData("72")
        let expectedPublic = "3d4017c3e843895a92b70aa74d1b7ebc9c982ccf2ec4968cc0cd55f12af4660c"
        let expectedSignature = """
            92a009a9f0d4cab8720e820b5f642540a2b27b5416503f8fb3762223ebdb69da\
            085ac1e43e15996e458f3613d0f11d8c387b2eaeb4302aeeb00d291612bb0c00
            """

        let pair = try Ed25519KeyPair(seed: seed)
        #expect(hexString(pair.publicKey) == expectedPublic)

        let signature = pair.sign(message)
        #expect(hexString(signature) == expectedSignature)
        #expect(try Ed25519KeyPair.verify(signature: signature, message: message, publicKey: pair.publicKey))
    }

    /// RFC 8032 §7.1, TEST 3 : message de deux octets.
    @Test("TEST 3 — message de deux octets")
    func test3DeuxOctets() throws {
        let seed = hexData("c5aa8df43f9f837bedb7442f31dcb7b166d38535076f094b85ce3a2e0b4458f7")
        let message = hexData("af82")
        let expectedPublic = "fc51cd8e6218a1a38da47ed00230f0580816ed13ba3303ac5deb911548908025"
        let expectedSignature = """
            6291d657deec24024827e69c3abe01a30ce548a284743a445e3680d7db5ac3ac\
            18ff9b538d16f290ae67f760984dc6594a7c15e9716ed28dc027beceea1ec40a
            """

        let pair = try Ed25519KeyPair(seed: seed)
        #expect(hexString(pair.publicKey) == expectedPublic)

        let signature = pair.sign(message)
        #expect(hexString(signature) == expectedSignature)
    }

    /// Une signature valide sur un message modifié doit être rejetée.
    ///
    /// Sans ce test, une implémentation de `verify` qui renverrait toujours `true` passerait
    /// les trois vecteurs ci-dessus.
    @Test("Une signature ne vaut que pour son message")
    func signatureRejeteeSurAutreMessage() throws {
        let pair = try Ed25519KeyPair(seed: hexData(
            "9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60"))
        let signature = pair.sign(Data("message authentique".utf8))

        #expect(try Ed25519KeyPair.verify(
            signature: signature,
            message: Data("message falsifié".utf8),
            publicKey: pair.publicKey
        ) == false)
    }

    /// La graine doit être restituée telle quelle : c'est elle qu'on persiste dans les
    /// credentials, et une paire relue doit redonner exactement la même clé publique.
    @Test("Une paire relue depuis sa graine est identique")
    func paireReconstruite() throws {
        let original = try Ed25519KeyPair()
        let reconstructed = try Ed25519KeyPair(seed: original.seed)

        #expect(original.publicKey == reconstructed.publicKey)

        let message = Data("AirPlay 2".utf8)
        #expect(original.sign(message) == reconstructed.sign(message))
    }
}

// MARK: - ChaCha20-Poly1305 (RFC 7539)

@Suite("ChaCha20-Poly1305 — vecteurs RFC 7539")
struct ChaChaPoly1305Tests {

    /// RFC 7539 §2.8.2 : le vecteur d'AEAD complet, avec données associées.
    ///
    /// Le nonce y est décrit comme 32 bits constants suivis de 64 bits d'IV ; concaténés,
    /// c'est le nonce de 12 octets ci-dessous.
    @Test("§2.8.2 — chiffrement avec données associées")
    func vecteurAEAD() throws {
        let key = hexData("808182838485868788898a8b8c8d8e8f909192939495969798999a9b9c9d9e9f")
        let nonce = hexData("070000004041424344454647")
        let additionalData = hexData("50515253c0c1c2c3c4c5c6c7")
        let plaintext = Data(
            "Ladies and Gentlemen of the class of '99: If I could offer you only one tip for the future, sunscreen would be it."
                .utf8)

        let expectedCiphertext = """
            d31a8d34648e60db7b86afbc53ef7ec2a4aded51296e08fea9e2b5a736ee62d6\
            3dbea45e8ca9671282fafb69da92728b1a71de0a9e060b2905d6a5b67ecd3b36\
            92ddbd7f2d778b8c9803aee328091b58fab324e4fad675945585808b4831d7bc\
            3ff4def08e4b7a9de576d26586cec64b6116
            """
        let expectedTag = "1ae10b594f09e26a7e902ecbd0600691"

        let cipher = try ChaChaPoly1305(key: key)
        let sealed = try cipher.seal(plaintext, nonce: nonce, additionalData: additionalData)

        let ciphertext = sealed.prefix(sealed.count - ChaChaPoly1305.tagLength)
        let tag = sealed.suffix(ChaChaPoly1305.tagLength)

        #expect(hexString(Data(ciphertext)) == expectedCiphertext)
        #expect(hexString(Data(tag)) == expectedTag)

        // Aller-retour : le déchiffrement doit rendre exactement l'entrée.
        let opened = try cipher.open(sealed, nonce: nonce, additionalData: additionalData)
        #expect(opened == plaintext)
    }

    /// Une étiquette altérée doit être refusée, et rien ne doit être renvoyé.
    ///
    /// C'est la propriété qui protège le pairing : sans elle, un sous-TLV forgé serait
    /// accepté comme authentique.
    @Test("Un cryptogramme altéré est rejeté")
    func cryptogrammeAltere() throws {
        let key = hexData("808182838485868788898a8b8c8d8e8f909192939495969798999a9b9c9d9e9f")
        let nonce = hexData("070000004041424344454647")
        let cipher = try ChaChaPoly1305(key: key)

        var sealed = try cipher.seal(Data("message".utf8), nonce: nonce)
        sealed[0] ^= 0x01  // un seul bit inversé dans le cryptogramme

        #expect(throws: ChaChaPoly1305.Failure.authenticationFailed) {
            try cipher.open(sealed, nonce: nonce)
        }
    }

    /// Les données associées font partie de l'authentification : les changer doit invalider.
    @Test("Des données associées différentes invalident l'étiquette")
    func donneesAssocieesDifferentes() throws {
        let key = hexData("808182838485868788898a8b8c8d8e8f909192939495969798999a9b9c9d9e9f")
        let nonce = hexData("070000004041424344454647")
        let cipher = try ChaChaPoly1305(key: key)

        let sealed = try cipher.seal(
            Data("message".utf8), nonce: nonce, additionalData: Data("contexte A".utf8))

        #expect(throws: ChaChaPoly1305.Failure.authenticationFailed) {
            try cipher.open(sealed, nonce: nonce, additionalData: Data("contexte B".utf8))
        }
    }

    @Test("Une clé de longueur invalide est refusée")
    func cleInvalide() {
        #expect(throws: ChaChaPoly1305.Failure.invalidKeyLength(16)) {
            try ChaChaPoly1305(key: Data(count: 16))
        }
    }

    /// Le wrapper ne doit jamais modifier le texte clair que lui passe l'appelant.
    /// `chachapoly_crypt` écrit dans son tampon d'entrée : sans copie défensive, l'argument
    /// de l'appelant serait écrasé par le cryptogramme.
    @Test("Le chiffrement ne modifie pas le texte clair de l'appelant")
    func texteClairPreserve() throws {
        let key = hexData("808182838485868788898a8b8c8d8e8f909192939495969798999a9b9c9d9e9f")
        let nonce = hexData("070000004041424344454647")
        let cipher = try ChaChaPoly1305(key: key)

        let plaintext = Data("le tampon de l'appelant".utf8)
        let copy = plaintext
        _ = try cipher.seal(plaintext, nonce: nonce)

        #expect(plaintext == copy)
    }
}

// MARK: - SRP-6a

@Suite("SRP-6a — échange complet")
struct SRPClientTests {

    /// Vérifie que le client SRP négocie bien une clé de session avec un serveur qui connaît
    /// le mot de passe, sur le groupe 3072 bits en SHA-512 — la configuration exacte
    /// d'AirPlay 2.
    ///
    /// Le partenaire est ici le **vérificateur de csrp lui-même**, pas une réimplémentation :
    /// le test porte donc sur le câblage du wrapper (paramètres, longueurs, ordre des appels),
    /// pas sur les mathématiques de SRP, qui sont celles de la bibliothèque vendue.
    /// La conformité au protocole réel est établie par le handshake contre le mock.
    @Test("Client et serveur aboutissent à la même clé de session")
    func echangeComplet() throws {
        let password = "3939"  // le code du mock airplay2-receiver
        let username = SRPClient.pairSetupUsername

        let client = try SRPClient(password: password)
        let publicA = try client.startAuthentication()
        #expect(!publicA.isEmpty)

        // Côté serveur : construit un vérificateur salé, puis répond au A du client.
        let server = try SRPTestServer(username: username, password: password)
        let (salt, publicB) = try server.challenge(forClientPublicKey: publicA)

        let proofM1 = try client.processChallenge(salt: salt, serverPublicKey: publicB)
        let proofHAMK = try server.verify(clientProof: proofM1)

        try client.verifyServerProof(proofHAMK)

        let clientKey = try client.sessionKey()
        #expect(clientKey == server.sessionKey)
        // SHA-512 : la clé de session fait 64 octets.
        #expect(clientKey.count == 64)
    }

    /// Un mot de passe erroné ne doit jamais aboutir à une session authentifiée.
    @Test("Un mauvais mot de passe est rejeté")
    func mauvaisMotDePasse() throws {
        let client = try SRPClient(password: "0000")
        let publicA = try client.startAuthentication()

        let server = try SRPTestServer(username: SRPClient.pairSetupUsername, password: "3939")
        let (salt, publicB) = try server.challenge(forClientPublicKey: publicA)

        let proofM1 = try client.processChallenge(salt: salt, serverPublicKey: publicB)
        // Le serveur refuse la preuve : il ne renvoie pas de HAMK exploitable.
        #expect(throws: SRPTestServer.Failure.self) {
            _ = try server.verify(clientProof: proofM1)
        }
    }

    /// La clé de session ne doit pas être exposée avant que le serveur ait été authentifié.
    @Test("La clé de session est indisponible avant vérification")
    func cleIndisponibleAvantVerification() throws {
        let client = try SRPClient(password: "3939")
        _ = try client.startAuthentication()

        #expect(throws: SRPClient.Failure.sessionNotEstablished) {
            _ = try client.sessionKey()
        }
    }
}

// MARK: - HKDF-SHA512

@Suite("HKDF-SHA512")
struct HKDF512Tests {

    /// Déterminisme et longueur : deux dérivations identiques donnent le même résultat,
    /// deux infos différentes donnent des clés différentes.
    ///
    /// C'est ce qui garantit que les clés du `pair-setup` et du `pair-verify` ne se
    /// confondent jamais, alors qu'elles partent parfois du même secret.
    @Test("Des étiquettes différentes produisent des clés différentes")
    func etiquettesDistinctes() {
        let secret = Data(repeating: 0x0b, count: 32)

        let setupKey = HKDF512.derive(
            secret: secret,
            salt: HKDF512.Label.setupEncryptSalt,
            info: HKDF512.Label.setupEncryptInfo
        )
        let verifyKey = HKDF512.derive(
            secret: secret,
            salt: HKDF512.Label.verifyEncryptSalt,
            info: HKDF512.Label.verifyEncryptInfo
        )
        let setupAgain = HKDF512.derive(
            secret: secret,
            salt: HKDF512.Label.setupEncryptSalt,
            info: HKDF512.Label.setupEncryptInfo
        )

        #expect(setupKey.count == 32)
        #expect(setupKey != verifyKey)
        #expect(setupKey == setupAgain)
    }
}
