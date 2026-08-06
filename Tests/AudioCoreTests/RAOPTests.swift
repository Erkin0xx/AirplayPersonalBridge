import AVFoundation
import Foundation
import Testing

@testable import AudioCore

/// Tests du sender RAOP (jalon 2, CDC 4.3).
///
/// Ces tests portent sur ce qu'une capture Wireshark ne peut pas montrer facilement : la
/// structure exacte des trames et paquets, octet par octet. Wireshark valide la séquence
/// protocolaire de bout en bout ; ces tests valident les briques qui la composent, là où une
/// erreur d'un bit produit un symptôme diffus (audio bruité, récepteur qui décroche) plutôt
/// qu'une erreur franche.
struct ALACEncoderTests {
    /// Longueur attendue d'une trame non compressée : en-tête de 20 bits, 32 bits par
    /// trame stéréo, marqueur de 3 bits, le tout aligné sur l'octet.
    @Test func trameNonCompresseeALaBonneLongueur() {
        let encoder = ALACEncoder(framesPerPacket: 352, channelCount: 2)
        let samples = [Int16](repeating: 0, count: 352 * 2)
        let frame = encoder.encode(samples, frameCount: 352)

        let bits = 20 + 352 * 2 * 16 + 3
        #expect(frame.count == (bits + 7) / 8)
    }

    /// L'en-tête doit annoncer une trame non compressée, sans champ de taille explicite.
    ///
    /// L'ordre des champs suit le décodeur de shairport-sync (`alac.c`, cas « 2 channels ») :
    /// 4 bits puis 12 bits d'inutilisé, `hasSize`, `uncompressedBytes` sur 2 bits,
    /// `isNotCompressed`. Soit **20 bits**, non alignés sur l'octet, d'où la relecture par
    /// flux de bits.
    ///
    /// Ce test est la contrepartie du défaut trouvé contre le mock : avec un en-tête de
    /// 11 bits, `isNotCompressed` était lu à 0 par le récepteur, qui partait décoder une
    /// trame compressée inexistante.
    @Test func enTeteAnnonceUneTrameNonCompressee() {
        let encoder = ALACEncoder(framesPerPacket: 4, channelCount: 2)
        let frame = encoder.encode([Int16](repeating: 0, count: 8), frameCount: 4)

        var reader = BitReader(bytes: frame)
        #expect(reader.read(4) == 0)   // inutilisé
        #expect(reader.read(12) == 0)  // inutilisé
        #expect(reader.read(1) == 0)   // hasSize : taille par défaut
        #expect(reader.read(2) == 0)   // uncompressedBytes
        #expect(reader.read(1) == 1)   // isNotCompressed
    }

    /// Les échantillons doivent ressortir en gros-boutiste, dans l'ordre gauche puis droite.
    ///
    /// C'est le test qui attrape une inversion d'octets : elle ne fait pas planter le
    /// récepteur, elle produit du bruit blanc à plein niveau.
    @Test func echantillonsEcritsEnGrosBoutisteEtDansLOrdre() {
        let encoder = ALACEncoder(framesPerPacket: 2, channelCount: 2)
        // Valeurs choisies pour être reconnaissables octet par octet, dont une négative
        // (0x8001 en complément à deux) qui piégerait une conversion de signe fautive.
        let samples: [Int16] = [0x1234, 0x5678, -0x7FFF, 0x0102]
        let frame = encoder.encode(samples, frameCount: 2)

        // L'en-tête fait 20 bits : les échantillons ne sont pas alignés sur l'octet.
        // On relit donc le flux de bits plutôt que d'indexer des octets.
        var reader = BitReader(bytes: frame)
        reader.skip(20)
        for expected in samples {
            #expect(reader.read(16) == UInt32(UInt16(bitPattern: expected)))
        }
        #expect(reader.read(3) == 7)  // marqueur de fin
    }

    /// Deux encodages successifs ne doivent pas se contaminer : le tampon interne est
    /// réutilisé, et un défaut de remise à zéro laisserait des bits du paquet précédent.
    @Test func lEncodeurNeGardePasDEtatEntreDeuxTrames() {
        let encoder = ALACEncoder(framesPerPacket: 4, channelCount: 2)
        let bruyant = [Int16](repeating: -1, count: 8)  // tous les bits à 1
        let silence = [Int16](repeating: 0, count: 8)

        _ = encoder.encode(bruyant, frameCount: 4)
        let apres = encoder.encode(silence, frameCount: 4)

        // Le silence encodé après un bloc à tous les bits à 1 doit être identique au
        // silence encodé sur un encodeur neuf : sinon le tampon garde des bits du bloc
        // précédent, ce qui produirait un craquement à chaque paquet.
        let neuf = ALACEncoder(framesPerPacket: 4, channelCount: 2)
        #expect(apres == neuf.encode(silence, frameCount: 4))

        // Vérification directe : tous les échantillons relus doivent être nuls.
        var reader = BitReader(bytes: apres)
        reader.skip(20)
        for _ in 0..<(4 * 2) {
            #expect(reader.read(16) == 0)
        }
    }
}

struct RAOPCryptoTests {
    /// La clé de session doit faire 16 octets (AES-128) et l'IV aussi.
    @Test func clesDeSessionALaBonneTaille() throws {
        let crypto = try RAOPCrypto()
        #expect(crypto.aesKey.count == 16)
        #expect(crypto.aesIV.count == 16)
    }

    /// Deux sessions doivent tirer des clés différentes : une clé constante serait un
    /// défaut silencieux, invisible à l'écoute comme en capture réseau.
    @Test func chaqueSessionTireDeNouvellesCles() throws {
        let premiere = try RAOPCrypto()
        let seconde = try RAOPCrypto()
        #expect(premiere.aesKey != seconde.aesKey)
        #expect(premiere.aesIV != seconde.aesIV)
    }

    /// Le chiffrement RSA doit produire 256 octets (modulus de 2048 bits) et être
    /// probabiliste — OAEP réintroduit de l'aléa à chaque appel.
    @Test func laCleDeSessionEstChiffreeEnRSA2048() throws {
        let crypto = try RAOPCrypto()
        let premier = try crypto.encryptedSessionKey()
        let second = try crypto.encryptedSessionKey()

        #expect(premier.count == 256)
        #expect(premier != second, "OAEP doit être probabiliste")
    }

    /// Le reliquat de moins de 16 octets reste **en clair**, sans bourrage : exigence du
    /// protocole, pas un oubli. Un bourrage ajouté ici décalerait tout le flux.
    @Test func leReliquatFinalResteEnClair() throws {
        let crypto = try RAOPCrypto()
        // 40 octets = 2 blocs de 16 chiffrés + 8 octets laissés tels quels.
        var payload = [UInt8](0..<40)
        let original = payload
        try crypto.encryptAudioInPlace(&payload)

        #expect(payload.count == original.count)
        #expect(Array(payload[32..<40]) == Array(original[32..<40]))
        #expect(Array(payload[0..<32]) != Array(original[0..<32]))
    }

    /// Chaque paquet repart du même IV : deux paquets identiques doivent produire le même
    /// chiffré. C'est ce qui permet au récepteur de décoder une retransmission isolée.
    @Test func chaquePaquetRepartDuMemeIV() throws {
        let crypto = try RAOPCrypto()
        var premier = [UInt8](repeating: 0xAB, count: 32)
        var second = premier
        try crypto.encryptAudioInPlace(&premier)
        try crypto.encryptAudioInPlace(&second)
        #expect(premier == second, "le CBC ne doit pas être chaîné d'un paquet à l'autre")
    }

    /// Un paquet plus court qu'un bloc AES doit ressortir intact.
    @Test func unPaquetTropCourtNEstPasChiffre() throws {
        let crypto = try RAOPCrypto()
        var payload = [UInt8](repeating: 0x11, count: 15)
        let original = payload
        try crypto.encryptAudioInPlace(&payload)
        #expect(payload == original)
    }

    /// Le base64 du SDP doit être dépourvu de `=` : certains récepteurs rejettent
    /// l'ANNOUNCE si le bourrage est présent.
    @Test func leBase64DuSDPEstSansBourrage() {
        // 16 octets produisent 24 caractères base64 dont 1 de bourrage.
        let encoded = RAOPCrypto.base64Unpadded([UInt8](repeating: 0, count: 16))
        #expect(!encoded.contains("="))
        #expect(encoded.count == 22)
    }
}

struct RTSPMessageTests {
    /// `Content-Length` doit être ajouté automatiquement quand un corps est présent :
    /// l'omettre laisse le récepteur en attente jusqu'à expiration du délai.
    @Test func laRequeteAjouteContentLength() {
        let request = RTSPRequest(
            method: "ANNOUNCE", uri: "rtsp://192.168.1.21/1234",
            headers: [("Content-Type", "application/sdp")],
            body: Data("v=0\r\n".utf8)
        )
        let text = String(decoding: request.serialized(), as: UTF8.self)

        #expect(text.hasPrefix("ANNOUNCE rtsp://192.168.1.21/1234 RTSP/1.0\r\n"))
        #expect(text.contains("Content-Length: 5\r\n"))
        #expect(text.hasSuffix("\r\n\r\nv=0\r\n"))
    }

    /// Un `Content-Length` déjà posé par l'appelant ne doit pas être dupliqué.
    @Test func contentLengthNEstPasDuplique() {
        let request = RTSPRequest(
            method: "SET_PARAMETER", uri: "rtsp://x/1",
            headers: [("Content-Length", "3")], body: Data("abc".utf8)
        )
        let text = String(decoding: request.serialized(), as: UTF8.self)
        #expect(text.components(separatedBy: "Content-Length").count == 2)
    }

    /// Analyse d'une réponse complète, en-têtes normalisés en minuscules.
    @Test func laReponseEstAnalyseeAvecSonCorps() throws {
        let raw = Data("""
            RTSP/1.0 200 OK\r
            CSeq: 2\r
            Audio-Latency: 88200\r
            Content-Length: 4\r
            \r
            abcd
            """.replacingOccurrences(of: "\nabcd", with: "\nabcd").utf8)
        let parsed = try #require(RTSPResponse.parse(raw))

        #expect(parsed.response.statusCode == 200)
        #expect(parsed.response.isSuccess)
        #expect(parsed.response.headers["audio-latency"] == "88200")
        #expect(parsed.response.body == Data("abcd".utf8))
    }

    /// Un tampon incomplet doit renvoyer `nil` sans consommer : c'est le cas normal d'une
    /// lecture par morceaux, pas une erreur.
    @Test func unTamponIncompletNeProduitRien() {
        #expect(RTSPResponse.parse(Data("RTSP/1.0 200 OK\r\nCSeq: 1\r\n".utf8)) == nil)
        // En-têtes complets mais corps tronqué.
        let tronque = Data("RTSP/1.0 200 OK\r\nContent-Length: 10\r\n\r\nabc".utf8)
        #expect(RTSPResponse.parse(tronque) == nil)
    }

    /// Deux réponses collées dans le même tampon : la première est rendue, le surplus est
    /// signalé par `consumed` pour rester disponible.
    @Test func leSurplusApresUneReponseEstConserve() throws {
        let raw = Data("RTSP/1.0 200 OK\r\nCSeq: 1\r\n\r\nRTSP/1.0 200 OK\r\nCSeq: 2\r\n\r\n".utf8)
        let parsed = try #require(RTSPResponse.parse(raw))
        #expect(parsed.consumed < raw.count)

        let reste = raw.dropFirst(parsed.consumed)
        let seconde = try #require(RTSPResponse.parse(Data(reste)))
        #expect(seconde.response.statusCode == 200)
    }

    /// Les ports du récepteur se lisent dans l'en-tête `Transport` de la réponse.
    ///
    /// PIÈGE : ce sont ces ports-là qui font foi, jamais ceux demandés dans le SETUP.
    @Test func lesPortsDuRecepteurSontLusDansTransport() throws {
        let raw = Data("""
            RTSP/1.0 200 OK\r
            CSeq: 3\r
            Transport: RTP/AVP/UDP;unicast;mode=record;server_port=6000;control_port=6001;timing_port=6002\r
            \r

            """.utf8)
        let parsed = try #require(RTSPResponse.parse(raw))
        let ports = parsed.response.transportParameters

        #expect(ports["server_port"] == "6000")
        #expect(ports["control_port"] == "6001")
        #expect(ports["timing_port"] == "6002")
        #expect(ports["mode"] == "record")
    }

    /// Un refus doit être reconnu comme tel, pour que le sender remonte l'erreur.
    @Test func unRefusNEstPasUnSucces() throws {
        let raw = Data("RTSP/1.0 453 Not Enough Bandwidth\r\nCSeq: 1\r\n\r\n".utf8)
        let parsed = try #require(RTSPResponse.parse(raw))
        #expect(!parsed.response.isSuccess)
        #expect(parsed.response.statusCode == 453)
        #expect(parsed.response.reasonPhrase == "Not Enough Bandwidth")
    }
}

struct RTPPacketTests {
    /// En-tête RTP : version 2, type de charge utile audio, champs en gros-boutiste.
    @Test func lEnTeteAudioEstConforme() {
        let packet = RTPPacketBuilder.audio(
            sequenceNumber: 0x1234, timestamp: 0xDEAD_BEEF,
            ssrc: 0x0102_0304, marker: false, payload: [0xAA, 0xBB]
        )
        let bytes = [UInt8](packet)

        #expect(bytes[0] == 0x80)  // version 2, sans padding ni extension
        #expect(bytes[1] == 0x60)  // type audio, marker absent
        #expect(bytes[2] == 0x12 && bytes[3] == 0x34)
        #expect(Array(bytes[4..<8]) == [0xDE, 0xAD, 0xBE, 0xEF])
        #expect(Array(bytes[8..<12]) == [0x01, 0x02, 0x03, 0x04])
        #expect(Array(bytes[12...]) == [0xAA, 0xBB])
    }

    /// Le bit marker n'est posé que sur le premier paquet du flux.
    @Test func leBitMarkerNEstPoseQueSurLePremierPaquet() {
        let premier = [UInt8](RTPPacketBuilder.audio(
            sequenceNumber: 1, timestamp: 0, ssrc: 0, marker: true, payload: []))
        let suivant = [UInt8](RTPPacketBuilder.audio(
            sequenceNumber: 2, timestamp: 0, ssrc: 0, marker: false, payload: []))

        #expect(premier[1] == 0xE0)  // 0x60 | 0x80
        #expect(suivant[1] == 0x60)
    }

    /// Le paquet de synchro fait 20 octets et relie l'instant NTP au timestamp RTP.
    ///
    /// Le premier champ vaut « timestamp courant moins latence » : l'instant que le
    /// récepteur est censé restituer maintenant.
    @Test func lePaquetDeSyncRelieNTPEtRTP() {
        let ntp = NTPTime(seconds: 0x1122_3344, fraction: 0x5566_7788)
        let packet = RTPPacketBuilder.sync(
            rtpTimestamp: 100_000, latencyFrames: 88_200, ntp: ntp, isFirst: false
        )
        let bytes = [UInt8](packet)

        #expect(bytes.count == 20)
        #expect(bytes[0] == 0x80)
        #expect(bytes[1] == 0xD4)  // type sync (0x54) | marker
        #expect(Array(bytes[2..<4]) == [0x00, 0x07])

        let restitue = UInt32(bytes[4]) << 24 | UInt32(bytes[5]) << 16
            | UInt32(bytes[6]) << 8 | UInt32(bytes[7])
        #expect(restitue == 100_000 - 88_200)
        #expect(Array(bytes[8..<16]) == [0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88])
        #expect(Array(bytes[16..<20]) == [0x00, 0x01, 0x86, 0xA0])  // 100 000
    }

    /// La première annonce de synchro porte le bit d'extension.
    @Test func laPremiereSyncPorteLeBitDExtension() {
        let premiere = [UInt8](RTPPacketBuilder.sync(
            rtpTimestamp: 0, latencyFrames: 0, ntp: NTPTime.now(), isFirst: true))
        let suivante = [UInt8](RTPPacketBuilder.sync(
            rtpTimestamp: 0, latencyFrames: 0, ntp: NTPTime.now(), isFirst: false))

        #expect(premiere[0] == 0x90)
        #expect(suivante[0] == 0x80)
    }

    /// Le timestamp de synchro doit repasser proprement sous zéro : l'arithmétique RTP est
    /// modulaire sur 32 bits, et un débordement non maîtrisé planterait le sender.
    @Test func leTimestampDeSyncBoucleSansDeborder() {
        let packet = RTPPacketBuilder.sync(
            rtpTimestamp: 1_000, latencyFrames: 88_200, ntp: NTPTime.now(), isFirst: false
        )
        let bytes = [UInt8](packet)
        let restitue = UInt32(bytes[4]) << 24 | UInt32(bytes[5]) << 16
            | UInt32(bytes[6]) << 8 | UInt32(bytes[7])
        #expect(restitue == UInt32(1_000) &- UInt32(88_200))
    }

    /// La réponse de timing recopie l'estampille d'origine : c'est elle qui permet au
    /// récepteur d'apparier la réponse à sa requête.
    @Test func laReponseDeTimingRecopieLEstampilleDOrigine() {
        let origine: [UInt8] = [0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF, 0x00, 0x11]
        let packet = RTPPacketBuilder.timingResponse(
            originTimestamp: origine,
            receiveTime: NTPTime(seconds: 1, fraction: 2),
            transmitTime: NTPTime(seconds: 3, fraction: 4)
        )
        let bytes = [UInt8](packet)

        #expect(bytes.count == 32)
        #expect(bytes[1] == 0xD3)  // type timingResponse (0x53) | marker
        #expect(Array(bytes[8..<16]) == origine)
    }

    /// Conversion NTP : l'époque NTP démarre en 1900, 2 208 988 800 s avant l'époque Unix.
    @Test func laConversionNTPUtiliseLEpoque1900() {
        let ntp = NTPTime(unixTime: 0)
        #expect(ntp.seconds == 2_208_988_800)

        let demiSeconde = NTPTime(unixTime: 0.5)
        #expect(demiSeconde.seconds == 2_208_988_800)
        // 0,5 s = la moitié de 2^32.
        #expect(demiSeconde.fraction == 0x8000_0000)
    }
}

/// Vérifie la conversion du format de capture (48 kHz float32) vers le format RAOP
/// (44,1 kHz Int16), et surtout que le tampon partagé n'est jamais modifié.
struct RAOPResamplerTests {
    private func formatDeCapture() throws -> AVAudioFormat {
        try #require(AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 48_000,
            channels: 2, interleaved: true
        ))
    }

    /// Le nombre de trames produites doit suivre le ratio 44,1/48, à la latence du filtre
    /// près.
    @Test func le48kHzEstConvertiEn44100() throws {
        let resampler = try RAOPResampler(inputFormat: formatDeCapture())
        #expect(resampler.outputFormat.sampleRate == 44_100)
        #expect(resampler.outputFormat.commonFormat == .pcmFormatInt16)
        #expect(resampler.outputFormat.isInterleaved)

        // 4800 trames à 48 kHz = 0,1 s, soit ~4410 trames à 44,1 kHz.
        let frames = 4_800
        var source = [Float](repeating: 0, count: frames * 2)
        for index in 0..<frames {
            let value = sin(Double(index) * 2 * .pi * 440 / 48_000)
            source[index * 2] = Float(value)
            source[index * 2 + 1] = Float(value)
        }

        let converted = try source.withUnsafeBufferPointer { buffer -> [Int16] in
            guard let base = buffer.baseAddress else { return [] }
            return try resampler.convert(base, frameCount: frames)
        }

        let produced = converted.count / 2
        // Tolérance large : le convertisseur retient quelques trames pour son filtre.
        #expect(abs(produced - 4_410) < 200, "attendu ~4410 trames, obtenu \(produced)")
    }

    /// Le float32 dans [−1, 1] doit couvrir la pleine échelle Int16 sans écrêter.
    @Test func laConversionEnInt16CouvreLaPleineEchelle() throws {
        let resampler = try RAOPResampler(inputFormat: formatDeCapture())
        let frames = 9_600
        var source = [Float](repeating: 0, count: frames * 2)
        for index in 0..<frames {
            let value = Float(sin(Double(index) * 2 * .pi * 100 / 48_000)) * 0.9
            source[index * 2] = value
            source[index * 2 + 1] = value
        }

        let converted = try source.withUnsafeBufferPointer { buffer -> [Int16] in
            guard let base = buffer.baseAddress else { return [] }
            return try resampler.convert(base, frameCount: frames)
        }

        let crete = converted.map { abs(Int($0)) }.max() ?? 0
        // 0,9 de pleine échelle ≈ 29 500 sur 32 767.
        #expect(crete > 25_000, "crête trop basse : \(crete)")
        #expect(crete <= 32_767)
    }

    /// **Invariant section 12** : le sender lit le flux partagé sans jamais le modifier.
    ///
    /// Ce test passe un tampon d'entrée dans le convertisseur et vérifie qu'il en ressort
    /// identique — c'est la garantie que la sortie Geneva ne peut pas altérer l'audio que
    /// verra la sortie AirPlay 2 du jalon 3.
    @Test func laConversionNeModifieJamaisLeTamponSource() throws {
        let resampler = try RAOPResampler(inputFormat: formatDeCapture())
        var source = [Float](repeating: 0, count: 4_800 * 2)
        for index in 0..<source.count {
            source[index] = Float(index % 1_000) / 1_000
        }
        let original = source

        _ = try source.withUnsafeMutableBufferPointer { buffer -> [Int16] in
            guard let base = buffer.baseAddress else { return [] }
            return try resampler.convert(base, frameCount: 4_800)
        }

        #expect(source == original, "le tampon source doit ressortir intact")
    }

    /// Régression : aucune trame ne doit être perdue sur un flux continu.
    ///
    /// `AVAudioConverter.convert` ne rend jamais plus de 4096 trames par appel, quelle que
    /// soit la capacité du tampon de sortie, et signale `.inputRanDry` en retenant encore
    /// des trames. Une première version s'arrêtait sur ce statut et perdait ~6,5 % du flux —
    /// un défaut permanent, audible, et que rien ne signalait à l'exécution.
    ///
    /// Sur 10 blocs de 4800 trames (1 s), le cumul doit rester à moins de 1 % du théorique.
    @Test func aucuneTrameNEstPerdueSurUnFluxContinu() throws {
        let resampler = try RAOPResampler(inputFormat: formatDeCapture())
        let framesParBloc = 4_800
        let blocs = 10
        let source = [Float](repeating: 0.25, count: framesParBloc * 2)

        var total = 0
        for _ in 0..<blocs {
            let converted = try source.withUnsafeBufferPointer { buffer -> [Int16] in
                guard let base = buffer.baseAddress else { return [] }
                return try resampler.convert(base, frameCount: framesParBloc)
            }
            total += converted.count / 2
        }

        let theorique = Double(framesParBloc * blocs) * 44_100 / 48_000
        let ecart = abs(Double(total) - theorique) / theorique
        #expect(ecart < 0.01, "perte de \(ecart * 100) % : \(total) trames au lieu de \(theorique)")
    }

    /// Un bloc plus grand que la capacité interne doit être traité en plusieurs passes,
    /// sans perte ni doublon.
    @Test func unGrosBlocEstTraiteEnPlusieursPasses() throws {
        let resampler = try RAOPResampler(
            inputFormat: formatDeCapture(), maximumInputFrames: 512
        )
        let frames = 4_800
        let source = [Float](repeating: 0.1, count: frames * 2)

        let converted = try source.withUnsafeBufferPointer { buffer -> [Int16] in
            guard let base = buffer.baseAddress else { return [] }
            return try resampler.convert(base, frameCount: frames)
        }

        let produced = converted.count / 2
        #expect(abs(produced - 4_410) < 300, "attendu ~4410 trames, obtenu \(produced)")
    }
}

/// Vérifie que le sender lit le ring buffer partagé sans jamais l'altérer
/// (invariant section 12).
struct RAOPRingBufferIsolationTests {
    /// Ce que le sender lit doit être exactement ce que la capture a écrit, et le ring
    /// buffer doit se comporter en lecture seule de son point de vue : après lecture, les
    /// données consommées ne doivent pas avoir été réécrites par le lecteur.
    @Test func leSenderLitSansEcrireDansLeTamponPartage() {
        let ring = AudioRingBuffer(capacityFrames: 1_024, channelCount: 2)
        var source = [Float](repeating: 0, count: 512 * 2)
        for index in 0..<source.count {
            source[index] = Float(index) / 1_000
        }
        source.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            ring.write(from: base, frameCount: 512)
        }

        // Lecture côté sender.
        var destination = [Float](repeating: 0, count: 512 * 2)
        let read = destination.withUnsafeMutableBufferPointer { buffer -> Int in
            guard let base = buffer.baseAddress else { return 0 }
            return ring.read(into: base, frameCount: 512)
        }

        #expect(read == 512)
        #expect(destination == source, "le sender doit lire exactement ce qui a été écrit")
        // Le producteur peut réécrire immédiatement : la lecture a bien libéré la place
        // sans corrompre l'état du tampon.
        #expect(ring.availableFrames == 0)
    }

    /// Deux consommateurs branchés sur **deux ring buffers distincts** (un par pipeline de
    /// sortie, comme l'exige la section 12) reçoivent le même flux, et l'un ne peut pas
    /// perturber l'autre.
    @Test func deuxPipelinesDeSortieSontIndependants() {
        let geneva = AudioRingBuffer(capacityFrames: 1_024, channelCount: 2)
        let homePod = AudioRingBuffer(capacityFrames: 1_024, channelCount: 2)
        let source = (0..<(256 * 2)).map { Float($0) / 100 }

        // La capture duplique en écriture vers chaque pipeline.
        source.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            geneva.write(from: base, frameCount: 256)
            homePod.write(from: base, frameCount: 256)
        }

        // Le sender Geneva draine tout ; celui du HomePod ne doit pas en être affecté.
        var poubelle = [Float](repeating: 0, count: 256 * 2)
        poubelle.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            _ = geneva.read(into: base, frameCount: 256)
        }

        #expect(geneva.availableFrames == 0)
        #expect(homePod.availableFrames == 256, "l'autre sortie doit être intacte")

        var restant = [Float](repeating: 0, count: 256 * 2)
        restant.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            _ = homePod.read(into: base, frameCount: 256)
        }
        #expect(restant == source)
    }
}

/// Lecture de champs de bits, pour vérifier ce que `BitWriter` a produit.
/// Réservée aux tests : le sender n'a jamais besoin de relire une trame ALAC.
private struct BitReader {
    private let bytes: [UInt8]
    private var position = 0

    init(bytes: [UInt8]) { self.bytes = bytes }

    mutating func skip(_ count: Int) { position += count }

    mutating func read(_ count: Int) -> UInt32 {
        var value: UInt32 = 0
        for _ in 0..<count {
            let byteIndex = position / 8
            guard byteIndex < bytes.count else { return value }
            let bit = (bytes[byteIndex] >> (7 - UInt8(position % 8))) & 1
            value = (value << 1) | UInt32(bit)
            position += 1
        }
        return value
    }
}
