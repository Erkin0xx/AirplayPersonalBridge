import AVFoundation
import Foundation

/// Motif sonore périodique : des salves posées à des trames fixes d'un cycle, chacune sur ses
/// canaux, et du silence numérique strict partout ailleurs.
///
/// C'est la forme commune des deux signaux de mesure du CLI (``ClickPattern``,
/// ``ChannelTestPattern``) : un instant connu à la trame près, et un contenu qu'on sait reconnaître
/// à l'oreille ou au micro.
public struct SyntheticPattern: Sendable, Equatable {
    public struct Burst: Sendable, Equatable {
        /// Première trame de la salve, comptée depuis le début du cycle.
        public let startFrame: Int
        /// Forme d'onde, la même sur chacun des canaux visés.
        public let samples: [Float]
        public let onLeft: Bool
        public let onRight: Bool

        public init(startFrame: Int, samples: [Float], onLeft: Bool, onRight: Bool) {
            self.startFrame = startFrame
            self.samples = samples
            self.onLeft = onLeft
            self.onRight = onRight
        }
    }

    /// Longueur du cycle, en trames. Le motif se répète à l'identique au-delà.
    public let cycleFrames: Int
    public let bursts: [Burst]

    /// - Precondition: chaque salve tient dans le cycle. Une salve à cheval sur deux cycles serait
    ///   une erreur de construction du motif, pas une situation d'exécution.
    public init(cycleFrames: Int, bursts: [Burst]) {
        precondition(cycleFrames > 0, "cycle vide")
        for burst in bursts {
            precondition(
                burst.startFrame >= 0 && burst.startFrame + burst.samples.count <= cycleFrames,
                "salve hors du cycle"
            )
        }
        self.cycleFrames = cycleFrames
        self.bursts = bursts
    }

    /// Fenêtre de Hann « périodique » : nulle à la première trame, 1 au milieu.
    static func hann(_ index: Int, length: Int) -> Double {
        0.5 - 0.5 * cos(2 * Double.pi * Double(index) / Double(length))
    }

    /// Bip sinusoïdal à fondus d'entrée et de sortie en demi-cosinus, sans clic aux bords.
    static func beep(
        frequency: Double, frames: Int, fadeFrames: Int, amplitude: Double, sampleRate: Double
    ) -> [Float] {
        (0..<frames).map { index in
            let fade: Double
            if index < fadeFrames {
                fade = 0.5 - 0.5 * cos(Double.pi * Double(index) / Double(fadeFrames))
            } else if index >= frames - fadeFrames {
                fade = 0.5 - 0.5 * cos(Double.pi * Double(frames - 1 - index) / Double(fadeFrames))
            } else {
                fade = 1
            }
            return Float(amplitude * fade * sin(2 * Double.pi * frequency * Double(index) / sampleRate))
        }
    }
}

/// Salves de mesure du calage acoustique entre enceintes (`audiocap --clicks`).
///
/// Une salve de 5 ms à 3 kHz, en fenêtre de Hann, **commence à chaque trame de capture multiple de
/// 96 000** (toutes les 2 s à 48 kHz), sur les deux canaux. La salve d'indice `k` (trames
/// `k · 96 000`) est donc attendue à `instant de restitution de la trame 0 + 2 k` secondes, ce que
/// le JSON de `--record-input` permet de dater sur l'horloge hôte.
///
/// **Repère** : une salve sur cinq (`k` multiple de 5) est doublée d'une seconde salve, identique,
/// 250 ms plus tard. Elle lève l'ambiguïté modulo 2 s d'une enceinte très en retard : une mesure
/// d'au moins 10 s situe chaque enceinte modulo 10 s.
///
/// Pourquoi ces valeurs : 3 kHz est au cœur de la bande que capte n'importe quel micro de portable
/// et que restitue n'importe quelle enceinte, loin du ronflement secteur et des basses de la pièce ;
/// 5 ms en Hann donnent environ 800 Hz de bande, assez pour dater la salve au dixième de
/// milliseconde par filtrage adapté, et séparent deux enceintes à 5 ms d'écart. 250 ms dépassent
/// tout écart de calage plausible sans tomber dans la traîne de réverbération d'une pièce meublée.
public enum ClickPattern {
    public static let sampleRate: Double = 48_000
    /// Période des salves : 2 s à 48 kHz.
    public static let periodFrames = 96_000
    /// Durée d'une salve : 5 ms à 48 kHz. 15 périodes exactes de 3 kHz.
    public static let burstFrames = 240
    public static let burstFrequency: Double = 3_000
    /// Une salve sur `markerEvery` est doublée.
    public static let markerEvery = 5
    /// Écart entre une salve repère et sa doublure : 250 ms à 48 kHz.
    public static let markerOffsetFrames = 12_000

    /// Le motif complet : `markerEvery` périodes, la première doublée.
    public static func make(levelDBFS: Double) -> SyntheticPattern {
        let burst = burstSamples(amplitude: pow(10, levelDBFS / 20))
        var bursts = (0..<markerEvery).map { index in
            SyntheticPattern.Burst(
                startFrame: index * periodFrames, samples: burst, onLeft: true, onRight: true
            )
        }
        bursts.append(SyntheticPattern.Burst(
            startFrame: markerOffsetFrames, samples: burst, onLeft: true, onRight: true
        ))
        return SyntheticPattern(cycleFrames: markerEvery * periodFrames, bursts: bursts)
    }

    /// Forme d'une salve : cosinus centré sur la fenêtre, donc crête exactement au niveau demandé,
    /// au milieu de la salve (trame 120).
    static func burstSamples(amplitude: Double) -> [Float] {
        (0..<burstFrames).map { index in
            let phase = 2 * Double.pi * burstFrequency * Double(index - burstFrames / 2) / sampleRate
            return Float(amplitude * SyntheticPattern.hann(index, length: burstFrames) * cos(phase))
        }
    }
}

/// Test d'écoute gauche/droite (`audiocap --channel-test`).
///
/// Toutes les 4 s : à 0 s, **un** bip grave (400 Hz, 0,4 s) sur le canal **gauche seul** ; à 2 s,
/// **deux** bips aigus (1 600 Hz, 0,15 s chacun, 0,15 s d'écart) sur le canal **droit seul**.
/// Jamais les deux canaux à la fois. Hauteur et nombre de bips disent le canal sans ambiguïté,
/// même pour une enceinte seule qui mélangerait les deux canaux.
public enum ChannelTestPattern {
    public static let sampleRate: Double = 48_000
    public static let cycleFrames = 192_000
    public static let leftFrequency: Double = 400
    public static let leftStartFrame = 0
    public static let leftFrames = 19_200
    public static let rightFrequency: Double = 1_600
    /// Débuts des deux bips droits : 2,0 s et 2,3 s.
    public static let rightStartFrames = [96_000, 110_400]
    public static let rightFrames = 7_200
    /// Fondus de 10 ms.
    static let fadeFrames = 480

    public static func make(levelDBFS: Double) -> SyntheticPattern {
        let amplitude = pow(10, levelDBFS / 20)
        let low = SyntheticPattern.beep(
            frequency: leftFrequency, frames: leftFrames, fadeFrames: fadeFrames,
            amplitude: amplitude, sampleRate: sampleRate
        )
        let high = SyntheticPattern.beep(
            frequency: rightFrequency, frames: rightFrames, fadeFrames: fadeFrames,
            amplitude: amplitude, sampleRate: sampleRate
        )
        var bursts = [SyntheticPattern.Burst(
            startFrame: leftStartFrame, samples: low, onLeft: true, onRight: false
        )]
        for start in rightStartFrames {
            bursts.append(SyntheticPattern.Burst(
                startFrame: start, samples: high, onLeft: false, onRight: true
            ))
        }
        return SyntheticPattern(cycleFrames: cycleFrames, bursts: bursts)
    }
}

/// Source synthétique qui joue un ``SyntheticPattern`` en boucle, cadencée en temps réel.
///
/// Comme ``ToneCaptureSource`` : aucune capture Core Audio ni autorisation, et le fil de génération
/// suit les règles du callback de capture. Utilisée avec `--record-input`, elle laisse donc l'entrée
/// physique être **la seule** capture du processus (invariant section 12).
///
/// ## La graduation
///
/// Le générateur est créé une fois pour toutes et compte les trames qu'il produit, arrêts compris :
/// la trame `n` du motif est la `n`-ième trame remise depuis la création, donc la trame de capture
/// `n` de la session qui ouvre cette source. C'est ce qui place les clics exactement aux trames
/// `k · 96 000` de l'horloge commune.
public final class PatternCaptureSource: AudioCaptureSource, @unchecked Sendable {
    public let pattern: SyntheticPattern
    public let sampleRate: Double
    public let blockFrames: Int
    private let generator: PatternBlockGenerator
    private let pacer: SyntheticBlockPacer

    public var requiredPermission: CapturePermission.Kind? { nil }

    /// - Parameters:
    ///   - blockFrames: taille des blocs. 512 ne divise pas 96 000 : une salve tombe à cheval sur
    ///     deux blocs, ce qui ne change rien à sa position.
    public init(
        pattern: SyntheticPattern,
        sampleRate: Double = 48_000,
        blockFrames: Int = 512,
        threadName: String = "fr.baptiste.airplaymultioutput.pattern"
    ) {
        self.pattern = pattern
        self.sampleRate = sampleRate
        self.blockFrames = blockFrames
        self.generator = PatternBlockGenerator(pattern: pattern, blockFrames: blockFrames)
        self.pacer = SyntheticBlockPacer(threadName: threadName)
    }

    /// Les salves de mesure, au niveau crête demandé.
    public static func clicks(levelDBFS: Double) -> PatternCaptureSource {
        PatternCaptureSource(
            pattern: ClickPattern.make(levelDBFS: levelDBFS), sampleRate: ClickPattern.sampleRate,
            threadName: "fr.baptiste.airplaymultioutput.clicks"
        )
    }

    /// Le test gauche/droite, au niveau crête demandé.
    public static func channelTest(levelDBFS: Double) -> PatternCaptureSource {
        PatternCaptureSource(
            pattern: ChannelTestPattern.make(levelDBFS: levelDBFS),
            sampleRate: ChannelTestPattern.sampleRate,
            threadName: "fr.baptiste.airplaymultioutput.channel-test"
        )
    }

    /// Stéréo entrelacé, comme le Process Tap : le flux suit le chemin de la vraie capture.
    public func prepare() throws -> AVAudioFormat {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 2, interleaved: true
        ) else {
            throw AudioCaptureError.unsupportedFormat("motif \(sampleRate) Hz, stéréo")
        }
        return format
    }

    public func start(deliveringTo consumer: @escaping CaptureBlockConsumer) throws {
        pacer.start(generator, sampleRate: sampleRate, deliveringTo: consumer)
    }

    public func stop() {
        pacer.stop()
    }

    public func isAudioExpected() -> Bool? { true }
}

/// Génère les blocs stéréo entrelacés d'un motif, dans une mémoire allouée une fois pour toutes.
///
/// Les salves sont recopiées à la construction dans des tableaux bruts : le fil de génération ne
/// touche ni `Array` ni référence comptée, et chaque trame se calcule en parcourant la poignée de
/// salves du motif.
final class PatternBlockGenerator: SyntheticBlockGenerator, @unchecked Sendable {
    let blockFrames: Int
    let cycleFrames: Int
    private let burstCount: Int
    private let starts: UnsafeMutablePointer<Int>
    private let lengths: UnsafeMutablePointer<Int>
    private let poolOffsets: UnsafeMutablePointer<Int>
    /// Bit 0 : canal gauche, bit 1 : canal droit.
    private let channelMasks: UnsafeMutablePointer<UInt8>
    private let pool: UnsafeMutablePointer<Float>
    private let poolCount: Int
    private let samples: UnsafeMutablePointer<Float>
    private let list: UnsafeMutableAudioBufferListPointer

    /// Trame de capture de la première trame du **prochain** bloc.
    private(set) var framePosition = 0

    init(pattern: SyntheticPattern, blockFrames: Int) {
        self.blockFrames = blockFrames
        self.cycleFrames = pattern.cycleFrames
        let count = pattern.bursts.count
        self.burstCount = count
        self.starts = .allocate(capacity: max(1, count))
        self.lengths = .allocate(capacity: max(1, count))
        self.poolOffsets = .allocate(capacity: max(1, count))
        self.channelMasks = .allocate(capacity: max(1, count))
        let total = pattern.bursts.reduce(0) { $0 + $1.samples.count }
        self.poolCount = max(1, total)
        self.pool = .allocate(capacity: max(1, total))
        pool.initialize(repeating: 0, count: max(1, total))

        var offset = 0
        for (index, burst) in pattern.bursts.enumerated() {
            starts[index] = burst.startFrame
            lengths[index] = burst.samples.count
            poolOffsets[index] = offset
            channelMasks[index] = (burst.onLeft ? 1 : 0) | (burst.onRight ? 2 : 0)
            for (sampleIndex, value) in burst.samples.enumerated() {
                pool[offset + sampleIndex] = value
            }
            offset += burst.samples.count
        }

        self.samples = .allocate(capacity: blockFrames * 2)
        samples.initialize(repeating: 0, count: blockFrames * 2)
        self.list = AudioBufferList.allocate(maximumBuffers: 1)
        list[0] = AudioBuffer(
            mNumberChannels: 2,
            mDataByteSize: UInt32(blockFrames * 2 * MemoryLayout<Float>.size),
            mData: UnsafeMutableRawPointer(samples)
        )
    }

    deinit {
        starts.deallocate()
        lengths.deallocate()
        poolOffsets.deallocate()
        channelMasks.deallocate()
        pool.deinitialize(count: poolCount)
        pool.deallocate()
        samples.deinitialize(count: blockFrames * 2)
        samples.deallocate()
        free(list.unsafeMutablePointer)
    }

    /// Boucles `while` : hors optimisation, `for … in 0..<n` alloue à chaque tour, et ce fil suit
    /// les règles du callback de capture.
    func renderNextBlock() {
        var cyclePosition = framePosition % cycleFrames
        var frame = 0
        while frame < blockFrames {
            var left: Float = 0
            var right: Float = 0
            var index = 0
            while index < burstCount {
                let offset = cyclePosition - starts[index]
                if offset >= 0, offset < lengths[index] {
                    let value = pool[poolOffsets[index] + offset]
                    let mask = channelMasks[index]
                    if mask & 1 != 0 { left += value }
                    if mask & 2 != 0 { right += value }
                }
                index += 1
            }
            samples[frame * 2] = left
            samples[frame * 2 + 1] = right
            cyclePosition += 1
            if cyclePosition == cycleFrames { cyclePosition = 0 }
            frame += 1
        }
        framePosition += blockFrames
    }

    func withBufferList(_ body: (UnsafePointer<AudioBufferList>) -> Void) {
        body(UnsafePointer(list.unsafePointer))
    }
}
