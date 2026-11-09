import AppKit
import AudioCore
import Foundation
import SwiftUI
import Testing

@testable import BridgeApp

/// Le panneau avec un message sous la Geneva, « Salon » juste dessous, en sombre et en clair. Inerte
/// tant que la variable n'est pas posée.
///
/// ```
/// MENUBAR_PNG_DIR=/chemin/dossier swift test --filter PanelMessageRenderingExport
/// ```
///
/// Même procédé que `MenuBarPanelExport` : une fenêtre jamais affichée, sur `SimulatedGlass`. Chaque
/// scène se rend deux fois : à la taille du panneau, puis dans une fenêtre restée à la hauteur d'avant le
/// message (`-fenetre-figee`), comme un panneau ouvert pendant que la Geneva cherche encore. C'est la
/// seconde qui montrait le chevauchement de la capture du 2026-11-09 (`PanelSpeakerRowLayoutTests`).
@Suite("Panneau — export d'un message sous une enceinte, à la demande")
struct PanelMessageRenderingExport {
    private static let genevaID = "raop/AABBCCDDEEFF@Geneva"

    /// `height` : celle de la fenêtre, à défaut celle que demande le contenu.
    private func writeHosted(
        _ view: some View, scheme: ColorScheme, height: CGFloat? = nil, to url: URL
    ) throws {
        let hosting = NSHostingView(
            rootView: view
                .environment(\.colorScheme, scheme)
                .environment(\.panelSimulatesGlass, true)
        )
        var size = hosting.fittingSize
        if let height { size.height = height }
        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.contentView = hosting
        hosting.frame = CGRect(origin: .zero, size: size)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        hosting.layoutSubtreeIfNeeded()
        let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: url)
    }

    private func panel(_ state: BridgeState, scheme: ColorScheme) -> some View {
        SimulatedGlass(scheme: scheme) {
            MenuBarPanelContent(
                state: state, loginItem: LoginItemController(service: PreviewLoginItemService())
            )
        }
    }

    /// En diffusion vers les HomePod, la Geneva dans l'état donné.
    private func streaming(geneva connection: OutputConnectionState) -> BridgeState {
        let state = BridgeState.preview(.streaming)
        state.outputs.first { $0.id == Self.genevaID }?.connection = connection
        return state
    }

    @Test(
        "Rend la Geneva en attente, message long puis enceinte introuvable, « Salon » juste dessous",
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

        // Le texte de la capture de Baptiste, complété comme la découverte l'écrivait ; puis celui que le
        // moteur relaie aujourd'hui pour la même Geneva éteinte.
        let seen = ["001122334455@Apple TV Salon", "6C4A85E2F1D0@Salon", "6C4A85E2F1D1@Salon (2)"]
        let messages = [
            "message-long": "aucun récepteur _raop._tcp correspondant à « F8F25A011261@Erki’s geneva » "
                + "(services vus : \(seen.joined(separator: ", ")))",
            "enceinte-introuvable":
                "\(RAOPDiscoveryError.notFound(name: "F8F25A011261@Erki’s geneva", seen: seen))",
        ]
        for scheme in [ColorScheme.dark, .light] {
            let suffix = scheme == .dark ? "sombre" : "clair"
            let beforeMessage = NSHostingView(
                rootView: panel(streaming(geneva: .connecting), scheme: scheme)
            ).fittingSize.height
            for (name, message) in messages {
                let waiting = OutputConnectionState.waiting(attempt: 2, message: message, nextAttemptAt: nil)
                try writeHosted(
                    panel(streaming(geneva: waiting), scheme: scheme), scheme: scheme,
                    to: directory.appending(path: "panneau-\(name)-\(suffix).png")
                )
                try writeHosted(
                    panel(streaming(geneva: waiting), scheme: scheme), scheme: scheme, height: beforeMessage,
                    to: directory.appending(path: "panneau-\(name)-fenetre-figee-\(suffix).png")
                )
            }
        }
    }
}
