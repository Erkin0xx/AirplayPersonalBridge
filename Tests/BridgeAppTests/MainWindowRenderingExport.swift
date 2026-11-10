import AppKit
import Foundation
import SwiftUI
import Testing

@testable import BridgeApp

/// Rend la fenêtre principale hors écran, sans lancer l'app : celle-ci découvrirait le vrai matériel
/// et ouvrirait les fenêtres d'autorisation de macOS.
///
/// Inerte tant que la variable d'environnement n'est pas posée.
///
/// ```
/// WINDOW_PNG_DIR=/chemin/dossier swift test --filter MainWindowExport
/// ```
///
/// Une vraie fenêtre à barre de titre, jamais affichée, dont on capture tout le cadre : barre d'outils
/// comprise. **Le verre ne se rend pas hors écran** : il lit ce que le serveur de fenêtres compose
/// derrière lui, et `cacheDisplay` n'y a pas accès. Les verres de l'app (`windowSimulatesGlass`) et ceux
/// du système (barre latérale, inspecteur, barre d'outils : `WindowSnapshot`) sont donc remplacés par un
/// aplat discret de même forme. Mise en page, alignements et contrastes se jugent sur ces images ; le
/// verre, et le prolongement du plan sous la barre latérale, ne se jugent que dans l'app.
@Suite("Fenêtre principale — export à la demande")
struct MainWindowExport {
    private static let size = CGSize(width: 1200, height: 760)
    private static let genevaID = "raop/AABBCCDDEEFF@Geneva"

    private func writeWindow(
        _ view: some View, scheme: ColorScheme, size: CGSize = Self.size,
        columns: WindowSnapshot.Columns = WindowSnapshot.Columns(), to url: URL
    ) throws {
        let hosting = NSHostingView(
            rootView: view
                .environment(\.colorScheme, scheme)
                .environment(\.windowSimulatesGlass, true)
                .environment(\.panelSimulatesGlass, true)
        )
        hosting.sceneBridgingOptions = [.toolbars, .title]
        // À la taille finale dès le départ : le plan se cadre sur sa première taille.
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
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.contentView = hosting
        window.setContentSize(size)
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        // Le cadre entier : la barre d'outils vit à côté de la vue hébergée, pas dedans.
        let frame = hosting.superview ?? hosting
        frame.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        let bitmap = try WindowSnapshot.capture(frame, scheme: scheme, columns: columns)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: url)
        window.close()
    }

    /// La fenêtre entière. Plus de colonne de verre à repeindre : le panneau des enceintes et l'inspecteur
    /// flottent, et leur verre a sa doublure (`windowSimulatesGlass`).
    private func writeMainWindow(
        _ state: BridgeState, selection: Set<PlanElement> = [], scheme: ColorScheme, size: CGSize = Self.size,
        to url: URL
    ) throws {
        try writeWindow(
            ContentView(state: state, preview: MainWindowPreviewOptions(planSelection: selection)),
            scheme: scheme, size: size,
            to: url
        )
    }

    /// L'installation de Baptiste, plan du salon compris, enceintes rattachées.
    private static func state(_ scene: BridgeState.PanelScene) -> BridgeState {
        let state = BridgeState.preview(scene)
        // Ces scènes sont celles de la vue « Plan » : la vue par défaut en est une autre.
        state.windowLayout = .plan
        state.roomLayout = RoomLayout.salon.bindingSpeakers(
            toOutputs: state.outputs.map { (id: $0.id, name: $0.displayName) }
        )
        return state
    }

    @Test(
        "Rend la fenêtre dans chaque situation, en sombre et en clair",
        .enabled(if: ProcessInfo.processInfo.environment["WINDOW_PNG_DIR"] != nil)
    )
    func renderScenes() throws {
        let path = try #require(ProcessInfo.processInfo.environment["WINDOW_PNG_DIR"])
        let directory = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        // Le tout premier rendu d'un processus sort blanc : on l'écarte.
        try writeWindow(
            Color.clear.frame(width: 10, height: 10), scheme: .dark, size: CGSize(width: 40, height: 40),
            to: directory.appending(path: ".amorce.png")
        )

        let scenes: [(String, BridgeState.PanelScene)] = [
            ("diffusion", .streaming), ("repos", .idle), ("alerte", .trouble),
            ("echec-demarrage", .startFailed), ("hors-ligne", .offline), ("vide", .empty),
            ("recherche", .searching), ("demarrage", .starting),
        ]
        // L'Apple TV masquée : sa carte quitte le panneau des enceintes, dont le pied le dit ; le plan garde
        // son dessin.
        let hidden = Self.state(.streaming)
        if let appleTV = hidden.outputs.first(where: { $0.displayName == "Apple TV Salon" }) {
            hidden.setHidden(true, for: appleTV)
        }
        try writeMainWindow(
            hidden, scheme: .dark, to: directory.appending(path: "fenetre-enceinte-masquee-sombre.png")
        )

        // Ce que seul le survol fait apparaître : l'œil barré de chaque carte.
        try writeWindow(
            ContentView(state: Self.state(.streaming)).environment(\.revealsHoverControls, true),
            scheme: .dark, to: directory.appending(path: "fenetre-survol-masquer-sombre.png")
        )

        // Le volume général masqué : le bouton de silence monte à côté de la commande.
        let bare = Self.state(.streaming)
        bare.setVisible(false, block: .masterVolume)
        try writeMainWindow(bare, scheme: .dark, to: directory.appending(path: "fenetre-blocs-masques-sombre.png"))

        // La fenêtre Réglages, seule : l'Apple TV et la paire masquées, les ondes aussi.
        let settings = Self.state(.streaming)
        for output in settings.outputs where output.displayName == "Apple TV Salon" || output.id == "airplay2/Salon" {
            settings.setHidden(true, for: output)
        }
        settings.setVisible(false, block: .haloWaves)
        try writeWindow(
            SettingsView(state: settings), scheme: .dark, size: SettingsView.size,
            to: directory.appending(path: "reglages-fenetre-sombre.png")
        )
        try writeWindow(
            SettingsView(state: Self.state(.idle)), scheme: .dark, size: SettingsView.size,
            to: directory.appending(path: "reglages-fenetre-rien-de-masque-sombre.png")
        )

        for scheme in [ColorScheme.dark, .light] {
            let suffix = scheme == .dark ? "sombre" : "clair"
            for (name, scene) in scenes {
                try writeMainWindow(
                    Self.state(scene), scheme: scheme,
                    to: directory.appending(path: "fenetre-\(name)-\(suffix).png")
                )
            }

            // Un meuble sélectionné : l'inspecteur ouvert sur la Geneva.
            let room = Self.state(.listeningPlaces)
            let geneva = room.roomLayout.objects.first { $0.kind.outputID == Self.genevaID }
            try writeMainWindow(
                room, selection: geneva.map { [.object($0.id)] } ?? [], scheme: scheme,
                to: directory.appending(path: "fenetre-inspecteur-\(suffix).png")
            )

            // Le cas le plus serré : la fenêtre à sa largeur minimale, inspecteur ouvert.
            let narrow = Self.state(.listeningPlaces)
            let narrowGeneva = narrow.roomLayout.objects.first { $0.kind.outputID == Self.genevaID }
            try writeMainWindow(
                narrow, selection: narrowGeneva.map { [.object($0.id)] } ?? [], scheme: scheme,
                size: CGSize(width: 960, height: 640),
                to: directory.appending(path: "fenetre-etroite-inspecteur-\(suffix).png")
            )

            // Plusieurs murs : le résumé de la sélection.
            let walls = Self.state(.listeningPlaces)
            try writeMainWindow(
                walls, selection: Set(walls.roomLayout.walls.prefix(3).map { .wall($0.id) }), scheme: scheme,
                to: directory.appending(path: "fenetre-inspecteur-murs-\(suffix).png")
            )

            // Un HomePod coupé seul : son curseur grisé, son bouton de silence enclenché.
            let mutedSpeaker = Self.state(.streaming)
            mutedSpeaker.outputs.first { $0.id == "airplay2/Salon (2)" }?.isMuted = true
            try writeMainWindow(
                mutedSpeaker, scheme: scheme,
                to: directory.appending(path: "fenetre-enceinte-coupee-\(suffix).png")
            )

            // Une application choisie qui ne joue pas : la ligne « Passera sur … » et son Annuler.
            let awaiting = Self.state(.idle)
            if let music = awaiting.sources.first(where: { $0.label.contains("Music") }) {
                awaiting.selectSource(id: music.id)
                awaiting.refreshSources()
            }
            awaiting.isMuted = true
            try writeMainWindow(
                awaiting, scheme: scheme,
                to: directory.appending(path: "fenetre-application-attendue-son-coupe-\(suffix).png")
            )

            // Les fenêtres surgissantes, seules : un rendu hors écran ne les ouvre pas.
            let settings = Self.state(.streaming)
            if let geneva = settings.outputs.first(where: { $0.id == Self.genevaID }) {
                try writeWindow(
                    SpeakerSettings(
                        output: geneva, effectiveGainDB: settings.effectiveGainDB(for: geneva),
                        listeningCompensationMS: settings.listeningCompensationMS(for: geneva),
                        listeningPlaceName: settings.listeningPlaceName
                    ),
                    scheme: scheme, size: CGSize(width: 330, height: 330),
                    to: directory.appending(path: "reglages-enceinte-\(suffix).png")
                )
            }
            try writeWindow(
                MacOptions(state: settings), scheme: scheme, size: CGSize(width: 340, height: 300),
                to: directory.appending(path: "options-mac-\(suffix).png")
            )

            // La feuille de diagnostic, seule.
            try writeWindow(
                DiagnosticsView(state: .preview()), scheme: scheme, size: CGSize(width: 520, height: 640),
                to: directory.appending(path: "diagnostic-\(suffix).png")
            )
        }
    }
}
