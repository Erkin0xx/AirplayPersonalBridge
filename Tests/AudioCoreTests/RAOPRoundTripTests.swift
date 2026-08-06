import CommonCrypto
import Foundation
import Testing

@testable import AudioCore

/// Aller-retour complet sur la charge utile audio : PCM → ALAC → AES → AES⁻¹ → ALAC⁻¹ → PCM.
///
/// Ce test répond à la question que la capture Wireshark ne tranche pas seule : les octets
/// qui partent sur le fil redonnent-ils bien l'audio d'origine ? Une capture montre la
/// structure des paquets, pas le fait que leur contenu se décode en le bon signal. Un
/// défaut de bourrage, d'endianness ou de découpage AES produirait des paquets d'apparence
/// parfaitement normale et du bruit à l'arrivée.
///
/// Le décodeur utilisé ici est volontairement minimal et réservé aux tests : il ne gère que
/// le mode non compressé, seul mode que l'encodeur produit (voir `ALACEncoder`).
struct RAOPRoundTripTests {
    /// Un signal connu doit ressortir **bit pour bit** identique : ALAC est sans perte, et
    /// le chiffrement est réversible. Toute différence ici est un défaut.
    @Test func lePCMRessortIdentiqueApresALACEtAES() throws {
        let frames = ALACEncoder.framesPerPacket
        // Deux fréquences distinctes par canal : une inversion gauche/droite se verrait.
        var pcm = [Int16](repeating: 0, count: frames * 2)
        for index in 0..<frames {
            pcm[index * 2] = Int16(16_000 * sin(Double(index) * 2 * .pi * 440 / 44_100))
            pcm[index * 2 + 1] = Int16(16_000 * sin(Double(index) * 2 * .pi * 660 / 44_100))
        }

        let encoder = ALACEncoder(framesPerPacket: frames, channelCount: 2)
        let crypto = try RAOPCrypto()

        var payload = encoder.encode(pcm, frameCount: frames)
        #expect(payload.count == 1_411, "trame ALAC de 352 trames stéréo non compressées")
        try crypto.encryptAudioInPlace(&payload)

        // Ce que ferait le récepteur.
        let decrypted = try Self.decryptAsReceiver(payload, key: crypto.aesKey, iv: crypto.aesIV)
        let decoded = try #require(Self.decodeUncompressedALAC(decrypted, channels: 2))

        #expect(decoded.count == pcm.count)
        #expect(decoded == pcm, "ALAC est sans perte : le PCM doit ressortir identique")
    }

    /// Les valeurs extrêmes doivent survivre au trajet : c'est là que se manifestent les
    /// erreurs de signe et de saturation.
    @Test func lesValeursExtremesSurviventAuTrajet() throws {
        let frames = 64
        let pcm: [Int16] = (0..<(frames * 2)).map { index in
            switch index % 4 {
            case 0: return Int16.min
            case 1: return Int16.max
            case 2: return -1
            default: return 0
            }
        }

        let encoder = ALACEncoder(framesPerPacket: frames, channelCount: 2)
        let crypto = try RAOPCrypto()
        var payload = encoder.encode(pcm, frameCount: frames)
        try crypto.encryptAudioInPlace(&payload)

        let decrypted = try Self.decryptAsReceiver(payload, key: crypto.aesKey, iv: crypto.aesIV)
        let decoded = try #require(Self.decodeUncompressedALAC(decrypted, channels: 2))
        #expect(decoded == pcm)
    }

    /// Deux paquets consécutifs doivent se décoder indépendamment l'un de l'autre.
    ///
    /// C'est la propriété qui rend une retransmission isolée exploitable par le récepteur,
    /// et la raison pour laquelle le CBC repart du même IV à chaque paquet.
    @Test func chaquePaquetSeDecodeIndependamment() throws {
        let frames = 352
        let encoder = ALACEncoder(framesPerPacket: frames, channelCount: 2)
        let crypto = try RAOPCrypto()

        let premier = (0..<(frames * 2)).map { Int16(truncatingIfNeeded: $0) }
        let second = (0..<(frames * 2)).map { Int16(truncatingIfNeeded: $0 &* 7 &+ 13) }

        var paquet1 = encoder.encode(premier, frameCount: frames)
        try crypto.encryptAudioInPlace(&paquet1)
        var paquet2 = encoder.encode(second, frameCount: frames)
        try crypto.encryptAudioInPlace(&paquet2)

        // Le second est décodé sans avoir traité le premier : pas d'état partagé.
        let decode2 = try #require(Self.decodeUncompressedALAC(
            try Self.decryptAsReceiver(paquet2, key: crypto.aesKey, iv: crypto.aesIV),
            channels: 2
        ))
        #expect(decode2 == second)

        let decode1 = try #require(Self.decodeUncompressedALAC(
            try Self.decryptAsReceiver(paquet1, key: crypto.aesKey, iv: crypto.aesIV),
            channels: 2
        ))
        #expect(decode1 == premier)
    }

    // MARK: - Côté récepteur (test uniquement)

    /// Déchiffre comme le fait un récepteur RAOP : AES-128-CBC sur les blocs entiers
    /// seulement, reliquat final laissé tel quel.
    private static func decryptAsReceiver(_ payload: [UInt8], key: [UInt8], iv: [UInt8]) throws -> [UInt8] {
        var output = payload
        let blockCount = payload.count / kCCBlockSizeAES128
        guard blockCount > 0 else { return output }
        let length = blockCount * kCCBlockSizeAES128

        var produced = 0
        let status = output.withUnsafeMutableBytes { raw -> CCCryptorStatus in
            guard let base = raw.baseAddress else { return CCCryptorStatus(kCCParamError) }
            return key.withUnsafeBytes { keyBytes in
                iv.withUnsafeBytes { ivBytes in
                    CCCrypt(
                        CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(0),
                        keyBytes.baseAddress, kCCKeySizeAES128, ivBytes.baseAddress,
                        base, length, base, length, &produced
                    )
                }
            }
        }
        guard status == CCCryptorStatus(kCCSuccess) else {
            throw RAOPCryptoError.audioEncryptionFailed(Int(status))
        }
        return output
    }

    /// Décode une trame ALAC **non compressée**. Renvoie `nil` si la trame annonce un autre
    /// mode, ce que l'encodeur du projet ne produit jamais.
    ///
    /// L'ordre de lecture reproduit **exactement** celui du décodeur de shairport-sync
    /// (`alac.c`, cas « 2 channels ») : 4 bits, puis 12 bits d'inutilisé, puis `hasSize`,
    /// `uncompressedBytes` et `isNotCompressed`. C'est ce qui rend ce test capable
    /// d'attraper un en-tête mal dimensionné — un décodeur de test qui reprendrait les
    /// hypothèses de l'encodeur validerait n'importe quoi.
    private static func decodeUncompressedALAC(_ frame: [UInt8], channels: Int) -> [Int16]? {
        var reader = TestBitReader(bytes: frame)
        _ = reader.read(4)                       // inutilisé
        _ = reader.read(12)                      // inutilisé
        let hasSize = reader.read(1)
        _ = reader.read(2)                       // uncompressedBytes
        guard reader.read(1) == 1 else { return nil }  // isNotCompressed
        if hasSize == 1 { _ = reader.read(32) }

        // La trame se termine par le marqueur de 3 bits puis l'alignement : le nombre
        // d'échantillons se déduit des bits restants.
        let sampleBits = (frame.count * 8) - 20 - 3
        let count = sampleBits / 16
        var samples: [Int16] = []
        samples.reserveCapacity(count)
        for _ in 0..<count {
            samples.append(Int16(bitPattern: UInt16(truncatingIfNeeded: reader.read(16))))
        }
        return samples
    }
}

/// Lecteur de champs de bits gros-boutistes, réservé aux tests.
private struct TestBitReader {
    private let bytes: [UInt8]
    private var position = 0

    init(bytes: [UInt8]) { self.bytes = bytes }

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
