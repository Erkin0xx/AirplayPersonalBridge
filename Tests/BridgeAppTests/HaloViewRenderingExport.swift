import AppKit
import AudioCore
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
        // Comme la scène de l'app (`hiddenTitleBar`) : barre de titre transparente, et boutons système
        // masqués comme le fait `AppLifecycle`, pour que le rendu montre ceux de l'app seuls.
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        SystemWindowButtons.hide(in: window)
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

        // Le son coupé : la sphère garde ses couleurs, voilées et immobiles, l'anneau s'éteint, et le
        // silence général, au bout de la rangée, devient un rond blanc.
        let muted = Self.state(.streaming)
        muted.isMuted = true
        try writeWindow(ContentView(state: muted), to: directory.appending(path: "halo-son-coupe.png"))
        try writeWindow(
            ContentView(state: muted), size: Self.minimumSize,
            to: directory.appending(path: "halo-son-coupe-minimale.png")
        )

        // Aucune enceinte, mais le son est resté coupé : le silence général reste là pour le rétablir.
        let mutedEmpty = Self.state(.empty)
        mutedEmpty.isMuted = true
        try writeWindow(ContentView(state: mutedEmpty), to: directory.appending(path: "halo-vide-son-coupe.png"))

        // Un HomePod coupé seul, et la Geneva décochée.
        let speakers = Self.state(.streaming)
        speakers.outputs.first { $0.id == "airplay2/Salon (2)" }?.isMuted = true
        if let geneva = speakers.outputs.first(where: { $0.proto == .raop && $0.isEnabled }) {
            speakers.toggleEnabled(geneva)
        }
        try writeWindow(ContentView(state: speakers), to: directory.appending(path: "halo-enceinte-coupee.png"))

        // L'Apple TV masquée : sa pastille s'en va, sans mention au pied de la vue (les Réglages, par le
        // bouton des options, disent ce qui est masqué).
        let hidden = Self.state(.streaming)
        if let appleTV = hidden.outputs.first(where: { $0.displayName == "Apple TV Salon" }) {
            hidden.setHidden(true, for: appleTV)
        }
        try writeWindow(ContentView(state: hidden), to: directory.appending(path: "halo-enceinte-masquee.png"))
        try writeWindow(
            ContentView(state: hidden), size: Self.minimumSize,
            to: directory.appending(path: "halo-enceinte-masquee-minimale.png")
        )

        // Ce que seul le survol fait apparaître : l'œil barré de chaque pastille.
        try writeWindow(
            ContentView(state: Self.state(.streaming)).environment(\.revealsHoverControls, true),
            to: directory.appending(path: "halo-survol-masquer.png")
        )

        // Les blocs masqués : ni ondes ni anneau, le silence général reste au bout de la rangée.
        let bare = Self.state(.streaming)
        bare.setVisible(false, block: .haloWaves)
        bare.setVisible(false, block: .masterVolume)
        try writeWindow(ContentView(state: bare), to: directory.appending(path: "halo-blocs-masques.png"))

        // Toutes masquées : la vue le dit, au lieu de « aucune enceinte ».
        let none = Self.state(.streaming)
        for output in none.outputs { none.setHidden(true, for: output) }
        try writeWindow(ContentView(state: none), to: directory.appending(path: "halo-toutes-masquees.png"))

        // La vue seule, sous une marge sûre factice à la place de la barre d'outils, que le rendu hors
        // écran peint en opaque : les ondes doivent rester centrées sur la sphère et passer dessous. Sa
        // propre marge haute (`topInset`) ne doit pas les rogner non plus.
        try writeWindow(
            HaloView(state: Self.state(.streaming), topInset: 48)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background { GrainientBackground(isLive: true) }
                .safeAreaPadding(.top, 90)
                .preferredColorScheme(.dark),
            size: CGSize(width: 960, height: 700),
            to: directory.appending(path: "halo-ondes-sous-la-barre.png")
        )
    }

    @Test(
        "Rend la vue Halo avec plus d'enceintes que deux rangées n'en montrent",
        .enabled(if: ProcessInfo.processInfo.environment["WINDOW_PNG_DIR"] != nil)
    )
    func renderCrowd() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["WINDOW_PNG_DIR"])
        let directory = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try writeWindow(
            Color.clear.frame(width: 10, height: 10), size: CGSize(width: 40, height: 40),
            to: directory.appending(path: ".amorce.png")
        )

        // Neuf enceintes trouvées par la découverte : les pastilles défilent sur deux rangées, et les
        // commandes rondes (silence général, recherche) sortent du défilement, épinglées à droite.
        let harness = BridgeHarness()
        let devices = (1...9).map { rank in
            RAOPDevice(
                serviceName: "AABBCCDDEE0\(rank)@Chambre \(rank)", host: "192.168.1.\(100 + rank)", port: 7000,
                txt: ["et": "0,4", "cn": "0,1"]
            )
        }
        await harness.discover(raop: devices)
        let crowd = harness.state
        crowd.windowLayout = .halo
        #expect(crowd.outputs.count == 9)
        try writeWindow(ContentView(state: crowd), to: directory.appending(path: "halo-beaucoup-d-enceintes.png"))
        try writeWindow(
            ContentView(state: crowd), size: Self.minimumSize,
            to: directory.appending(path: "halo-beaucoup-d-enceintes-minimale.png")
        )
        // Huit tiennent encore sur deux rangées à 1200 pt, commandes comprises : rien n'est épinglé.
        if let last = crowd.outputs.last { crowd.setHidden(true, for: last) }
        try writeWindow(ContentView(state: crowd), to: directory.appending(path: "halo-huit-enceintes.png"))
    }
}
