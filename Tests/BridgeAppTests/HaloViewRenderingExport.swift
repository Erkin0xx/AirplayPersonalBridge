import AppKit
import Foundation
import SwiftUI
import Testing

@testable import BridgeApp

/// Rend la vue « Halo » de la fenêtre hors écran, sans lancer l'app, sur le modèle de `MainWindowExport`.
///
/// Inerte tant que la variable d'environnement n'est pas posée.
///
/// ```
/// WINDOW_PNG_DIR=/chemin/dossier swift test --filter HaloViewExport
/// ```
///
/// **Ce que ces images ne montrent pas** : le verre (remplacé par un aplat, `windowSimulatesGlass`), et le
/// mouvement — la sphère, les ondes et les égaliseurs sortent figés sur une image. Mise en page,
/// alignements et contrastes se jugent ici ; le reste, dans l'app.
@Suite("Vue Halo — export à la demande")
struct HaloViewExport {
    private static let size = CGSize(width: 1200, height: 760)
    /// La taille minimale de la fenêtre (`ContentView`).
    private static let minimumSize = CGSize(width: 960, height: 620)

    private func writeWindow(_ view: some View, size: CGSize = Self.size, to url: URL) throws {
        let hosting = NSHostingView(
            rootView: view
                .environment(\.colorScheme, .dark)
                .environment(\.windowSimulatesGlass, true)
                .environment(\.panelSimulatesGlass, true)
        )
        hosting.sceneBridgingOptions = [.toolbars, .title]
        hosting.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.title = "AirPlay Personal Bridge"
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = hosting
        window.setContentSize(size)
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        // Le cadre entier : la barre d'outils vit à côté de la vue hébergée, pas dedans.
        let frame = hosting.superview ?? hosting
        frame.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        let bitmap = try WindowSnapshot.capture(frame, scheme: .dark, columns: WindowSnapshot.Columns())
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: url)
        window.close()
    }

    private static func state(_ scene: BridgeState.PanelScene) -> BridgeState {
        let state = BridgeState.preview(scene)
        state.windowLayout = .halo
        return state
    }

    @Test(
        "Rend la vue Halo dans chaque situation, et à la taille minimale",
        .enabled(if: ProcessInfo.processInfo.environment["WINDOW_PNG_DIR"] != nil)
    )
    func renderScenes() throws {
        let path = try #require(ProcessInfo.processInfo.environment["WINDOW_PNG_DIR"])
        let directory = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        // Le tout premier rendu d'un processus sort blanc : on l'écarte.
        try writeWindow(
            Color.clear.frame(width: 10, height: 10), size: CGSize(width: 40, height: 40),
            to: directory.appending(path: ".amorce.png")
        )

        let scenes: [(String, BridgeState.PanelScene)] = [
            ("diffusion", .streaming), ("repos", .idle), ("alerte", .trouble),
            ("echec-demarrage", .startFailed), ("vide", .empty), ("recherche", .searching),
            ("demarrage", .starting), ("hors-ligne", .offline), ("rien-ne-joue", .nothingPlaying),
        ]
        for (name, scene) in scenes {
            try writeWindow(
                ContentView(state: Self.state(scene)), to: directory.appending(path: "halo-\(name).png")
            )
        }

        // La fenêtre à sa taille minimale : les pastilles passent sur deux rangées, le halo rétrécit.
        for (name, scene) in [("diffusion", BridgeState.PanelScene.streaming), ("alerte", .trouble)] {
            try writeWindow(
                ContentView(state: Self.state(scene)), size: Self.minimumSize,
                to: directory.appending(path: "halo-\(name)-minimale.png")
            )
        }

        // Le son coupé : la sphère garde ses couleurs, voilées et immobiles, l'anneau s'éteint.
        let muted = Self.state(.streaming)
        muted.isMuted = true
        try writeWindow(ContentView(state: muted), to: directory.appending(path: "halo-son-coupe.png"))

        // Un HomePod coupé seul, et la Geneva décochée.
        let speakers = Self.state(.streaming)
        speakers.outputs.first { $0.id == "airplay2/Salon (2)" }?.isMuted = true
        if let geneva = speakers.outputs.first(where: { $0.proto == .raop && $0.isEnabled }) {
            speakers.toggleEnabled(geneva)
        }
        try writeWindow(ContentView(state: speakers), to: directory.appending(path: "halo-enceinte-coupee.png"))

        // La vue seule, sous une marge sûre factice à la place de la barre d'outils, que le rendu hors
        // écran peint en opaque : les ondes doivent rester centrées sur la sphère et passer dessous.
        try writeWindow(
            HaloView(state: Self.state(.streaming))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background { AuroraBackground(isLive: true) }
                .safeAreaPadding(.top, 90)
                .preferredColorScheme(.dark),
            size: CGSize(width: 960, height: 700),
            to: directory.appending(path: "halo-ondes-sous-la-barre.png")
        )
    }
}
