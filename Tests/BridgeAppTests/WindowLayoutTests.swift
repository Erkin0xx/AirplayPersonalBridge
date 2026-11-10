import CoreGraphics
import Foundation
import Testing

@testable import BridgeApp

/// Le choix de la vue de la fenêtre, et le fond qu'elles partagent.
@Suite("Fenêtre — vue choisie et fond")
struct WindowLayoutTests {
    @Test("Chaque vue se relit des réglages")
    func layoutRoundTrip() throws {
        for layout in WindowLayout.allCases {
            var settings = BridgeSettings()
            settings.windowLayout = layout
            let data = try JSONEncoder().encode(settings)
            #expect(try JSONDecoder().decode(BridgeSettings.self, from: data).windowLayout == layout)
        }
    }

    @Test("Un fichier d'avant ce choix, ou une vue inconnue, donne la vue par défaut sans rien perdre d'autre")
    func unknownLayoutFallsBack() throws {
        let old = Data(#"{"masterVolumeDB": -31, "isMuted": true}"#.utf8)
        let fromOld = try JSONDecoder().decode(BridgeSettings.self, from: old)
        #expect(fromOld.windowLayout == .default)
        #expect(fromOld.masterVolumeDB == -31)

        let unknown = Data(#"{"masterVolumeDB": -31, "windowLayout": "hologramme"}"#.utf8)
        let fromUnknown = try JSONDecoder().decode(BridgeSettings.self, from: unknown)
        #expect(fromUnknown.windowLayout == .default)
        #expect(fromUnknown.masterVolumeDB == -31)
    }

    @Test("Changer de vue ne touche ni à la diffusion ni aux enceintes")
    func switchingLayoutIsVisualOnly() {
        let state = BridgeState.preview(.streaming)
        let phase = state.streamingPhase
        let enabled = state.outputs.map(\.isEnabled)
        let master = state.masterVolumeDB
        for layout in WindowLayout.allCases {
            state.windowLayout = layout
            #expect(state.windowLayout == layout)
        }
        #expect(state.streamingPhase == phase)
        #expect(state.outputs.map(\.isEnabled) == enabled)
        #expect(state.masterVolumeDB == master)
    }

    @Test("Le fond vit quand un son part, et seulement alors")
    func audibleStreaming() {
        let streaming = BridgeState.preview(.streaming)
        #expect(streaming.isAudiblyStreaming)
        streaming.isMuted = true
        #expect(!streaming.isAudiblyStreaming)
        #expect(!BridgeState.preview(.idle).isAudiblyStreaming)
    }
}
