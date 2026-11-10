import AppKit
import Foundation
import SwiftUI
import Testing

@testable import BridgeApp

/// Rend le fond seul, hors écran, à plusieurs instants de son cycle : le mouvement ne se voit sur aucun
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

    @Test(
        "Rend le fond seul à quatre instants du cycle, au repos, et à la taille minimale",
        .enabled(if: ProcessInfo.processInfo.environment["WINDOW_PNG_DIR"] != nil)
    )
    func renderCycle() throws {
        let path = try #require(ProcessInfo.processInfo.environment["WINDOW_PNG_DIR"])
        let directory = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let size = CGSize(width: 1200, height: 760)

        for quarter in 0..<4 {
            try write(
                phase: Double(quarter) * .pi / 2, gain: GrainientField.liveGain, size: size,
                to: directory.appending(path: "fond-instant-\(quarter).png")
            )
        }
        try write(phase: 0, gain: GrainientField.restGain, size: size, to: directory.appending(path: "fond-repos.png"))
        try write(
            phase: 0, gain: GrainientField.liveGain, size: CGSize(width: 960, height: 620),
            to: directory.appending(path: "fond-minimal.png")
        )
    }
}
