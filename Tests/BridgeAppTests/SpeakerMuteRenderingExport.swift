import AppKit
import Foundation
import SwiftUI
import Testing

@testable import BridgeApp

/// Le panneau avec un HomePod coupé, en sombre et en clair. Inerte tant que la variable n'est pas posée.
///
/// ```
/// MENUBAR_PNG_DIR=/chemin/dossier swift test --filter SpeakerMuteRenderingExport
/// ```
///
/// Même procédé que `MenuBarPanelExport` : une fenêtre jamais affichée, sur `SimulatedGlass`.
@Suite("Panneau — export d'un HomePod coupé, à la demande")
struct SpeakerMuteRenderingExport {
    private func writeHosted(_ view: some View, scheme: ColorScheme, to url: URL) throws {
        let hosting = NSHostingView(
            rootView: view
                .environment(\.colorScheme, scheme)
                .environment(\.panelSimulatesGlass, true)
        )
        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: hosting.fittingSize),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.contentView = hosting
        hosting.frame = CGRect(origin: .zero, size: hosting.fittingSize)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        hosting.layoutSubtreeIfNeeded()
        let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: url)
    }

    @Test(
        "Rend le panneau en diffusion, « Salon (2) » coupé, en sombre et en clair",
        .enabled(if: ProcessInfo.processInfo.environment["MENUBAR_PNG_DIR"] != nil)
    )
    func render() throws {
        let path = try #require(ProcessInfo.processInfo.environment["MENUBAR_PNG_DIR"])
        let directory = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Le tout premier rendu d'un processus sort blanc : on l'écarte.
        try writeHosted(
            Color.clear.frame(width: 10, height: 10), scheme: .dark,
            to: directory.appending(path: ".amorce.png")
        )

        let mutedID = "airplay2/Salon (2)"
        for scheme in [ColorScheme.dark, .light] {
            let suffix = scheme == .dark ? "sombre" : "clair"
            for (name, hovered) in [("enceinte-coupee", nil), ("enceinte-coupee-survol", mutedID)] {
                let state = BridgeState.preview(.streaming)
                state.outputs.first { $0.id == mutedID }?.isMuted = true
                try writeHosted(
                    SimulatedGlass(scheme: scheme) {
                        MenuBarPanelContent(
                            state: state,
                            loginItem: LoginItemController(service: PreviewLoginItemService()),
                            preview: PanelPreviewOptions(hoveredSpeakerID: hovered)
                        )
                    }, scheme: scheme,
                    to: directory.appending(path: "panneau-\(name)-\(suffix).png")
                )
            }
        }
    }
}
