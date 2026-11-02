import Foundation
import OSLog

/// Séquence RTSP d'une session AirPlay 2, du `SETUP` au `TEARDOWN`.
///
/// ## Ce qui change par rapport à RAOP (jalon 2)
///
/// Le socle de transport est le même (`RTSPClient`, `UDPChannel`, `RTPPacketBuilder`), mais
/// la négociation diffère sur trois points :
///
/// 1. **Pas d'`ANNOUNCE`, pas de SDP.** Les paramètres passent par des **plists binaires**
///    dans le corps des requêtes, et non par une description SDP en texte.
/// 2. **Deux `SETUP` successifs**, et non un seul :
///    - le premier, **sans** clé `streams`, ouvre la session et fait répondre au récepteur
///      son `eventPort` ;
///    - le second, **avec** `streams`, ouvre le flux audio et rend `dataPort` et
///      `controlPort`.
///    L'ordre observé dans une session pyatv de référence contre ce même mock est :
///    `SETUP` → `SETUP` → `SET_PARAMETER` (volume) → `RECORD` → `TEARDOWN`.
/// 3. **Le canal de contrôle est chiffré** dès la fin du pair-setup (voir
///    `AirPlay2ControlChannel`), là où RAOP reste en clair.
///
/// ## Invariant section 12
///
/// Cet acteur ne connaît ni la capture, ni le sender RAOP. Il ne détient aucun tampon PCM :
/// il négocie une session et rend les ports obtenus, rien de plus.
public actor AirPlay2Session {

    public enum Failure: Error, CustomStringConvertible {
        case malformedResponse(step: String)
        case missingField(String, step: String)

        public var description: String {
            switch self {
            case let .malformedResponse(step):
                return "réponse illisible du récepteur à l'étape \(step)"
            case let .missingField(field, step):
                return "champ « \(field) » absent de la réponse à l'étape \(step)"
            }
        }
    }

    /// Format audio négocié, tel qu'AirPlay 2 le code en bits.
    ///
    /// Valeurs relevées dans `AirplayAudFmt` du récepteur. Le projet demande le PCM 44,1 kHz,
    /// comme pyatv : la capture livrant du 48 kHz, la conversion reste nécessaire.
    public enum AudioFormat: UInt32 {
        case alac44100_16_2 = 0x0004_0000  // 1 << 18
        case pcm44100_16_2 = 0x0000_0800  // 1 << 11
    }

    /// Type de flux RTP. `realtime` est le mode « direct » : le récepteur joue au fil de
    /// l'eau avec un tampon court, ce qui correspond à la diffusion du son système.
    /// `buffered` (103) sert à envoyer un morceau entier d'avance, sans objet ici.
    public enum StreamType: UInt32 {
        case realtime = 96
        case buffered = 103
    }

    /// Ports rendus par le récepteur à l'issue des deux `SETUP`.
    ///
    /// Comme en RAOP (piège relevé au jalon 2), **ce sont ces valeurs qui font foi**, jamais
    /// celles suggérées dans la requête.
    public struct Endpoints: Sendable {
        /// Port du canal d'événements, rendu par le premier `SETUP`.
        public let eventPort: UInt16
        /// Port de données audio (RTP), rendu par le second `SETUP`.
        public let dataPort: UInt16
        /// Port de contrôle (retransmissions, synchronisation).
        public let controlPort: UInt16
        /// Identifiant de flux attribué par le récepteur, à rappeler au `TEARDOWN`.
        public let streamID: UInt32
        /// Valeur brute d'`audioBufferSize` annoncée par le récepteur.
        ///
        /// **Ce n'est pas une latence, et l'unité n'est pas établie.** On aurait aimé y voir
        /// l'équivalent AirPlay 2 de l'en-tête `Audio-Latency` de RAOP — la part de latence
        /// interne au récepteur, celle qu'aucune mesure de trajet ne révèle (CDC 4.5). Mais
        /// le mock rend 8 388 608, soit exactement 8 MiB : une **taille de tampon en octets**,
        /// qui vaudrait 190 secondes si on la lisait en trames. Elle est donc rapportée telle
        /// quelle, sans conversion, et n'alimente aucun calcul.
        ///
        /// À trancher contre un vrai Apple TV ; en attendant, la latence AirPlay 2 réellement
        /// utilisée est celle que **nous** annonçons dans les paquets de synchronisation.
        public let audioBufferSize: Int
    }

    /// Trames par paquet. 352 comme en RAOP : c'est la valeur qu'attendent les récepteurs
    /// AirPlay, et elle donne 7,98 ms de son par paquet à 44,1 kHz.
    public static let framesPerPacket = 352

    /// Identité du contrôleur distant, portée à l'identique par **toutes** les requêtes RTSP de la
    /// session.
    ///
    /// ## Pourquoi c'est une règle, pas un détail
    ///
    /// Le HomePod (firmware 27.2, `srcvers=1005.13.2`) rattache la session au `Client-Instance` et
    /// au `DACP-ID` de son premier `SETUP`, et refuse en `403 Forbidden` toute requête qui en porte
    /// d'autres. Défaut relevé sur le matériel : seuls les `SETUP` et `/feedback` portaient ces
    /// en-têtes, si bien que `SET_PARAMETER`, `RECORD` et `TEARDOWN` partaient avec ceux que
    /// `RTSPClient` ajoute de lui-même (`User-Agent: AirPlayMultiOutput/1.0` et son propre
    /// `Client-Instance`) : pour le HomePod, un autre contrôleur que celui de la session. Le volume,
    /// émis avant le `RECORD`, recevait `403` à chaque session.
    ///
    /// pyatv les pose sur chacune de ses requêtes de session (`support/rtsp.py`, `exchange`), et le
    /// HomePod les accepte toutes. Ils sont donc définis ici, une fois, et ajoutés par
    /// ``exchange(_:uri:headers:body:timeout:)``, seul chemin vers le client RTSP : une requête
    /// ajoutée plus tard les portera sans qu'on ait à y penser. Le `User-Agent` et le
    /// `Client-Instance` étant fournis, `RTSPClient` n'ajoute pas les siens : aucun en-tête ne part
    /// en double.
    struct ControllerIdentity: Sendable, Equatable {
        static let userAgent = "AirPlay/550.10"

        /// Identifiant de contrôleur distant, en hexadécimal 64 bits : `DACP-ID` et
        /// `Client-Instance`.
        let dacpID: String
        /// Jeton `Active-Remote`, entier 32 bits.
        let activeRemote: String

        static func random() -> ControllerIdentity {
            ControllerIdentity(
                dacpID: String(UInt64.random(in: .min ... .max), radix: 16).uppercased(),
                activeRemote: String(UInt32.random(in: .min ... .max))
            )
        }

        /// Les quatre en-têtes, dans l'ordre de pyatv.
        var headers: [(name: String, value: String)] {
            [
                ("User-Agent", Self.userAgent),
                ("DACP-ID", dacpID),
                ("Active-Remote", activeRemote),
                ("Client-Instance", dacpID),
            ]
        }
    }

    /// Ne s'emploie qu'à travers ``exchange(_:uri:headers:body:timeout:)``, qui pose l'identité
    /// du contrôleur.
    private let client: RTSPClient
    private let device: AirPlay2Device
    private let log = AudioLog.airplay2

    /// URI de session, construite une fois et **réutilisée telle quelle** pour toutes les
    /// requêtes suivantes. Le jalon 2 a montré qu'un `TEARDOWN` portant une URI reconstruite
    /// est couramment rejeté par le matériel réel, laissant la session bloquée côté
    /// récepteur — shairport-sync le tolérait, rien ne dit qu'un Apple TV le fera.
    ///
    /// Défaut corrigé le 2026-08-11 : elle était bâtie sur l'adresse **du récepteur**, alors
    /// que la convention — suivie par notre propre sender RAOP comme par pyatv — veut celle du
    /// **client**. Sur un récepteur joint en IPv6 lien-local, cela produisait de surcroît un
    /// littéral sans crochets, donc une URI malformée. Elle est donc fixée à la connexion,
    /// pas à l'initialisation, puisque l'adresse locale n'est connue qu'à ce moment.
    private var sessionURI: String

    /// Clé et IV du flux audio, tirés au sort par session.
    ///
    /// En pairing transitoire il n'y a pas de FairPlay : la clé de flux est simplement
    /// transmise au récepteur dans le `SETUP`, protégée par le chiffrement du canal de
    /// contrôle — c'est précisément ce que ce chiffrement sert à protéger.
    public let streamKey: Data
    public let streamIV: Data

    /// Identifiant du flux, repris de l'identifiant de session comme le fait pyatv. Un
    /// récepteur réel s'en sert pour rattacher le flux audio à la session ouverte.
    private let streamConnectionID: Int
    /// Tirée au sort par session, comme chez pyatv.
    let controller = ControllerIdentity.random()

    public init(client: RTSPClient, device: AirPlay2Device) {
        self.client = client
        self.device = device
        // Sur **32 bits**, comme pyatv (`randrange(2**32)`) : un identifiant plus large est
        // accepté par le mock mais rien ne dit qu'un récepteur réel le tolère.
        let sessionIdentifier = Int.random(in: 1...Int(UInt32.max))
        self.streamConnectionID = sessionIdentifier
        // Valeur d'attente : `setup` la remplace par l'adresse locale réelle.
        self.sessionURI = "rtsp://0.0.0.0/\(sessionIdentifier)"

        var key = Data(count: 32)
        var iv = Data(count: 16)
        var generator = SystemRandomNumberGenerator()
        for index in 0..<32 { key[index] = UInt8.random(in: .min ... .max, using: &generator) }
        for index in 0..<16 { iv[index] = UInt8.random(in: .min ... .max, using: &generator) }
        streamKey = key
        streamIV = iv
    }

    /// Ouvre la session et le flux audio (les deux `SETUP`), puis renvoie les ports obtenus.
    /// - Parameters:
    ///   - timingPort: port UDP **local** d'où partiront les échanges d'horloge. Le mock s'en
    ///     passait ; le firmware Apple réel refuse le `SETUP` en `400` sans lui, puisqu'il n'a
    ///     alors aucune adresse où interroger notre horloge.
    ///   - controlPort: port UDP **local** du canal de contrôle, annoncé dans le flux.
    public func setup(
        format: AudioFormat = .pcm44100_16_2,
        streamType: StreamType = .realtime,
        timingPort: UInt16,
        controlPort: UInt16
    ) async throws -> Endpoints {
        // L'URI de session porte l'adresse **locale**, connue seulement une fois connecté. Un
        // littéral IPv6 doit être encadré de crochets, sans quoi l'URI est malformée.
        let localAddress = await client.localAddress
        let host = localAddress.contains(":") ? "[\(localAddress)]" : localAddress
        sessionURI = "rtsp://\(host)/\(streamConnectionID)"

        // --- SETUP 1 : session. Pas de clé `streams` : c'est ce qui le distingue. ---
        //
        // Le jeu de clés suit celui de pyatv (`protocols/raop/protocols/airplayv2.py`), qui
        // est validé contre du matériel Apple. Les champs d'identité (`osName`, `model`…) ne
        // sont pas décoratifs : un récepteur réel refuse un `SETUP` incomplet en `400`, là où
        // airplay2-receiver acceptait un plist minimal.
        let sessionBody: [String: Any] = [
            "deviceID": deviceIdentifier,
            "sessionUUID": UUID().uuidString.uppercased(),
            "name": "AirPlayMultiOutput",
            "model": "iPhone14,3",
            "macAddress": deviceIdentifier,
            "sourceVersion": "690.7.1",
            "osName": "iPhone OS",
            "osVersion": "16.5",
            "osBuildVersion": "20F66",
            "timingPort": Int(timingPort),
            // Horloge : `NTP` correspond au mode temps réel (CDC 4.5).
            "timingProtocol": "NTP",
            "isMultiSelectAirPlay": true,
            "groupContainsGroupLeader": false,
            "senderSupportsRelay": false,
            "statsCollectionEnabled": false,
        ]
        let sessionResponse = try await sendPlist(sessionBody, method: "SETUP", step: "SETUP session")
        guard let eventPort = sessionResponse["eventPort"] as? Int else {
            throw Failure.missingField("eventPort", step: "SETUP session")
        }
        log.debug("SETUP session : eventPort=\(eventPort)")

        // --- SETUP 2 : flux audio. ---
        // Même remarque que pour le `SETUP` de session : jeu de clés calqué sur pyatv.
        // `ct: 1` désigne le PCM brut ; `shiv` n'y figure pas — le chiffrement du flux dérive
        // tout de `shk`, et envoyer un IV séparé n'apporte rien au récepteur.
        let streamBody: [String: Any] = [
            "streams": [
                [
                    "type": streamType.rawValue,
                    "audioFormat": format.rawValue,
                    "audioMode": "default",
                    "ct": 1,
                    "isMedia": true,
                    "sr": 44_100,
                    "spf": Self.framesPerPacket,
                    "shk": streamKey,
                    "controlPort": Int(controlPort),
                    "latencyMin": 11_025,
                    "latencyMax": 88_200,
                    "supportsDynamicStreamID": false,
                    "streamConnectionID": streamConnectionID,
                ]
            ]
        ]
        let streamResponse = try await sendPlist(streamBody, method: "SETUP", step: "SETUP flux")
        guard let streams = streamResponse["streams"] as? [[String: Any]],
            let stream = streams.first
        else {
            throw Failure.missingField("streams", step: "SETUP flux")
        }
        guard let dataPort = stream["dataPort"] as? Int else {
            throw Failure.missingField("dataPort", step: "SETUP flux")
        }
        let controlPort = stream["controlPort"] as? Int ?? 0
        let streamID = stream["streamID"] as? Int ?? 0
        let audioBufferSize = stream["audioBufferSize"] as? Int ?? 0

        log.info(
            """
            SETUP flux : dataPort=\(dataPort) controlPort=\(controlPort) streamID=\(streamID) \
            audioBufferSize=\(audioBufferSize)
            """
        )

        return Endpoints(
            eventPort: UInt16(truncatingIfNeeded: eventPort),
            dataPort: UInt16(truncatingIfNeeded: dataPort),
            controlPort: UInt16(truncatingIfNeeded: controlPort),
            streamID: UInt32(truncatingIfNeeded: streamID),
            audioBufferSize: audioBufferSize
        )
    }

    /// `RECORD` : le récepteur commence à attendre l'audio.
    ///
    /// `RTP-Info` porte le premier numéro de séquence et l'horodatage initial, comme en
    /// RAOP : c'est le point d'ancrage temporel du flux.
    ///
    /// - Returns: `Audio-Latency` annoncée par le récepteur, en trames, ou `nil` s'il n'annonce rien.
    ///   Journalisée dans les deux cas : c'est ce qui établira si les HomePod en donnent une.
    @discardableResult
    public func record(startSequence: UInt16, startTimestamp: UInt32) async throws -> Int? {
        let response = try await exchange(
            "RECORD",
            headers: [
                ("RTP-Info", "seq=\(startSequence);rtptime=\(startTimestamp)"),
                ("Content-Length", "0"),
            ]
        )
        log.info("RECORD accepté (seq=\(startSequence) rtptime=\(startTimestamp))")
        guard let announced = response.headers["audio-latency"] else {
            log.info("RECORD : pas d'Audio-Latency annoncée")
            return nil
        }
        log.info("RECORD : Audio-Latency annoncée \(announced, privacy: .public) trames")
        return Int(announced.trimmingCharacters(in: .whitespaces))
    }

    /// Maintien de session : `POST /feedback`, sans corps.
    ///
    /// pyatv en émet un toutes les 2 s dès avant le `RECORD` (`airplayv2.py`,
    /// `_feedback_task_loop`), « pour que l'appareil distant ne ferme pas la connexion », et c'est
    /// aussi la cadence d'iOS. Sur le fil c'est sa requête à l'identique : RTSP/1.0, `CSeq`, et les
    /// en-têtes d'identité du contrôleur, sans `Content-Length`.
    ///
    /// - Parameter timeout: court, pour ne pas retenir les autres requêtes, qui passent après lui sur
    ///   la même connexion. Une réponse qui ne vient pas n'a pas d'autre conséquence : voir
    ///   `AirPlay2Sender.runKeepAlive`.
    public func sendFeedback(timeout: Duration = .seconds(4)) async throws {
        _ = try await exchange("POST", uri: "/feedback", timeout: timeout)
    }

    /// Valeur de volume réellement émise, pour une consigne quelconque.
    ///
    /// Le protocole ne connaît que `-30…0` et `-144` pour le silence. Sous `-30`, pyatv considère
    /// le son coupé (`dbfs_to_pct`), d'où le même choix ici : monter à `-30` jouerait plus fort
    /// que ce qui est demandé. Une consigne `NaN` coupe aussi — c'est la seule valeur sûre pour un
    /// réglage de volume indéterminé. Les valeurs infimes sont ramenées à `0` : Swift les
    /// écrirait `-5e-05`, une notation qu'aucun récepteur n'a la garantie de lire.
    static func wireVolume(_ decibels: Float) -> Float {
        guard !decibels.isNaN, decibels >= -30 else { return -144 }
        if decibels > -0.001 { return 0 }
        return decibels
    }

    /// Règle le volume, en décibels.
    ///
    /// Échelle AirPlay : `-144` coupe le son, `-30` à `0` couvre la plage utile. Identique
    /// à RAOP, y compris le format texte du corps.
    public func setVolume(_ decibels: Float) async throws {
        let body = Data("volume: \(Self.wireVolume(decibels))\r\n".utf8)
        _ = try await exchange(
            "SET_PARAMETER",
            headers: [
                ("Content-Type", "text/parameters"),
                ("Content-Length", String(body.count)),
            ],
            body: body
        )
        log.debug("volume réglé à \(decibels) dB")
    }

    /// `TEARDOWN` : ferme la session proprement.
    ///
    /// Émis avec l'URI de session d'origine (voir ``sessionURI``). Les erreurs sont
    /// journalisées mais non propagées : à ce stade la diffusion est finie, et faire échouer
    /// l'arrêt n'apporterait rien à l'appelant.
    public func teardown() async {
        do {
            // Délai court, même raison qu'en RAOP : le récepteur ferme couramment la
            // connexion dès le TEARDOWN reçu, sans répondre.
            _ = try await exchange(
                "TEARDOWN", headers: [("Content-Length", "0")], timeout: .seconds(2))
            log.info("TEARDOWN accepté")
        } catch {
            log.error("TEARDOWN en échec : \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: - Plists

    /// Identifiant matériel **de l'émetteur**, au format d'une adresse MAC.
    ///
    /// Défaut corrigé le 2026-08-11 : cette propriété renvoyait le `deviceid` lu dans
    /// l'annonce Bonjour du **récepteur**, si bien que le `SETUP` lui annonçait sa propre
    /// adresse comme étant la nôtre. airplay2-receiver l'acceptait ; un HomePod réel refuse
    /// la session en `400`. La valeur est tirée au sort par session, avec le bit « administré
    /// localement » posé (0x02) et le bit multicast à zéro, comme le veut IEEE 802.
    private let deviceIdentifier: String = {
        var generator = SystemRandomNumberGenerator()
        var bytes = (0..<6).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        bytes[0] = (bytes[0] | 0x02) & 0xFE
        return bytes.map { String(format: "%02X", $0) }.joined(separator: ":")
    }()

    /// Sérialise un plist binaire, l'envoie, et analyse la réponse.
    private func sendPlist(
        _ body: [String: Any],
        method: String,
        step: String
    ) async throws -> [String: Any] {
        let payload = try PropertyListSerialization.data(
            fromPropertyList: body, format: .binary, options: 0
        )
        log.info("→ \(step, privacy: .public) (\(payload.count) octets de plist)")
        // Pas d'en-tête `X-Apple-*` ici : pyatv les réserve à `/play` et consorts, et n'en met
        // aucun sur ses `SETUP` — vérifié dans sa trace de debug contre ce HomePod, où le `SETUP`
        // ne porte que `CSeq`, ces deux-là et l'identité du contrôleur.
        let response = try await exchange(
            method,
            headers: [
                ("Content-Type", "application/x-apple-binary-plist"),
                ("Content-Length", String(payload.count)),
            ],
            body: payload
        )

        guard !response.body.isEmpty else { return [:] }
        guard let parsed = try? PropertyListSerialization.propertyList(
            from: response.body, options: [], format: nil
        ) as? [String: Any] else {
            throw Failure.malformedResponse(step: step)
        }
        return parsed
    }

    // MARK: - Émission

    /// Seul chemin d'une requête de session vers le récepteur : il y ajoute l'identité du
    /// contrôleur (voir ``ControllerIdentity``), après les en-têtes propres à la requête.
    ///
    /// - Parameter uri: `nil` pour l'URI de session, la seule que le matériel accepte sur
    ///   `SETUP`, `SET_PARAMETER`, `RECORD` et `TEARDOWN`.
    private func exchange(
        _ method: String,
        uri: String? = nil,
        headers: [(name: String, value: String)] = [],
        body: Data = Data(),
        timeout: Duration = .seconds(10)
    ) async throws -> RTSPResponse {
        let request = RTSPRequest(
            method: method,
            uri: uri ?? sessionURI,
            headers: headers + controller.headers,
            body: body
        )
        return try await client.send(request, timeout: timeout)
    }
}
