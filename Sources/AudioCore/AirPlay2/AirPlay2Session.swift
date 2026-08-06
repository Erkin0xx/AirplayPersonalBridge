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
    /// Valeurs relevées dans `AirplayAudFmt` du récepteur. Le projet demande
    /// `ALAC_44100_16_2`, ce qui permet de réutiliser tel quel l'encodeur ALAC et le
    /// rééchantillonneur du jalon 2 — la capture livrant du 48 kHz, la conversion vers
    /// 44,1 kHz reste nécessaire dans les deux cas.
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

    private let client: RTSPClient
    private let device: AirPlay2Device
    private let log = AudioLog.airplay2

    /// URI de session, construite une fois et **réutilisée telle quelle** pour toutes les
    /// requêtes suivantes. Le jalon 2 a montré qu'un `TEARDOWN` portant une URI reconstruite
    /// est couramment rejeté par le matériel réel, laissant la session bloquée côté
    /// récepteur — shairport-sync le tolérait, rien ne dit qu'un Apple TV le fera.
    private let sessionURI: String

    /// Clé et IV du flux audio, tirés au sort par session.
    ///
    /// En pairing transitoire il n'y a pas de FairPlay : la clé de flux est simplement
    /// transmise au récepteur dans le `SETUP`, protégée par le chiffrement du canal de
    /// contrôle — c'est précisément ce que ce chiffrement sert à protéger.
    public let streamKey: Data
    public let streamIV: Data

    public init(client: RTSPClient, device: AirPlay2Device) {
        self.client = client
        self.device = device
        self.sessionURI = "rtsp://\(device.host)/\(UInt64.random(in: 1...UInt64.max))"

        var key = Data(count: 32)
        var iv = Data(count: 16)
        var generator = SystemRandomNumberGenerator()
        for index in 0..<32 { key[index] = UInt8.random(in: .min ... .max, using: &generator) }
        for index in 0..<16 { iv[index] = UInt8.random(in: .min ... .max, using: &generator) }
        streamKey = key
        streamIV = iv
    }

    /// Ouvre la session et le flux audio (les deux `SETUP`), puis renvoie les ports obtenus.
    public func setup(
        format: AudioFormat = .alac44100_16_2,
        streamType: StreamType = .realtime
    ) async throws -> Endpoints {
        // --- SETUP 1 : session. Pas de clé `streams` : c'est ce qui le distingue. ---
        let sessionBody: [String: Any] = [
            "deviceID": deviceIdentifier,
            "sessionUUID": UUID().uuidString,
            "name": "AirPlayMultiOutput",
            "model": "AirPlayMultiOutput",
            "sourceVersion": "366.0",
            // Horloge : `NTP` correspond au mode temps réel. Le jalon 4 exploitera ce
            // canal pour l'alignement automatique (CDC 4.5).
            "timingProtocol": "NTP",
            "isMultiSelectAirPlay": true,
        ]
        let sessionResponse = try await sendPlist(sessionBody, method: "SETUP", step: "SETUP session")
        guard let eventPort = sessionResponse["eventPort"] as? Int else {
            throw Failure.missingField("eventPort", step: "SETUP session")
        }
        log.debug("SETUP session : eventPort=\(eventPort)")

        // --- SETUP 2 : flux audio. ---
        let streamBody: [String: Any] = [
            "streams": [
                [
                    "type": streamType.rawValue,
                    "audioFormat": format.rawValue,
                    // `ct` : type de compression. 0 laisse le récepteur déduire du format.
                    "ct": 0,
                    "spf": Self.framesPerPacket,
                    "shk": streamKey,
                    "shiv": streamIV,
                    "controlPort": 0,
                    "latencyMin": 11_025,
                    "latencyMax": 88_200,
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
    public func record(startSequence: UInt16, startTimestamp: UInt32) async throws {
        let request = RTSPRequest(
            method: "RECORD",
            uri: sessionURI,
            headers: [
                ("RTP-Info", "seq=\(startSequence);rtptime=\(startTimestamp)"),
                ("Content-Length", "0"),
            ]
        )
        _ = try await client.send(request)
        log.info("RECORD accepté (seq=\(startSequence) rtptime=\(startTimestamp))")
    }

    /// Règle le volume, en décibels.
    ///
    /// Échelle AirPlay : `-144` coupe le son, `-30` à `0` couvre la plage utile. Identique
    /// à RAOP, y compris le format texte du corps.
    public func setVolume(_ decibels: Float) async throws {
        let body = Data("volume: \(decibels)\r\n".utf8)
        let request = RTSPRequest(
            method: "SET_PARAMETER",
            uri: sessionURI,
            headers: [
                ("Content-Type", "text/parameters"),
                ("Content-Length", String(body.count)),
            ],
            body: body
        )
        _ = try await client.send(request)
        log.debug("volume réglé à \(decibels) dB")
    }

    /// `TEARDOWN` : ferme la session proprement.
    ///
    /// Émis avec l'URI de session d'origine (voir ``sessionURI``). Les erreurs sont
    /// journalisées mais non propagées : à ce stade la diffusion est finie, et faire échouer
    /// l'arrêt n'apporterait rien à l'appelant.
    public func teardown() async {
        let request = RTSPRequest(
            method: "TEARDOWN",
            uri: sessionURI,
            headers: [("Content-Length", "0")]
        )
        do {
            // Délai court, même raison qu'en RAOP : le récepteur ferme couramment la
            // connexion dès le TEARDOWN reçu, sans répondre.
            _ = try await client.send(request, timeout: .seconds(2))
            log.info("TEARDOWN accepté")
        } catch {
            log.error("TEARDOWN en échec : \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: - Plists

    /// Identifiant matériel annoncé au récepteur.
    ///
    /// Repris de l'annonce Bonjour du récepteur quand elle est exploitable, à défaut dérivé
    /// de l'identifiant de client RTSP — le format attendu est celui d'une adresse MAC.
    private var deviceIdentifier: String {
        if !device.deviceIdentifier.isEmpty { return device.deviceIdentifier }
        return "02:00:00:00:00:01"
    }

    /// Sérialise un plist binaire, l'envoie, et analyse la réponse.
    private func sendPlist(
        _ body: [String: Any],
        method: String,
        step: String
    ) async throws -> [String: Any] {
        let payload = try PropertyListSerialization.data(
            fromPropertyList: body, format: .binary, options: 0
        )
        let request = RTSPRequest(
            method: method,
            uri: sessionURI,
            headers: [
                ("Content-Type", "application/x-apple-binary-plist"),
                ("Content-Length", String(payload.count)),
            ],
            body: payload
        )
        let response = try await client.send(request)

        guard !response.body.isEmpty else { return [:] }
        guard let parsed = try? PropertyListSerialization.propertyList(
            from: response.body, options: [], format: nil
        ) as? [String: Any] else {
            throw Failure.malformedResponse(step: step)
        }
        return parsed
    }
}
