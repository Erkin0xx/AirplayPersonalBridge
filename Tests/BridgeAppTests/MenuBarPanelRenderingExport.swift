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
///
/// **Les matériaux ne se rendent pas hors écran** : un flou d'arrière-plan et le verre lisent ce que
/// le serveur de fenêtres compose derrière eux, et `cacheDisplay` n'y a pas accès. Le panneau est donc
/// posé ici sur `SimulatedGlass`, une approximation du matériau de `MenuBarExtra` au-dessus d'un fond
/// d'écran coloré. Mise en page, alignements et contrastes se jugent sur ces images ; le rendu du verre
/// ne se juge que dans l'app.
@Suite("Panneau de la barre de menus — export à la demande")
struct MenuBarPanelExport {
    /// `ImageRenderer` remplace les contrôles AppKit par un rectangle barré, dont le menu des
    /// sources. Une vue dans une fenêtre jamais affichée les dessine pour de bon.
    private func writeHosted(_ view: some View, scheme: ColorScheme, to url: URL) throws {
        let hosting = NSHostingView(
            rootView: view
                .environment(\.colorScheme, scheme)
                .environment(\.panelSimulatesGlass, true)
        )
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

        // Le tout premier rendu d'un processus sort blanc : on l'écarte.
        try writeHosted(
            Color.clear.frame(width: 10, height: 10), scheme: .dark,
            to: directory.appending(path: ".amorce.png")
        )

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
                    SimulatedGlass(scheme: scheme) { panel }, scheme: scheme,
                    to: directory.appending(path: "panneau-\(scene.rawValue)-\(suffix).png")
                )
            }
        }

        // Ce que seule la souris fait apparaître : options dépliées, survol, valeur en dB.
        for scheme in [ColorScheme.dark, .light] {
            let panel = MenuBarPanelContent(
                state: .preview(.listeningPlaces),
                loginItem: LoginItemController(service: PreviewLoginItemService()),
                preview: PanelPreviewOptions(
                    expandsOptions: true, hoveredSpeakerID: "airplay2/Salon", showsVolumeValue: true
                )
            )
            let suffix = scheme == .dark ? "sombre" : "clair"
            try writeHosted(
                SimulatedGlass(scheme: scheme) { panel }, scheme: scheme,
                to: directory.appending(path: "panneau-survol-options-\(suffix).png")
            )

            let muted = BridgeState.preview(.streaming)
            muted.isMuted = true
            try writeHosted(
                SimulatedGlass(scheme: scheme) {
                    MenuBarPanelContent(
                        state: muted,
                        loginItem: LoginItemController(service: PreviewLoginItemService())
                    )
                }, scheme: scheme,
                to: directory.appending(path: "panneau-son-coupe-\(suffix).png")
            )

            // Le tiroir des basses et des aigus de la Geneva, en diffusion puis décochée : il agit dans les deux cas.
            let genevaID = "raop/AABBCCDDEEFF@Geneva"
            try writeHosted(
                SimulatedGlass(scheme: scheme) {
                    MenuBarPanelContent(
                        state: .preview(.streaming),
                        loginItem: LoginItemController(service: PreviewLoginItemService()),
                        preview: PanelPreviewOptions(openDrawerSpeakerID: genevaID)
                    )
                }, scheme: scheme,
                to: directory.appending(path: "panneau-basses-aigus-ouvert-\(suffix).png")
            )

            let unchecked = BridgeState.preview(.idle)
            unchecked.outputs.first { $0.id == genevaID }?.isEnabled = false
            try writeHosted(
                SimulatedGlass(scheme: scheme) {
                    MenuBarPanelContent(
                        state: unchecked,
                        loginItem: LoginItemController(service: PreviewLoginItemService()),
                        preview: PanelPreviewOptions(openDrawerSpeakerID: genevaID)
                    )
                }, scheme: scheme,
                to: directory.appending(path: "panneau-basses-aigus-decochee-\(suffix).png")
            )

            let mutedWithDrawer = BridgeState.preview(.streaming)
            mutedWithDrawer.isMuted = true
            try writeHosted(
                SimulatedGlass(scheme: scheme) {
                    MenuBarPanelContent(
                        state: mutedWithDrawer,
                        loginItem: LoginItemController(service: PreviewLoginItemService()),
                        preview: PanelPreviewOptions(expandsOptions: true, openDrawerSpeakerID: genevaID)
                    )
                }, scheme: scheme,
                to: directory.appending(path: "panneau-son-coupe-basses-aigus-options-\(suffix).png")
            )
        }

        try MenuBarGlyphSheet.write(to: directory)
    }
}

/// Une approximation du matériau du panneau, pour les rendus d'essai uniquement. Partagée avec
/// `SpeakerMuteRenderingExport`.
struct SimulatedGlass<Content: View>: View {
    let scheme: ColorScheme
    @ViewBuilder var content: Content

    var body: some View {
        content
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .background {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(scheme == .dark ? Color(white: 0.13).opacity(0.86) : Color(white: 0.95).opacity(0.86))
                    .overlay {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(.white.opacity(scheme == .dark ? 0.14 : 0.5), lineWidth: 1)
                    }
            }
            .padding(14)
            .background {
                // Le fond d'écran de la capture de Baptiste : assez coloré pour trahir un contraste
                // qui ne tiendrait que sur un gris uni.
                LinearGradient(
                    colors: scheme == .dark
                        ? [Color(red: 0.08, green: 0.1, blue: 0.2), Color(red: 0.42, green: 0.14, blue: 0.3),
                           Color(red: 0.8, green: 0.45, blue: 0.2)]
                        : [Color(red: 0.72, green: 0.85, blue: 0.98), Color(red: 0.98, green: 0.82, blue: 0.86),
                           Color(red: 0.99, green: 0.9, blue: 0.7)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
            }
    }
}

/// Les glyphes à leur taille réelle, entre leurs voisins système, et grossis pour lire les pixels.
private enum MenuBarGlyphSheet {
    private static let neighbours = ["airplayaudio", "wifi", "moon.fill", "battery.75percent", "switch.2"]

    static func write(to directory: URL) throws {
        for isDark in [true, false] {
            let name = isDark ? "fonce" : "clair"
            for scale in [1, 2] {
                let rep = try strip(scale: scale, isDark: isDark)
                try png(rep).write(to: directory.appending(path: "glyphes-\(name)-\(scale)x.png"))
                try png(magnified(rep, by: 12 / scale))
                    .write(to: directory.appending(path: "glyphes-\(name)-\(scale)x-grossi.png"))
            }
        }
    }

    private static func strip(scale: Int, isDark: Bool) throws -> NSBitmapImageRep {
        let cell: CGFloat = 30
        let count = BridgeGlyph.Variant.allCases.count + neighbours.count
        let size = CGSize(width: cell * CGFloat(count), height: 24)
        let rep = try #require(
            NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: Int(size.width) * scale,
                pixelsHigh: Int(size.height) * scale, bitsPerSample: 8, samplesPerPixel: 4,
                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0,
                bitsPerPixel: 0
            )
        )
        rep.size = size
        let context = try #require(NSGraphicsContext(bitmapImageRep: rep))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        defer { NSGraphicsContext.restoreGraphicsState() }
        (isDark ? NSColor(white: 0.14, alpha: 1) : NSColor(white: 0.87, alpha: 1)).setFill()
        CGRect(origin: .zero, size: size).fill()

        let tint: NSColor = isDark ? .white : .black
        let symbols = neighbours.compactMap {
            NSImage(systemSymbolName: $0, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 15, weight: .regular))
        }
        let images = BridgeGlyph.Variant.allCases.map(MenuBarGlyphImage.image(for:)) + symbols
        for (index, image) in images.enumerated() {
            let origin = CGPoint(
                x: cell * CGFloat(index) + (cell - image.size.width) / 2,
                y: ((24 - image.size.height) / 2).rounded()
            )
            // Comme la barre de menus : c'est le masque de l'image qui compte, teinté à la main.
            let tinted = NSImage(size: image.size, flipped: false) { rect in
                image.draw(in: rect)
                tint.set()
                rect.fill(using: .sourceIn)
                return true
            }
            tinted.draw(in: CGRect(origin: origin, size: image.size))
        }
        return rep
    }

    private static func magnified(_ rep: NSBitmapImageRep, by factor: Int) throws -> NSBitmapImageRep {
        let output = try #require(
            NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: rep.pixelsWide * factor,
                pixelsHigh: rep.pixelsHigh * factor, bitsPerSample: 8, samplesPerPixel: 4,
                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0,
                bitsPerPixel: 0
            )
        )
        let context = try #require(NSGraphicsContext(bitmapImageRep: output))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .none
        rep.draw(in: CGRect(x: 0, y: 0, width: output.pixelsWide, height: output.pixelsHigh))
        NSGraphicsContext.restoreGraphicsState()
        return output
    }

    private static func png(_ rep: NSBitmapImageRep) throws -> Data {
        try #require(rep.representation(using: .png, properties: [:]))
    }
}
