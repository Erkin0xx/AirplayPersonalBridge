import AppKit
import CoreGraphics
import Foundation
import Testing

@testable import BridgeApp

/// Le relevé de la capture : 178 pixels par mètre, coin intérieur haut-gauche de l'alcôve au
/// pixel (166, 150). Les attendus sont écrits en pixels de la capture ou avec ses cotes
/// imprimées, jamais recopiés de `SalonPlan.swift` : un test qui relirait les mêmes nombres
/// ne vérifierait rien.
private func fromCapture(px x: Double, _ y: Double) -> CGPoint {
    CGPoint(x: (x - 166) / 178, y: (y - 150) / 178)
}

private let genevaID = "raop/AABBCCDDEEFF@Geneva"

@Suite("Plan du salon — fidélité à la capture")
struct SalonPlanTests {
    private let salon = RoomLayout.salon

    private func object(named name: String) throws -> RoomObject {
        try #require(salon.objects.first { $0.name == name })
    }

    private func wall(from a: (Double, Double), to b: (Double, Double)) throws
        -> RoomLayout.WallSegment
    {
        try #require(
            salon.walls.first {
                hypot($0.a.x - a.0, $0.a.y - a.1) < 0.001 && hypot($0.b.x - b.0, $0.b.y - b.1) < 0.001
            }
        )
    }

    @Test("Chaque mur mesure la cote imprimée sur la capture")
    func wallLengthsMatchPrintedDimensions() throws {
        let printed: [((Double, Double), (Double, Double), Double)] = [
            ((0.65, 0), (4.25, 0), 3.60),  // mur fenêtre, « 360 »
            ((4.25, 0), (4.25, 5.90), 5.90),  // mur sauge, « 590 »
            ((4.25, 5.90), (0, 5.90), 4.25),  // mur du buffet, « 425 »
            ((0, 5.00), (0, 2.85), 2.15),  // alcôve, « 215 »
            ((0, 2.85), (0.65, 2.85), 0.65),  // retour, « 65 »
            ((0.65, 2.85), (0.65, 0), 2.85),  // mur canapé, « 285 »
        ]
        #expect(salon.walls.count == printed.count)
        for (a, b, length) in printed {
            #expect(abs(try wall(from: a, to: b).length - length) < 0.001)
        }
    }

    @Test("L'ouverture de la porte fait bien 90 cm : aucun mur entre 5,00 et 5,90")
    func doorOpeningIsLeftOpen() {
        let throughOpening = CGPoint(x: 0, y: 5.45)
        #expect(salon.walls.allSatisfy { $0.distance(to: throughOpening) > 0.44 })
    }

    @Test("La pièce s'annonce en 4,25 × 5,90, ce qui déborde n'y change rien")
    func dimensionsAreTheWalls() throws {
        let dimensions = try #require(salon.dimensions)
        #expect(abs(dimensions.width - 4.25) < 0.001)
        #expect(abs(dimensions.height - 5.90) < 0.001)
        // Le cadrage, lui, doit voir ce qui déborde, sans quoi ce serait hors de la fenêtre...
        let bounds = try #require(salon.bounds)
        #expect(bounds.minX < -0.5)
        // ... mais pas davantage : le cercle circonscrit d'une fenêtre de 1,80 m le gonflait
        // de 90 cm, et la pièce n'occupait plus que 40 % de la vue.
        #expect(bounds.minY > -0.2 && bounds.maxY < 6.3)
        #expect(bounds.maxX < 4.5)
    }

    @Test("Le cadrage d'un objet tourné suit son emprise réelle")
    func boundsFollowRotation() throws {
        var bar = RoomObject(
            kind: .tvStand, position: .zero, size: CGSize(width: 2, height: 0.4), elevation: 0.5
        )
        let flat = try #require(RoomLayout(objects: [bar]).bounds)
        #expect(abs(flat.width - 2) < 1e-9 && abs(flat.height - 0.4) < 1e-9)
        bar.rotation = 90
        let upright = try #require(RoomLayout(objects: [bar]).bounds)
        #expect(abs(upright.width - 0.4) < 1e-9 && abs(upright.height - 2) < 1e-9)
    }

    @Test("Les trois enceintes sont à moins de 5 cm de leur marque sur la capture")
    func speakersMatchTheirMarks() throws {
        // Centres mesurés au pixel sur les marques ajoutées à la main.
        let marks: [(String, CGPoint)] = [
            ("Geneva", fromCapture(px: 325, 201)),
            ("HomePod G", fromCapture(px: 327.5, 643)),
            ("HomePod D", fromCapture(px: 888, 603)),
        ]
        for (name, mark) in marks {
            let position = try object(named: name).position
            #expect(hypot(position.x - mark.x, position.y - mark.y) < 0.05, "\(name)")
        }
    }

    @Test("Les enceintes reprennent les tailles de la bibliothèque")
    func speakersUsePresetSizes() throws {
        #expect(try object(named: "Geneva").size == RoomObject.Library.geneva.size)
        #expect(try object(named: "HomePod G").size == RoomObject.Library.homePod.size)
        #expect(try object(named: "HomePod D").size == RoomObject.Library.homePod.size)
    }

    @Test("Chaque HomePod est bien posé sur le meuble qui le porte")
    func homePodsRestOnTheirFurniture() throws {
        let left = try object(named: "HomePod G")
        let table = try #require(salon.objects.first { $0.kind == .sideTable && $0.shape == .ellipse })
        #expect(table.contains(left.position))
        #expect(left.elevation > table.elevation)

        let right = try object(named: "HomePod D")
        let sideboard = try object(named: "Buffet")
        #expect(sideboard.contains(right.position))
        #expect(right.elevation > sideboard.elevation)

        let geneva = try object(named: "Geneva")
        let console = try object(named: "Console")
        #expect(console.contains(geneva.position))
        #expect(geneva.elevation > console.elevation)
    }

    @Test("Les HomePod sont rattachés à leur sortie, la Geneva attend d'être vue")
    func initialBindings() throws {
        #expect(try object(named: "HomePod G").kind.outputID == "airplay2/Salon")
        #expect(try object(named: "HomePod D").kind.outputID == "airplay2/Salon (2)")
        let geneva = try object(named: "Geneva")
        #expect(geneva.kind == .speaker(outputID: nil))
    }

    @Test("Par défaut on écoute à table, côté fenêtre, face à la télé, oreilles à 1,10 m")
    func defaultListenerSitsAtTheTable() throws {
        let listener = try #require(salon.listener)
        #expect(listener.name == "À table")
        #expect(listener.elevation == 1.10)
        #expect(listener.rotation == 180)
        let table = try #require(salon.objects.first { $0.kind == .table })
        // Entre le bord de la table et la fenêtre, centré sur la table.
        #expect(listener.position.y < table.position.y - table.size.height / 2)
        #expect(listener.position.y > 0)
        #expect(abs(listener.position.x - table.position.x) < 0.01)
        let tv = try #require(salon.objects.first { $0.kind == .tv })
        #expect(tv.position.y > listener.position.y)
    }

    @Test("Le second lieu d'écoute est la place gauche du canapé, face à la télé")
    func secondListenerSitsOnTheLeftOfTheSofa() throws {
        let listeners = salon.listeners
        #expect(listeners.count == 2)
        let onSofa = try #require(listeners.last)
        #expect(onSofa.name == "Au canapé")
        #expect(onSofa.rotation == 180)
        let sofa = try #require(salon.objects.first { $0.kind == .sofa && $0.shape == .lShape })
        #expect(sofa.contains(onSofa.position))
        #expect(onSofa.position.x < sofa.position.x)
    }

    @Test("Choisir un lieu d'écoute change les distances, et ne survit pas à sa suppression")
    func selectingAListenerDrivesTheDelays() throws {
        var layout = salon
        let ids = ["airplay2/Salon", "airplay2/Salon (2)"]
        let atTable = layout.suggestedDelaysMS(for: ids)
        let onSofa = try #require(layout.listeners.last)

        layout.selectListener(id: onSofa.id)
        #expect(layout.listener?.id == onSofa.id)
        #expect(layout.suggestedDelaysMS(for: ids) != atTable)

        // Un identifiant qui n'est pas un lieu d'écoute ne change rien.
        let table = try #require(layout.objects.first { $0.kind == .table })
        layout.selectListener(id: table.id)
        #expect(layout.listener?.id == onSofa.id)

        layout.objects.removeAll { $0.id == onSofa.id }
        #expect(layout.listener?.name == "À table")
    }

    @Test("Le lieu choisi survit à l'écriture du plan, et un ancien fichier retombe sur le premier")
    func activeListenerIsPersisted() throws {
        var layout = salon
        let onSofa = try #require(layout.listeners.last)
        layout.selectListener(id: onSofa.id)

        let data = try JSONEncoder().encode(layout)
        let decoded = try JSONDecoder().decode(RoomLayout.self, from: data)
        #expect(decoded.listener?.id == onSofa.id)

        var fields = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        fields.removeValue(forKey: "activeListenerID")
        let older = try JSONDecoder().decode(
            RoomLayout.self, from: JSONSerialization.data(withJSONObject: fields))
        #expect(older.listener?.name == "À table")
    }

    @Test("Le canapé d'angle garde ses cotes réelles, retour en bas à droite")
    func sofaKeepsItsMeasuredSize() throws {
        let sofa = try #require(salon.objects.first { $0.kind == .sofa && $0.shape == .lShape })
        #expect(sofa.size == CGSize(width: 2.43, height: 1.56))
        #expect(sofa.isMirrored)
        // Dans le vide du L : à gauche du retour, sous la branche longue.
        let inTheCorner = CGPoint(
            x: sofa.position.x - 0.8, y: sofa.position.y + sofa.size.height / 2 - 0.1
        )
        #expect(!sofa.contains(inTheCorner))
        // Dans le retour.
        let inTheReturn = CGPoint(
            x: sofa.position.x + sofa.size.width / 2 - 0.2, y: sofa.position.y + sofa.size.height / 2 - 0.1
        )
        #expect(sofa.contains(inTheReturn))
    }

    @Test("Les objets hors du contour sont nommés comme tels")
    func outsideObjectsAreNamed() {
        let outside = salon.objects.filter { $0.position.x < 0 }
        #expect(outside.count == 2)
        #expect(outside.allSatisfy { $0.name.contains("hors pièce") })
    }

    @Test("Le plan contient bien tous les types qu'il prétend représenter")
    func everyNewKindAppears() {
        let kinds = Set(salon.objects.map(\.kind))
        for expected: RoomObject.Kind in [
            .armchair, .chair, .plant, .lamp, .sideboard, .console, .desk, .rug, .door, .window,
            .radiator, .decor, .sofa, .tvStand, .tv, .table, .coffeeTable, .sideTable, .listener,
        ] {
            #expect(kinds.contains(expected), "\(expected)")
        }
    }

    @Test("Délais suggérés : à chaque lieu, la sortie la plus lointaine garde 0 ms")
    func suggestedDelaysAreConsistent() throws {
        var bound = salon.bindingSpeakers(toOutputs: [(id: genevaID, name: "Geneva")])
        let ids = [genevaID, "airplay2/Salon", "airplay2/Salon (2)"]

        for place in bound.listeners {
            bound.selectListener(id: place.id)
            let delays = bound.suggestedDelaysMS(for: ids)
            #expect(delays.count == 3)

            let distances = try ids.map { id in
                try #require(bound.distanceToListener(outputID: id))
            }
            let farthest = try #require(distances.max())
            for (id, distance) in zip(ids, distances) {
                let expected = (farthest - distance) / RoomLayout.speedOfSound * 1000
                #expect(abs(try #require(delays[id]) - expected) < 0.001)
                // Quelques millisecondes : l'ordre de grandeur d'une pièce, pas d'une erreur.
                #expect(expected >= 0 && expected < 10)
            }
        }

        // Lues sur le plan : à table c'est le HomePod gauche le plus loin, au canapé la Geneva.
        bound.selectListener(id: try #require(bound.listeners.first).id)
        #expect(bound.suggestedDelaysMS(for: ids)["airplay2/Salon"] == 0)
        bound.selectListener(id: try #require(bound.listeners.last).id)
        #expect(bound.suggestedDelaysMS(for: ids)[genevaID] == 0)
    }

    @Test("Sans la Geneva, le plus lointain des deux HomePod devient la référence")
    func delaysWithoutGeneva() {
        let delays = salon.suggestedDelaysMS(for: ["airplay2/Salon", "airplay2/Salon (2)"])
        #expect(delays.count == 2)
        #expect(delays.values.contains(0))
        #expect(delays.values.allSatisfy { $0 < 2 })
    }

    @Test("Repères et tapis n'entrent dans aucun calcul")
    func landmarksStayOutOfTheCalculation() {
        var stripped = salon
        stripped.objects.removeAll { [.door, .window, .rug].contains($0.kind) }
        let ids = ["airplay2/Salon", "airplay2/Salon (2)"]
        #expect(stripped.suggestedDelaysMS(for: ids) == salon.suggestedDelaysMS(for: ids))
    }

    @Test("Les enceintes se dessinent au-dessus de tout, le tapis en dessous")
    func drawingOrder() throws {
        let ordered = salon.objectsInDrawingOrder
        #expect(ordered.first?.kind == .rug)
        let lastFurniture = try #require(ordered.lastIndex { $0.kind.layer == .furniture })
        let firstSpeaker = try #require(ordered.firstIndex { $0.kind.outputID != nil })
        #expect(lastFurniture < firstSpeaker)
    }

    @Test("Le corps des murs part vers l'extérieur et se raccorde sans trou aux angles")
    func wallBodiesAreOutsideAndMitred() throws {
        let top = try wall(from: (0.65, 0), to: (4.25, 0))
        let body = salon.wallBody(top)
        #expect(body.count == 4)
        #expect(body.allSatisfy { $0.y <= 0.0001 })
        // Angle sortant en haut à gauche : le corps va jusqu'au coin extérieur.
        #expect(body.contains { hypot($0.x - 0.51, $0.y + 0.14) < 0.001 })
        // Angle rentrant du retour : l'onglet ne mord pas dans la pièce.
        let turning = try wall(from: (0.65, 2.85), to: (0.65, 0))
        #expect(salon.wallBody(turning).allSatisfy { $0.x <= 0.6501 })
        #expect(salon.wallBody(turning).contains { hypot($0.x - 0.51, $0.y - 2.71) < 0.001 })
    }

    @Test("La rotation du plan conserve épaisseur et peinture des murs")
    func rotationKeepsWallFinish() {
        var rotated = salon
        for _ in 0..<4 { rotated = rotated.rotatedQuarterTurn(clockwise: true) }
        #expect(rotated.walls.map(\.thickness) == salon.walls.map(\.thickness))
        #expect(rotated.walls.map(\.paint) == salon.walls.map(\.paint))
    }
}

@Suite("Plan de la pièce — clics")
struct PlanHitTests {
    private let rug = RoomObject(
        kind: .rug, position: CGPoint(x: 2, y: 2), size: CGSize(width: 3, height: 2), elevation: 0.01
    )
    private let table = RoomObject(
        kind: .coffeeTable, position: CGPoint(x: 2, y: 2), size: CGSize(width: 0.8, height: 0.8),
        elevation: 0.4, shape: .ellipse
    )

    @Test("Le tapis est le dernier à répondre, même posé après la table")
    func rugYieldsToFurniture() {
        let layout = RoomLayout(objects: [table, rug])
        #expect(layout.object(at: CGPoint(x: 2, y: 2))?.id == table.id)
        #expect(layout.object(at: CGPoint(x: 1, y: 2))?.id == rug.id)
        #expect(layout.objectsInDrawingOrder.first?.id == rug.id)
    }

    @Test("Le débattement d'une porte laisse passer les clics vers ce qui s'y trouve")
    func doorSwingYieldsToFurniture() {
        // La porte se dessine au-dessus des meubles, pour rester visible sur le mur : c'est
        // bien la règle de priorité, pas l'ordre de dessin, qui la fait passer après.
        let door = RoomObject(
            kind: .door, position: CGPoint(x: 2, y: 2), size: CGSize(width: 0.9, height: 0.9),
            elevation: 0
        )
        let layout = RoomLayout(objects: [table, door])
        #expect(layout.objectsInDrawingOrder.last?.id == door.id)
        #expect(layout.object(at: CGPoint(x: 2, y: 2))?.id == table.id)
        #expect(layout.object(at: CGPoint(x: 2.42, y: 2.42))?.id == door.id)
        #expect(layout.element(at: CGPoint(x: 2, y: 2), wallTolerance: 0.1) == .object(table.id))
    }

    @Test("Un clic près d'un mur le prend avant le tapis, mais après un meuble")
    func wallBeatsRugButNotFurniture() {
        let wall = RoomLayout.WallSegment(a: CGPoint(x: 2, y: 0), b: CGPoint(x: 2, y: 4))
        let layout = RoomLayout(walls: [wall], objects: [rug, table])
        #expect(layout.element(at: CGPoint(x: 2.05, y: 2), wallTolerance: 0.1) == .object(table.id))
        #expect(layout.element(at: CGPoint(x: 2.05, y: 3.5), wallTolerance: 0.1) == .wall(wall.id))
        #expect(layout.element(at: CGPoint(x: 3, y: 2.5), wallTolerance: 0.1) == .object(rug.id))
        #expect(layout.element(at: CGPoint(x: 8, y: 8), wallTolerance: 0.1) == nil)
    }

    @Test("Le corps d'un mur épais cache ce qui déborde derrière lui")
    func wallBodyHidesWhatOverflows() {
        let wall = RoomLayout.WallSegment(
            a: CGPoint(x: 0, y: 0), b: CGPoint(x: 4, y: 0), thickness: 0.14
        )
        let chair = RoomObject(
            kind: .chair, position: CGPoint(x: 1, y: 0), size: CGSize(width: 0.5, height: 0.5),
            elevation: 0.45
        )
        let layout = RoomLayout(walls: [wall], objects: [chair])
        #expect(layout.element(at: CGPoint(x: 1, y: -0.07), wallTolerance: 0.01) == .wall(wall.id))
        #expect(layout.element(at: CGPoint(x: 1, y: 0.1), wallTolerance: 0.01) == .object(chair.id))
    }

    @Test("Une enceinte se prend avant le meuble qui la porte")
    func speakerBeatsItsFurniture() throws {
        let speaker = RoomObject(
            kind: .speaker(outputID: nil), position: CGPoint(x: 2, y: 2),
            size: CGSize(width: 0.15, height: 0.15), elevation: 0.5, shape: .ellipse
        )
        // Posée avant la table : l'étage l'emporte sur l'ordre de pose.
        let layout = RoomLayout(objects: [speaker, table])
        #expect(layout.object(at: CGPoint(x: 2, y: 2))?.id == speaker.id)
    }

    @Test("Le feuillage d'une plante ne capte pas les clics, seul son pot le fait")
    func foliageLetsClicksThrough() {
        let plant = RoomObject(
            kind: .plant, position: CGPoint(x: 2, y: 2), size: CGSize(width: 1, height: 1),
            elevation: 1.8, shape: .ellipse
        )
        #expect(plant.contains(CGPoint(x: 2, y: 2)))
        #expect(!plant.contains(CGPoint(x: 2.4, y: 2)))
    }

    @Test("Tous les symboles de la bibliothèque existent dans ce système")
    func symbolsExist() {
        let kinds = RoomObject.Library.groups.flatMap(\.1).map(\.kind)
        for kind in kinds {
            #expect(NSImage(systemSymbolName: kind.symbol, accessibilityDescription: nil) != nil, "\(kind)")
        }
    }

    @Test("Une Geneva tirée de la bibliothèque porte son nom : c'est lui qui la rattache")
    func libraryGenevaIsNamed() {
        let geneva = RoomObject.Library.geneva.makeObject(at: .zero)
        #expect(geneva.name == "Geneva")
        let renamed = RoomObject.Library.geneva.makeObject(at: .zero, name: "Salon")
        #expect(renamed.name == "Salon")
    }
}

@Suite("Plan de la pièce — rattachement des enceintes")
struct SpeakerBindingTests {
    private func speaker(_ name: String, output: String? = nil) -> RoomObject {
        RoomObject(
            kind: .speaker(outputID: output), position: .zero,
            size: CGSize(width: 0.2, height: 0.2), elevation: 1, name: name, shape: .ellipse
        )
    }

    private func bound(_ object: RoomObject, to outputs: [(id: String, name: String)]) -> String? {
        RoomLayout(objects: [object]).bindingSpeakers(toOutputs: outputs).objects[0].kind.outputID
    }

    @Test("La Geneva se rattache à une sortie qui porte son nom, casse et accents ignorés")
    func bindsByName() {
        #expect(bound(speaker("Geneva"), to: [(id: "x", name: "geneva")]) == "x")
        #expect(bound(speaker("Géneva"), to: [(id: "x", name: "GENEVA")]) == "x")
    }

    @Test("Elle se rattache aussi par alias, dans les deux sens")
    func bindsByAlias() {
        #expect(bound(speaker("Geneva"), to: [(id: "x", name: "AeroSphere Large")]) == "x")
        #expect(bound(speaker("AeroSphere"), to: [(id: "x", name: "Geneva-Mock")]) == "x")
        #expect(bound(speaker("Geneva"), to: [(id: "x", name: "Salon"), (id: "y", name: "Aérosphère")]) == "y")
    }

    @Test("Le nom exact l'emporte sur l'alias")
    func exactNameWins() {
        let outputs = [(id: "alias", name: "AeroSphere"), (id: "exact", name: "Geneva")]
        #expect(bound(speaker("Geneva"), to: outputs) == "exact")
    }

    @Test("Deux candidates : dans le doute, on ne rattache pas")
    func ambiguousStaysUnbound() {
        let outputs = [(id: "a", name: "Geneva Salon"), (id: "b", name: "Geneva Chambre")]
        #expect(bound(speaker("Geneva"), to: outputs) == nil)
        let twins = [(id: "a", name: "Geneva"), (id: "b", name: "Geneva")]
        #expect(bound(speaker("Geneva"), to: twins) == nil)
    }

    @Test("Un rattachement existant n'est jamais remplacé, même si sa sortie a disparu")
    func existingBindingIsKept() {
        #expect(bound(speaker("Geneva", output: "ancienne"), to: [(id: "x", name: "Geneva")]) == "ancienne")
    }

    @Test("Ni un nom vide, ni un autre appareil, ni un objet qui n'est pas une enceinte")
    func noFalsePositives() {
        #expect(bound(speaker(""), to: [(id: "x", name: "")]) == nil)
        #expect(bound(speaker("HomePod G"), to: [(id: "x", name: "Salon")]) == nil)
        #expect(bound(speaker("Geneva"), to: [(id: "x", name: "Apple TV Salon")]) == nil)
        let table = RoomObject(
            kind: .table, position: .zero, size: CGSize(width: 1, height: 1), elevation: 0.7,
            name: "Geneva"
        )
        let layout = RoomLayout(objects: [table]).bindingSpeakers(toOutputs: [(id: "x", name: "Geneva")])
        #expect(layout.objects[0].kind == .table)
    }

    @Test("Le plan du salon : seule la Geneva attend, les HomePod ne bougent pas")
    func salonBindsGenevaOnly() throws {
        let outputs: [(id: String, name: String)] = [
            (id: "raop/AA@Geneva AeroSphere", name: "Geneva AeroSphere"),
            (id: "airplay2/Salon", name: "Salon"),
            (id: "airplay2/Salon (2)", name: "Salon (2)"),
            (id: "airplay2/Apple TV Salon", name: "Apple TV Salon"),
        ]
        let layout = RoomLayout.salon.bindingSpeakers(toOutputs: outputs)
        func output(_ name: String) throws -> String? {
            try #require(layout.objects.first { $0.name == name }).kind.outputID
        }
        #expect(try output("Geneva") == "raop/AA@Geneva AeroSphere")
        #expect(try output("HomePod G") == "airplay2/Salon")
        #expect(try output("HomePod D") == "airplay2/Salon (2)")
        // Rien à faire une seconde fois : l'appelant n'a donc rien à sauvegarder.
        #expect(layout.bindingSpeakers(toOutputs: outputs) == layout)
    }
}

@Suite("Plan de la pièce — persistance")
struct RoomLayoutPersistenceTests {
    /// Un dossier jetable : ces tests ne doivent jamais approcher du vrai plan de Baptiste.
    private func temporaryFile() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "plan-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appending(path: "room-layout.json")
    }

    private func preservedCopies(nextTo url: URL) throws -> [URL] {
        try FileManager.default
            .contentsOfDirectory(
                at: url.deletingLastPathComponent(), includingPropertiesForKeys: nil
            )
            .filter { $0.lastPathComponent.contains("illisible") }
    }

    @Test("Tous les types d'objet survivent à un aller-retour JSON")
    func everyKindRoundTrips() throws {
        let kinds: [RoomObject.Kind] = [
            .sofa, .tv, .tvStand, .table, .coffeeTable, .sideTable, .shelf, .device, .listener,
            .armchair, .chair, .plant, .lamp, .sideboard, .console, .desk, .rug, .door, .window,
            .radiator, .decor, .speaker(outputID: nil), .speaker(outputID: "airplay2/Salon (2)"),
        ]
        for kind in kinds {
            let data = try JSONEncoder().encode(kind)
            #expect(try JSONDecoder().decode(RoomObject.Kind.self, from: data) == kind)
        }
    }

    @Test("Chaque nouveau type a son propre nom dans le JSON, pas celui d'un autre")
    func kindsAreDistinctOnDisk() throws {
        let kinds: [RoomObject.Kind] = [
            .armchair, .chair, .plant, .lamp, .sideboard, .console, .desk, .rug, .door, .window,
            .radiator, .decor,
        ]
        let encoded = try kinds.map { String(decoding: try JSONEncoder().encode($0), as: UTF8.self) }
        #expect(Set(encoded).count == kinds.count)
    }

    @Test("Le plan du salon complet survit à un aller-retour JSON")
    func salonRoundTrips() throws {
        let data = try JSONEncoder().encode(RoomLayout.salon)
        let decoded = try #require(RoomLayout.decodeReportingLoss(data))
        #expect(decoded.isComplete)
        let layout = decoded.layout
        #expect(layout.walls.count == RoomLayout.salon.walls.count)
        #expect(layout.objects.map(\.kind) == RoomLayout.salon.objects.map(\.kind))
        #expect(layout.walls.map(\.thickness) == RoomLayout.salon.walls.map(\.thickness))
        #expect(layout.walls.map(\.paint) == RoomLayout.salon.walls.map(\.paint))
    }

    @Test("Un type inconnu retombe sur un meuble au lieu de faire échouer le plan")
    func unknownKindIsTolerated() throws {
        let json = """
            {"walls":[],"objects":[{"kind":{"type":"meuble-du-futur"},"position":[1,2],"size":[1,1],"elevation":0.5}]}
            """
        let layout = try JSONDecoder().decode(RoomLayout.self, from: Data(json.utf8))
        #expect(layout.objects.count == 1)
        #expect(layout.objects[0].kind == .table)
    }

    @Test("Un mur d'avant l'épaisseur se relit tel quel")
    func oldWallFormatStillReads() throws {
        let json = """
            {"walls":[{"id":"\(UUID().uuidString)","a":[0,0],"b":[3,0]}],"objects":[]}
            """
        let layout = try JSONDecoder().decode(RoomLayout.self, from: Data(json.utf8))
        #expect(layout.walls.count == 1)
        #expect(layout.walls[0].thickness == 0)
        #expect(layout.walls[0].paint == nil)
    }

    @Test("Un meuble abîmé ne coûte que lui-même, et l'original est préservé")
    func damagedObjectCostsOnlyItself() throws {
        let url = try temporaryFile()
        let json = """
            {"walls":[{"a":[0,0],"b":[3,0]}],"objects":[
              {"kind":{"type":"sofa"},"position":[1,2],"size":[2,1],"elevation":0.45},
              {"kind":{"type":"sofa"},"position":"abîmé"},
              {"kind":{"type":"table"},"position":[3,3],"size":[1,1],"elevation":0.7}
            ]}
            """
        try Data(json.utf8).write(to: url)
        let layout = RoomLayout.load(from: url, legacyDefaults: nil)
        #expect(layout.walls.count == 1)
        #expect(layout.objects.count == 2)
        #expect(try preservedCopies(nextTo: url).count == 1)
    }

    @Test("JSON corrompu : plan vide, mais l'original est préservé à côté")
    func corruptJSONIsPreserved() throws {
        let url = try temporaryFile()
        let original = Data("{\"walls\":[{\"a\":[0,0]".utf8)
        try original.write(to: url)

        let layout = RoomLayout.load(from: url, legacyDefaults: nil)
        #expect(layout.walls.isEmpty && layout.objects.isEmpty)

        // Le geste qui suit dans l'app : la sauvegarde qui écrasait tout.
        #expect(layout.save(to: url))
        #expect(try Data(contentsOf: url) != original)

        let copies = try preservedCopies(nextTo: url)
        #expect(copies.count == 1)
        #expect(try Data(contentsOf: try #require(copies.first)) == original)
        #expect(try #require(copies.first).pathExtension == "json")
    }

    @Test("Relancer l'app sur le même fichier abîmé ne multiplie pas les copies")
    func preservationIsIdempotent() throws {
        let url = try temporaryFile()
        try Data("pas du json".utf8).write(to: url)
        _ = RoomLayout.load(from: url, legacyDefaults: nil)
        _ = RoomLayout.load(from: url, legacyDefaults: nil)
        #expect(try preservedCopies(nextTo: url).count == 1)
        // Mais un fichier abîmé différemment ne doit pas écraser la première copie.
        try Data("autre chose".utf8).write(to: url)
        _ = RoomLayout.load(from: url, legacyDefaults: nil)
        #expect(try preservedCopies(nextTo: url).count == 2)
    }

    @Test("Un fichier sain ne laisse aucune copie, un fichier absent non plus")
    func healthyFileLeavesNoCopy() throws {
        let url = try temporaryFile()
        #expect(RoomLayout.load(from: url, legacyDefaults: nil) == RoomLayout())
        let salon = RoomLayout.salon
        #expect(salon.save(to: url))
        #expect(RoomLayout.load(from: url, legacyDefaults: nil) == salon)
        #expect(try preservedCopies(nextTo: url).isEmpty)
    }

    @Test("Un fichier que le système refuse de lire est écarté du chemin de la sauvegarde")
    func unreadableFileIsMovedAside() throws {
        let url = try temporaryFile()
        let original = Data("{\"walls\":[]}".utf8)
        try original.write(to: url)
        let manager = FileManager.default
        try manager.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path(percentEncoded: false))

        let layout = RoomLayout.load(from: url, legacyDefaults: nil)
        #expect(layout == RoomLayout())
        #expect(!manager.fileExists(atPath: url.path(percentEncoded: false)))

        let copy = try #require(try preservedCopies(nextTo: url).first)
        try manager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: copy.path(percentEncoded: false))
        #expect(try Data(contentsOf: copy) == original)
    }

    @Test("Fichier abîmé et ancien plan en préférences : on repart de l'ancien, l'original reste")
    func legacyPlanStillRecovers() throws {
        let url = try temporaryFile()
        let abimé = Data("pas du json".utf8)
        try abimé.write(to: url)
        let suite = "plan-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let legacy = RoomLayout(
            walls: [RoomLayout.WallSegment(a: .zero, b: CGPoint(x: 2, y: 0))]
        )
        defaults.set(try JSONEncoder().encode(legacy), forKey: "roomLayout.v4")

        #expect(RoomLayout.load(from: url, legacyDefaults: defaults) == legacy)
        // Récupéré une fois pour toutes : il est désormais dans le fichier.
        #expect(RoomLayout.load(from: url, legacyDefaults: nil) == legacy)
        let copies = try preservedCopies(nextTo: url)
        #expect(copies.count == 1)
        #expect(try Data(contentsOf: try #require(copies.first)) == abimé)
    }

    @Test("Une sauvegarde impossible le dit au lieu de réussir en silence")
    func failedSaveReports() {
        let url = URL(fileURLWithPath: "/dossier-qui-n-existe-pas-\(UUID().uuidString)/plan.json")
        #expect(!RoomLayout.salon.save(to: url))
    }
}

@Suite("Plan de la pièce — annulation")
struct PlanHistoryTests {
    private let empty = RoomLayout()
    private func layout(walls count: Int) -> RoomLayout {
        RoomLayout(
            walls: (0..<count).map {
                RoomLayout.WallSegment(a: CGPoint(x: Double($0), y: 0), b: CGPoint(x: Double($0), y: 1))
            }
        )
    }

    @Test("Annuler rend l'état d'avant, rétablir rend celui d'après")
    func undoRedo() throws {
        var history = PlanHistory()
        #expect(!history.canUndo && !history.canRedo)
        let before = layout(walls: 2)
        history.record(before)
        let after = RoomLayout()  // « Tout effacer »

        let undone = history.undo(from: after)
        #expect(undone == before)
        #expect(history.canRedo && !history.canUndo)

        let redone = history.redo(from: before)
        #expect(redone == after)
        #expect(history.canUndo && !history.canRedo)
    }

    @Test("Un nouveau geste après une annulation efface ce qu'on pouvait rétablir")
    func newActionClearsRedo() {
        var history = PlanHistory()
        let first = layout(walls: 1)
        history.record(first)
        _ = history.undo(from: layout(walls: 2))
        #expect(history.canRedo)
        history.record(first)
        #expect(!history.canRedo)
    }

    @Test("Annuler sans rien à annuler ne fait rien")
    func undoOnEmpty() {
        var history = PlanHistory()
        #expect(history.undo(from: empty) == nil)
        #expect(history.redo(from: empty) == nil)
    }

    @Test("Un instantané identique à l'état courant est sauté : annuler a toujours un effet")
    func noOpSnapshotIsSkipped() {
        var history = PlanHistory()
        let first = layout(walls: 1)
        let second = layout(walls: 2)
        history.record(first)
        history.record(second)
        // Le geste retenu n'a finalement rien changé : on est encore sur `second`.
        let undone = history.undo(from: second)
        #expect(undone == first)
    }

    @Test("Les retouches d'un même réglage ne font qu'un pas d'annulation")
    func groupedEditsCoalesce() {
        var history = PlanHistory()
        let start = layout(walls: 1)
        history.record(start, group: "curseur")
        history.record(layout(walls: 2), group: "curseur")
        history.record(layout(walls: 3), group: "curseur")
        #expect(history.undoStack.count == 1)
        let undone = history.undo(from: layout(walls: 4))
        #expect(undone == start)
    }

    @Test("Changer d'objet clôt le groupe : c'est un nouveau pas d'annulation")
    func endingGroupStartsNewStep() {
        var history = PlanHistory()
        history.record(layout(walls: 1), group: "a")
        history.endGroup()
        history.record(layout(walls: 2), group: "a")
        #expect(history.undoStack.count == 2)
        history.record(layout(walls: 3), group: "b")
        #expect(history.undoStack.count == 3)
        history.record(layout(walls: 4))
        history.record(layout(walls: 5), group: "b")
        #expect(history.undoStack.count == 5)
    }

    @Test("La pile est bornée : les gestes les plus anciens sont oubliés")
    func stackIsBounded() {
        var history = PlanHistory()
        for index in 0..<(PlanHistory.limit + 20) { history.record(layout(walls: index)) }
        #expect(history.undoStack.count == PlanHistory.limit)
        #expect(history.undoStack.first?.walls.count == 20)
    }
}
