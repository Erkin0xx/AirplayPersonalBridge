import AppKit
import AudioCore
import Foundation
import SwiftUI
import Testing

@testable import BridgeApp

/// Rend les trois vues de la fenêtre à chaque palier de taille, hors écran, sans lancer l'app : de la
/// taille par défaut à la taille minimale (`WindowSizing.minimum`), plus une fenêtre large et basse et
/// une fenêtre étroite et haute.
///
/// Inerte tant que la variable d'environnement n'est pas posée.
///
/// ```
/// WINDOW_PNG_DIR=/chemin/dossier swift test --filter SmallWindowExport
/// ```
///
/// Comme les autres exports : le verre sort en aplat, le mouvement figé. Ce qui se juge ici, c'est qu'à
/// aucune taille un élément n'en chevauche un autre, ne déborde ou ne soit rogné.
@Suite("Petite fenêtre — export à la demande")
struct SmallWindowExport {
    /// Les tailles demandées par Baptiste, de la taille par défaut à la plus petite.
    static let sizes: [(name: String, size: CGSize)] = [
        ("1200x760", CGSize(width: 1200, height: 760)),
        ("960x620", CGSize(width: 960, height: 620)),
        ("760x560", CGSize(width: 760, height: 560)),
        ("600x480", CGSize(width: 600, height: 480)),
        ("minimale", minimum),
        ("large-basse-900x420", CGSize(width: 900, height: 420)),
        ("etroite-haute-460x760", CGSize(width: 460, height: 760)),
    ]

    private static var minimum: CGSize { WindowSizing.minimum }

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
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        SystemWindowButtons.hide(in: window)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = hosting
        window.setContentSize(size)
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        let frame = hosting.superview ?? hosting
        frame.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        let bitmap = try WindowSnapshot.capture(frame, scheme: .dark, columns: WindowSnapshot.Columns())
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: url)
        window.close()
    }

    /// L'installation de Baptiste, plan du salon compris, dans la vue demandée.
    private static func state(
        _ scene: BridgeState.PanelScene, layout: WindowLayout, environment: BridgeEnvironment = .inert
    ) -> BridgeState {
        let state = BridgeState.preview(scene, environment: environment)
        state.roomLayout = RoomLayout.salon.bindingSpeakers(
            toOutputs: state.outputs.map { (id: $0.id, name: $0.displayName) }
        )
        state.windowLayout = layout
        return state
    }

    private static let layouts: [(name: String, layout: WindowLayout)] = [
        ("halo", .halo), ("console", .console), ("plan", .plan),
    ]

    private func directory() throws -> URL {
        let path = try #require(ProcessInfo.processInfo.environment["WINDOW_PNG_DIR"])
        let directory = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Le tout premier rendu d'un processus sort blanc : on l'écarte.
        try writeWindow(
            Color.clear.frame(width: 10, height: 10), size: CGSize(width: 40, height: 40),
            to: directory.appending(path: ".amorce.png")
        )
        return directory
    }

    @Test(
        "Rend les trois vues en diffusion à chaque palier de taille",
        .enabled(if: ProcessInfo.processInfo.environment["WINDOW_PNG_DIR"] != nil)
    )
    func renderEverySize() throws {
        let directory = try directory()
        for (layoutName, layout) in Self.layouts {
            for (sizeName, size) in Self.sizes {
                try writeWindow(
                    ContentView(state: Self.state(.streaming, layout: layout)), size: size,
                    to: directory.appending(path: "\(layoutName)-diffusion-\(sizeName).png")
                )
            }
        }
    }

    /// Les trois vues au repos, à la taille par défaut : rien n'y bouge, deux rendus se comparent au pixel
    /// près. C'est la preuve qu'un palier ne touche pas à la grande fenêtre.
    @Test(
        "Rend les trois vues au repos à la taille par défaut, pour comparaison au pixel",
        .enabled(if: ProcessInfo.processInfo.environment["WINDOW_PNG_DIR"] != nil)
    )
    func renderReference() throws {
        let directory = try directory()
        for (layoutName, layout) in Self.layouts {
            for scene in [BridgeState.PanelScene.idle, .trouble] {
                try writeWindow(
                    ContentView(state: Self.state(scene, layout: layout)), size: CGSize(width: 1200, height: 760),
                    to: directory.appending(path: "reference-\(layoutName)-\(scene.rawValue)-1200x760.png")
                )
            }
        }
    }

    @Test(
        "Rend les trois vues à la taille minimale : repos, alerte, application au nom long",
        .enabled(if: ProcessInfo.processInfo.environment["WINDOW_PNG_DIR"] != nil)
    )
    func renderMinimumScenes() throws {
        let directory = try directory()
        let scenes: [(String, BridgeState.PanelScene)] = [
            ("repos", .idle), ("alerte", .trouble), ("echec-demarrage", .startFailed), ("vide", .empty),
        ]
        for (layoutName, layout) in Self.layouts {
            for (sceneName, scene) in scenes {
                try writeWindow(
                    ContentView(state: Self.state(scene, layout: layout)), size: Self.minimum,
                    to: directory.appending(path: "\(layoutName)-\(sceneName)-minimale.png")
                )
            }
            // Le son coupé : il doit se voir, et se rétablir, à la plus petite taille.
            let muted = Self.state(.streaming, layout: layout)
            muted.isMuted = true
            try writeWindow(
                ContentView(state: muted), size: Self.minimum,
                to: directory.appending(path: "\(layoutName)-son-coupe-minimale.png")
            )
            // Une application au nom long : la pastille de source tronque avant de toucher ses voisins.
            let source = CaptureSource.application(
                pids: [777], name: "Un lecteur de musique au nom interminable", bundleID: "com.exemple.long"
            )
            var environment = BridgeEnvironment.inert
            environment.availableSources = { [.systemWide, source, .inputDevice] }
            let long = Self.state(.streaming, layout: layout, environment: environment)
            long.refreshSources()
            long.selectSource(id: source.id)
            for (sizeName, size) in [("minimale", Self.minimum), ("760x560", CGSize(width: 760, height: 560))] {
                try writeWindow(
                    ContentView(state: long), size: size,
                    to: directory.appending(path: "\(layoutName)-source-longue-\(sizeName).png")
                )
            }
        }
    }

    /// Ce qu'un rendu hors écran n'ouvre pas tout seul : le panneau des enceintes de la vue Plan en
    /// surimpression, et l'inspecteur, dans une fenêtre trop étroite pour les loger à côté du plan.
    @Test(
        "Rend les surimpressions de la vue Plan dans une petite fenêtre",
        .enabled(if: ProcessInfo.processInfo.environment["WINDOW_PNG_DIR"] != nil)
    )
    func renderPlanOverlays() throws {
        let directory = try directory()
        let sizes = [("minimale", Self.minimum), ("600x480", CGSize(width: 600, height: 480))]
        for (sizeName, size) in sizes {
            for (sceneName, scene) in [("diffusion", BridgeState.PanelScene.streaming), ("alerte", .trouble)] {
                try writeWindow(
                    ContentView(
                        state: Self.state(scene, layout: .plan),
                        preview: MainWindowPreviewOptions(showsSpeakerPanel: true)
                    ),
                    size: size, to: directory.appending(path: "plan-panneau-ouvert-\(sceneName)-\(sizeName).png")
                )
            }
            let room = Self.state(.listeningPlaces, layout: .plan)
            let speaker = room.roomLayout.objects.first { $0.kind.outputID != nil }
            try writeWindow(
                ContentView(
                    state: room,
                    preview: MainWindowPreviewOptions(planSelection: speaker.map { [.object($0.id)] } ?? [])
                ),
                size: size, to: directory.appending(path: "plan-inspecteur-\(sizeName).png")
            )
        }
        // Toutes les enceintes masquées : les vues Halo et Console le disent, sans déborder.
        for (layoutName, layout) in Self.layouts {
            let none = Self.state(.streaming, layout: layout)
            for output in none.outputs { none.setHidden(true, for: output) }
            try writeWindow(
                ContentView(state: none), size: Self.minimum,
                to: directory.appending(path: "\(layoutName)-toutes-masquees-minimale.png")
            )
        }
    }

    @Test(
        "Rend les trois vues avec neuf enceintes, à la taille minimale et à 600 × 480",
        .enabled(if: ProcessInfo.processInfo.environment["WINDOW_PNG_DIR"] != nil)
    )
    func renderCrowd() async throws {
        let directory = try directory()
        let harness = BridgeHarness()
        let devices = (1...9).map { rank in
            RAOPDevice(
                serviceName: "AABBCCDDEE0\(rank)@Chambre \(rank)", host: "192.168.1.\(100 + rank)", port: 7000,
                txt: ["et": "0,4", "cn": "0,1"]
            )
        }
        await harness.discover(raop: devices)
        let crowd = harness.state
        #expect(crowd.outputs.count == 9)
        for (layoutName, layout) in Self.layouts {
            crowd.windowLayout = layout
            for (sizeName, size) in [("minimale", Self.minimum), ("600x480", CGSize(width: 600, height: 480))] {
                try writeWindow(
                    ContentView(state: crowd), size: size,
                    to: directory.appending(path: "\(layoutName)-beaucoup-d-enceintes-\(sizeName).png")
                )
            }
        }
    }
}
