import Darwin
import Foundation

/// Base de temps de l'horloge hôte.
///
/// `mach_absolute_time` — l'horloge d'`AVAudioTime.hostTime` et des horodatages Core Audio — compte
/// des « ticks » de `numer / denom` nanosecondes : 125/3 sur Apple Silicon (un tick = 41,67 ns), 1/1
/// sur Intel. Elle ne compte pas la veille, ce qui est sans objet pendant une mesure.
public struct HostTimebase: Sendable, Equatable, Codable {
    public let numer: UInt32
    public let denom: UInt32

    public init(numer: UInt32, denom: UInt32) {
        precondition(numer > 0 && denom > 0, "base de temps nulle")
        self.numer = numer
        self.denom = denom
    }

    /// Celle de la machine.
    public static func current() -> HostTimebase {
        var info = mach_timebase_info_data_t()
        guard mach_timebase_info(&info) == KERN_SUCCESS, info.numer > 0, info.denom > 0 else {
            return HostTimebase(numer: 1, denom: 1)
        }
        return HostTimebase(numer: info.numer, denom: info.denom)
    }

    /// Ticks en nanosecondes, tronqués, **exacts** : `ticks = q·denom + r` donne `q·numer +
    /// ⌊r·numer / denom⌋`, sans le débordement d'un `ticks × numer` direct ni l'arrondi d'un `Double`.
    public func nanoseconds(fromTicks ticks: UInt64) -> UInt64 {
        let denominator = UInt64(denom)
        let numerator = UInt64(numer)
        return (ticks / denominator) * numerator + (ticks % denominator) * numerator / denominator
    }

    /// Nanosecondes en ticks, tronqués.
    public func ticks(fromNanoseconds nanoseconds: UInt64) -> UInt64 {
        let denominator = UInt64(denom)
        let numerator = UInt64(numer)
        return (nanoseconds / numerator) * denominator
            + (nanoseconds % numerator) * denominator / numerator
    }
}

/// Lecture des deux horloges, injectée pour que les tests maîtrisent l'une et l'autre.
public protocol HostClockReading: Sendable {
    /// `mach_absolute_time()`.
    func hostTicks() -> UInt64
    /// `Date().timeIntervalSince1970` : l'horloge de ``SharedPlaybackClock`` et des estampilles NTP.
    func unixTime() -> TimeInterval
}

public struct SystemHostClock: HostClockReading {
    public init() {}
    public func hostTicks() -> UInt64 { mach_absolute_time() }
    public func unixTime() -> TimeInterval { Date().timeIntervalSince1970 }
}

/// Un relevé simultané des deux horloges.
public struct WallHostPair: Sendable, Equatable, Codable {
    /// Instant Unix lu.
    public let unixTime: TimeInterval
    /// Instant hôte au milieu de l'encadrement de cette lecture, en nanosecondes.
    public let hostNanoseconds: UInt64
    /// Largeur de l'encadrement, en nanosecondes : le relevé est juste à ± sa moitié.
    public let uncertaintyNanoseconds: UInt64

    public init(unixTime: TimeInterval, hostNanoseconds: UInt64, uncertaintyNanoseconds: UInt64) {
        self.unixTime = unixTime
        self.hostNanoseconds = hostNanoseconds
        self.uncertaintyNanoseconds = uncertaintyNanoseconds
    }
}

/// Passage entre l'horloge commune et l'horloge hôte.
///
/// ## Ce qui est relié à quoi
///
/// - L'horloge commune (``SharedPlaybackClock``) date ses instants en **temps Unix**, lu par `Date`.
///   Les senders les annoncent tels quels en NTP (``NTPTime`` : Unix + 2 208 988 800 s) et répondent
///   au canal de timing avec la même horloge : c'est sur elle que les récepteurs se calent.
/// - Un micro date ses blocs en **ticks hôte** (`AVAudioTime.hostTime`, `mach_absolute_time`).
///
/// Ces deux horloges ne sont pas la même : l'horloge murale est l'horloge hôte plus un décalage que
/// `timed` (NTP) ajuste en continu, par petites pentes. Aucune API ne donne ce décalage, d'où le
/// relevé : une lecture de `Date` encadrée par deux lectures de `mach_absolute_time`, la plus serrée
/// d'une série gardée. L'encadrement tient en un tick sur cette machine (41 ns, relevé le
/// 2026-11-02) ; c'est la résolution d'un `Double` à 1,7 × 10⁹ s (0,24 µs) qui borne alors le relevé,
/// quatre cents fois sous le dixième de milliseconde visé.
///
/// Avec deux relevés, au début et à la fin d'une mesure, la correspondance suit la pente de
/// l'horloge murale entre les deux : un réglage NTP pendant la mesure n'y introduit pas d'erreur
/// linéaire. Avec un seul, la pente est supposée nulle.
public struct HostClockMapping: Sendable, Equatable {
    public let timebase: HostTimebase
    /// Relevés, dans l'ordre où ils ont été faits. Au moins un.
    public let pairs: [WallHostPair]

    public init(timebase: HostTimebase, pairs: [WallHostPair]) {
        precondition(!pairs.isEmpty, "correspondance sans relevé")
        self.timebase = timebase
        self.pairs = pairs
    }

    /// Relève les deux horloges ensemble.
    ///
    /// - Parameter attempts: lectures faites ; la plus serrée est gardée. Une préemption entre deux
    ///   lectures élargit l'encadrement d'une seule d'entre elles.
    public static func measure(
        clock: any HostClockReading = SystemHostClock(),
        timebase: HostTimebase = .current(),
        attempts: Int = 64
    ) -> WallHostPair {
        var bestBefore: UInt64 = 0
        var bestWidth = UInt64.max
        var bestUnix: TimeInterval = 0
        var attempt = 0
        while attempt < max(1, attempts) {
            let before = clock.hostTicks()
            let unix = clock.unixTime()
            let after = clock.hostTicks()
            attempt += 1
            guard after >= before else { continue }
            if after - before < bestWidth {
                bestWidth = after - before
                bestBefore = before
                bestUnix = unix
            }
        }
        if bestWidth == .max {
            // Horloge hôte qui recule à chaque lecture : impossible sur du vrai matériel, seule une
            // doublure le peut. Le relevé reste utilisable, sans encadrement.
            let host = clock.hostTicks()
            return WallHostPair(
                unixTime: clock.unixTime(),
                hostNanoseconds: timebase.nanoseconds(fromTicks: host),
                uncertaintyNanoseconds: .max
            )
        }
        return WallHostPair(
            unixTime: bestUnix,
            hostNanoseconds: timebase.nanoseconds(fromTicks: bestBefore + bestWidth / 2),
            uncertaintyNanoseconds: timebase.nanoseconds(fromTicks: bestWidth)
        )
    }

    /// Nanosecondes d'horloge hôte par seconde d'horloge murale, entre le premier et le dernier
    /// relevé. 1 × 10⁹ avec un seul relevé.
    public var hostNanosecondsPerUnixSecond: Double {
        guard let first = pairs.first, let last = pairs.last,
              last.unixTime != first.unixTime
        else { return 1e9 }
        return (Double(last.hostNanoseconds) - Double(first.hostNanoseconds))
            / (last.unixTime - first.unixTime)
    }

    /// Écart de rythme entre horloge murale et horloge hôte pendant la mesure, en ppm. Nul avec un
    /// seul relevé. Quelques ppm : `timed` ajuste l'heure. Au-delà de 100 : l'heure a été changée
    /// pendant la mesure, et la mesure est à refaire.
    public var rateDeviationPPM: Double {
        (hostNanosecondsPerUnixSecond / 1e9 - 1) * 1e6
    }

    /// Instant hôte, en nanosecondes, d'un instant Unix.
    public func hostNanoseconds(forUnixTime unixTime: TimeInterval) -> Double {
        guard let first = pairs.first else { return 0 }
        return Double(first.hostNanoseconds)
            + (unixTime - first.unixTime) * hostNanosecondsPerUnixSecond
    }

    /// Instant Unix d'un instant hôte en nanosecondes.
    public func unixTime(forHostNanoseconds nanoseconds: Double) -> TimeInterval {
        guard let first = pairs.first else { return 0 }
        return first.unixTime
            + (nanoseconds - Double(first.hostNanoseconds)) / hostNanosecondsPerUnixSecond
    }

    /// Instant hôte, en nanosecondes, d'un instant hôte en ticks (`AVAudioTime.hostTime`).
    public func hostNanoseconds(forTicks ticks: UInt64) -> UInt64 {
        timebase.nanoseconds(fromTicks: ticks)
    }
}
