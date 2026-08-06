import Foundation

/// Encodeur ALAC pour RAOP, en mode trames non compressées.
///
/// ## Pourquoi le mode non compressé
///
/// Le format ALAC de RAOP n'est pas un fichier `.m4a` : c'est un flux de trames brutes, sans
/// conteneur, dont les paramètres sont négociés hors bande dans le SDP de l'`ANNOUNCE`.
/// Le bitstream ALAC prévoit explicitement un mode « échantillons bruts » (bit
/// `isNotCompressed`), que tout décodeur ALAC conforme doit gérer — c'est le chemin de repli
/// de l'encodeur de référence d'Apple quand la prédiction n'apporte rien.
///
/// Ce mode est retenu ici pour une raison de fond : le codec est **sans perte** dans les
/// deux cas, donc la qualité audio est rigoureusement identique. Le seul écart est le débit
/// réseau — environ 1,4 Mbit/s au lieu de ~0,8 Mbit/s pour du 44,1 kHz stéréo 16 bits. Sur
/// un réseau local c'est sans conséquence, et cela évite d'embarquer une implémentation de
/// prédiction linéaire et de codage de Rice dont une erreur produirait une corruption audio
/// silencieuse, difficile à distinguer d'un problème de transport.
///
/// Si la mesure au jalon 4 montre que ce débit pose un problème réel de gigue, le passage à
/// la compression effective se fait derrière cette même interface, sans toucher au reste du
/// sender.
///
/// ## Format produit
///
/// Trame stéréo, bits écrits en gros-boutiste (MSB en premier) :
///
/// | Champ | Bits | Valeur |
/// |---|---|---|
/// | inutilisé | 4 | `0` |
/// | inutilisé | 12 | `0` |
/// | `hasSize` | 1 | `0` : la trame fait la taille par défaut |
/// | `uncompressedBytes` | 2 | `0` |
/// | `isNotCompressed` | 1 | `1` |
/// | échantillons | 32/trame | gauche puis droite, 16 bits chacun, gros-boutiste |
///
/// La trame est complétée par `111` (marqueur de fin) puis alignée sur l'octet.
///
/// PIÈGE vérifié contre le décodeur de shairport-sync (`alac.c`, cas « 2 channels ») :
/// l'en-tête fait **20 bits, pas 11**. Le décodeur lit 4 bits puis 12 bits d'inutilisé
/// avant `hasSize`. Une première version écrivait `channels - 1` sur 3 bits suivis de
/// 4 bits d'inutilisé, ce que décrivent plusieurs documentations informelles d'ALAC : ces
/// 3 bits appartiennent en réalité au *tag d'élément* du bitstream ALAC, que RAOP ne
/// transporte pas. Avec 9 bits manquants, tous les champs suivants sont décalés,
/// `isNotCompressed` est lu à 0, et le décodeur part dans la branche compressée — d'où des
/// erreurs « unhandled prediction type » et un récepteur qui finit par s'arrêter.
///
/// Cette classe n'alloue qu'à l'init et ne connaît aucune destination réseau
/// (invariant section 12).
public final class ALACEncoder {
    /// Nombre de trames par paquet RAOP. Valeur canonique du protocole, reprise telle quelle
    /// dans le SDP (`fmtp`) : le récepteur dimensionne ses buffers dessus.
    public static let framesPerPacket = 352

    public let framesPerPacket: Int
    public let channelCount: Int
    /// Tampon de sortie, alloué une seule fois. `UnsafeMutableBufferPointer` plutôt qu'un
    /// `[UInt8]` : faire échapper le pointeur d'un `withUnsafeMutableBufferPointer` d'Array
    /// est un comportement indéfini, alors qu'un tampon possédé en propre est valide pour
    /// toute la vie de l'objet.
    private let output: UnsafeMutableBufferPointer<UInt8>

    /// - Parameters:
    ///   - framesPerPacket: trames par paquet ; doit correspondre au `fmtp` annoncé.
    ///   - channelCount: nombre de canaux entrelacés (2 pour RAOP).
    public init(framesPerPacket: Int = ALACEncoder.framesPerPacket, channelCount: Int = 2) {
        precondition(framesPerPacket > 0, "framesPerPacket nul")
        precondition(channelCount == 2, "RAOP n'est défini ici que pour du stéréo")
        self.framesPerPacket = framesPerPacket
        self.channelCount = channelCount
        // Borne haute : en-tête (11 bits) + 32 bits par trame + marqueur, arrondi large.
        // Allouée une fois ; `encode` n'alloue que la copie renvoyée.
        let capacity = framesPerPacket * channelCount * 2 + 16
        let pointer = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
        pointer.initialize(repeating: 0, count: capacity)
        self.output = UnsafeMutableBufferPointer(start: pointer, count: capacity)
    }

    deinit {
        output.baseAddress?.deinitialize(count: output.count)
        output.baseAddress?.deallocate()
    }

    /// Encode un bloc de trames entrelacées 16 bits signées.
    ///
    /// - Parameter samples: `frameCount * channelCount` échantillons entrelacés.
    /// - Returns: la trame ALAC. Le tampon interne est réutilisé d'un appel à l'autre ; la
    ///   valeur renvoyée est une copie, sûre à conserver.
    public func encode(_ samples: [Int16], frameCount: Int) -> [UInt8] {
        precondition(
            samples.count >= frameCount * channelCount,
            "bloc trop court pour \(frameCount) trames"
        )
        var writer = BitWriter(buffer: output)

        // En-tête de 20 bits : voir la note de classe sur les 4 + 12 bits d'inutilisé.
        writer.write(0, bits: 4)   // inutilisé
        writer.write(0, bits: 12)  // inutilisé
        writer.write(0, bits: 1)   // hasSize : trame de taille par défaut
        writer.write(0, bits: 2)   // uncompressedBytes
        writer.write(1, bits: 1)   // isNotCompressed

        for frame in 0..<frameCount {
            for channel in 0..<channelCount {
                let sample = samples[frame * channelCount + channel]
                // Reinterprétation en non signé : `write` manipule des motifs de bits, la
                // conversion directe d'un Int16 négatif vers UInt32 piégerait.
                writer.write(UInt32(UInt16(bitPattern: sample)), bits: 16)
            }
        }

        writer.write(7, bits: 3)  // marqueur de fin de trame
        writer.alignToByte()
        return Array(UnsafeBufferPointer(rebasing: output[0..<writer.byteCount]))
    }
}

/// Écriture de champs de bits en gros-boutiste dans un tampon existant.
///
/// N'alloue pas : le tampon est fourni par l'appelant, qui l'a dimensionné une fois.
struct BitWriter {
    private let buffer: UnsafeMutableBufferPointer<UInt8>
    private var bitPosition = 0

    init(buffer: UnsafeMutableBufferPointer<UInt8>) {
        self.buffer = buffer
        // Les bits sont composés par OU : le tampon doit repartir à zéro à chaque trame.
        buffer.baseAddress?.update(repeating: 0, count: buffer.count)
    }

    /// Nombre d'octets écrits, marqueur de fin et alignement compris.
    var byteCount: Int { (bitPosition + 7) / 8 }

    /// Écrit les `bits` bits de poids faible de `value`, MSB en premier.
    mutating func write(_ value: UInt32, bits: Int) {
        precondition(bits > 0 && bits <= 32, "largeur de champ hors bornes")
        guard let base = buffer.baseAddress else { return }
        for offset in stride(from: bits - 1, through: 0, by: -1) {
            let bit = (value >> UInt32(offset)) & 1
            guard bit == 1 else {
                bitPosition += 1
                continue
            }
            let byteIndex = bitPosition / 8
            guard byteIndex < buffer.count else { return }
            base[byteIndex] |= UInt8(0x80 >> (bitPosition % 8))
            bitPosition += 1
        }
    }

    /// Complète l'octet en cours par des zéros.
    mutating func alignToByte() {
        bitPosition = byteCount * 8
    }
}
