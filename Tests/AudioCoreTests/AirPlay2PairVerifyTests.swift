import Foundation
import Testing

@testable import AudioCore

/// `pair-verify` contre un accessoire simulé en processus, écrit depuis le code de pyatv.
///
/// **Portée** : ces tests établissent que notre `performPairVerify` est conforme à ce que fait
/// pyatv, message par message. Ils ne prouvent pas qu'un vrai Apple TV l'accepte : seul un essai
/// sur l'appareil le dira (voir le compte rendu de la passe de robustesse).
@Suite("pair-verify — accessoire simulé")
struct AirPlay2PairVerifyTests {

    private struct Scenario {
        let receiver: FakeAirPlay2Receiver
        let credentials: HapCredentials
        let identity: SimulatedIdentity
    }

    /// Un appairage système déjà acquis : les deux côtés connaissent la clé publique de l'autre.
    private func paired(
        wrongDomainBehaviour: FakeAirPlay2Receiver.WrongDomainBehaviour = .reject
    ) async throws -> Scenario {
        let identity = SimulatedIdentity.random(identifier: "96A1F186-3B44-4AFC-9E53-3F2DEC7B6B01")
        let client = try Ed25519KeyPair()
        let clientIdentifier = Data("D2A1E8C0-0000-4000-8000-1234567890AB".utf8)

        var options = FakeAirPlay2Receiver.Options()
        options.transientEnabled = false
        options.identity = identity
        options.pairedClient = (clientIdentifier, client.publicKey)
        options.wrongDomainBehaviour = wrongDomainBehaviour
        let receiver = FakeAirPlay2Receiver(options: options)
        try await receiver.start()

        let credentials = HapCredentials(
            receiverPublicKey: try identity.publicKey,
            clientSecretSeed: client.seed,
            receiverIdentifier: identity.identifier,
            clientIdentifier: clientIdentifier
        )
        return Scenario(receiver: receiver, credentials: credentials, identity: identity)
    }

    private func verify(
        _ scenario: Scenario, credentials: HapCredentials? = nil
    ) async throws -> AirPlay2PairingSession.SessionKeys {
        let client = RTSPClient(host: "127.0.0.1", port: scenario.receiver.port)
        try await client.connect()
        let pairing = AirPlay2PairingSession(client: client, device: scenario.receiver.device())
        do {
            let keys = try await pairing.performPairVerify(
                credentials: credentials ?? scenario.credentials)
            await client.disconnect()
            return keys
        } catch {
            await client.disconnect()
            throw error
        }
    }

    /// M1 → M4 complet. L'accessoire simulé vérifie aussi **notre** signature à M3 : un échange
    /// abouti établit donc les deux sens de l'authentification.
    @Test("L'échange aboutit, et les deux côtés s'authentifient")
    func echangeComplet() async throws {
        let scenario = try await paired()
        defer { scenario.receiver.stop() }

        let keys = try await verify(scenario)

        #expect(keys.sharedSecret.count == 32)
        #expect(keys.outgoing != keys.incoming)
        let exchanges = scenario.receiver.requests().filter { $0.uri == "/pair-verify" }
        #expect(exchanges.count == 2)
    }

    /// **La correction du commit d2886e4 restée ouverte.** pyatv poste en `X-Apple-HKP: 3`
    /// (`airplay/auth/hap.py`), et son accessoire simulé refuse en `501` toute autre valeur.
    /// Le projet envoyait `4`, recopié du pair-setup.
    @Test("Le pair-verify annonce le domaine système, X-Apple-HKP 3")
    func domaineSysteme() async throws {
        let scenario = try await paired()
        defer { scenario.receiver.stop() }

        _ = try await verify(scenario)

        let exchanges = scenario.receiver.requests().filter { $0.uri == "/pair-verify" }
        #expect(exchanges.allSatisfy { $0.headers["x-apple-hkp"] == "3" })
        #expect(exchanges.allSatisfy { $0.protocolVersion == "HTTP/1.1" })
        #expect(exchanges.allSatisfy { $0.headers["cseq"] == nil })
    }

    /// Reproduit le symptôme relevé contre l'Apple TV : hors du domaine système, un récepteur
    /// répond sous une autre identité. L'échange se déroule, le sous-TLV se déchiffre, identifiant
    /// et signature ont les bonnes longueurs — et rien ne vérifie.
    ///
    /// Le test passe parce qu'on annonce désormais `3`. Avec `4`, il échoue exactement comme
    /// échouait la session réelle.
    @Test("Un récepteur sensible au domaine répond sous la bonne identité")
    func domaineChoisitIdentite() async throws {
        let other = SimulatedIdentity.random(identifier: "7358e914-0000-4000-8000-000000000000")
        let scenario = try await paired(wrongDomainBehaviour: .otherIdentity(other))
        defer { scenario.receiver.stop() }

        _ = try await verify(scenario)
    }

    /// Le contrôle qui authentifie le récepteur : il ne doit jamais céder.
    @Test("Une signature qui ne vérifie pas fait échouer la session")
    func signatureInvalide() async throws {
        let scenario = try await paired()
        defer { scenario.receiver.stop() }

        // Mêmes identifiants, mais une clé publique qui n'est pas celle de l'accessoire.
        let impostor = try Ed25519KeyPair()
        let wrongKey = HapCredentials(
            receiverPublicKey: impostor.publicKey,
            clientSecretSeed: scenario.credentials.clientSecretSeed,
            receiverIdentifier: scenario.credentials.receiverIdentifier,
            clientIdentifier: scenario.credentials.clientIdentifier
        )

        await #expect(throws: AirPlay2PairingSession.Failure.self) {
            _ = try await verify(scenario, credentials: wrongKey)
        }
        // M3 ne doit pas être parti : on n'a pas signé pour un inconnu.
        #expect(scenario.receiver.requests().filter { $0.uri == "/pair-verify" }.count == 1)
    }

    /// Une identité étrangère et une signature invalide : l'écart d'identifiant sert au
    /// diagnostic, pas à la décision, et le message le nomme.
    @Test("Une autre identité est nommée comme telle")
    func identiteEtrangere() async throws {
        let scenario = try await paired()
        defer { scenario.receiver.stop() }

        let impostor = try Ed25519KeyPair()
        let foreign = HapCredentials(
            receiverPublicKey: impostor.publicKey,
            clientSecretSeed: scenario.credentials.clientSecretSeed,
            receiverIdentifier: Data("un-autre-appareil".utf8),
            clientIdentifier: scenario.credentials.clientIdentifier
        )

        do {
            _ = try await verify(scenario, credentials: foreign)
            Issue.record("la session aurait dû échouer")
        } catch AirPlay2PairingSession.Failure.receiverIdentityMismatch {
            // attendu
        } catch {
            Issue.record("mauvaise erreur : \(error)")
        }
    }

    /// Une clé valide suffit : l'identifiant reste un repère. L'accepter n'ôte rien à la sûreté,
    /// puisque la signature porte sur cet identifiant même.
    @Test("Un identifiant différent mais bien signé ne bloque pas")
    func identifiantDifferentBienSigne() async throws {
        let scenario = try await paired()
        defer { scenario.receiver.stop() }

        let relabelled = HapCredentials(
            receiverPublicKey: scenario.credentials.receiverPublicKey,
            clientSecretSeed: scenario.credentials.clientSecretSeed,
            receiverIdentifier: Data("identifiant-enregistre-autrement".utf8),
            clientIdentifier: scenario.credentials.clientIdentifier
        )

        _ = try await verify(scenario, credentials: relabelled)
    }

    /// M4 peut refuser : l'accessoire n'a pas reconnu notre signature.
    @Test("Un refus du récepteur à M4 remonte en erreur")
    func refusM4() async throws {
        let scenario = try await paired()
        defer { scenario.receiver.stop() }

        let stranger = try Ed25519KeyPair()
        let wrongClient = HapCredentials(
            receiverPublicKey: scenario.credentials.receiverPublicKey,
            clientSecretSeed: stranger.seed,
            receiverIdentifier: scenario.credentials.receiverIdentifier,
            clientIdentifier: scenario.credentials.clientIdentifier
        )

        do {
            _ = try await verify(scenario, credentials: wrongClient)
            Issue.record("la session aurait dû échouer")
        } catch AirPlay2PairingSession.Failure.receiverRejected(.authentication, _) {
            // attendu
        } catch {
            Issue.record("mauvaise erreur : \(error)")
        }
    }

    /// Le canal chiffré doit fonctionner aussi après un `pair-verify` : les clés dérivent du
    /// secret X25519, pas d'une clé SRP.
    @Test("Une session complète tient sur les clés du pair-verify")
    func sessionComplete() async throws {
        let scenario = try await paired()
        defer { scenario.receiver.stop() }

        let harness = try SenderHarness(
            receiver: scenario.receiver, credentials: scenario.credentials)
        defer { harness.feeder.stop() }

        try await harness.sender.start(volume: -20)
        #expect(await waitUntil { scenario.receiver.audioPackets(inSession: 0).count >= 20 })
        await harness.sender.stop()

        let key = scenario.receiver.streamKey(inSession: 0)
        let packet = try #require(scenario.receiver.audioPackets(inSession: 0).first)
        _ = try FakeAirPlay2Receiver.decryptAudio(packet, key: key)
        #expect(scenario.receiver.requests().contains { $0.method == "RECORD" && $0.wasEncrypted })
    }
}
