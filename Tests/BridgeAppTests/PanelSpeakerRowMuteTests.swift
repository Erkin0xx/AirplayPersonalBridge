import AppKit
import AudioCore
import Foundation
import SwiftUI
import Testing

@testable import BridgeApp

@Suite("Panneau — silence par enceinte")
struct PanelSpeakerRowMuteTests {
    @Test("Le bouton coupe l'enceinte seule, sans la décocher ni la sortir du moteur")
    func buttonReachesEngine() async throws {
        let (harness, _, right) = try await pairHarnessForPanel()
        await harness.startStreaming(expecting: [Devices.leftID, Devices.rightID])
        let rightSender = try #require(harness.factory.latest(Devices.rightID))

        PanelSpeakerMute.toggle(right)
        #expect(right.isMuted)
        #expect(right.isEnabled)
        #expect(await eventually { await rightSender.pushedLevels.last?.isMuted == true })
        PanelSpeakerMute.toggle(right)
        #expect(await eventually { await rightSender.pushedLevels.last?.isMuted == false })
        #expect(await rightSender.stopCount == 0)
        #expect(harness.factory.senders(Devices.rightID).count == 1)
        await harness.stopStreaming()
    }

    @Test("L'état se lit : libellés, valeur et aide pour VoiceOver et au survol")
    func readableState() {
        let output = OutputState(
            id: Devices.rightID, displayName: "Salon (2)", host: "h", port: 1, proto: .airplay2
        )
        #expect(PanelSpeakerMute.accessibilityLabel(for: output) == "Couper le son de Salon (2)")
        #expect(PanelSpeakerMute.accessibilityValue(for: output) == "désactivé")
        #expect(PanelSpeakerMute.rowStateWord(for: output) == nil)
        output.isMuted = true
        #expect(PanelSpeakerMute.accessibilityValue(for: output) == "activé")
        #expect(PanelSpeakerMute.rowStateWord(for: output) == "son coupé")
        #expect(PanelSpeakerMute.sliderHelp(for: output).contains("coupé"))
        // Décochée, elle ne joue pas : son silence n'a rien à annoncer sur la rangée.
        output.isEnabled = false
        #expect(PanelSpeakerMute.rowStateWord(for: output) == nil)
    }

    /// Un nom de SF Symbol inconnu n'affiche rien, sans erreur (CLAUDE.md, « Widget et app »).
    @Test("Le symbole du bouton existe")
    func symbolExists() {
        #expect(NSImage(systemSymbolName: PanelSpeakerMuteButton.symbol, accessibilityDescription: nil) != nil)
    }
}

@MainActor
private func pairHarnessForPanel() async throws -> (BridgeHarness, left: OutputState, right: OutputState) {
    let harness = BridgeHarness()
    await harness.discover(airplay2: [PairDevices.left, PairDevices.right])
    let left = try #require(harness.output(Devices.leftID))
    let right = try #require(harness.output(Devices.rightID))
    left.trimDB = 0.5
    right.trimDB = -11.5
    return (harness, left, right)
}
