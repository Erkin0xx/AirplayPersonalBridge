import CryptoKit
import Foundation

@testable import AudioCore

/// Côté récepteur du pair-setup transitoire, **dans l'ordre réel du protocole**.
///
/// `SRPTestServer` ne peut pas tenir ce rôle : `srp_verifier_new` de csrp exige le `A` du client
/// pour produire `B`, alors qu'en HAP le récepteur envoie `B` au message M2, avant d'avoir vu `A`
/// (M3). D'où cette implémentation autonome, à usage de test uniquement.
///
/// Elle a un second mérite : écrite d'après les conventions d'AirPlay 2 (`ap2/pairing/srp.py` du
/// mock), et non d'après csrp, elle recoupe indépendamment le bourrage hybride du client — `u` et
/// `k` bourrés, `H(g)` non bourré. Un écart s'y verrait sur la preuve M1.
final class TransientSRPServer {
    /// Sel fixe : le vérificateur `v` s'en déduit par un calcul coûteux, qu'on ne fait qu'une fois.
    /// Premier octet non nul, csrp hachant le sel sous forme de nombre, sans zéros de tête.
    static let salt = Data((0..<16).map { UInt8(0xA0 &+ $0) })

    private static let context = MontgomeryContext(modulusHex: SRPClient.group3072N)
    private static let generator = [UInt8(5)]
    private static let moduleLength = 384

    /// `v = g^x`, avec `x = H(sel ‖ H("Pair-Setup:3939"))`.
    private static let verifier: [UInt64] = {
        let inner = Data(SHA512.hash(data: Data("Pair-Setup:\(AirPlay2PairingSession.transientPassword)".utf8)))
        let x = Data(SHA512.hash(data: salt + inner))
        return context.power(base: context.limbs(fromBigEndian: Data(generator)), exponent: x)
    }()

    /// `k = H(N ‖ PAD(g))`.
    private static let multiplier: [UInt64] = {
        let n = context.bigEndianBytes(context.modulus, width: moduleLength)
        let k = Data(SHA512.hash(data: n + padded(Data(generator))))
        return context.limbs(fromBigEndian: k)
    }()

    private let secret: Data
    /// `B = k·v + g^b`, à envoyer au message M2.
    let publicB: Data

    init() {
        var generator = SystemRandomNumberGenerator()
        // 128 bits suffisent à un test, et rendent l'échange dix fois plus rapide que 3072 bits.
        secret = Data((0..<16).map { _ in UInt8.random(in: 0...255, using: &generator) })
        let context = Self.context
        let gb = context.power(
            base: context.limbs(fromBigEndian: Data(Self.generator)), exponent: secret
        )
        let kv = context.multiply(Self.multiplier, Self.verifier)
        publicB = context.bigEndianBytes(context.add(kv, gb), width: Self.moduleLength)
    }

    /// Vérifie la preuve du client (M3) et rend la preuve du serveur et la clé de session (M4).
    ///
    /// - Returns: `nil` si la preuve du client ne correspond pas.
    func verify(clientPublic: Data, clientProof: Data) -> (serverProof: Data, sessionKey: Data)? {
        let context = Self.context
        let u = Data(SHA512.hash(data: Self.padded(clientPublic) + Self.padded(publicB)))
        // S = (A · v^u)^b
        let vu = context.power(base: Self.verifier, exponent: u)
        let base = context.multiply(context.limbs(fromBigEndian: clientPublic), vu)
        let shared = context.power(base: base, exponent: secret)
        let key = Data(
            SHA512.hash(
                data: Self.minimal(context.bigEndianBytes(shared, width: Self.moduleLength))))

        // M1 = H(H(N) ^ H(g), H(I), s, A, B, K). `H(g)` sur l'octet seul, **sans** bourrage :
        // c'est l'hybride propre à AirPlay 2.
        let hashN = Data(
            SHA512.hash(data: context.bigEndianBytes(context.modulus, width: Self.moduleLength)))
        let hashG = Data(SHA512.hash(data: Data(Self.generator)))
        let xored = Data(zip(hashN, hashG).map { $0 ^ $1 })
        let hashI = Data(SHA512.hash(data: Data(SRPClient.pairSetupUsername.utf8)))
        var material = xored + hashI + Self.salt
        material += Self.minimal(clientPublic)
        material += Self.minimal(publicB)
        material += key
        let expected = Data(SHA512.hash(data: material))
        guard expected == clientProof else { return nil }

        let serverProof = Data(SHA512.hash(data: Self.minimal(clientPublic) + expected + key))
        return (serverProof, key)
    }

    private static func padded(_ value: Data) -> Data {
        Data(repeating: 0, count: max(0, moduleLength - value.count)) + value
    }

    private static func minimal(_ value: Data) -> Data {
        Data(value.drop(while: { $0 == 0 }))
    }
}

/// Arithmétique modulaire de Montgomery, juste ce qu'il faut pour SRP.
///
/// Mots de 64 bits, ordre croissant. Écrite pour la clarté et non pour le temps constant : elle
/// ne sert qu'à jouer le récepteur dans les tests.
struct MontgomeryContext: Sendable {
    let modulus: [UInt64]
    private let inverse: UInt64
    private let rSquared: [UInt64]
    private var count: Int { modulus.count }

    init(modulusHex: String) {
        let digits = Array(modulusHex.utf8).map { byte -> UInt64 in
            byte <= UInt8(ascii: "9")
                ? UInt64(byte - UInt8(ascii: "0"))
                : UInt64((byte | 0x20) - UInt8(ascii: "a") + 10)
        }
        var limbs = [UInt64](repeating: 0, count: (digits.count + 15) / 16)
        for (position, digit) in digits.reversed().enumerated() {
            limbs[position / 16] |= digit << UInt64(position % 16 * 4)
        }
        modulus = limbs

        // Inverse de N modulo 2^64, par la méthode de Newton.
        var value: UInt64 = 1
        for _ in 0..<6 { value = value &* (2 &- limbs[0] &* value) }
        inverse = 0 &- value

        // R² mod N, par doublements successifs depuis 1.
        var running = [UInt64](repeating: 0, count: limbs.count)
        running[0] = 1
        for _ in 0..<(2 * 64 * limbs.count) {
            running = Self.addModulo(running, running, limbs)
        }
        rSquared = running
    }

    /// `a · b mod N`.
    func multiply(_ a: [UInt64], _ b: [UInt64]) -> [UInt64] {
        reduce(montgomery(montgomery(a, rSquared), montgomery(b, rSquared)))
    }

    func add(_ a: [UInt64], _ b: [UInt64]) -> [UInt64] {
        Self.addModulo(a, b, modulus)
    }

    /// `base ^ exponent mod N`, l'exposant en octets big-endian.
    func power(base: [UInt64], exponent: Data) -> [UInt64] {
        let montBase = montgomery(base, rSquared)
        var one = [UInt64](repeating: 0, count: count)
        one[0] = 1
        var result = montgomery(one, rSquared)
        for byte in exponent {
            for bit in (0..<8).reversed() {
                result = montgomery(result, result)
                if byte >> UInt8(bit) & 1 == 1 {
                    result = montgomery(result, montBase)
                }
            }
        }
        return reduce(result)
    }

    func limbs(fromBigEndian bytes: Data) -> [UInt64] {
        var limbs = [UInt64](repeating: 0, count: count)
        for (position, byte) in bytes.reversed().enumerated() where position < count * 8 {
            limbs[position / 8] |= UInt64(byte) << UInt64(position % 8 * 8)
        }
        return limbs
    }

    func bigEndianBytes(_ limbs: [UInt64], width: Int) -> Data {
        var output = [UInt8](repeating: 0, count: width)
        for position in 0..<width where position / 8 < limbs.count {
            output[width - 1 - position] = UInt8(truncatingIfNeeded: limbs[position / 8] >> UInt64(position % 8 * 8))
        }
        return Data(output)
    }

    private func reduce(_ value: [UInt64]) -> [UInt64] {
        var one = [UInt64](repeating: 0, count: count)
        one[0] = 1
        return montgomery(value, one)
    }

    /// Multiplication de Montgomery, méthode CIOS : `a · b · R⁻¹ mod N`.
    ///
    /// **Des `while` et des pointeurs, à dessein.** Ce calcul revient plus de mille fois par
    /// pair-setup, en compilation de test, donc sans optimisation : un `for` sur un intervalle et une
    /// fonction intermédiaire y coûtent cher à chaque tour. Écrit plus simplement, un pair-setup
    /// prenait 1,2 s de CPU, et la suite AirPlay 2 en occupait tous les cœurs pendant ses premières
    /// secondes : le pool `.global()` du process accusait 3,5 s de retard, ce qui faisait échouer
    /// les tests qui jugent une cadence en temps réel (« Une rafale de demandes… »).
    private func montgomery(_ a: [UInt64], _ b: [UInt64]) -> [UInt64] {
        let size = count
        let inverse = self.inverse
        var t = [UInt64](repeating: 0, count: size + 2)
        t.withUnsafeMutableBufferPointer { tBuffer in
            modulus.withUnsafeBufferPointer { nBuffer in
                a.withUnsafeBufferPointer { aBuffer in
                    b.withUnsafeBufferPointer { bBuffer in
                        guard let t = tBuffer.baseAddress, let n = nBuffer.baseAddress,
                            let a = aBuffer.baseAddress, let b = bBuffer.baseAddress
                        else { return }
                        var i = 0
                        while i < size {
                            let bi = b[i]
                            var carry: UInt64 = 0
                            var j = 0
                            while j < size {
                                // `t[j] + a[j]·bi + retenue`, qui tient toujours sur 128 bits.
                                let (high, low) = a[j].multipliedFullWidth(by: bi)
                                let (first, overflow1) = low.addingReportingOverflow(t[j])
                                let (second, overflow2) = first.addingReportingOverflow(carry)
                                t[j] = second
                                carry = high &+ (overflow1 ? 1 : 0) &+ (overflow2 ? 1 : 0)
                                j &+= 1
                            }
                            let (sum, overflow) = t[size].addingReportingOverflow(carry)
                            t[size] = sum
                            t[size + 1] = overflow ? 1 : 0

                            let m = t[0] &* inverse
                            let (firstHigh, firstLow) = m.multipliedFullWidth(by: n[0])
                            carry = firstHigh &+ (firstLow.addingReportingOverflow(t[0]).overflow ? 1 : 0)
                            j = 1
                            while j < size {
                                let (high, low) = m.multipliedFullWidth(by: n[j])
                                let (first, overflow1) = low.addingReportingOverflow(t[j])
                                let (second, overflow2) = first.addingReportingOverflow(carry)
                                t[j &- 1] = second
                                carry = high &+ (overflow1 ? 1 : 0) &+ (overflow2 ? 1 : 0)
                                j &+= 1
                            }
                            let (last, lastOverflow) = t[size].addingReportingOverflow(carry)
                            t[size &- 1] = last
                            t[size] = t[size + 1] &+ (lastOverflow ? 1 : 0)
                            i &+= 1
                        }
                    }
                }
            }
        }
        let overflowed = t[size] != 0
        var result = Array(t[0..<size])
        if overflowed || !Self.isLess(result, modulus) {
            result = Self.subtract(result, modulus)
        }
        return result
    }

    private static func isLess(_ a: [UInt64], _ b: [UInt64]) -> Bool {
        for index in a.indices.reversed() where a[index] != b[index] {
            return a[index] < b[index]
        }
        return false
    }

    private static func subtract(_ a: [UInt64], _ b: [UInt64]) -> [UInt64] {
        var result = a
        var borrow = false
        for index in a.indices {
            let (first, overflow1) = a[index].subtractingReportingOverflow(b[index])
            let (second, overflow2) = first.subtractingReportingOverflow(borrow ? 1 : 0)
            result[index] = second
            borrow = overflow1 || overflow2
        }
        return result
    }

    private static func addModulo(_ a: [UInt64], _ b: [UInt64], _ n: [UInt64]) -> [UInt64] {
        var result = a
        var carry = false
        for index in a.indices {
            let (first, overflow1) = a[index].addingReportingOverflow(b[index])
            let (second, overflow2) = first.addingReportingOverflow(carry ? 1 : 0)
            result[index] = second
            carry = overflow1 || overflow2
        }
        if carry || !isLess(result, n) {
            result = subtract(result, n)
        }
        return result
    }
}
