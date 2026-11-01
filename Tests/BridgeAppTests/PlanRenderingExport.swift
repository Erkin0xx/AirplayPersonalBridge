import AppKit
import CoreGraphics
import Foundation
import SwiftUI
import Testing

@testable import BridgeApp

/// Deux commandes utilitaires, sous forme de tests inertes tant que leur variable
/// d'environnement n'est pas posée : c'est le seul endroit d'où l'on atteint à la fois le code
/// de l'app et le système de fichiers sans lancer l'app (qui découvrirait le vrai matériel).
///
/// ```
/// PLAN_PNG_OUT=/chemin/plan.png   swift test --filter PlanExport   # rend le plan du salon
/// SALON_JSON_OUT=/chemin/plan.json swift test --filter PlanExport  # écrit son JSON
/// ```
@Suite("Plan du salon — exports à la demande")
struct PlanExport {
    /// Même géométrie que la capture de référence : 178 pixels par mètre, pixel (166, 150) à
    /// l'origine du modèle, 1068 × 1328 pixels. Le rendu se superpose donc à la capture sans
    /// aucun recalage. En points, c'est la moitié à l'échelle 2, soit la densité d'un écran
    /// Retina, pour que textes et traits aient la taille qu'ils auront vraiment dans l'app.
    private static let canvas = CGSize(width: 534, height: 664)
    private static let transform = PlanTransform(
        scale: 89, origin: CGPoint(x: 83, y: 75)
    )

    /// Comme dans l'app une fois la Geneva allumée : les trois enceintes rattachées.
    private static var boundLayout: RoomLayout {
        RoomLayout.salon.bindingSpeakers(
            toOutputs: [
                (id: "raop/AABBCCDDEEFF@Geneva", name: "Geneva"),
                (id: RoomLayout.salonLeftHomePodID, name: "Salon"),
                (id: RoomLayout.salonRightHomePodID, name: "Salon (2)"),
            ]
        )
    }

    private static let outputIDs = [
        "raop/AABBCCDDEEFF@Geneva", RoomLayout.salonLeftHomePodID, RoomLayout.salonRightHomePodID,
    ]

    private func renderPNG(
        _ plan: PlanRenderer, canvas: CGSize, scheme: ColorScheme, to url: URL
    ) throws {
        let view = Canvas { context, size in plan.draw(in: &context, size: size) }
            .frame(width: canvas.width, height: canvas.height)
            .background(Theme.background)
            .environment(\.colorScheme, scheme)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        // Les couleurs dynamiques se résolvent sur l'apparence courante du dessin, pas sur
        // l'environnement SwiftUI : hors d'une fenêtre, il faut la poser soi-même.
        let appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        var image: CGImage?
        (appearance ?? NSAppearance.currentDrawing()).performAsCurrentDrawingAppearance {
            image = renderer.cgImage
        }
        let rendered = try #require(image)
        let data = try #require(
            NSBitmapImageRep(cgImage: rendered).representation(using: .png, properties: [:])
        )
        try data.write(to: url)
    }

    @Test(
        "Rend le plan du salon en PNG : modes sombre et clair, et à la taille de l'app",
        .enabled(if: ProcessInfo.processInfo.environment["PLAN_PNG_OUT"] != nil)
    )
    func renderSalon() throws {
        let path = try #require(ProcessInfo.processInfo.environment["PLAN_PNG_OUT"])
        let url = URL(fileURLWithPath: path)
        func sibling(_ suffix: String) -> URL {
            url.deletingPathExtension().appendingPathExtension("\(suffix).png")
        }

        let layout = Self.boundLayout
        let reference = PlanRenderer(
            layout: layout, transform: Self.transform, outputIDs: Self.outputIDs
        )
        try renderPNG(reference, canvas: Self.canvas, scheme: .dark, to: url)
        try renderPNG(reference, canvas: Self.canvas, scheme: .light, to: sibling("clair"))

        // Le cas le plus serré : la zone de plan de la fenêtre minimale, cadrée comme l'app le
        // fait à l'ouverture, en mode édition avec un objet sélectionné.
        let compact = CGSize(width: 560, height: 490)
        var editing = PlanRenderer(
            layout: layout, transform: .fitting(layout, in: compact), outputIDs: Self.outputIDs,
            showsVertexHandles: true
        )
        if let geneva = layout.objects.first(where: { $0.name == "Geneva" }) {
            editing.selection = [.object(geneva.id)]
        }
        try renderPNG(editing, canvas: compact, scheme: .dark, to: sibling("app"))
        editing.selection = []
        editing.showsAllLabels = true
        try renderPNG(editing, canvas: compact, scheme: .dark, to: sibling("app-cotes"))
    }

    @Test(
        "Écrit le JSON du plan du salon, lisible par l'app",
        .enabled(if: ProcessInfo.processInfo.environment["SALON_JSON_OUT"] != nil)
    )
    func exportSalonJSON() throws {
        let path = try #require(ProcessInfo.processInfo.environment["SALON_JSON_OUT"])
        let url = URL(fileURLWithPath: path)
        let layout = RoomLayout.salon
        #expect(layout.save(to: url))
        // Relu comme l'app le relira : un JSON qu'elle ne saurait pas lire la ferait repartir
        // d'un plan vide.
        let decoded = try #require(RoomLayout.decodeReportingLoss(Data(contentsOf: url)))
        #expect(decoded.isComplete)
        #expect(decoded.layout == layout)
    }
}
