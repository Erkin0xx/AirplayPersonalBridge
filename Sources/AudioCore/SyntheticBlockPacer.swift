import AVFoundation
import Atomics
import Foundation

/// Ce qu'une source synthétique remet au fil qui la cadence : un bloc à la fois, dans une mémoire
/// allouée une fois pour toutes.
///
/// Les deux méthodes sont appelées depuis ce fil, qui suit les règles du callback de capture
/// (CDC section 13) : ni allocation, ni verrou, ni Swift Concurrency. Un générateur n'est jamais
/// appelé par deux fils à la fois : ``SyntheticBlockPacer/stop()`` attend la fin du sien avant
/// qu'un autre ne démarre.
protocol SyntheticBlockGenerator: AnyObject, Sendable {
    var blockFrames: Int { get }
    /// Calcule le bloc suivant.
    func renderNextBlock()
    /// Prête le dernier bloc calculé, le temps de `body`.
    func withBufferList(_ body: (UnsafePointer<AudioBufferList>) -> Void)
}

/// Le fil qui cadence une source synthétique au rythme du temps réel.
///
/// Partagé par la sinusoïde, les clics de mesure et le test de canaux : seul le contenu des blocs
/// les distingue. Un bloc part à chaque échéance (`échéance += durée d'un bloc`), jamais en
/// rafale : c'est le rythme d'un vrai périphérique, à la dérive près, et ce qui fait passer le
/// flux par les mêmes tampons que la vraie capture.
final class SyntheticBlockPacer: @unchecked Sendable {
    private let running = ManagedAtomic<Bool>(false)
    /// Signalé par le fil quand il a fini : `stop` l'attend, ce qui garantit qu'aucun bloc ne suit
    /// son retour.
    private let finished = DispatchSemaphore(value: 0)
    private var thread: Thread?
    private let threadName: String

    init(threadName: String) {
        self.threadName = threadName
    }

    deinit { stop() }

    /// Lance le fil. Sans effet s'il tourne déjà.
    ///
    /// - Returns: faux si le fil tournait déjà.
    @discardableResult
    func start<Generator: SyntheticBlockGenerator>(
        _ generator: Generator,
        sampleRate: Double,
        deliveringTo consumer: @escaping CaptureBlockConsumer
    ) -> Bool {
        guard running.compareExchange(
            expected: false, desired: true, ordering: .acquiringAndReleasing
        ).exchanged else { return false }

        let blockSeconds = Double(generator.blockFrames) / sampleRate
        let box = ConsumerBox(consumer)
        let thread = Thread { [running, finished] in
            let clock = ContinuousClock()
            var deadline = clock.now
            let period = Duration.seconds(blockSeconds)
            let frames = UInt32(generator.blockFrames)
            while running.load(ordering: .acquiring) {
                generator.renderNextBlock()
                generator.withBufferList { box.consumer($0, frames) }
                deadline += period
                let now = clock.now
                if deadline > now {
                    Thread.sleep(forTimeInterval: Self.seconds(deadline - now))
                } else if now - deadline > .seconds(1) {
                    // Veille de la machine : repartir de maintenant plutôt que de rattraper en
                    // rafale.
                    deadline = now
                }
            }
            finished.signal()
        }
        thread.name = threadName
        thread.qualityOfService = .userInteractive
        self.thread = thread
        thread.start()
        return true
    }

    /// Arrête le fil. **Au retour, plus aucun bloc n'est remis au consommateur.**
    func stop() {
        guard running.compareExchange(
            expected: true, desired: false, ordering: .acquiringAndReleasing
        ).exchanged else { return }
        finished.wait()
        thread = nil
    }

    private static func seconds(_ duration: Duration) -> TimeInterval {
        let (seconds, attoseconds) = duration.components
        return Double(seconds) + Double(attoseconds) / 1e18
    }
}

/// Une référence à ce bloc de code ne fait que traverser la frontière de création du fil.
private final class ConsumerBox: @unchecked Sendable {
    let consumer: CaptureBlockConsumer
    init(_ consumer: @escaping CaptureBlockConsumer) { self.consumer = consumer }
}
