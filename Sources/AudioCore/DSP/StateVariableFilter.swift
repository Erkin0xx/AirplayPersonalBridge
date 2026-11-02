import Foundation

/// Filtre à variables d'état en intégration trapézoïdale (TPT), d'après Andrew Simper (Cytomic,
/// « Linear Trapezoidal Integrated SVF », 2013) : la forme « SvfLinearTrapOptimised2 ».
///
/// ## Pourquoi cette topologie plutôt que le biquad transposé direct II
///
/// - **Modulation.** Ses deux états sont ceux de deux intégrateurs, l'équivalent numérique des
///   courants de deux condensateurs : ils ont un sens physique indépendant des coefficients.
///   Changer la fréquence ou le gain d'un échantillon au suivant laisse ces états valides, et la
///   sortie ne saute pas. Les états d'un biquad direct II sont des sommes de produits d'entrées et de
///   sorties passées **par les anciens coefficients** : les modifier rend ces états incohérents,
///   d'où des transitoires qui grandissent avec la vitesse de modulation.
/// - **Précision dans le grave.** À 30 Hz sous 48 kHz, les pôles d'un biquad sont à 0,3 % du cercle
///   unité et ses coefficients `a1 ≈ −1,9945`, `a2 ≈ 0,9945` : la réponse se lit dans leurs derniers
///   chiffres. Le SVF travaille sur `g = tan(π·f/fs) ≈ 0,002`, sans cette annulation.
/// - **Même réponse.** Ses fonctions de transfert sont exactement celles de l'« Audio EQ Cookbook »
///   (transformée bilinéaire prégauchie à la charnière) : le plateau grave de l'ADR-002 garde sa
///   courbe au bit près de l'arithmétique, seule la façon de la calculer change.
///
/// Un plateau à 0 dB a `m0 = 1`, `m1 = m2 = 0` : sa sortie **est** son entrée, quel que soit son état.
/// C'est ce qui rend le contournement de ``ToneControl`` exact sans attendre l'extinction d'une queue.
///
/// Sans allocation après `init` : l'état est réservé une fois pour toutes, un emplacement par canal.
struct StateVariableFilter: Sendable {
    /// Coefficients d'une forme : `a1…a3` pour la récurrence, `m0…m2` pour le mélange des sorties.
    struct Coefficients: Sendable, Equatable {
        var a1: Double
        var a2: Double
        var a3: Double
        var m0: Double
        var m1: Double
        var m2: Double

        /// Sortie égale à l'entrée.
        static let identity = Coefficients(a1: 1, a2: 0, a3: 0, m0: 1, m1: 0, m2: 0)

        /// Récurrence commune à toutes les formes, pour une pulsation prégauchie `g` et un
        /// amortissement `k = 1/Q`.
        private static func recurrence(g: Double, k: Double, m0: Double, m1: Double, m2: Double)
            -> Coefficients
        {
            let a1 = 1 / (1 + g * (g + k))
            let a2 = g * a1
            let a3 = g * a2
            return Coefficients(a1: a1, a2: a2, a3: a3, m0: m0, m1: m1, m2: m2)
        }

        /// `tan(π·f/fs)` : la charnière prégauchie, qui fait tomber la réponse numérique exactement
        /// sur la réponse analogique à cette fréquence-là.
        static func prewarp(cornerHz: Double, sampleRate: Double) -> Double {
            tan(Double.pi * min(cornerHz, 0.49 * sampleRate) / sampleRate)
        }

        /// Passe-haut d'ordre 2. Butterworth pour `q = 1/√2` : −3,01 dB à la coupure, 12 dB/octave.
        static func highPass(prewarped g: Double, q: Double) -> Coefficients {
            let k = 1 / q
            return recurrence(g: g, k: k, m0: 1, m1: -k, m2: -1)
        }

        /// Plateau grave (Simper ; identique au « low shelf » du cookbook à même charnière et même Q).
        static func lowShelf(prewarped g0: Double, q: Double, gainDecibels: Double) -> Coefficients {
            let a = pow(10, gainDecibels / 40)
            let k = 1 / q
            return recurrence(g: g0 / a.squareRoot(), k: k, m0: 1, m1: k * (a - 1), m2: a * a - 1)
        }

        /// Plateau aigu (Simper ; identique au « high shelf » du cookbook).
        static func highShelf(prewarped g0: Double, q: Double, gainDecibels: Double) -> Coefficients {
            let a = pow(10, gainDecibels / 40)
            let k = 1 / q
            return recurrence(
                g: g0 * a.squareRoot(), k: k, m0: a * a, m1: k * (1 - a) * a, m2: 1 - a * a
            )
        }
    }

    var coefficients: Coefficients
    private var ic1: [Double]
    private var ic2: [Double]

    init(channelCount: Int, coefficients: Coefficients = .identity) {
        self.coefficients = coefficients
        self.ic1 = [Double](repeating: 0, count: channelCount)
        self.ic2 = [Double](repeating: 0, count: channelCount)
    }

    /// Un échantillon d'un canal. Sans allocation, sans branchement.
    @inline(__always)
    mutating func tick(_ v0: Double, channel: Int) -> Double {
        let c = coefficients
        let s1 = ic1[channel]
        let s2 = ic2[channel]
        let v3 = v0 - s2
        let v1 = c.a1 * s1 + c.a2 * v3
        let v2 = s2 + c.a2 * s1 + c.a3 * v3
        ic1[channel] = 2 * v1 - s1
        ic2[channel] = 2 * v2 - s2
        return c.m0 * v0 + c.m1 * v1 + c.m2 * v2
    }

    /// Oublie l'historique : la sortie suivante ne doit plus rien à l'audio d'avant.
    mutating func clearState() {
        var channel = 0
        while channel < ic1.count {
            ic1[channel] = 0
            ic2[channel] = 0
            channel += 1
        }
    }
}
