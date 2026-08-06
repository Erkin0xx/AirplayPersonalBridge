import Foundation
import Network
import OSLog

/// Les trois canaux UDP d'une session RAOP, tels que le protocole les définit.
///
/// | Canal | Sens | Rôle |
/// |---|---|---|
/// | audio | sender → récepteur | paquets RTP de charge utile ALAC chiffrée |
/// | control | bidirectionnel | annonces de synchro périodiques ; demandes de retransmission entrantes |
/// | timing | bidirectionnel | requêtes/réponses d'horloge, à l'initiative du récepteur |
///
/// Le canal de timing est le point d'ancrage temporel dont parle le CDC 4.5 : c'est lui qui
/// fournira, au jalon 4, la mesure de latence réelle du récepteur.
public struct RTPPorts: Sendable {
    public let audio: UInt16
    public let control: UInt16
    public let timing: UInt16

    public init(audio: UInt16, control: UInt16, timing: UInt16) {
        self.audio = audio
        self.control = control
        self.timing = timing
    }
}

/// Types de charge utile RTP du protocole RAOP.
enum RTPPayloadType: UInt8 {
    case timingRequest = 0x52
    case timingResponse = 0x53
    case sync = 0x54
    case retransmitRequest = 0x55
    case audioData = 0x60
    case audioResend = 0x56
}

/// Horloge NTP de la session.
///
/// RAOP transporte les instants au format NTP 64 bits : 32 bits de secondes depuis 1900,
/// 32 bits de fraction. Les récepteurs recoupent ces valeurs pour se caler.
public struct NTPTime {
    /// Décalage entre l'époque NTP (1900) et l'époque Unix (1970), en secondes.
    /// 70 ans dont 17 bissextiles.
    public static let epochOffset: Double = 2_208_988_800

    public let seconds: UInt32
    public let fraction: UInt32

    public init(unixTime: TimeInterval) {
        let ntp = unixTime + Self.epochOffset
        self.seconds = UInt32(truncatingIfNeeded: Int64(ntp))
        self.fraction = UInt32(truncatingIfNeeded: Int64((ntp - ntp.rounded(.down)) * 4_294_967_296))
    }

    public init(seconds: UInt32, fraction: UInt32) {
        self.seconds = seconds
        self.fraction = fraction
    }

    public static func now() -> NTPTime { NTPTime(unixTime: Date().timeIntervalSince1970) }

    public var bigEndianBytes: [UInt8] {
        withUnsafeBytes(of: seconds.bigEndian, Array.init)
            + withUnsafeBytes(of: fraction.bigEndian, Array.init)
    }
}

/// Fabrique des paquets RTP RAOP.
///
/// Séparée du transport pour être testable sans réseau : chaque méthode est une fonction
/// pure de ses entrées.
public enum RTPPacketBuilder {
    /// En-tête RTP de 12 octets.
    ///
    /// Sur le tout premier paquet audio, le bit *marker* est posé — le récepteur y lit le
    /// début d'un flux et réinitialise ses buffers.
    static func header(
        payloadType: RTPPayloadType,
        sequenceNumber: UInt16,
        timestamp: UInt32,
        ssrc: UInt32,
        marker: Bool
    ) -> [UInt8] {
        var bytes: [UInt8] = []
        bytes.append(0x80)  // version 2, sans padding, sans extension, 0 CSRC
        bytes.append(payloadType.rawValue | (marker ? 0x80 : 0x00))
        bytes.append(contentsOf: withUnsafeBytes(of: sequenceNumber.bigEndian, Array.init))
        bytes.append(contentsOf: withUnsafeBytes(of: timestamp.bigEndian, Array.init))
        bytes.append(contentsOf: withUnsafeBytes(of: ssrc.bigEndian, Array.init))
        return bytes
    }

    /// En-tête RTP audio seul, sans charge utile.
    ///
    /// Exposé pour AirPlay 2 : son chiffrement de flux (ChaCha20-Poly1305) prend l'en-tête
    /// comme **données associées**, ce qui suppose de l'obtenir avant de chiffrer la charge
    /// utile — impossible avec ``audio(sequenceNumber:timestamp:ssrc:marker:payload:)``, qui
    /// assemble les deux d'un coup. RAOP continue d'utiliser cette dernière, inchangée.
    public static func audioHeader(
        sequenceNumber: UInt16,
        timestamp: UInt32,
        ssrc: UInt32,
        marker: Bool
    ) -> Data {
        Data(
            header(
                payloadType: .audioData,
                sequenceNumber: sequenceNumber,
                timestamp: timestamp,
                ssrc: ssrc,
                marker: marker
            )
        )
    }

    /// Paquet audio : en-tête RTP suivi de la charge utile ALAC chiffrée.
    public static func audio(
        sequenceNumber: UInt16,
        timestamp: UInt32,
        ssrc: UInt32,
        marker: Bool,
        payload: [UInt8]
    ) -> Data {
        var packet = header(
            payloadType: .audioData,
            sequenceNumber: sequenceNumber,
            timestamp: timestamp,
            ssrc: ssrc,
            marker: marker
        )
        packet.append(contentsOf: payload)
        return Data(packet)
    }

    /// Paquet de synchronisation, émis sur le canal de contrôle.
    ///
    /// Il relie un instant NTP à un timestamp RTP, ce qui donne au récepteur son point de
    /// calage. `isFirst` pose le bit d'extension, attendu sur la toute première annonce.
    ///
    /// `latency` est le retard, en trames, entre l'instant « maintenant » et le timestamp
    /// courant : c'est la profondeur de buffer que le récepteur doit respecter avant de
    /// restituer.
    public static func sync(
        rtpTimestamp: UInt32,
        latencyFrames: UInt32,
        ntp: NTPTime,
        isFirst: Bool
    ) -> Data {
        var packet: [UInt8] = []
        packet.append(isFirst ? 0x90 : 0x80)  // bit d'extension sur la première annonce
        packet.append(RTPPayloadType.sync.rawValue | 0x80)  // marker toujours posé
        packet.append(contentsOf: [0x00, 0x07])  // longueur en mots de 32 bits, moins un
        // Timestamp « maintenant moins latence » : l'instant que le récepteur est censé
        // être en train de restituer.
        packet.append(
            contentsOf: withUnsafeBytes(
                of: (rtpTimestamp &- latencyFrames).bigEndian, Array.init))
        packet.append(contentsOf: ntp.bigEndianBytes)
        packet.append(contentsOf: withUnsafeBytes(of: rtpTimestamp.bigEndian, Array.init))
        return Data(packet)
    }

    /// Réponse à une requête d'horloge du récepteur.
    ///
    /// Le récepteur mesure l'aller-retour pour estimer le décalage entre son horloge et
    /// celle du sender ; les trois estampilles doivent donc être renseignées fidèlement.
    public static func timingResponse(
        originTimestamp: [UInt8],
        receiveTime: NTPTime,
        transmitTime: NTPTime
    ) -> Data {
        var packet: [UInt8] = []
        packet.append(0x80)
        packet.append(RTPPayloadType.timingResponse.rawValue | 0x80)
        packet.append(contentsOf: [0x00, 0x07])
        packet.append(contentsOf: [0x00, 0x00, 0x00, 0x00])
        // Estampille d'origine : recopiée telle quelle depuis la requête, c'est elle qui
        // permet au récepteur d'apparier la réponse.
        packet.append(contentsOf: originTimestamp)
        packet.append(contentsOf: receiveTime.bigEndianBytes)
        packet.append(contentsOf: transmitTime.bigEndianBytes)
        return Data(packet)
    }
}
