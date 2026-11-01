import Foundation
import Network
import Testing

@testable import AudioCore

@Suite("Canal de contrôle chiffré — cas limites")
struct AirPlay2ControlChannelEdgeTests {
    private let key = Data(repeating: 0x11, count: 32)

    private func pair() throws -> (
        sender: AirPlay2ControlChannel.Direction, receiver: AirPlay2ControlChannel.Direction
    ) {
        (
            try AirPlay2ControlChannel.Direction(key: key),
            try AirPlay2ControlChannel.Direction(key: key)
        )
    }

    /// La limite des 1 024 octets, de part et d'autre : c'est là que se cachent les erreurs de
    /// découpage.
    @Test("Exactement 1024 octets tiennent en un bloc, 1025 en deux", arguments: [
        (1_024, 1), (1_025, 2), (2_048, 2), (2_049, 3), (1, 1),
    ])
    func limiteDeBloc(length: Int, blocks: Int) throws {
        let (sender, receiver) = try pair()
        let message = Data((0..<length).map { UInt8($0 % 251) })

        let sealed = try sender.seal(message)
        #expect(sealed.count == length + blocks * (2 + 16))

        let (plaintext, consumed) = try receiver.open(sealed)
        #expect(plaintext == message)
        #expect(consumed == sealed.count)
    }

    /// Le préfixe de longueur doit être en little-endian : 1024 = `00 04`.
    @Test("Le préfixe de longueur est en little-endian")
    func prefixeLittleEndian() throws {
        let (sender, _) = try pair()
        let sealed = try sender.seal(Data(repeating: 0, count: 1_024))
        #expect(sealed[0] == 0x00)
        #expect(sealed[1] == 0x04)
    }

    /// Chaque fragment possible d'un message réparti sur plusieurs blocs : TCP coupe où il veut.
    @Test("Un message livré octet par octet se reconstitue")
    func livraisonOctetParOctet() throws {
        let (sender, receiver) = try pair()
        let message = Data((0..<2_500).map { UInt8($0 % 251) })
        let sealed = try sender.seal(message)

        var buffer = Data()
        var plaintext = Data()
        for byte in sealed {
            buffer.append(byte)
            let (clear, consumed) = try receiver.open(buffer)
            buffer.removeFirst(consumed)
            plaintext.append(clear)
        }

        #expect(plaintext == message)
        #expect(buffer.isEmpty)
    }

    /// `removeFirst` sur un `Data` en fait une tranche, dont `startIndex` n'est plus 0. Tout
    /// accès par index absolu s'y casserait les dents.
    @Test("Un tampon dont l'indice de départ n'est pas zéro est lu correctement")
    func tamponDecale() throws {
        let (sender, receiver) = try pair()
        var buffer = Data(repeating: 0xEE, count: 7)
        buffer.append(try sender.seal(Data("SETUP\r\n".utf8)))
        buffer.removeFirst(7)
        #expect(buffer.startIndex != 0)

        let (plaintext, consumed) = try receiver.open(buffer)
        #expect(plaintext == Data("SETUP\r\n".utf8))
        #expect(consumed == buffer.count)
    }

    /// Le compteur vit aussi longtemps que la connexion : un second message se déchiffre avec le
    /// nonce qui suit le premier, sinon toute la session s'arrête au deuxième échange.
    @Test("Le compteur avance d'un message à l'autre, sans repartir de zéro")
    func compteurPersistant() throws {
        let (sender, receiver) = try pair()
        let first = try sender.seal(Data("A".utf8))
        let second = try sender.seal(Data("B".utf8))

        _ = try receiver.open(first)
        let (clear, _) = try receiver.open(second)
        #expect(clear == Data("B".utf8))

        // Un lecteur neuf repart de zéro : il ne peut pas lire le second message sans le premier.
        let fresh = try AirPlay2ControlChannel.Direction(key: key)
        #expect(throws: AirPlay2ControlChannel.Failure.self) { _ = try fresh.open(second) }
    }

    /// Le compteur compte des **blocs**, pas des messages.
    @Test("Le compteur compte les blocs : un message de deux blocs en consomme deux")
    func compteurParBloc() throws {
        let (sender, receiver) = try pair()
        let long = try sender.seal(Data(repeating: 1, count: 1_500))
        let next = try sender.seal(Data("suite".utf8))

        _ = try receiver.open(long)
        let (clear, _) = try receiver.open(next)
        #expect(clear == Data("suite".utf8))
    }

    /// Un bloc rejeté ne doit pas décaler les compteurs : le même bloc rejoué, intact, repasse.
    @Test("Une étiquette invalide ne fait pas avancer le compteur")
    func echecSansAvancee() throws {
        let (sender, receiver) = try pair()
        let sealed = try sender.seal(Data("X".utf8))

        var tampered = sealed
        tampered[tampered.count - 1] ^= 0x01
        #expect(throws: AirPlay2ControlChannel.Failure.self) { _ = try receiver.open(tampered) }

        let (clear, _) = try receiver.open(sealed)
        #expect(clear == Data("X".utf8))
    }

    /// La longueur fait partie des données associées : la modifier invalide le bloc.
    @Test("Altérer le préfixe de longueur invalide le bloc")
    func longueurAuthentifiee() throws {
        let (sender, receiver) = try pair()
        var sealed = try sender.seal(Data("ABCDEF".utf8))
        sealed[0] = 3
        #expect(throws: AirPlay2ControlChannel.Failure.self) { _ = try receiver.open(sealed) }
    }

    /// Les nonces de `seal` doivent s'accorder avec ceux de pyatv : 4 octets nuls, puis le
    /// compteur sur 8 octets little-endian (`_PACK_NONCE_WITH_4_BYTE_PAD`).
    @Test("Le nonce du deuxième bloc est celui de pyatv")
    func nonceConformeAPyatv() throws {
        let (sender, _) = try pair()
        _ = try sender.seal(Data("premier".utf8))
        let second = try sender.seal(Data("second".utf8))

        let cipher = try ChaChaPoly1305(key: key)
        let nonce = Data([0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0])
        let clear = try cipher.open(
            Data(second.dropFirst(2)), nonce: nonce, additionalData: Data(second.prefix(2)))
        #expect(clear == Data("second".utf8))
    }
}

/// `RTSPClient` contre un récepteur simulé, sur ce qu'un acteur réentrant laissait passer.
@Suite("RTSPClient — échanges sur le canal chiffré")
struct RTSPClientExchangeTests {

    /// Une connexion déjà appairée, chiffrée des deux côtés.
    private func connectedClient(
        to receiver: FakeAirPlay2Receiver
    ) async throws -> RTSPClient {
        let client = RTSPClient(host: "127.0.0.1", port: receiver.port)
        try await client.connect()
        let pairing = AirPlay2PairingSession(client: client, device: receiver.device())
        let keys = try await pairing.performTransientPairSetup()
        try await client.enableEncryption(keys: keys)
        return client
    }

    private func feedback() -> RTSPRequest {
        RTSPRequest(method: "POST", uri: "/feedback")
    }

    /// Deux requêtes entrelacées se liraient mutuellement leur réponse. Le récepteur simulé
    /// répond avec retard et relève tout chevauchement.
    @Test("Des appels concurrents ne s'entrelacent jamais")
    func appelsConcurrents() async throws {
        let receiver = FakeAirPlay2Receiver()
        try await receiver.start()
        defer { receiver.stop() }
        receiver.script = { request, _ in
            request.uri == "/feedback" ? .delayed(0.02) : .normal
        }
        let client = try await connectedClient(to: receiver)

        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<10 {
                group.addTask {
                    _ = try await client.send(RTSPRequest(method: "POST", uri: "/feedback"))
                }
            }
            try await group.waitForAll()
        }

        #expect(receiver.overlappingRequestCount == 0)
        #expect(receiver.count(method: "POST", uri: "/feedback") == 10)
        await client.disconnect()
    }

    /// Le défaut le plus insidieux du canal chiffré : une réponse arrivée après l'échéance partait
    /// vers une lecture orpheline et disparaissait. Le compteur de nonces restait alors décalé
    /// d'un bloc, et plus rien ne se déchiffrait jusqu'à la fin de la session.
    @Test("Une réponse arrivée après l'échéance n'est pas perdue")
    func reponseTardive() async throws {
        let receiver = FakeAirPlay2Receiver()
        try await receiver.start()
        defer { receiver.stop() }
        receiver.script = { request, occurrence in
            request.uri == "/feedback" && occurrence == 0 ? .delayed(0.4) : .normal
        }
        let client = try await connectedClient(to: receiver)

        await #expect(throws: RTSPError.self) {
            _ = try await client.send(RTSPRequest(method: "POST", uri: "/feedback"), timeout: .milliseconds(100))
        }
        try await Task.sleep(for: .milliseconds(500))

        // La suivante doit se déchiffrer, et lire sa propre réponse, pas celle de la précédente.
        let response = try await client.send(
            RTSPRequest(method: "RECORD", uri: "rtsp://x/1"), timeout: .seconds(2))
        #expect(response.isSuccess)
        #expect(response.headers["cseq"] == "2")
        await client.disconnect()
    }

    /// La même, mais la réponse tardive arrive pendant que la requête suivante attend déjà.
    @Test("Une réponse tardive est écartée par son CSeq")
    func reponseTardivePendantLaSuivante() async throws {
        let receiver = FakeAirPlay2Receiver()
        try await receiver.start()
        defer { receiver.stop() }
        receiver.script = { request, occurrence in
            if request.uri == "/feedback", occurrence == 0 { return .delayed(0.3) }
            return request.method == "RECORD" ? .delayed(0.5) : .normal
        }
        let client = try await connectedClient(to: receiver)

        await #expect(throws: RTSPError.self) {
            _ = try await client.send(RTSPRequest(method: "POST", uri: "/feedback"), timeout: .milliseconds(100))
        }
        let response = try await client.send(
            RTSPRequest(method: "RECORD", uri: "rtsp://x/1"), timeout: .seconds(2))
        #expect(response.headers["cseq"] == "2")
        await client.disconnect()
    }

    /// Un message plus grand qu'un bloc et qu'un fragment TCP : `SETUP` en est souvent proche.
    @Test("Une réponse répartie sur plusieurs blocs se reconstitue")
    func reponseMultiBloc() async throws {
        let receiver = FakeAirPlay2Receiver()
        try await receiver.start()
        defer { receiver.stop() }
        let client = try await connectedClient(to: receiver)

        // `SET_PARAMETER` avec un corps de 5 Ko : la requête aussi est découpée.
        let body = Data(repeating: 0x61, count: 5_000)
        let response = try await client.send(
            RTSPRequest(
                method: "SET_PARAMETER", uri: "rtsp://x/1",
                headers: [("Content-Length", "5000")], body: body))
        #expect(response.isSuccess)
        #expect(receiver.volumes(inSession: 0).first?.utf8.count == 5_000)
        await client.disconnect()
    }

    /// Une rupture réveille tout de suite celui qui attend : pas d'échéance à subir.
    @Test("disconnect() réveille une requête en attente")
    func disconnectReveille() async throws {
        let receiver = FakeAirPlay2Receiver()
        try await receiver.start()
        defer { receiver.stop() }
        receiver.script = { request, _ in request.uri == "/feedback" ? .silent : .normal }
        let client = try await connectedClient(to: receiver)

        let task = Task {
            try await client.send(RTSPRequest(method: "POST", uri: "/feedback"), timeout: .seconds(30))
        }
        #expect(await eventually { receiver.count(method: "POST", uri: "/feedback") == 1 })

        let start = ContinuousClock.now
        await client.disconnect()
        let result = await task.result
        #expect(ContinuousClock.now - start < .seconds(1))
        #expect(throws: RTSPError.self) { _ = try result.get() }
    }

    @Test("Une fermeture côté récepteur remonte en rupture de connexion")
    func fermetureRecepteur() async throws {
        let receiver = FakeAirPlay2Receiver()
        try await receiver.start()
        defer { receiver.stop() }
        receiver.script = { request, _ in request.uri == "/feedback" ? .close : .normal }
        let client = try await connectedClient(to: receiver)

        do {
            _ = try await client.send(RTSPRequest(method: "POST", uri: "/feedback"), timeout: .seconds(5))
            Issue.record("la requête aurait dû échouer")
        } catch RTSPError.connectionFailed {
            // attendu
        } catch {
            Issue.record("mauvaise erreur : \(error)")
        }
        await client.disconnect()
    }

    @Test("disconnect() réveille un établissement en cours")
    func disconnectPendantConnect() async throws {
        // 192.0.2.1 : adresse réservée à la documentation, la connexion reste en suspens. Aucun appareil
        // du réseau n'est sollicité.
        let client = RTSPClient(host: "192.0.2.1", port: 7000)
        let task = Task { try await client.connect(timeout: .seconds(30)) }
        try await Task.sleep(for: .milliseconds(100))

        let start = ContinuousClock.now
        await client.disconnect()
        let result = await task.result
        #expect(ContinuousClock.now - start < .seconds(1))
        #expect(throws: RTSPError.self) { try result.get() }
    }
}
