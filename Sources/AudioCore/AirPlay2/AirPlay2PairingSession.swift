import Foundation
import OSLog

/// Déroule le `pair-setup` d'AirPlay 2 et produit les clés de session.
///
/// ## Chemin retenu : le pair-setup **transitoire**
///
/// Le CDC 4.4 décrit un pairing avec code à 4 chiffres, réalisé une fois via pyatv, dont on
/// conserve des credentials long terme rejoués ensuite par `pair-verify`. **Le récepteur de
/// test n'emprunte pas ce chemin** : il annonce le bit de fonctionnalité 48
/// (`TransientPairing`) et n'arme pas le bit 43 (`SystemPairing`). pyatv le confirme en
/// rapportant `Pairing: NotNeeded`, et `atvremote pair` échoue contre lui.
///
/// En mode transitoire, le dialogue s'arrête à **M4** : les deux côtés dérivent une clé de
/// session depuis SRP-6a, activent le chiffrement, et **n'échangent aucune clé long terme**.
/// Il n'y a donc aucun credential à extraire ni à persister — l'absence de fichier de
/// credentials au jalon 3 est une conséquence du protocole, pas un oubli.
///
/// La décision est tracée dans le vault (`decisions/003-pairing-transitoire-airplay2.md`).
/// Les primitives du chemin long terme (Ed25519, X25519) sont implémentées et testées : les
/// ajouter le jour où un vrai Apple TV les réclamera est une extension, pas une réécriture.
///
/// ## Invariant section 12
///
/// Ce type ne connaît ni la capture, ni le sender RAOP. Il ne parle qu'au récepteur qu'on
/// lui désigne, et ne partage aucun état avec une autre sortie.
public actor AirPlay2PairingSession {

    public enum Failure: Error, CustomStringConvertible {
        /// Le récepteur n'annonce pas le pair-setup transitoire.
        ///
        /// Refuser ici plutôt que plus loin est délibéré : sans ce garde-fou, l'échec se
        /// manifesterait par un message cryptographique incompréhensible plusieurs étapes
        /// plus tard.
        case transientPairingUnsupported(features: UInt64)
        /// Le récepteur a renvoyé un TLV d'erreur.
        case receiverRejected(PairingTLV8.PairingError, step: String)
        /// Réponse illisible ou incomplète.
        case malformedResponse(step: String)
        /// Étape inattendue dans la réponse (M2 attendu, autre chose reçu).
        case unexpectedState(step: String)
        /// Le récepteur ne s'est pas identifié comme celui avec qui l'appairage a été fait.
        case receiverIdentityMismatch
        /// La signature du récepteur ne vérifie pas avec sa clé publique long terme.
        case receiverSignatureInvalid

        public var description: String {
            switch self {
            case let .transientPairingUnsupported(features):
                return """
                    le récepteur n'annonce pas le pair-setup transitoire \
                    (features=0x\(String(features, radix: 16)), bit 48 absent) — \
                    un appairage persistant avec code est probablement exigé
                    """
            case let .receiverRejected(error, step):
                return "récepteur : \(error.description) (étape \(step))"
            case let .malformedResponse(step):
                return "réponse de pairing illisible à l'étape \(step)"
            case let .unexpectedState(step):
                return "étape de pairing inattendue dans la réponse (\(step))"
            case .receiverIdentityMismatch:
                return "le récepteur renvoie un identifiant qui n'est pas celui appairé"
            case .receiverSignatureInvalid:
                return "signature du récepteur invalide — credentials périmés ou usurpation"
            }
        }
    }

    /// Clés dérivées à l'issue du pair-setup, pour chiffrer le canal de contrôle.
    ///
    /// Les deux sens ont des clés **différentes** : ce que nous écrivons est chiffré avec la
    /// clé « write » du récepteur, ce que nous lisons avec sa clé « read ». Les intervertir
    /// donne un canal qui échoue au premier bloc, sur une étiquette Poly1305 invalide.
    public struct SessionKeys: Sendable {
        /// Clé dont le récepteur se sert pour **lire** ce que nous écrivons.
        public let outgoing: Data
        /// Clé dont le récepteur se sert pour **écrire** ce que nous lisons.
        public let incoming: Data
        /// Clé de session SRP brute, conservée pour le chiffrement du flux audio.
        public let sharedSecret: Data
    }

    /// Mot de passe du pair-setup transitoire.
    ///
    /// En transitoire, aucun code n'est affiché par le récepteur : la spécification HomeKit
    /// et toutes les implémentations (dont celle du mock) emploient la valeur fixe `3939`.
    /// Ce n'est pas un secret, seulement une constante du protocole.
    public static let transientPassword = "3939"

    private let client: RTSPClient
    private let device: AirPlay2Device
    private let log = AudioLog.airplay2

    public init(client: RTSPClient, device: AirPlay2Device) {
        self.client = client
        self.device = device
    }

    /// Exécute le pair-setup transitoire (M1 → M4) et renvoie les clés de session.
    public func performTransientPairSetup() async throws -> SessionKeys {
        guard device.supportsTransientPairing else {
            throw Failure.transientPairingUnsupported(features: device.features)
        }

        log.info("pair-setup transitoire vers \(self.device.serviceName, privacy: .public)")

        // Pas de `/pair-pin-start` ici, contrairement à pyatv qui l'envoie toujours.
        //
        // Cette requête demande au récepteur d'**afficher un code d'appairage**. En
        // transitoire, aucun code n'est saisi : elle est donc inutile, et les HomePod
        // acceptent le pair-setup sans elle (vérifié le 2026-08-11). Sur un Apple TV, en
        // revanche, elle fait apparaître un code à l'écran à chaque tentative — un code que
        // rien ne consomme, puisque le transitoire y est de toute façon refusé en 470.
        // L'envoyer revenait à polluer l'écran de l'utilisateur pour rien.

        // --- M1 : demande de démarrage SRP ---
        // L'ordre des éléments (state, method, flags) est celui qu'emploient les senders
        // existants ; certains récepteurs y sont sensibles.
        let m1 = PairingTLV8.encode([
            (.state, PairingTLV8.byte(PairingTLV8.State.m1.rawValue)),
            (.method, PairingTLV8.byte(PairingTLV8.Method.pairSetup.rawValue)),
            (.flags, PairingTLV8.flagsValue(.transient)),
        ])
        let m2Items = try await exchange(m1, step: "M1")

        guard PairingTLV8.state(in: m2Items) == .m2 else {
            throw Failure.unexpectedState(step: "M2")
        }
        guard let salt = m2Items[.salt],
            let serverPublicKey = m2Items[.publicKey]
        else {
            throw Failure.malformedResponse(step: "M2")
        }
        log.debug("M2 reçu : sel \(salt.count) o, clé publique serveur \(serverPublicKey.count) o")

        // --- M3 : preuve du client ---
        let srp = try SRPClient(password: Self.transientPassword)
        let publicA = try srp.startAuthentication()
        let proofM1 = try srp.processChallenge(salt: salt, serverPublicKey: serverPublicKey)

        let m3 = PairingTLV8.encode([
            (.state, PairingTLV8.byte(PairingTLV8.State.m3.rawValue)),
            (.publicKey, publicA),
            (.proof, proofM1),
        ])
        let m4Items = try await exchange(m3, step: "M3")

        guard PairingTLV8.state(in: m4Items) == .m4 else {
            throw Failure.unexpectedState(step: "M4")
        }
        guard let serverProof = m4Items[.proof] else {
            throw Failure.malformedResponse(step: "M4")
        }

        // Authentifie le **récepteur** : sans cette vérification, n'importe quel
        // interlocuteur se disant Apple TV serait accepté.
        try srp.verifyServerProof(serverProof)
        let sharedSecret = try srp.sessionKey()

        log.info("pair-setup transitoire abouti (clé de session \(sharedSecret.count) o)")

        // Le pairing s'arrête ici en transitoire : la clé de session SRP devient
        // directement la racine du chiffrement du canal de contrôle.
        return SessionKeys(
            outgoing: HKDF512.derive(
                secret: sharedSecret,
                salt: AirPlay2ControlChannel.cipherSalt,
                info: AirPlay2ControlChannel.writeKeyInfo
            ),
            incoming: HKDF512.derive(
                secret: sharedSecret,
                salt: AirPlay2ControlChannel.cipherSalt,
                info: AirPlay2ControlChannel.readKeyInfo
            ),
            sharedSecret: sharedSecret
        )
    }

    /// Rejoue un appairage système déjà acquis et produit les clés de session.
    ///
    /// C'est le pendant du transitoire pour un récepteur qui exige l'appairage persistant —
    /// un Apple TV, typiquement, qui refuse le transitoire en `470`. Aucun code n'est
    /// demandé : les credentials remplacent la saisie.
    ///
    /// Déroulé (référence : `pyatv/auth/hap_srp.py`, `verify1`/`verify2`) :
    ///
    /// 1. M1 — on envoie une clé publique X25519 **éphémère**, tirée pour cette session.
    /// 2. M2 — le récepteur renvoie la sienne et un sous-TLV chiffré.
    /// 3. Le secret partagé X25519 donne, par HKDF, la clé qui déchiffre ce sous-TLV. On y
    ///    trouve l'identifiant du récepteur et sa signature, qu'on vérifie avec sa clé
    ///    publique long terme. **C'est cette étape qui authentifie le récepteur** : sans
    ///    elle, n'importe quelle machine du réseau pourrait se faire passer pour lui.
    /// 4. M3 — on signe à notre tour et on renvoie le tout chiffré.
    ///
    /// Les clés du canal de contrôle dérivent du **secret X25519**, pas d'une clé SRP :
    /// c'est la différence de fond avec le transitoire.
    public func performPairVerify(credentials: HapCredentials) async throws -> SessionKeys {
        log.info("pair-verify vers \(self.device.serviceName, privacy: .public)")

        let ephemeral = try Curve25519KeyPair()

        let m1 = PairingTLV8.encode([
            (.state, PairingTLV8.byte(PairingTLV8.State.m1.rawValue)),
            (.publicKey, ephemeral.publicKey),
        ])
        let m2 = try await exchange(m1, step: "verify-M1", uri: "/pair-verify")

        guard let receiverPublic = m2[.publicKey], let sealed = m2[.encryptedData] else {
            throw Failure.malformedResponse(step: "verify-M2")
        }

        let shared = try ephemeral.sharedSecret(withPublicKey: receiverPublic)
        let sessionKey = HKDF512.derive(
            secret: shared,
            salt: HKDF512.Label.verifyEncryptSalt,
            info: HKDF512.Label.verifyEncryptInfo
        )
        let cipher = try ChaChaPoly1305(key: sessionKey)

        let plain = try cipher.open(sealed, nonce: Self.nonce("PV-Msg02"))
        guard let inner = PairingTLV8.decode(plain),
            let identifier = inner[.identifier],
            let signature = inner[.signature]
        else {
            throw Failure.malformedResponse(step: "verify-M2")
        }
        // L'identifiant renvoyé n'est **pas** comparé pour égalité stricte.
        //
        // Un Apple TV renvoie ici son identifiant de pairing (`pi` de l'annonce Bonjour,
        // `7358e914-…`), alors que pyatv enregistre dans ses credentials l'identifiant sous
        // lequel *lui* désigne l'appareil (`96A1F186-…`, dérivé de l'adresse matérielle). Les
        // deux sont légitimes et ne coïncident pas : exiger l'égalité rejetait des
        // credentials parfaitement valides.
        //
        // Ce n'est de toute façon pas ce contrôle qui authentifie le récepteur, mais la
        // **signature** vérifiée juste après : seul le détenteur de la clé privée associée à
        // `receiverPublicKey` peut la produire. L'identifiant n'est qu'un repère, et un écart
        // se journalise sans faire échouer la session.
        if identifier != credentials.receiverIdentifier {
            log.debug("""
                identifiant du récepteur différent de celui mémorisé \
                (reçu \(String(data: identifier, encoding: .utf8) ?? identifier.hexEncoded, privacy: .public)) \
                — sans conséquence, la signature fait foi
                """)
        }

        // Le récepteur signe : sa clé publique de session ‖ son identifiant ‖ la nôtre.
        let signedByReceiver = receiverPublic + identifier + ephemeral.publicKey
        guard try Ed25519KeyPair.verify(
            signature: signature, message: signedByReceiver,
            publicKey: credentials.receiverPublicKey
        ) else {
            throw Failure.receiverSignatureInvalid
        }

        // Nous signons le miroir : notre clé publique ‖ notre identifiant ‖ la sienne.
        let client = try Ed25519KeyPair(seed: credentials.clientSecretSeed)
        let signedByClient = ephemeral.publicKey + credentials.clientIdentifier + receiverPublic
        let proof = PairingTLV8.encode([
            (.identifier, credentials.clientIdentifier),
            (.signature, client.sign(signedByClient)),
        ])

        let m3 = PairingTLV8.encode([
            (.state, PairingTLV8.byte(PairingTLV8.State.m3.rawValue)),
            (.encryptedData, try cipher.seal(proof, nonce: Self.nonce("PV-Msg03"))),
        ])
        _ = try await exchange(m3, step: "verify-M3", uri: "/pair-verify")

        log.info("pair-verify abouti (secret partagé \(shared.count) o)")
        return SessionKeys(
            outgoing: HKDF512.derive(
                secret: shared,
                salt: AirPlay2ControlChannel.cipherSalt,
                info: AirPlay2ControlChannel.writeKeyInfo
            ),
            incoming: HKDF512.derive(
                secret: shared,
                salt: AirPlay2ControlChannel.cipherSalt,
                info: AirPlay2ControlChannel.readKeyInfo
            ),
            sharedSecret: shared
        )
    }

    /// Nonce ChaCha20-Poly1305 d'un message de pairing.
    ///
    /// HAP nomme ses nonces par une chaîne de 8 octets (`PV-Msg02`) ; le chiffre en attend
    /// 12. Les quatre octets manquants sont des zéros **en tête**, comme pour le compteur du
    /// canal de contrôle.
    private static func nonce(_ label: String) -> Data {
        Data(repeating: 0, count: 4) + Data(label.utf8)
    }

    /// Poste un message TLV8 sur `/pair-setup` et décode la réponse.
    private func exchange(
        _ body: Data, step: String, uri: String = "/pair-setup"
    ) async throws -> [PairingTLV8.Tag: Data] {
        let request = RTSPRequest(
            method: "POST",
            uri: uri,
            headers: [
                ("Content-Length", String(body.count)),
                ("User-Agent", "AirPlay/320.20"),
                ("Connection", "keep-alive"),
                // Indique au récepteur le mode de pairing employé. 4 = transitoire.
                ("X-Apple-HKP", "4"),
                ("Content-Type", "application/octet-stream"),
            ],
            body: body,
            // Le pairing sort du cadre RTSP : pyatv y poste en HTTP/1.1, sans CSeq.
            protocolVersion: "HTTP/1.1"
        )
        let response = try await client.send(request)

        guard let items = PairingTLV8.decode(response.body) else {
            throw Failure.malformedResponse(step: step)
        }
        if let error = PairingTLV8.error(in: items) {
            throw Failure.receiverRejected(error, step: step)
        }
        return items
    }
}
