import AudioCore
import CoreAudio
import Foundation
import Testing

@testable import BridgeApp

/// Le vrai volume du Mac, par Core Audio. **Jamais lancé par défaut** : il change le volume de la
/// machine, d'un cran et le temps d'une lecture, puis rend la valeur d'origine.
///
/// ```
/// SYSTEM_VOLUME_TESTS=1 swift test --filter SystemVolumeIntegration
/// ```
///
/// Le silence n'est basculé que s'il ne peut rien faire entendre : couper un Mac qui joue, ou rétablir
/// un Mac dont le volume est à zéro. Sinon ce test-là ne fait rien.
@Suite(
    "Volume du Mac — Core Audio réel", .serialized,
    .enabled(if: ProcessInfo.processInfo.environment["SYSTEM_VOLUME_TESTS"] != nil)
)
struct SystemVolumeIntegrationTests {
    /// Compte les notifications, sur le MainActor.
    final class Counter {
        var value = 0
    }

    /// Rend la valeur d'origine, quoi qu'il arrive au test.
    private func restore(_ original: SystemOutputVolume.Reading) {
        if let volume = original.volume {
            SystemOutputVolume.setVolume(volume, on: original.deviceID)
        }
        if let muted = original.isMuted {
            SystemOutputVolume.setMuted(muted, on: original.deviceID)
        }
    }

    private static func close(_ a: Float?, _ b: Float) -> Bool {
        guard let a else { return false }
        return abs(a - b) < 0.01
    }

    @Test("Un cran de volume est vu par l'écouteur, puis la valeur d'origine est rendue")
    func volumeStepIsObserved() async throws {
        let original = try #require(SystemOutputVolume.read(), "aucune sortie par défaut")
        let volume = try #require(original.volume, "« \(original.deviceName) » n'a pas de volume réglable")
        defer { restore(original) }

        let control = LiveSystemVolumeControl()
        let notifications = Counter()
        control.startObserving { notifications.value += 1 }
        defer { control.stopObserving() }

        let target = volume + 1 / 16 <= 1 ? volume + 1 / 16 : volume - 1 / 16
        #expect(control.setVolume(target, on: original.deviceID))
        #expect(await eventually { notifications.value > 0 }, "l'écouteur n'a rien vu")
        #expect(Self.close(control.read()?.volume, target))

        let seen = notifications.value
        restore(original)
        #expect(await eventually { notifications.value > seen })
        #expect(Self.close(SystemOutputVolume.read()?.volume, volume))
    }

    @Test("Le silence est vu par l'écouteur, puis rendu, s'il ne fait rien entendre")
    func muteIsObserved() async throws {
        let original = try #require(SystemOutputVolume.read(), "aucune sortie par défaut")
        guard let muted = original.isMuted else { return }
        // Rétablir le son d'un Mac coupé qui a du volume le ferait entendre : on s'abstient.
        guard !muted || original.volume == 0 else { return }
        defer { restore(original) }

        let control = LiveSystemVolumeControl()
        let notifications = Counter()
        control.startObserving { notifications.value += 1 }
        defer { control.stopObserving() }

        #expect(control.setMuted(!muted, on: original.deviceID))
        #expect(await eventually { notifications.value > 0 }, "l'écouteur n'a rien vu")
        #expect(control.read()?.isMuted == !muted)
        restore(original)
        #expect(await eventually { SystemOutputVolume.read()?.isMuted == muted })
    }

    /// Bout en bout dans l'app, le temps d'une diffusion vers un sender sans réseau. La capture de test
    /// ne coupe pas le son local : les enceintes sont donc mises en silence d'abord, pour que le Mac le
    /// soit aussi pendant tout le test, et le master posé sur le volume du Mac, qui n'en change pas.
    @Test("Une diffusion règle le Mac, un cran du Mac déplace le master, l'arrêt rend tout")
    func sessionFollowsRealVolume() async throws {
        let original = try #require(SystemOutputVolume.read(), "aucune sortie par défaut")
        let volume = try #require(original.volume, "« \(original.deviceName) » n'a pas de volume réglable")
        defer { restore(original) }

        let harness = BridgeHarness(systemVolume: LiveSystemVolumeControl())
        harness.state.isMuted = true
        harness.state.masterVolumeDB = SystemVolumeLink.masterDB(forScalar: Double(volume))
        await harness.discover(raop: [Devices.genevaRAOP])
        await harness.startStreaming(expecting: [Devices.genevaID])
        #expect(harness.state.systemVolume.isActive)
        #expect(harness.store.stored.systemVolumeMemory?.deviceUID == original.deviceUID)
        #expect(await eventually { SystemOutputVolume.read()?.isMuted == true })
        #expect(Self.close(SystemOutputVolume.read()?.volume, volume))

        let target = volume + 1 / 16 <= 1 ? volume + 1 / 16 : volume - 1 / 16
        // Passé la fenêtre d'écho du réglage de départ, comme une touche pressée ensuite.
        try await Task.sleep(for: .milliseconds(50))
        SystemOutputVolume.setVolume(target, on: original.deviceID)
        let expected = SystemVolumeLink.masterDB(forScalar: Double(target))
        #expect(await eventually { abs(harness.state.masterVolumeDB - expected) < 0.6 })

        await harness.stopStreaming()
        #expect(!harness.state.systemVolume.isActive)
        #expect(harness.store.stored.systemVolumeMemory == nil)
        #expect(Self.close(SystemOutputVolume.read()?.volume, volume))
        #expect(SystemOutputVolume.read()?.isMuted == original.isMuted)
    }
}
