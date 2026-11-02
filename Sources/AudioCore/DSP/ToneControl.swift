import Foundation

/// Égaliseur de la Geneva (ADR-002, révisé) : coupe des aigus, renfort des basses borné par un
/// passe-haut subsonique, correction dynamique du grave, et un limiteur de sécurité.
///
/// ## Chaîne, à la fréquence de capture
///
/// ```
/// x ─▶ plateau aigu (0 à −9 dB, 3 kHz) ─▶ z ──────────────────────────────┬─▶ z + d·m ─▶ limiteur ─▶
///                                         └▶ passe-haut 30 Hz ─▶ plateau grave (0 à +12 dB, 80 Hz) ─▶ − z = m
/// ```
///
/// Les trois filtres sont des SVF en intégration trapézoïdale (``StateVariableFilter``), dont les
/// réponses sont celles du cookbook de R. Bristow-Johnson : le plateau grave garde la charnière, le Q,
/// la plage et le glissement de l'ADR-002.
///
/// ## Où elle s'applique (invariant section 12)
///
/// Sur la **copie propre au sender RAOP**, extraite du ring buffer et pas encore rééchantillonnée. Le
/// tampon partagé n'est jamais touché : les HomePod reçoivent un flux intact. En flottant double, avant
/// la conversion en 16 bits, où un dépassement serait déjà un écrêtage.
///
/// ## Transparence
///
/// Basses à 0 dB et aigus à 0 dB : **contournée**, aucun échantillon n'est lu ni écrit, le flux ressort
/// identique au bit près. Un plateau SVF à 0 dB rend exactement son entrée quel que soit son état, et le
/// fondu du passe-haut à zéro aussi : le contournement reprend dès la fin des rampes, sans attendre
/// l'extinction d'une queue, et sans raccord audible puisque la sortie y valait déjà l'entrée.
///
/// ## Le passe-haut subsonique, et pourquoi un fondu enchaîné
///
/// Butterworth d'ordre 2 à ``subsonicCornerHz`` : −3 dB à 30 Hz, −7,8 dB à 20 Hz, 12 dB/octave. Le
/// plateau seul montait jusqu'au continu : à +12 dB, 20 à 30 Hz prenaient aussi +12 dB, que le boomer de
/// 152 mm ne restitue plus, et qui coûtaient de la marge, de l'excursion et la compression interne de
/// l'enceinte. Actif dès que le renfort demandé est > 0, il entre et sort par un **fondu enchaîné** de
/// ``subsonicFadeSeconds`` entre le signal et sa version filtrée, plutôt que par un glissement de sa
/// coupure depuis quelques hertz. Un glissement finit forcément par une commutation : le jour où on
/// coupe le filtre, la sortie repasse d'un coup de `HP(z)` à `z`, et l'écart y est fait de tout ce que
/// le filtre retenait, la composante continue d'une entrée physique comprise. Le fondu n'a aucun instant
/// de commutation : le continu revient en 50 ms. Son seul prix est un creux lisse, de 2 dB au plus vers
/// 40 Hz pendant ces 50 ms, quand les deux versions, déphasées, se mélangent à parts égales.
///
/// ## Correction dynamique du grave plutôt qu'un limiteur pleine bande
///
/// La sortie s'écrit `z + d·m` : le signal aux aigus réglés, plus la modification du grave `m` (passe-haut
/// et plateau), dosée par une profondeur `d` de 0 à 1. Quand `z + m` dépasserait le plafond, c'est `d`
/// qui recule, juste assez pour que la crête tienne sous ``ceiling`` : **le renfort du grave recule, les
/// médiums et les aigus n'y perdent rien**, au lieu de baisser tous ensemble comme sous l'ancien limiteur
/// (le « pompage »). Au pire `d = 0`, et la Geneva reçoit le grave d'origine, celui d'un renfort nul.
///
/// Pourquoi ce mélange après des filtres fixes, plutôt que moduler le gain du plateau lui-même : `d`
/// change à chaque crête, parfois d'un échantillon au suivant. Ici il ne touche à aucun coefficient ni à
/// aucun état de filtre, c'est un simple produit, donc rien ne peut y résonner ; et la sortie est linéaire
/// en `d`, ce qui donne la profondeur admissible par une division, exacte, à chaque trame. Les filtres
/// eux ne bougent qu'avec les curseurs, à ``rampDecibelsPerSecond``, et la topologie SVF les laisse
/// glisser échantillon par échantillon sans transitoire. `m` n'a presque rien au-dessus de 200 Hz : à
/// 1 kHz, sa part est un déphasage de 2°, si bien que doser `d` y change le niveau de moins de 0,01 dB.
///
/// Attaque **instantanée, sans anticipation** : la profondeur descend à la trame même où la crête l'exige,
/// donc aucun dépassement à rattraper, et aucun retard à compenser dans `OutputSynchronizer` (une
/// anticipation de N trames y imposerait un décalage de N trames, exactement, sous peine de désaligner la
/// Geneva des HomePod). Puis un **maintien** de ``bassHoldSeconds``, plus long que l'intervalle entre deux
/// crêtes d'un grave à 20 Hz : sur une note tenue, la profondeur reste fixe au lieu de remonter entre
/// chaque crête pour être rabattue à la suivante, ce qui modulerait le grave à sa propre fréquence et le
/// déformerait. Enfin une **remontée** de constante ``bassReleaseSeconds``.
///
/// ## Limiteur de sécurité
///
/// Pleine bande, relié entre canaux, plafond ``ceiling``, remontée 150 ms : celui de l'ancien filtre. Il
/// ne voit plus que ce que la correction du grave ne peut pas résoudre, c'est-à-dire une source qui
/// dépasse déjà le plafond sans aucun renfort : rarissime, et compté dans ``safetyLimitedFrames``.
///
/// ## Alignement (CDC 4.5)
///
/// **Aucun décalage de trame** : tout est causal et rend une sortie par entrée, sans tampon ni
/// anticipation, donc rien à compenser dans `OutputSynchronizer`. Il reste le retard de groupe, propre à
/// des filtres à phase minimale, et borné au grave :
///
/// | | 40 Hz | 80 Hz | 1 kHz |
/// |---|---|---|---|
/// | passe-haut 30 Hz seul | 5,0 ms | 1,2 ms | < 0,01 ms |
/// | plateau grave à +12 dB seul | 2,5 ms | 0 ms | < 0,02 ms |
/// | chaîne à +12 dB | 7,5 ms | 1,2 ms | < 0,01 ms |
/// | plateau aigu à −9 dB | < 0,05 ms | < 0,05 ms | 0,05 ms |
///
/// Le calage avec les HomePod se joue dans les médiums, où le retard ajouté reste sous 0,05 ms ; les
/// quelques millisecondes à 40 Hz, une fraction de période (25 ms), portent sur une bande que les HomePod
/// ne restituent presque pas. Chiffres vérifiés dans `DSPToneControlTests`.
public struct ToneControl: Sendable {
    // MARK: - Réglages

    /// Charnière et Q du plateau grave (ADR-002).
    public static let bassCornerHz: Double = 80
    public static let bassQ: Double = 0.7
    /// Bornes du curseur « Basses ». Un renfort seulement : rien ne justifie de creuser le grave.
    public static let bassRangeDecibels: ClosedRange<Double> = 0...12

    /// Charnière et Q du plateau aigu. 3 kHz : au-dessus de la voix, là où le décalage de la Geneva sur
    /// les HomePod produit un filtrage en peigne serré.
    public static let trebleCornerHz: Double = 3_000
    public static let trebleQ: Double = 0.7
    /// Bornes du curseur « Aigus ». Une coupe seulement : les HomePod portent l'image et le détail, la
    /// Geneva le corps.
    public static let trebleRangeDecibels: ClosedRange<Double> = -9...0

    /// Coupure du passe-haut subsonique. 30 Hz par défaut, sous la réponse utile du boomer de 152 mm de
    /// la Geneva ; **à ajuster par mesure** quand un micro aura relevé sa vraie coupure basse.
    public static let subsonicCornerHz: Double = 30
    /// Butterworth : la réponse la plus plate sans bosse au-dessus de la coupure.
    static let subsonicQ: Double = 1 / 2.0.squareRoot()

    /// 12 dB en 50 ms : assez long pour ne rien entendre, assez court pour suivre le curseur.
    static let rampDecibelsPerSecond: Double = 240
    /// Durée du fondu d'entrée et de sortie du passe-haut, celle d'une rampe complète des basses.
    static let subsonicFadeSeconds: Double = 0.05
    /// Plafond de sortie. Sous 1 pour laisser au rééchantillonneur la place de ses dépassements (Gibbs),
    /// qui écrêteraient sinon à la conversion en 16 bits.
    static let ceiling: Double = 0.98
    /// Cible de la correction du grave, un rien sous le plafond : `dry + d·m`, calculé avec la profondeur
    /// exacte, tombe sinon une fois sur deux un ulp au-dessus, et le limiteur de sécurité s'en mêlerait.
    private static let depthBound: Double = ceiling * (1 - 1e-12)
    /// Maintien de la correction du grave après la dernière crête qui l'a exigée : plus long que la
    /// demi-période d'un grave à 20 Hz, l'intervalle entre deux crêtes.
    static let bassHoldSeconds: Double = 0.025
    /// Constante de temps de la remontée du grave.
    static let bassReleaseSeconds: Double = 0.15
    /// Écart de profondeur sous lequel une crête est tenue pour la même que la précédente : elle
    /// prolonge le maintien au lieu de laisser la remontée commencer. 0,001, soit moins de 0,01 dB.
    static let bassHoldTolerance: Double = 1e-3
    /// Constante de temps de la remontée du limiteur de sécurité.
    static let limiterReleaseSeconds: Double = 0.15
    /// Écart à 1 sous lequel un gain est tenu pour relâché (≈ 0,001 dB).
    private static let releasedGain: Double = 0.9999

    public let sampleRate: Double
    public let channelCount: Int

    private let bassPrewarp: Double
    private let treblePrewarp: Double
    private let rampStep: Double
    private let fadeStep: Double
    private let holdFrames: Int
    private let bassReleaseStep: Double
    private let limiterReleaseStep: Double

    private var bassTarget: Double = 0
    private(set) var bassCurrent: Double = 0
    private var trebleTarget: Double = 0
    private(set) var trebleCurrent: Double = 0
    /// Part de la version filtrée par le passe-haut, de 0 à 1 : le fondu enchaîné.
    private(set) var subsonicMix: Double = 0

    private var treble: StateVariableFilter
    private var subsonic: StateVariableFilter
    private var bass: StateVariableFilter

    /// Profondeur de la modification du grave, `d` ci-dessus. 1 : tout le renfort réglé.
    private(set) var bassDepth: Double = 1
    private var holdRemaining = 0
    private(set) var limiterGain: Double = 1
    /// Trames où le limiteur de sécurité a dû baisser le signal. Diagnostic, jamais remis à zéro.
    private(set) var safetyLimitedFrames = 0

    /// Par canal, pour la trame en cours : le signal aux aigus réglés, puis la sortie.
    private var dry: [Double]
    /// Par canal, pour la trame en cours : la modification du grave `m`.
    private var wet: [Double]

    public init(sampleRate: Double, channelCount: Int) {
        precondition(sampleRate > 0, "fréquence d'échantillonnage nulle")
        precondition(channelCount > 0, "nombre de canaux nul")
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        bassPrewarp = StateVariableFilter.Coefficients.prewarp(
            cornerHz: Self.bassCornerHz, sampleRate: sampleRate
        )
        treblePrewarp = StateVariableFilter.Coefficients.prewarp(
            cornerHz: Self.trebleCornerHz, sampleRate: sampleRate
        )
        rampStep = Self.rampDecibelsPerSecond / sampleRate
        fadeStep = 1 / (Self.subsonicFadeSeconds * sampleRate)
        holdFrames = Int((Self.bassHoldSeconds * sampleRate).rounded())
        bassReleaseStep = 1 - exp(-1 / (Self.bassReleaseSeconds * sampleRate))
        limiterReleaseStep = 1 - exp(-1 / (Self.limiterReleaseSeconds * sampleRate))

        treble = StateVariableFilter(channelCount: channelCount)
        subsonic = StateVariableFilter(
            channelCount: channelCount,
            coefficients: .highPass(
                prewarped: StateVariableFilter.Coefficients.prewarp(
                    cornerHz: Self.subsonicCornerHz, sampleRate: sampleRate
                ),
                q: Self.subsonicQ
            )
        )
        bass = StateVariableFilter(channelCount: channelCount)
        dry = [Double](repeating: 0, count: channelCount)
        wet = [Double](repeating: 0, count: channelCount)
        updateBassCoefficients()
        updateTrebleCoefficients()
    }

    // MARK: - Consignes

    /// Renfort des basses, en dB. Hors bornes, il est ramené dans la plage ; non fini, il vaut 0.
    public mutating func setBassBoost(decibels: Double) {
        bassTarget = Self.clamped(decibels, to: Self.bassRangeDecibels)
    }

    /// Coupe des aigus, en dB (négatif). Hors bornes, elle est ramenée dans la plage ; non finie, 0.
    public mutating func setTrebleCut(decibels: Double) {
        trebleTarget = Self.clamped(decibels, to: Self.trebleRangeDecibels)
    }

    public var bassBoostDecibels: Double { bassTarget }
    public var trebleCutDecibels: Double { trebleTarget }

    /// Vrai quand `process` n'écrit rien : les deux réglages à 0 dB, rampes et fondu terminés.
    public var isTransparent: Bool { !isBassActive && !isTrebleActive && limiterGain == 1 }

    /// Oublie l'historique, sans toucher aux consignes.
    ///
    /// À appeler après une coupure de flux : l'état des filtres appartient à un audio qui ne sera jamais
    /// joué, et les gains de correction à des crêtes qui n'existent plus. Les réglages rejoignent
    /// directement leur consigne, puisqu'il n'y a plus de continuité à préserver.
    public mutating func reset() {
        treble.clearState()
        subsonic.clearState()
        bass.clearState()
        bassCurrent = bassTarget
        trebleCurrent = trebleTarget
        subsonicMix = bassTarget > 0 ? 1 : 0
        updateBassCoefficients()
        updateTrebleCoefficients()
        bassDepth = 1
        holdRemaining = 0
        limiterGain = 1
    }

    // MARK: - Traitement

    /// Applique la chaîne à des échantillons entrelacés, sur place. Sans allocation, sans verrou.
    ///
    /// À n'appeler que sur une copie propre au sender, jamais sur le tampon partagé.
    public mutating func process(_ samples: UnsafeMutablePointer<Float>, frameCount: Int) {
        guard frameCount > 0, !isTransparent else { return }

        // `while` plutôt que `for … in 0..<n` : hors optimisation, ce dernier alloue à chaque tour
        // (constaté par la sonde d'allocation des tests).
        var frame = 0
        while frame < frameCount {
            advanceRamps()
            let shapesTreble = isTrebleActive
            let shapesBass = isBassActive
            let base = frame * channelCount

            var allowedDepth = 1.0
            var channel = 0
            while channel < channelCount {
                // Une valeur non finie ne doit pas entrer : elle resterait dans l'état des filtres, et
                // tout ce qui suit deviendrait du silence ou du bruit.
                let raw = samples[base + channel]
                let input = raw.isFinite ? Double(raw) : 0
                let shaped = shapesTreble ? treble.tick(input, channel: channel) : input
                dry[channel] = shaped
                if shapesBass {
                    let highPassed = subsonic.tick(shaped, channel: channel)
                    let cleaned = shaped + subsonicMix * (highPassed - shaped)
                    let modification = bass.tick(cleaned, channel: channel) - shaped
                    wet[channel] = modification
                    allowedDepth = min(
                        allowedDepth, Self.allowedDepth(dry: shaped, modification: modification)
                    )
                }
                channel += 1
            }
            if shapesBass { followBassEnvelope(allowedDepth: allowedDepth) }

            var peak = 0.0
            channel = 0
            while channel < channelCount {
                let output = shapesBass ? dry[channel] + bassDepth * wet[channel] : dry[channel]
                dry[channel] = output
                peak = max(peak, abs(output))
                channel += 1
            }
            followLimiter(peak: peak)

            channel = 0
            while channel < channelCount {
                samples[base + channel] = Float(dry[channel] * limiterGain)
                channel += 1
            }
            frame += 1
        }

        // Un étage revenu au neutre rend déjà son entrée : son état ne servirait plus qu'à fausser sa
        // prochaine entrée en jeu, qui doit partir de zéro comme celle d'un filtre neuf.
        if !isTrebleActive { treble.clearState() }
        if !isBassActive {
            subsonic.clearState()
            bass.clearState()
            bassDepth = 1
            holdRemaining = 0
        }
    }

    // MARK: - Interne

    private var isBassActive: Bool { bassTarget != 0 || bassCurrent != 0 || subsonicMix != 0 }
    private var isTrebleActive: Bool { trebleTarget != 0 || trebleCurrent != 0 }

    /// La plus grande profondeur, de 0 à 1, qui garde `|dry + d·modification|` sous le plafond.
    ///
    /// La sortie est linéaire en `d` : elle croise le plafond en un seul point, que donne une division.
    /// Si le signal sans renfort dépasse déjà, aucune profondeur ne suffit, et c'est la plus utile qui
    /// est rendue (0 si le renfort aggrave la crête, 1 s'il la réduit) : le reste revient au limiteur.
    @inline(__always)
    static func allowedDepth(dry: Double, modification: Double) -> Double {
        let full = dry + modification
        guard abs(full) > ceiling, modification != 0 else { return 1 }
        let bound = full > 0 ? depthBound : -depthBound
        return min(max((bound - dry) / modification, 0), 1)
    }

    /// Attaque instantanée, maintien, puis remontée exponentielle.
    private mutating func followBassEnvelope(allowedDepth: Double) {
        if allowedDepth < bassDepth {
            bassDepth = allowedDepth
            holdRemaining = holdFrames
        } else if allowedDepth < 1, allowedDepth - bassDepth < Self.bassHoldTolerance {
            // La même crête revient : le grave est toujours trop fort, on tient.
            holdRemaining = holdFrames
        } else if holdRemaining > 0 {
            holdRemaining -= 1
        } else if bassDepth < 1 {
            bassDepth += (1 - bassDepth) * bassReleaseStep
            bassDepth = min(bassDepth, allowedDepth)
            if bassDepth >= Self.releasedGain, allowedDepth == 1 { bassDepth = 1 }
        }
    }

    /// Sans anticipation : le gain descend à l'instant même où la crête l'exige, puis remonte lentement.
    private mutating func followLimiter(peak: Double) {
        let allowed = peak > Self.ceiling ? Self.ceiling / peak : 1
        if allowed < limiterGain {
            limiterGain = allowed
        } else if limiterGain < 1 {
            limiterGain += (1 - limiterGain) * limiterReleaseStep
            limiterGain = min(limiterGain, allowed)
            if limiterGain >= Self.releasedGain, allowed == 1 { limiterGain = 1 }
        }
        if limiterGain < 1 { safetyLimitedFrames += 1 }
    }

    /// Fait glisser les réglages vers leur consigne, d'un pas par trame.
    @inline(__always)
    private mutating func advanceRamps() {
        if bassCurrent != bassTarget {
            bassCurrent = Self.step(bassCurrent, toward: bassTarget, by: rampStep)
            updateBassCoefficients()
        }
        if trebleCurrent != trebleTarget {
            trebleCurrent = Self.step(trebleCurrent, toward: trebleTarget, by: rampStep)
            updateTrebleCoefficients()
        }
        let mixTarget: Double = bassTarget > 0 ? 1 : 0
        if subsonicMix != mixTarget {
            subsonicMix = Self.step(subsonicMix, toward: mixTarget, by: fadeStep)
        }
    }

    private mutating func updateBassCoefficients() {
        bass.coefficients = .lowShelf(
            prewarped: bassPrewarp, q: Self.bassQ, gainDecibels: bassCurrent
        )
    }

    private mutating func updateTrebleCoefficients() {
        treble.coefficients = .highShelf(
            prewarped: treblePrewarp, q: Self.trebleQ, gainDecibels: trebleCurrent
        )
    }

    @inline(__always)
    private static func step(_ value: Double, toward target: Double, by step: Double) -> Double {
        if abs(target - value) <= step { return target }
        return value + (target > value ? step : -step)
    }

    private static func clamped(_ value: Double, to range: ClosedRange<Double>) -> Double {
        guard value.isFinite else { return 0 }
        return min(max(value, range.lowerBound), range.upperBound)
    }
}
