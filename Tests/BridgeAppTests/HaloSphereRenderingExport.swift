import AppKit
import Foundation
import SwiftUI
import Testing

@testable import BridgeApp

/// Rend le centre du halo et l'anneau du volume seuls, hors écran, en planches : le disque à plusieurs
/// instants de la diffusion, ses allures, des gros plans, et l'anneau à plusieurs niveaux. C'est le seul
/// moyen de juger le mouvement du logo et des lueurs sans lancer l'app.
///
/// Inerte tant que la variable d'environnement n'est pas posée.
///
/// ```
/// SPHERE_PNG_DIR=/chemin/dossier swift test --filter HaloSphereExport
/// ```
@Suite("Sphère du halo — export à la demande")
struct HaloSphereExport {
    private struct Cell {
        var label: String
        var look: HaloSphere.Look = .live
        var isAudible = true
        var glyph: BridgeGlyph.Variant = .idle
        var time: TimeInterval = 0
        var decibels = -24.0
        var isMuted = false
        var diameter: CGFloat = 280
        /// Un gros plan : le centre agrandi, rogné au cadre de la case.
        var zoom: CGFloat = 1
    }

    private static func tile(_ cell: Cell, isLiveGround: Bool) -> some View {
        VStack(spacing: 6) {
            ZStack {
                HaloSphere(
                    look: cell.look, isAudible: cell.isAudible, glyph: cell.glyph, diameter: cell.diameter,
                    frozenTime: cell.time
                )
                HaloVolumeRing(
                    decibels: .constant(cell.decibels), isMuted: .constant(cell.isMuted),
                    range: BridgeSettings.Limits.masterDB,
                    radius: HaloMetrics.ringRadius(forSphere: cell.diameter),
                    isLive: cell.look == .live && cell.isAudible
                )
            }
            .scaleEffect(cell.zoom)
            .frame(width: 400, height: 400)
            .clipped()
            Text(cell.label).font(.caption).foregroundStyle(.white.opacity(0.7))
        }
        .frame(width: 420, height: 430)
        .background { GrainientBackground(isLive: isLiveGround) }
    }

    private func write(_ view: some View, size: CGSize, to url: URL) throws {
        let hosting = NSHostingView(
            rootView: view
                .environment(\.colorScheme, .dark)
                .environment(\.windowSimulatesGlass, true)
                .frame(width: size.width, height: size.height)
        )
        hosting.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = hosting
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        hosting.layoutSubtreeIfNeeded()
        let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: url)
        window.close()
    }

    private func writeRow(_ cells: [Cell], name: String, in directory: URL) throws {
        try write(
            HStack(spacing: 0) {
                ForEach(cells, id: \.label) { Self.tile($0, isLiveGround: $0.look == .live) }
            },
            size: CGSize(width: 420 * CGFloat(cells.count), height: 430),
            to: directory.appending(path: "\(name).png")
        )
    }

    @Test(
        "Rend la sphère et l'anneau en planches",
        .enabled(if: ProcessInfo.processInfo.environment["SPHERE_PNG_DIR"] != nil)
    )
    func renderSheets() throws {
        let path = try #require(ProcessInfo.processInfo.environment["SPHERE_PNG_DIR"])
        let directory = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try write(Color.clear, size: CGSize(width: 40, height: 40), to: directory.appending(path: ".amorce.png"))

        // Quatre instants de la diffusion : le logo y est pris dans son mouvement, les lueurs dans leur
        // dérive.
        let instants: [TimeInterval] = [0.6, 2.1, 4.4, 7.9]
        try writeRow(
            instants.map { Cell(label: "diffusion, t = \($0) s", time: $0) },
            name: "centre-diffusion", in: directory
        )
        try writeRow(
            [
                Cell(label: "repos", look: .resting, isAudible: false),
                Cell(label: "session sans son (coupé)", isAudible: false, isMuted: true),
                Cell(label: "démarrage", look: .resting, isAudible: false, glyph: .connecting),
                Cell(label: "petit disque 150", time: 2.1, diameter: 150),
            ],
            name: "centre-allures", in: directory
        )
        try writeRow(
            [
                Cell(label: "repos, gros plan", look: .resting, isAudible: false, zoom: 1.4),
                Cell(label: "diffusion t = 2,1 s, gros plan", time: 2.1, zoom: 1.4),
                Cell(label: "diffusion t = 4,4 s, gros plan", time: 4.4, zoom: 1.4),
                Cell(label: "son coupé, gros plan", isAudible: false, isMuted: true, zoom: 1.4),
            ],
            name: "centre-gros-plans", in: directory
        )
        try writeRow(
            [
                Cell(label: "volume minimum", decibels: BridgeSettings.Limits.masterDB.lowerBound),
                Cell(label: "volume −50 dB", decibels: -50),
                Cell(label: "mi-course", decibels: -30),
                Cell(label: "volume maximum", decibels: BridgeSettings.Limits.masterDB.upperBound),
            ],
            name: "anneau-niveaux", in: directory
        )
    }
}
