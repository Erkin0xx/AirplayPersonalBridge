import Foundation

/// **Référence de test** : l'ancien renfort de basses (biquad RBJ en forme transposée directe II, puis
/// limiteur de crête pleine bande), tel qu'il était dans `Sources/AudioCore/DSP/LowShelfFilter.swift`
/// avant `ToneControl`. Code d'origine, seul le nom a changé.
///
/// Gardé pour que les tests de `ToneControl` mesurent ce qu'ils corrigent au lieu de l'affirmer : la
/// montée du plateau jusqu'au continu, et le pompage des médiums par le limiteur pleine bande.
struct LegacyLowShelfReference: Sendable {
    /// Fréquence charnière et facteur de qualité retenus par l'ADR-002.
    public static let defaultCornerHz: Double = 80
    public static let defaultQ: Double = 0.7
    /// Bornes du curseur de l'interface (ADR-002 : « 0 → +12 dB »). Un renfort seulement : le
    /// filtre n'est pas un égaliseur, et rien ne justifie de lui laisser creuser le grave.
    public static let gainRangeDecibels: ClosedRange<Double> = 0...12
    /// 12 dB en 50 ms : assez long pour ne rien entendre, assez court pour suivre le curseur.
    static let rampDecibelsPerSecond: Double = 240
    /// Un recalcul de coefficients toutes les 32 trames (≈ 0,7 ms) : le pas reste de 0,16 dB.
    static let rampStepFrames = 32
    /// Plafond de sortie du limiteur. Sous 1 pour laisser au rééchantillonneur la place de
    /// ses dépassements (Gibbs), qui écrêteraient sinon à la conversion en 16 bits.
    static let ceiling: Double = 0.98
    /// Constante de temps de remontée du limiteur. Bien au-dessus de la période des graves
    /// (25 ms à 40 Hz) : le gain tient d'une crête à l'autre au lieu de moduler l'onde.
    static let releaseSeconds: Double = 0.15
    /// Résidu sous lequel la queue du filtre est tenue pour éteinte (−240 dBFS).
    private static let silentResidual: Double = 1e-12
    /// Écart à 1 sous lequel le limiteur est tenu pour relâché (≈ 0,001 dB).
    private static let releasedGain: Double = 0.9999

    struct Coefficients: Sendable {
        var b0: Double = 1
        var b1: Double = 0
        var b2: Double = 0
        var a1: Double = 0
        var a2: Double = 0
    }

    public let sampleRate: Double
    public let channelCount: Int
    private let cornerHz: Double
    private let q: Double
    private let releaseStep: Double

    private var targetGain: Double = 0
    private var currentGain: Double = 0
    private(set) var coefficients = Coefficients()
    private var z1: [Double]
    private var z2: [Double]
    /// Sortie du biquad pour la trame en cours, avant limitation.
    private var frameOutput: [Double]
    private var limiterGain: Double = 1
    /// Trames écoulées depuis le dernier pas de rampe.
    private var framesSinceRampStep = 0

    public init(
        sampleRate: Double,
        channelCount: Int,
        cornerHz: Double = LegacyLowShelfReference.defaultCornerHz,
        q: Double = LegacyLowShelfReference.defaultQ
    ) {
        precondition(sampleRate > 0, "fréquence d'échantillonnage nulle")
        precondition(channelCount > 0, "nombre de canaux nul")
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.cornerHz = cornerHz
        self.q = q
        self.releaseStep = 1 - exp(-1 / (Self.releaseSeconds * sampleRate))
        self.z1 = [Double](repeating: 0, count: channelCount)
        self.z2 = [Double](repeating: 0, count: channelCount)
        self.frameOutput = [Double](repeating: 0, count: channelCount)
        self.coefficients = Self.coefficients(
            gainDecibels: 0, cornerHz: cornerHz, q: q, sampleRate: sampleRate
        )
    }

    /// Consigne de gain, en dB. Hors bornes, ou non finie, elle est ramenée dans la plage.
    public mutating func setGain(decibels: Double) {
        guard decibels.isFinite else {
            targetGain = 0
            return
        }
        targetGain = min(max(decibels, Self.gainRangeDecibels.lowerBound),
                         Self.gainRangeDecibels.upperBound)
    }

    /// Consigne courante, en dB.
    public var gainDecibels: Double { targetGain }

    /// Vrai quand `process` n'écrit rien : gain nul et queue du filtre éteinte.
    public var isTransparent: Bool {
        targetGain == 0 && currentGain == 0 && limiterGain == 1 && !hasResidualState
    }

    /// Oublie l'historique, sans toucher à la consigne.
    ///
    /// À appeler après une coupure de flux : la queue du filtre appartient à un audio qui ne
    /// sera jamais joué, et le gain du limiteur à des crêtes qui n'existent plus. Le gain
    /// rejoint directement sa consigne, puisqu'il n'y a plus de continuité à préserver.
    public mutating func reset() {
        for channel in 0..<channelCount {
            z1[channel] = 0
            z2[channel] = 0
        }
        limiterGain = 1
        framesSinceRampStep = 0
        currentGain = targetGain
        coefficients = Self.coefficients(
            gainDecibels: currentGain, cornerHz: cornerHz, q: q, sampleRate: sampleRate
        )
    }

    /// Applique le filtre à des échantillons entrelacés, sur place. Sans allocation.
    ///
    /// À n'appeler que sur une copie propre au sender, jamais sur le tampon partagé.
    public mutating func process(_ samples: UnsafeMutablePointer<Float>, frameCount: Int) {
        guard frameCount > 0, !isTransparent else { return }

        for frame in 0..<frameCount {
            advanceRamp()
            let base = frame * channelCount
            var peak = 0.0
            for channel in 0..<channelCount {
                // Une valeur non finie ne doit pas entrer : elle resterait dans l'état du
                // filtre, et tout ce qui suit deviendrait du silence ou du bruit.
                let raw = samples[base + channel]
                let input = raw.isFinite ? Double(raw) : 0
                let output = coefficients.b0 * input + z1[channel]
                z1[channel] = coefficients.b1 * input - coefficients.a1 * output + z2[channel]
                z2[channel] = coefficients.b2 * input - coefficients.a2 * output
                frameOutput[channel] = output
                peak = max(peak, abs(output))
            }

            // Sans anticipation : le gain descend à l'instant même où la crête l'exige. Il
            // suit donc l'onde pendant sa montée sans la découper, puis remonte lentement.
            let allowed = peak > Self.ceiling ? Self.ceiling / peak : 1
            if allowed < limiterGain {
                limiterGain = allowed
            } else if limiterGain < 1 {
                limiterGain += (1 - limiterGain) * releaseStep
                limiterGain = min(limiterGain, allowed)
                if limiterGain >= Self.releasedGain, allowed == 1 { limiterGain = 1 }
            }

            for channel in 0..<channelCount {
                samples[base + channel] = Float(frameOutput[channel] * limiterGain)
            }
        }

        if targetGain == 0, currentGain == 0, !hasResidualState {
            // Queue éteinte : poser un zéro exact, pour que le contournement soit bit à bit.
            for channel in 0..<channelCount {
                z1[channel] = 0
                z2[channel] = 0
            }
        }
    }

    // MARK: - Interne

    private var hasResidualState: Bool {
        for channel in 0..<channelCount {
            if abs(z1[channel]) > Self.silentResidual || abs(z2[channel]) > Self.silentResidual {
                return true
            }
        }
        return false
    }

    /// Fait glisser le gain vers sa consigne, par petits pas.
    private mutating func advanceRamp() {
        guard currentGain != targetGain else { return }
        framesSinceRampStep += 1
        guard framesSinceRampStep >= Self.rampStepFrames else { return }
        framesSinceRampStep = 0
        let step = Self.rampDecibelsPerSecond * Double(Self.rampStepFrames) / sampleRate
        if abs(targetGain - currentGain) <= step {
            currentGain = targetGain
        } else {
            currentGain += targetGain > currentGain ? step : -step
        }
        coefficients = Self.coefficients(
            gainDecibels: currentGain, cornerHz: cornerHz, q: q, sampleRate: sampleRate
        )
    }

    /// Plateau grave de l'« Audio EQ Cookbook » (R. Bristow-Johnson), normalisé sur `a0`.
    ///
    /// À 0 dB (`A = 1`), `b` et `a` sont égaux à l'arithmétique flottante près : avec un état
    /// nul, la sortie vaut exactement l'entrée. C'est ce qui rend le retour au contournement
    /// sans raccord audible.
    static func coefficients(
        gainDecibels: Double, cornerHz: Double, q: Double, sampleRate: Double
    ) -> Coefficients {
        let a = pow(10, gainDecibels / 40)
        let omega = 2 * Double.pi * cornerHz / sampleRate
        let cosine = cos(omega)
        let alpha = sin(omega) / (2 * q)
        let shelf = 2 * a.squareRoot() * alpha

        let b0 = a * ((a + 1) - (a - 1) * cosine + shelf)
        let b1 = 2 * a * ((a - 1) - (a + 1) * cosine)
        let b2 = a * ((a + 1) - (a - 1) * cosine - shelf)
        let a0 = (a + 1) + (a - 1) * cosine + shelf
        let a1 = -2 * ((a - 1) + (a + 1) * cosine)
        let a2 = (a + 1) + (a - 1) * cosine - shelf
        return Coefficients(
            b0: b0 / a0, b1: b1 / a0, b2: b2 / a0, a1: a1 / a0, a2: a2 / a0
        )
    }
}
