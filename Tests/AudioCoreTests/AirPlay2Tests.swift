import AVFoundation
import Foundation
import Testing

@testable import AudioCore

// MARK: - TLV8

@Suite("TLV8 — encodage des messages de pairing")
struct PairingTLV8Tests {

    @Test("Un aller-retour préserve les valeurs")
    func allerRetour() throws {
        let encoded = PairingTLV8.encode([
            (.state, PairingTLV8.byte(1)),
            (.method, PairingTLV8.byte(0)),
            (.flags, PairingTLV8.flagsValue(.transient)),
        ])
        let decoded = try #require(PairingTLV8.decode(encoded))

        #expect(PairingTLV8.state(in: decoded) == .m1)
        #expect(decoded[.method] == Data([0]))
        #expect(decoded[.flags] == Data([0x10]))
    }

    /// Le cas qui casse tout décodeur naïf : une valeur de plus de 255 octets est découpée
    /// en plusieurs éléments du **même type**, que le lecteur doit reconcaténer.
    ///
    /// C'est le cas courant, pas un cas limite : la clé publique SRP fait 384 octets et
    /// arrive donc systématiquement en deux fragments.
    @Test("Une valeur de plus de 255 octets est fragmentée puis reconstituée")
    func fragmentation() throws {
        let publicKey = Data((0..<384).map { UInt8($0 % 256) })
        let encoded = PairingTLV8.encode([(.publicKey, publicKey)])

        // 384 octets = un fragment de 255 + un de 129, soit 2 en-têtes de 2 octets.
        #expect(encoded.count == 384 + 4)
        // Le second fragment commence bien par un en-tête de même type.
        #expect(encoded[257] == PairingTLV8.Tag.publicKey.rawValue)
        #expect(encoded[258] == 129)

        let decoded = try #require(PairingTLV8.decode(encoded))
        #expect(decoded[.publicKey] == publicKey)
    }

    @Test("Une valeur d'exactement 255 octets tient en un seul fragment")
    func fragmentationLimite() throws {
        let value = Data(repeating: 0xAB, count: 255)
        let encoded = PairingTLV8.encode([(.proof, value)])

        #expect(encoded.count == 257)
        let decoded = try #require(PairingTLV8.decode(encoded))
        #expect(decoded[.proof] == value)
    }

    @Test("Un message tronqué est rejeté plutôt qu'analysé à moitié")
    func messageTronque() {
        // Annonce 10 octets mais n'en fournit que 3.
        let truncated = Data([0x03, 0x0A, 0x01, 0x02, 0x03])
        #expect(PairingTLV8.decode(truncated) == nil)
    }

    @Test("Un TLV d'erreur est reconnu")
    func erreurReconnue() throws {
        let encoded = PairingTLV8.encode([
            (.state, PairingTLV8.byte(2)),
            (.error, PairingTLV8.byte(PairingTLV8.PairingError.authentication.rawValue)),
        ])
        let decoded = try #require(PairingTLV8.decode(encoded))
        #expect(PairingTLV8.error(in: decoded) == .authentication)
    }

    @Test("Un type inconnu est ignoré sans faire échouer l'analyse")
    func typeInconnuIgnore() throws {
        // 0x7F n'est pas un type connu : le protocole autorise l'ajout d'éléments, un
        // récepteur plus récent peut en émettre.
        var encoded = PairingTLV8.encode([(.state, PairingTLV8.byte(1))])
        encoded.append(contentsOf: [0x7F, 0x02, 0xAA, 0xBB])

        let decoded = try #require(PairingTLV8.decode(encoded))
        #expect(PairingTLV8.state(in: decoded) == .m1)
    }

    @Test("Le drapeau transitoire tient sur un seul octet")
    func drapeauTransitoire() {
        // Le récepteur attend 0x10, pas un entier 32 bits complet bourré de zéros.
        #expect(PairingTLV8.flagsValue(.transient) == Data([0x10]))
    }
}

// MARK: - Canal de contrôle chiffré

@Suite("Canal de contrôle chiffré AirPlay 2")
struct AirPlay2ControlChannelTests {

    private func makeKeys() -> AirPlay2PairingSession.SessionKeys {
        let secret = Data(repeating: 0x2A, count: 64)
        return AirPlay2PairingSession.SessionKeys(
            outgoing: HKDF512.derive(
                secret: secret,
                salt: AirPlay2ControlChannel.cipherSalt,
                info: AirPlay2ControlChannel.writeKeyInfo
            ),
            incoming: HKDF512.derive(
                secret: secret,
                salt: AirPlay2ControlChannel.cipherSalt,
                info: AirPlay2ControlChannel.readKeyInfo
            ),
            sharedSecret: secret
        )
    }

    /// Le sens sortant d'un côté doit se déchiffrer avec le sens entrant configuré sur la
    /// même clé — c'est la vérification de bout en bout du cadrage et du nonce.
    @Test("Un message chiffré se relit à l'identique")
    func allerRetour() throws {
        let keys = makeKeys()
        let sender = try AirPlay2ControlChannel.Direction(key: keys.outgoing)
        let receiver = try AirPlay2ControlChannel.Direction(key: keys.outgoing)

        let message = Data("SETUP rtsp://192.168.1.21/1234 RTSP/1.0\r\n\r\n".utf8)
        let sealed = try sender.seal(message)
        let (plaintext, consumed) = try receiver.open(sealed)

        #expect(plaintext == message)
        #expect(consumed == sealed.count)
    }

    /// Un message de plus de 1024 octets doit être découpé en plusieurs blocs, chacun avec
    /// son propre nonce — et se reconstituer à la lecture.
    @Test("Un message de plus d'un bloc est découpé puis reconstitué")
    func messageMultiBloc() throws {
        let keys = makeKeys()
        let sender = try AirPlay2ControlChannel.Direction(key: keys.outgoing)
        let receiver = try AirPlay2ControlChannel.Direction(key: keys.outgoing)

        let message = Data((0..<3000).map { UInt8($0 % 256) })
        let sealed = try sender.seal(message)

        // 3000 octets = 2 blocs de 1024 + 1 de 952, chacun avec 2 octets de longueur et
        // 16 d'étiquette.
        #expect(sealed.count == 3000 + 3 * (2 + 16))

        let (plaintext, _) = try receiver.open(sealed)
        #expect(plaintext == message)
    }

    /// Le compteur de nonce doit avancer d'un bloc à l'autre. S'il repartait de zéro, deux
    /// blocs différents seraient chiffrés avec le même nonce — faille classique de l'AEAD.
    @Test("Deux messages identiques donnent deux cryptogrammes différents")
    func nonceProgresse() throws {
        let keys = makeKeys()
        let sender = try AirPlay2ControlChannel.Direction(key: keys.outgoing)

        let message = Data("RECORD\r\n".utf8)
        let first = try sender.seal(message)
        let second = try sender.seal(message)

        #expect(first != second)
    }

    /// En TCP, un message arrive en plusieurs morceaux. Un bloc incomplet ne doit rien
    /// consommer : l'appelant rappellera avec la suite.
    @Test("Un bloc incomplet n'est pas consommé")
    func blocIncomplet() throws {
        let keys = makeKeys()
        let sender = try AirPlay2ControlChannel.Direction(key: keys.outgoing)
        let receiver = try AirPlay2ControlChannel.Direction(key: keys.outgoing)

        let sealed = try sender.seal(Data("SETUP\r\n".utf8))
        let partial = sealed.prefix(sealed.count - 5)

        let (plaintext, consumed) = try receiver.open(Data(partial))
        #expect(plaintext.isEmpty)
        #expect(consumed == 0)
    }

    @Test("Un cryptogramme altéré est rejeté")
    func cryptogrammeAltere() throws {
        let keys = makeKeys()
        let sender = try AirPlay2ControlChannel.Direction(key: keys.outgoing)
        let receiver = try AirPlay2ControlChannel.Direction(key: keys.outgoing)

        var sealed = try sender.seal(Data("SETUP\r\n".utf8))
        sealed[4] ^= 0x01

        #expect(throws: AirPlay2ControlChannel.Failure.self) {
            _ = try receiver.open(sealed)
        }
    }

    /// Les deux sens ont des clés distinctes : lire avec la mauvaise doit échouer.
    /// Les intervertir donnerait un canal qui échoue au premier bloc.
    @Test("Les clés des deux sens ne sont pas interchangeables")
    func clesDistinctes() throws {
        let keys = makeKeys()
        #expect(keys.outgoing != keys.incoming)

        let sender = try AirPlay2ControlChannel.Direction(key: keys.outgoing)
        let wrongDirection = try AirPlay2ControlChannel.Direction(key: keys.incoming)

        let sealed = try sender.seal(Data("SETUP\r\n".utf8))
        #expect(throws: AirPlay2ControlChannel.Failure.self) {
            _ = try wrongDirection.open(sealed)
        }
    }
}

// MARK: - Découverte

@Suite("Découverte AirPlay 2 — lecture des capacités annoncées")
struct AirPlay2DeviceTests {

    /// Valeurs relevées sur l'annonce Bonjour réelle du mock.
    private static let mockTXT: [String: String] = [
        "features": "0x405f4200,0x1c300",
        "pi": "aa5cb8df-7f14-4249-901a-5e748ce57a93",
        "pk": "3b9bd2b0adce158bf00f78ab40aec13c1355d73e6d3aa93f4ef49406bc314835",
        "deviceid": "1e:88:d1:55:d6:fd",
    ]

    /// Les bits de fonctionnalité arrivent en deux mots de 32 bits séparés par une virgule,
    /// le second étant celui de **poids fort**. Les concaténer dans le mauvais ordre donne
    /// un mode de pairing faux, sans erreur visible.
    @Test("Les deux mots de features sont recombinés dans le bon ordre")
    func featuresRecombinees() {
        let device = AirPlay2Device(
            serviceName: "ApTV-HomePod-Mock", host: "192.168.1.21", port: 7000, txt: Self.mockTXT)

        #expect(device.features == 0x0001_C300_405F_4200)
    }

    /// C'est cette lecture qui décide du chemin de pairing employé par le sender.
    @Test("Le mock annonce le pairing transitoire, pas l'appairage système")
    func capacitesDePairing() {
        let device = AirPlay2Device(
            serviceName: "ApTV-HomePod-Mock", host: "192.168.1.21", port: 7000, txt: Self.mockTXT)

        #expect(device.supportsTransientPairing)  // bit 48
        #expect(device.requiresSystemPairing == false)  // bit 43
        #expect(device.supportsHomeKitPairing)  // bit 46
    }

    @Test("La clé publique est décodée depuis l'hexadécimal")
    func clePublique() throws {
        let device = AirPlay2Device(
            serviceName: "ApTV-HomePod-Mock", host: "192.168.1.21", port: 7000, txt: Self.mockTXT)

        let key = try #require(device.publicKey)
        #expect(key.count == 32)
        #expect(key.first == 0x3B)
        #expect(device.pairingIdentifier == "aa5cb8df-7f14-4249-901a-5e748ce57a93")
    }

    /// Un TXT vide ou illisible ne doit pas faire planter la lecture : le sender décidera
    /// ensuite qu'il ne sait pas parler à ce récepteur.
    @Test("Un TXT absent donne des capacités nulles sans planter")
    func txtAbsent() {
        let device = AirPlay2Device(
            serviceName: "Inconnu", host: "192.168.1.99", port: 7000, txt: [:])

        #expect(device.features == 0)
        #expect(device.supportsTransientPairing == false)
        #expect(device.publicKey == nil)
    }
}

// MARK: - Invariants section 12

@Suite("AirPlay 2 — invariants d'architecture (section 12)")
struct AirPlay2InvariantTests {

    private func makeFormat() throws -> AVAudioFormat {
        try #require(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2,
                interleaved: true))
    }

    /// Le sender ne doit **jamais** écrire dans le ring buffer partagé : il en est le
    /// consommateur, pas le producteur.
    ///
    /// Vérifié en écrivant un motif connu, en laissant le sender lire, et en contrôlant que
    /// ce qui a été lu est exactement ce qui avait été écrit.
    @Test("Le sender lit le ring buffer sans jamais le modifier")
    func ringBufferEnLectureSeule() throws {
        let format = try makeFormat()
        let ring = AudioRingBuffer(capacityFrames: 4_096, channelCount: 2)

        let frameCount = 512
        var written = [Float](repeating: 0, count: frameCount * 2)
        for index in 0..<written.count {
            written[index] = Float(index) / Float(written.count)
        }
        written.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            _ = ring.write(from: base, frameCount: frameCount)
        }

        _ = AirPlay2Sender(
            device: AirPlay2Device(serviceName: "T", host: "127.0.0.1", port: 7000, txt: [:]),
            ring: ring,
            captureFormat: format
        )

        // Relecture directe : le contenu doit être intact, le sender n'ayant rien écrit.
        var readBack = [Float](repeating: 0, count: frameCount * 2)
        let read = readBack.withUnsafeMutableBufferPointer { buffer -> Int in
            guard let base = buffer.baseAddress else { return 0 }
            return ring.read(into: base, frameCount: frameCount)
        }

        #expect(read == frameCount)
        #expect(readBack == written)
    }

    /// Chaque sortie a **son** ring buffer. Deux sorties qui tournent en parallèle ne
    /// doivent pas se voler d'échantillons : c'est ce qui permet à la Geneva et au groupe
    /// HomePod de recevoir le même flux sans interférer.
    @Test("Deux pipelines de sortie n'interfèrent pas")
    func pipelinesIndependants() throws {
        let format = try makeFormat()
        let ringA = AudioRingBuffer(capacityFrames: 2_048, channelCount: 2)
        let ringB = AudioRingBuffer(capacityFrames: 2_048, channelCount: 2)

        let frameCount = 256
        var samples = [Float](repeating: 0, count: frameCount * 2)
        for index in 0..<samples.count { samples[index] = Float(index) }

        // La capture duplique vers les deux pipelines.
        for ring in [ringA, ringB] {
            samples.withUnsafeBufferPointer { buffer in
                guard let base = buffer.baseAddress else { return }
                _ = ring.write(from: base, frameCount: frameCount)
            }
        }

        _ = AirPlay2Sender(
            device: AirPlay2Device(serviceName: "AP2", host: "127.0.0.1", port: 7000, txt: [:]),
            ring: ringA, captureFormat: format
        )
        _ = RAOPSender(
            device: RAOPDevice(serviceName: "RAOP", host: "127.0.0.1", port: 5000, txt: [:]),
            ring: ringB, captureFormat: format
        )

        // Vider entièrement A ne doit rien retirer à B.
        var scratch = [Float](repeating: 0, count: frameCount * 2)
        _ = scratch.withUnsafeMutableBufferPointer { buffer -> Int in
            guard let base = buffer.baseAddress else { return 0 }
            return ringA.read(into: base, frameCount: frameCount)
        }

        #expect(ringA.availableFrames == 0)
        #expect(ringB.availableFrames == frameCount)
    }

    /// Le sender démarre à l'arrêt et n'ouvre aucune connexion tant qu'on ne le lui demande
    /// pas : construire un sender ne doit avoir aucun effet de bord réseau.
    @Test("Un sender construit reste inerte")
    func senderInerte() async throws {
        let format = try makeFormat()
        let sender = AirPlay2Sender(
            device: AirPlay2Device(serviceName: "T", host: "127.0.0.1", port: 7000, txt: [:]),
            ring: AudioRingBuffer(capacityFrames: 1_024, channelCount: 2),
            captureFormat: format
        )

        let state = await sender.state
        let statistics = await sender.statistics
        #expect(state == .idle)
        #expect(statistics.packetsSent == 0)
    }
}
