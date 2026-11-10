import AppKit
import Foundation
import SwiftUI
import Testing

@testable import BridgeApp

/// Rend le fond seul, hors écran, à huit instants de son cycle, et leur planche : le mouvement ne se voit sur aucun
/// autre rendu, où le fond sort figé à sa première image.
///
/// Inerte tant que la variable d'environnement n'est pas posée.
///
/// ```
/// WINDOW_PNG_DIR=/chemin/dossier swift test --filter GrainientBackgroundExport
/// ```
///
/// Chaque image est une image-clé étirée sous le grain, comme dans la vue. **Ce qu'elles ne montrent
/// pas** : le fondu d'une image-clé à la suivante, que joue Core Animation dans l'app.
@Suite("Fond — export à la demande")
struct GrainientBackgroundExport {
    private func write(phase: Double, gain: Double, size: CGSize, to url: URL) throws {
        let aspect = GrainientField.quantizedAspect(width: size.width, height: size.height)
        let image = try #require(GrainientField.image(aspect: aspect, phase: phase, gain: gain))
        let grain = try #require(GrainientBackground.grain)
        let view = ZStack {
            Image(decorative: image, scale: 1).resizable().interpolation(.high)
            Image(decorative: grain, scale: 2).resizable(resizingMode: .tile)
        }
        .frame(width: size.width, height: size.height)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let rendered = try #require(renderer.cgImage)
        let data = try #require(NSBitmapImageRep(cgImage: rendered).representation(using: .png, properties: [:]))
        try data.write(to: url)
    }

    /// Le fond à cet instant du cycle, sous son grain, à cette taille.
    private func frame(time: TimeInterval, size: CGSize) throws -> some View {
        let aspect = GrainientField.quantizedAspect(width: 1200, height: 760)
        let image = try #require(
            GrainientField.image(aspect: aspect, phase: GrainientField.phase(at: time), gain: GrainientField.liveGain)
        )
        let grain = try #require(GrainientBackground.grain)
        return ZStack {
            Image(decorative: image, scale: 1).resizable().interpolation(.high)
            Image(decorative: grain, scale: 2).resizable(resizingMode: .tile)
        }
        .frame(width: size.width, height: size.height)
    }

    @Test(
        "Rend le fond seul à huit instants du cycle, leur planche, le repos, et la taille minimale",
        .enabled(if: ProcessInfo.processInfo.environment["WINDOW_PNG_DIR"] != nil)
    )
    func renderCycle() throws {
        let path = try #require(ProcessInfo.processInfo.environment["WINDOW_PNG_DIR"])
        let directory = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let size = CGSize(width: 1200, height: 760)
        let instants = 8
        let times = (0..<instants).map { Double($0) * GrainientField.period / Double(instants) }

        for (index, time) in times.enumerated() {
            try write(
                phase: GrainientField.phase(at: time), gain: GrainientField.liveGain, size: size,
                to: directory.appending(path: "fond-instant-\(index).png")
            )
        }
        try write(phase: 0, gain: GrainientField.restGain, size: size, to: directory.appending(path: "fond-repos.png"))
        try write(
            phase: 0, gain: GrainientField.liveGain, size: CGSize(width: 960, height: 620),
            to: directory.appending(path: "fond-minimal.png")
        )

        // La planche : les huit instants côte à côte, quatre par rangée, chacun avec son heure dans le cycle.
        let thumb = CGSize(width: 600, height: 380)
        let frames = try times.map { try frame(time: $0, size: thumb) }
        let sheet = VStack(spacing: 6) {
            ForEach(0..<2, id: \.self) { row in
                HStack(spacing: 6) {
                    ForEach(0..<4, id: \.self) { column in
                        let index = row * 4 + column
                        frames[index]
                            .overlay(alignment: .topLeading) {
                                Text(String(format: "t = %.1f s", times[index]))
                                    .font(.system(size: 20, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .padding(10)
                            }
                    }
                }
            }
        }
        .padding(6)
        .background(Color.black)
        let renderer = ImageRenderer(content: sheet)
        renderer.scale = 1
        let rendered = try #require(renderer.cgImage)
        let data = try #require(NSBitmapImageRep(cgImage: rendered).representation(using: .png, properties: [:]))
        try data.write(to: directory.appending(path: "fond-planche.png"))
    }
}
