import Foundation

/// Le niveau d'une sortie, appliqué par son sender sur **sa** copie du flux : un gain numérique, et
/// un silence qui ne coûte pas la session.
///
/// Distinct du volume AirPlay, que le récepteur applique lui-même. Les deux HomePod d'une paire
/// stéréo n'ont qu'**un** volume côté récepteur (le dernier réglé vaut pour les deux) : c'est ce gain
/// qui rend à chacun son propre niveau, et ce silence qui en coupe un sans couper l'autre.
public struct OutputLevel: Sendable, Equatable {
    /// Gain, en dB. Une atténuation : ramené à `OutputGainStage.gainRangeDecibels`, donc jamais
    /// au-dessus de 0 dB, et sans risque d'écrêtage.
    public var gainDB: Float
    /// Silence numérique : le gain glisse vers zéro, la session reste ouverte et le flux continue de
    /// partir. Jamais un volume AirPlay à −144, qui couperait aussi l'autre membre d'une paire.
    public var isMuted: Bool

    public init(gainDB: Float = 0, isMuted: Bool = false) {
        self.gainDB = gainDB
        self.isMuted = isMuted
    }

    /// Ni gain ni silence : l'étage est contourné.
    public static let unity = OutputLevel()
}

/// L'étage de gain d'une sortie : un multiplicateur par trame, qui glisse sans clic.
///
/// ## Où il s'applique (invariant section 12)
///
/// Sur la **copie propre au sender**, extraite du ring buffer, en flottant et à la fréquence de
/// capture, juste avant le rééchantillonnage et la conversion en 16 bits. Le tampon partagé n'est
/// jamais touché, et l'autre sortie n'en sait rien.
///
/// En RAOP, **après** la chaîne DSP (renfort de basses et ce qui la suit) : il tient la place du
/// volume du récepteur, qui s'applique lui aussi en bout de chaîne. Deux conséquences voulues : le
/// silence coupe aussi la queue des filtres, et la chaîne continue de tourner sur le vrai signal
/// pendant le silence, si bien qu'au retour du son elle est déjà en régime, sans transitoire. Le
/// limiteur du renfort voit le même signal quel que soit le gain : le timbre ne dépend pas du niveau.
/// Atténuer avant la conversion en 16 bits plutôt qu'après ne coûte aucune résolution.
///
/// ## Transparence
///
/// À 0 dB et hors silence, l'étage est **contourné** : aucun échantillon n'est lu ni écrit, le flux
/// ressort identique au bit près. Un glissement qui revient à 0 dB se termine sur un gain d'exactement
/// 1, et le contournement reprend dès la trame suivante.
///
/// ## Pas de clic
///
/// Le gain ne change jamais d'un coup : il rejoint sa consigne en ligne droite, en amplitude, en
/// ``fadeSeconds``, trame par trame. Le silence est donc un fondu de 15 ms, qui finit sur un zéro
/// exact. Une nouvelle consigne en plein glissement repart du gain atteint, sans saut.
///
/// ## Alignement (CDC 4.5)
///
/// **Aucun retard.** Chaque trame ressort à sa place, multipliée par un scalaire : ni tampon, ni
/// anticipation, ni retard de groupe. Le calage des sorties n'en est pas affecté.
///
/// ## Temps réel
///
/// Ni allocation ni verrou : l'état tient en quelques scalaires, et les boucles sont des `while`
/// (`for … in 0..<n` alloue à chaque tour en debug). Il ne tourne pourtant pas dans le callback de
/// capture, mais dans la tâche du sender, en aval du ring buffer.
public struct OutputGainStage: Sendable {
    /// Bornes du gain. Plus bas que −60 dB, mieux vaut le silence, que porte ``OutputLevel/isMuted``.
    public static let gainRangeDecibels: ClosedRange<Float> = -60...0
    /// Durée de tout glissement, silence compris : dans la fourchette de 10 à 20 ms d'un fondu sans
    /// clic, et assez court pour qu'un curseur suive.
    public static let fadeSeconds: Double = 0.015

    public let channelCount: Int
    /// Trames d'un glissement complet.
    let fadeFrames: Int

    /// Consigne courante.
    public private(set) var level = OutputLevel.unity
    /// Gain linéaire visé, et gain appliqué à la dernière trame traitée.
    private var targetGain: Float = 1
    private var currentGain: Float = 1
    /// Glissement en cours : gain de départ, pas par trame, et trames déjà parcourues.
    private var rampStart: Float = 1
    private var rampStep: Float = 0
    private var rampPosition = 0
    private var isRamping = false

    public init(sampleRate: Double, channelCount: Int) {
        precondition(sampleRate > 0, "fréquence d'échantillonnage nulle")
        precondition(channelCount > 0, "nombre de canaux nul")
        self.channelCount = channelCount
        self.fadeFrames = max(1, Int((Self.fadeSeconds * sampleRate).rounded()))
    }

    /// Nouvelle consigne. Le gain y glisse en ``fadeSeconds`` ; une consigne inchangée ne relance rien.
    ///
    /// Un gain hors bornes est ramené dans la plage ; un gain non fini vaut 0 dB, comme le renfort de
    /// basses.
    public mutating func setLevel(_ newLevel: OutputLevel) {
        var sanitized = newLevel
        sanitized.gainDB =
            newLevel.gainDB.isFinite
            ? min(max(newLevel.gainDB, Self.gainRangeDecibels.lowerBound),
                  Self.gainRangeDecibels.upperBound)
            : 0
        level = sanitized
        let gain = Self.linearGain(for: sanitized)
        guard gain != targetGain else { return }
        targetGain = gain
        rampStart = currentGain
        rampStep = (gain - currentGain) / Float(fadeFrames)
        rampPosition = 0
        isRamping = true
    }

    /// Vrai quand `process` n'écrit rien : 0 dB, hors silence, aucun glissement en cours.
    public var isTransparent: Bool { !isRamping && currentGain == 1 }

    /// Vrai quand le fondu vers le silence est terminé : `process` n'écrit plus que des zéros.
    public var isSilent: Bool { !isRamping && currentGain == 0 }

    /// Gain linéaire appliqué à la dernière trame traitée.
    public var appliedGain: Float { currentGain }

    /// Rejoint la consigne sur-le-champ, sans glissement.
    ///
    /// À appeler après une coupure de flux, comme pour le renfort de basses : il n'y a plus de
    /// continuité à préserver, et une reprise ne doit pas partir d'un gain qui n'a plus cours.
    public mutating func reset() {
        currentGain = targetGain
        rampStart = targetGain
        rampStep = 0
        rampPosition = 0
        isRamping = false
    }

    /// Applique le gain à des échantillons entrelacés, sur place. Sans allocation.
    ///
    /// À n'appeler que sur une copie propre au sender, jamais sur le tampon partagé.
    public mutating func process(_ samples: UnsafeMutablePointer<Float>, frameCount: Int) {
        guard frameCount > 0, !isTransparent else { return }

        var frame = 0
        while frame < frameCount, isRamping {
            rampPosition += 1
            if rampPosition >= fadeFrames {
                // La dernière trame tombe exactement sur la consigne : 1 pour reprendre le
                // contournement au bit près, 0 pour un silence exact.
                currentGain = targetGain
                isRamping = false
            } else {
                currentGain = rampStart + rampStep * Float(rampPosition)
            }
            scale(samples + frame * channelCount, count: channelCount, by: currentGain)
            frame += 1
        }

        guard frame < frameCount, currentGain != 1 else { return }
        scale(
            samples + frame * channelCount, count: (frameCount - frame) * channelCount,
            by: currentGain
        )
    }

    // MARK: - Interne

    private func scale(_ samples: UnsafeMutablePointer<Float>, count: Int, by gain: Float) {
        var index = 0
        if gain == 0 {
            while index < count {
                samples[index] = 0
                index += 1
            }
            return
        }
        while index < count {
            samples[index] *= gain
            index += 1
        }
    }

    static func linearGain(for level: OutputLevel) -> Float {
        if level.isMuted { return 0 }
        if level.gainDB >= 0 { return 1 }
        return powf(10, level.gainDB / 20)
    }
}
