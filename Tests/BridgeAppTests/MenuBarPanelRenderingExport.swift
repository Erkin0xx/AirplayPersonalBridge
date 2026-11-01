import AppKit
import Foundation
import SwiftUI
import Testing

@testable import BridgeApp

/// Rend le panneau de la barre de menus hors écran, sans lancer l'app : celle-ci découvrirait le
/// vrai matériel et ouvrirait les fenêtres d'autorisation de macOS.
///
/// Inerte tant que la variable d'environnement n'est pas posée.
///
/// ```
/// MENUBAR_PNG_DIR=/chemin/dossier swift test --filter MenuBarPanelExport
/// ```
@Suite("Panneau de la barre de menus — export à la demande")
struct MenuBarPanelExport {
    private func write(_ view: some View, scheme: ColorScheme, to url: URL) throws {
        let renderer = ImageRenderer(content: view.environment(\.colorScheme, scheme))
        renderer.scale = 2
        // Les couleurs dynamiques se résolvent sur l'apparence courante du dessin, pas sur
        // l'environnement SwiftUI : hors d'une fenêtre, il faut la poser soi-même.
        let appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        var image: CGImage?
        (appearance ?? NSAppearance.currentDrawing()).performAsCurrentDrawingAppearance {
            image = renderer.cgImage
        }
        let rendered = try #require(image)
        let data = try #require(
            NSBitmapImageRep(cgImage: rendered).representation(using: .png, properties: [:])
        )
        try data.write(to: url)
    }

    /// `ImageRenderer` remplace les contrôles AppKit par un rectangle barré, dont le menu des
    /// sources. Une vue dans une fenêtre jamais affichée les dessine pour de bon.
    private func writeHosted(_ view: some View, scheme: ColorScheme, to url: URL) throws {
        let hosting = NSHostingView(rootView: view)
        let appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: hosting.fittingSize),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.appearance = appearance
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
        "Rend le panneau dans chaque situation, en sombre et en clair",
        .enabled(if: ProcessInfo.processInfo.environment["MENUBAR_PNG_DIR"] != nil)
    )
    func renderScenes() throws {
        let path = try #require(ProcessInfo.processInfo.environment["MENUBAR_PNG_DIR"])
        let directory = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        for scene in BridgeState.PanelScene.allCases {
            let service =
                scene == .startFailed
                ? PreviewLoginItemService(status: .requiresApproval)
                : PreviewLoginItemService(status: scene == .streaming ? .enabled : .disabled)
            for scheme in [ColorScheme.dark, .light] {
                let panel = MenuBarPanelContent(
                    state: .preview(scene),
                    loginItem: LoginItemController(service: service)
                )
                let suffix = scheme == .dark ? "sombre" : "clair"
                try writeHosted(
                    panel, scheme: scheme,
                    to: directory.appending(path: "panneau-\(scene.rawValue)-\(suffix).png")
                )
            }
        }

        // Les quatre icônes à leur taille réelle, pour juger de ce qu'on distingue dans la barre.
        for scheme in [ColorScheme.dark, .light] {
            let strip = HStack(spacing: 16) {
                ForEach(MenuBarStatus.allCases, id: \.symbolName) { status in
                    VStack(spacing: 6) {
                        Image(systemName: status.symbolName)
                            .font(.system(size: 15))
                            .frame(height: 22)
                        Text(status.symbolName)
                            .font(.system(size: 7))
                    }
                    .frame(width: 96)
                }
            }
            .foregroundStyle(scheme == .dark ? Color.white : Color.black)
            .padding(10)
            .background(scheme == .dark ? Color.black : Color.white)
            let suffix = scheme == .dark ? "sombre" : "clair"
            try write(strip, scheme: scheme, to: directory.appending(path: "icones-\(suffix).png"))
        }
    }
}
