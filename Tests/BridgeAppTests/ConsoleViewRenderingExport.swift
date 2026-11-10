import AppKit
import Foundation
import SwiftUI
import Testing

@testable import BridgeApp

/// Rend la vue « Console » de la fenêtre hors écran, sans lancer l'app : celle-ci découvrirait le vrai
/// matériel et ouvrirait les fenêtres d'autorisation de macOS.
///
/// Inerte tant que la variable d'environnement n'est pas posée.
///
/// ```
/// WINDOW_PNG_DIR=/chemin/dossier swift test --filter ConsoleViewExport
/// ```
///
/// Comme `MainWindowExport` : une vraie fenêtre à barre de titre, jamais affichée, dont on capture tout
/// le cadre. **Le verre ne se rend pas hors écran** : les tuiles et la barre d'outils sortent en aplat
/// (`windowSimulatesGlass`, `WindowSnapshot`). Mise en page, alignements et contrastes se jugent sur ces
/// images ; le verre sur les nappes, et le mouvement, ne se jugent que dans l'app.
@Suite("Vue Console — export à la demande")
struct ConsoleViewExport {
    private static let size = CGSize(width: 1200, height: 760)

    private func writeWindow(_ state: BridgeState, size: CGSize = Self.size, to url: URL) throws {
        state.windowLayout = .console
        try writeWindow(ContentView(state: state), size: size, to: url)
    }

    private func writeWindow(_ view: some View, size: CGSize, to url: URL) throws {
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
        // Comme la scène de l'app (`hiddenTitleBar`) : barre de titre transparente, boutons seuls.
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
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

    /// L'installation de Baptiste, plan du salon compris : c'est lui qui donne les deux lieux d'écoute.
    private static func state(_ scene: BridgeState.PanelScene) -> BridgeState {
        let state = BridgeState.preview(scene)
        state.roomLayout = RoomLayout.salon.bindingSpeakers(
            toOutputs: state.outputs.map { (id: $0.id, name: $0.displayName) }
        )
        return state
    }

    @Test(
        "Rend la console dans chaque situation",
        .enabled(if: ProcessInfo.processInfo.environment["WINDOW_PNG_DIR"] != nil)
    )
    func renderScenes() throws {
        let path = try #require(ProcessInfo.processInfo.environment["WINDOW_PNG_DIR"])
        let directory = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        // Le tout premier rendu d'un processus sort blanc : on l'écarte.
        try writeWindow(.preview(.idle), size: CGSize(width: 960, height: 620), to: directory.appending(path: ".amorce.png"))

        let scenes: [(String, BridgeState.PanelScene)] = [
            ("diffusion", .streaming), ("repos", .idle), ("alerte", .trouble),
            ("echec-demarrage", .startFailed), ("vide", .empty), ("recherche", .searching),
            ("hors-ligne", .offline), ("demarrage", .starting),
        ]
        for (name, scene) in scenes {
            try writeWindow(Self.state(scene), to: directory.appending(path: "console-\(name).png"))
        }

        // Un HomePod coupé seul : son curseur grisé, son bouton de silence enclenché.
        let mutedSpeaker = Self.state(.streaming)
        mutedSpeaker.outputs.first { $0.id == "airplay2/Salon (2)" }?.isMuted = true
        try writeWindow(mutedSpeaker, to: directory.appending(path: "console-enceinte-coupee.png"))

        // Le son de toutes les enceintes coupé : le général éteint, les tuiles à leur place.
        let muted = Self.state(.streaming)
        muted.isMuted = true
        try writeWindow(muted, to: directory.appending(path: "console-son-coupe.png"))

        // Une enceinte décochée : son curseur éteint, sa tuile à sa place.
        let unticked = Self.state(.streaming)
        if let geneva = unticked.outputs.first(where: { $0.displayName == "Geneva" }) {
            unticked.toggleEnabled(geneva)
            geneva.connection = .idle
        }
        try writeWindow(unticked, to: directory.appending(path: "console-enceinte-decochee.png"))

        // L'Apple TV masquée : sa tuile s'en va, la ligne discrète le dit en face de la recherche.
        let hidden = Self.state(.streaming)
        if let appleTV = hidden.outputs.first(where: { $0.displayName == "Apple TV Salon" }) {
            hidden.setHidden(true, for: appleTV)
        }
        try writeWindow(hidden, to: directory.appending(path: "console-enceinte-masquee.png"))

        // Ce que seul le survol fait apparaître : l'œil barré dans le coin de chaque tuile.
        let hovered = Self.state(.streaming)
        hovered.windowLayout = .console
        try writeWindow(
            ContentView(state: hovered).environment(\.revealsHoverControls, true), size: Self.size,
            to: directory.appending(path: "console-survol-masquer.png")
        )

        // Les blocs masqués : ni volume général dans la barre, ni lieu d'écoute en haut.
        let bare = Self.state(.streaming)
        bare.setVisible(false, block: .masterVolume)
        bare.setVisible(false, block: .listeningPlaces)
        try writeWindow(bare, to: directory.appending(path: "console-blocs-masques.png"))

        // Toutes masquées : la console le dit, au lieu de « aucune enceinte ».
        let none = Self.state(.streaming)
        for output in none.outputs { none.setHidden(true, for: output) }
        try writeWindow(none, to: directory.appending(path: "console-toutes-masquees.png"))

        // La rangée qui ne tient pas : elle défile d'un bord à l'autre. La fenêtre ne descend pas sous
        // 960 points et une scène d'essai n'a que quatre enceintes : la vue seule, donc, plus étroite
        // que la fenêtre ne le permet.
        let narrow = Self.state(.streaming)
        try writeWindow(
            ConsoleView(state: narrow)
                .background { GrainientBackground(isLive: true) }
                .tint(BridgeTheme.accent)
                .frame(width: 720, height: 568),
            size: CGSize(width: 720, height: 568), to: directory.appending(path: "console-rangee-defilante.png")
        )

        // Les cas les plus serrés : la fenêtre à sa taille minimale, en diffusion puis avec une alerte et
        // deux enceintes en peine.
        let minimum = CGSize(width: 960, height: 620)
        try writeWindow(Self.state(.streaming), size: minimum, to: directory.appending(path: "console-minimum-diffusion.png"))
        try writeWindow(Self.state(.trouble), size: minimum, to: directory.appending(path: "console-minimum-alerte.png"))

        // La plus grande fenêtre visée : les tuiles ne s'étirent pas sans fin.
        try writeWindow(
            Self.state(.streaming), size: CGSize(width: 1400, height: 900),
            to: directory.appending(path: "console-grande-diffusion.png")
        )
    }
}
