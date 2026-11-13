import AppKit
import AudioCore
import Foundation
import SwiftUI
import Testing

@testable import BridgeApp

/// Rend le widget hors écran, sans lancer l'app ni ouvrir de fenêtre, sur le modèle de `HaloViewExport`.
///
/// Inerte tant que la variable d'environnement n'est pas posée.
///
/// ```
/// WINDOW_PNG_DIR=/chemin/dossier swift test --filter WidgetExport
/// ```
///
/// Chaque image pose le widget sur un fond gris sombre, comme les maquettes : ses coins arrondis s'y
/// lisent. `-reel` est à la taille du widget (345 × 165 points, rendus au double) ; `-agrandi` le montre
/// 2,1 fois plus grand, à l'échelle des maquettes 23 et 24.
///
/// **Ce que ces images ne montrent pas** : le mouvement (fond, lueurs et logo sortent figés), l'ombre de la
/// fenêtre, qui est celle du système, et tout ce qui tient à la vraie fenêtre : elle flotte, se déplace
/// par son fond, retient sa place. Cela ne se juge que dans l'app.
@Suite("Widget — export à la demande")
struct WidgetExport {
    private static let margin: CGFloat = 20
    private static let zoom: CGFloat = 2.1

    private func write(_ state: BridgeState, zoom: CGFloat = 1, to url: URL) throws {
        let widget = WidgetMetrics.size
        let size = CGSize(
            width: widget.width * zoom + 2 * Self.margin, height: widget.height * zoom + 2 * Self.margin
        )
        let view = WidgetView(state: state)
            .scaleEffect(zoom, anchor: .topLeading)
            .frame(width: widget.width * zoom, height: widget.height * zoom, alignment: .topLeading)
            .padding(Self.margin)
            .background(BridgeTheme.color(0x17181A))
            .environment(\.colorScheme, .dark)
            .environment(\.windowSimulatesGlass, true)
            .environment(\.panelSimulatesGlass, true)
        let hosting = NSHostingView(rootView: view)
        hosting.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(
            contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = hosting
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: url)
        window.close()
    }

    /// L'installation de Baptiste : la Geneva et les deux HomePod, l'Apple TV masquée.
    private static func state(_ scene: BridgeState.PanelScene, style: WidgetStyle) -> BridgeState {
        let state = BridgeState.preview(scene)
        state.widget.style = style
        if let appleTV = state.outputs.first(where: { $0.displayName == "Apple TV Salon" }) {
            state.setHidden(true, for: appleTV)
        }
        return state
    }

    private static func directory() throws -> URL {
        let path = try #require(ProcessInfo.processInfo.environment["WINDOW_PNG_DIR"])
        let directory = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @Test(
        "Rend les deux styles du widget, au repos et en diffusion, à taille réelle et agrandis",
        .enabled(if: ProcessInfo.processInfo.environment["WINDOW_PNG_DIR"] != nil)
    )
    func renderStyles() throws {
        let directory = try Self.directory()
        // Le tout premier rendu d'un processus sort blanc : on l'écarte.
        try write(.preview(.idle), to: directory.appending(path: ".amorce.png"))

        for style in WidgetStyle.allCases {
            // Au repos, la Geneva est éteinte : grisée, « Hors ligne ».
            for (name, scene) in [("repos", BridgeState.PanelScene.offline), ("diffusion", .streaming)] {
                let prefix = "widget-\(style.rawValue)-\(name)"
                try write(Self.state(scene, style: style), to: directory.appending(path: "\(prefix)-reel.png"))
                try write(
                    Self.state(scene, style: style), zoom: Self.zoom,
                    to: directory.appending(path: "\(prefix)-agrandi.png")
                )
            }

            // Le son coupé : l'anneau ou le curseur s'éteint, la valeur dit « Coupé ».
            let muted = Self.state(.streaming, style: style)
            muted.isMuted = true
            try write(
                muted, zoom: Self.zoom, to: directory.appending(path: "widget-\(style.rawValue)-son-coupe.png")
            )

            // Une enceinte coupée, une décochée.
            let mixed = Self.state(.streaming, style: style)
            mixed.outputs.first { $0.id == "airplay2/Salon (2)" }?.isMuted = true
            if let geneva = mixed.outputs.first(where: { $0.displayName == "Geneva" }) {
                mixed.toggleEnabled(geneva)
            }
            try write(
                mixed, zoom: Self.zoom,
                to: directory.appending(path: "widget-\(style.rawValue)-enceinte-coupee.png")
            )

            // Une seule enceinte : elle se centre dans la zone.
            let single = Self.state(.streaming, style: style)
            for output in single.outputs where output.displayName != "Geneva" {
                single.setHidden(true, for: output)
            }
            try write(
                single, zoom: Self.zoom, to: directory.appending(path: "widget-\(style.rawValue)-une-enceinte.png")
            )

            // L'Apple TV affichée : quatre enceintes, dont une qui exige un appairage. La rangée défile.
            let four = BridgeState.preview(.streaming)
            four.widget.style = style
            try write(
                four, zoom: Self.zoom,
                to: directory.appending(path: "widget-\(style.rawValue)-quatre-enceintes.png")
            )

            // Aucune enceinte, puis toutes masquées.
            let empty = BridgeState.preview(.empty)
            empty.widget.style = style
            try write(empty, zoom: Self.zoom, to: directory.appending(path: "widget-\(style.rawValue)-aucune.png"))
            let hidden = Self.state(.idle, style: style)
            for output in hidden.outputs { hidden.setHidden(true, for: output) }
            try write(
                hidden, zoom: Self.zoom,
                to: directory.appending(path: "widget-\(style.rawValue)-toutes-masquees.png")
            )
        }
    }

    @Test(
        "Rend le widget avec cinq enceintes : la rangée défile",
        .enabled(if: ProcessInfo.processInfo.environment["WINDOW_PNG_DIR"] != nil)
    )
    func renderCrowd() async throws {
        let directory = try Self.directory()
        try write(.preview(.idle), to: directory.appending(path: ".amorce.png"))

        let harness = BridgeHarness()
        let devices = (1...5).map { rank in
            RAOPDevice(
                serviceName: "AABBCCDDEE0\(rank)@Chambre \(rank)", host: "192.168.1.\(100 + rank)", port: 7000,
                txt: ["et": "0,4", "cn": "0,1"]
            )
        }
        await harness.discover(raop: devices)
        let crowd = harness.state
        #expect(crowd.visibleOutputs.count == 5)
        for style in WidgetStyle.allCases {
            crowd.widget.style = style
            try write(
                crowd, zoom: Self.zoom,
                to: directory.appending(path: "widget-\(style.rawValue)-cinq-enceintes.png")
            )
        }
    }
}
