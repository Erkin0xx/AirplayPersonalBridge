//
//  PlanRenderer.swift
//  AirplayPersonalBridge
//

import AppKit
import SwiftUI

/// Les couleurs du plan.
///
/// Deux familles. Le fond, la grille et les états (sélection, tracé, distances) sont des couleurs du
/// système : elles suivent l'apparence, l'accent et le contraste choisis dans les Réglages, comme le
/// reste de la fenêtre. Les matières, elles, sont prélevées sur le plan d'origine de Baptiste : du bois
/// reste du bois en mode clair comme en mode sombre, d'où des couleurs fixes ; seuls le mur, le tapis et
/// le contour, qui se détachent du fond, changent avec lui.
enum PlanPalette {
    /// Le fond du plan : une table, pas une page. Un gris à peine teinté, plus doux que le noir ou le
    /// blanc purs d'un document, sur lequel le sol de la pièce se détache.
    static let canvas = dynamic(dark: 0x0E0C12, light: 0xE9E8E4)
    /// Le sol de la pièce, posé sur la table : c'est lui la feuille.
    static let floor = dynamic(dark: 0x1D1A22, light: 0xFBFAF7)
    /// La graduation au mètre : un point par mètre, pas un quadrillage.
    static let grid = dynamic(dark: 0x3D3846, light: 0xC2BFB7)
    /// Ce qui est sélectionné ou désigné : l'accent de l'app.
    static let selection = BridgeTheme.accent
    /// Le mur en cours de tracé.
    static let drawing = BridgeTheme.accent
    /// La mesure de calibrage.
    static let measure = Color(nsColor: .systemRed)
    /// Le lieu d'écoute et les distances qui en partent.
    static let listening = Color(nsColor: .systemOrange)
    /// Les cotes au repos.
    static let secondaryText = Color(nsColor: .secondaryLabelColor)
    /// Les traits de premier plan : contour des poignées, de la tête, des oreilles.
    static let ink = Color(nsColor: .labelColor)

    static let wall = dynamic(dark: 0xD0D7D0, light: 0x565C57)
    static let outline = dynamic(dark: 0xE4EAE6, light: 0x6B6F6A)
    static let rug = dynamic(dark: 0x272723, light: 0xE4DFD3)
    static let rugLine = dynamic(dark: 0x4A4438, light: 0xB9B09C)

    static let wood = fixed(0xB38B5E)
    static let darkWood = fixed(0x86604B)
    static let paleWood = fixed(0xAD9670)
    static let fabric = fixed(0xD7CEBD)
    static let fabricShade = fixed(0xC3B9A5)
    static let chairSeat = fixed(0xB3A283)
    static let charcoal = fixed(0x4B514D)
    static let slate = fixed(0x4E5D5D)
    static let taupe = fixed(0x8C8270)
    static let taupeShade = fixed(0x68675D)
    static let glass = fixed(0x7B9397)
    static let sage = fixed(0x7B9A80)
    static let foliage = fixed(0x7FA46B)
    static let amber = fixed(0xF0B64D)

    /// L'unique accent des enceintes, le même pour tous les modèles : c'est le sujet du plan, il doit
    /// se repérer en premier, mais par un trait fin plutôt que par une couleur criarde. Le violet du
    /// thème, parce que le reste est déjà pris : l'ambre aux lampes et aux distances, le rose à la
    /// sélection, le vert aux plantes.
    static let speakerAccent = dynamic(dark: 0xB69CFF, light: 0x6A4BD8)
    /// Le tissu maillé, vu du dessus : le flanc qui fuit vers le bord s'assombrit.
    static let meshLight = fixed(0x5C625E)
    static let meshDark = fixed(0x2A2E2C)
    /// Le disque tactile du HomePod : du verre sombre, plus lisse que le tissu qui l'entoure.
    static let touchLight = fixed(0x3C4240)
    static let touchDark = fixed(0x151817)

    private static func fixed(_ hex: UInt32) -> Color {
        Color(nsColor: color(hex))
    }

    private static func dynamic(dark: UInt32, light: UInt32) -> Color {
        Color(
            nsColor: NSColor(name: nil) { appearance in
                color(appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light)
            }
        )
    }

    private static func color(_ hex: UInt32) -> NSColor {
        NSColor(
            srgbRed: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255, alpha: 1
        )
    }
}

extension PlanTransform {
    /// La partie d'une vue que des panneaux flottants laissent visible. Quand ils ne laissent pas au moins
    /// le tiers de la largeur ou de la hauteur, c'est la vue entière : mieux vaut un plan sous un panneau
    /// qu'un plan minuscule.
    static func visibleRect(in size: CGSize, insets: EdgeInsets) -> CGRect {
        let width = size.width - insets.leading - insets.trailing
        let height = size.height - insets.top - insets.bottom
        let x = width >= size.width / 3 ? insets.leading : 0
        let y = height >= size.height / 3 ? insets.top : 0
        return CGRect(
            x: x, y: y,
            width: width >= size.width / 3 ? width : size.width,
            height: height >= size.height / 3 ? height : size.height
        )
    }
}

/// Le dessin du plan, sans vue ni état d'interface.
///
/// Séparé de l'éditeur pour pouvoir être **rendu hors de l'app** : un test produit un PNG du
/// plan, ce qui permet de le comparer à un document de référence sans ouvrir de fenêtre. Ce
/// qui relève du tracé en cours (mur, calibrage) reste dans la vue, qui le dessine par-dessus.
///
/// Toutes les tailles d'objets dérivent des mètres du modèle ; seules les épaisseurs de trait
/// et les textes sont en points, pour rester lisibles à tous les zooms.
struct PlanRenderer {
    var layout: RoomLayout
    var transform: PlanTransform
    /// Les sorties découvertes : seules leurs enceintes ont un trait vers l'auditeur.
    var outputIDs: [String] = []
    var selection: Set<PlanElement> = []
    var hoveredObject: UUID?
    var hoveredVertex: CGPoint?
    var showsAllLabels = false
    var showsVertexHandles = false
    /// Ce qu'on écrit à côté du nom d'une enceinte : le volume de sa sortie, si elle est cochée.
    var speakerCaptions: [String: String] = [:]
    var backgroundImage: NSImage?

    private var scale: Double { transform.scale }

    func draw(in context: inout GraphicsContext, size: CGSize) {
        drawFloor(&context)
        drawBackground(&context)
        drawGrid(&context, size: size)
        let objects = layout.objectsInDrawingOrder
        for object in objects where object.kind.layer < .wallFixture {
            drawBody(of: object, in: &context)
        }
        // Après les meubles : un mur cache ce qui déborde derrière lui, comme le feuillage
        // d'une plante posée dans un angle.
        drawWalls(&context)
        for object in objects where object.kind.layer == .wallFixture {
            drawBody(of: object, in: &context)
        }
        drawDistanceLines(&context)
        for object in objects where object.kind.layer == .top {
            drawBody(of: object, in: &context)
        }
        drawWallLabels(&context)
        drawVertexHandles(&context)
        // Les textes en tout dernier : un nom masqué par le meuble voisin ne sert à rien.
        for object in objects { drawLabels(of: object, in: &context) }
    }

    // MARK: - Fond et grille

    /// L'image de fond, sous la grille pour que les cotes restent lisibles par-dessus.
    private func drawBackground(_ context: inout GraphicsContext) {
        guard let background = layout.background, let image = backgroundImage else { return }
        let pixels = Self.pixelSize(of: image)
        let size = CGSize(
            width: pixels.width * background.metersPerPixel * scale,
            height: pixels.height * background.metersPerPixel * scale
        )
        let topLeft = transform.toView(background.origin)
        let imageCenter = CGPoint(x: topLeft.x + size.width / 2, y: topLeft.y + size.height / 2)
        let rect = CGRect(
            x: -size.width / 2, y: -size.height / 2, width: size.width, height: size.height
        )

        // L'image tourne autour de son centre pour suivre les rotations du plan : un
        // décalque qui ne suivrait pas cesserait de correspondre au relevé.
        context.drawLayer { layer in
            layer.translateBy(x: imageCenter.x, y: imageCenter.y)
            layer.rotate(by: .degrees(background.rotation))
            layer.opacity = background.opacity
            layer.draw(Image(nsImage: image), in: rect)
            layer.opacity = 1
            if !background.isLocked {
                layer.stroke(
                    Path(rect), with: .color(PlanPalette.selection),
                    style: .init(lineWidth: 2, dash: [6, 4])
                )
            }
        }
    }

    /// Dimensions en **pixels** de l'image, pas en points : une capture d'écran Retina
    /// rapporte une taille en points deux fois plus petite que sa vraie définition, ce qui
    /// fausserait l'échelle d'un facteur 2 sans que rien ne le signale.
    static func pixelSize(of image: NSImage) -> CGSize {
        if let representation = image.representations.first {
            return CGSize(width: representation.pixelsWide, height: representation.pixelsHigh)
        }
        return image.size
    }

    /// Le sol : l'intérieur des murs, un ton au-dessus du fond, avec l'ombre d'une feuille posée. Sans
    /// lui, la pièce n'était qu'un trait sur un quadrillage. Pas sous une image de fond : elle est le sol.
    private func drawFloor(_ context: inout GraphicsContext) {
        guard layout.background == nil else { return }
        var floor = Path()
        for outline in Self.floorOutlines(of: layout.walls) { addPolygon(outline, to: &floor) }
        guard !floor.isEmpty else { return }
        context.drawLayer { layer in
            layer.addFilter(.shadow(color: .black.opacity(0.22), radius: 22, y: 8))
            layer.fill(floor, with: .color(PlanPalette.floor))
        }
    }

    /// Les contours que dessinent les murs, face intérieure : une boucle fermée, ou une suite de murs
    /// ouverte par une porte, qu'on referme d'un trait. Un mur isolé ou un embranchement n'en donnent pas :
    /// mieux vaut aucun sol qu'un sol faux.
    static func floorOutlines(of walls: [RoomLayout.WallSegment]) -> [[CGPoint]] {
        struct Corner: Hashable {
            let x: Int
            let y: Int
            init(_ point: CGPoint) {
                // Au centimètre : deux murs tracés bout à bout partagent leur coin.
                x = Int((point.x * 100).rounded())
                y = Int((point.y * 100).rounded())
            }
        }
        var points: [Corner: CGPoint] = [:]
        var neighbours: [Corner: [Corner]] = [:]
        var order: [Corner] = []
        for wall in walls {
            let a = Corner(wall.a)
            let b = Corner(wall.b)
            guard a != b else { continue }
            for (corner, point) in [(a, wall.a), (b, wall.b)] where points[corner] == nil {
                points[corner] = point
                order.append(corner)
            }
            neighbours[a, default: []].append(b)
            neighbours[b, default: []].append(a)
        }

        var visited: Set<Corner> = []
        var outlines: [[CGPoint]] = []
        // Les bouts d'abord : une suite ouverte se parcourt d'un bout à l'autre.
        let starts = order.filter { neighbours[$0]?.count == 1 } + order
        for start in starts where !visited.contains(start) {
            var chain = [start]
            var previous: Corner?
            var current = start
            var isValid = true
            visited.insert(start)
            while true {
                let around = neighbours[current] ?? []
                guard around.count <= 2 else {
                    isValid = false
                    break
                }
                guard let next = around.first(where: { $0 != previous && !visited.contains($0) }) else { break }
                visited.insert(next)
                chain.append(next)
                previous = current
                current = next
            }
            // Le reste d'un embranchement ne doit pas se présenter plus tard comme une pièce.
            if !isValid {
                var pending = chain
                while let corner = pending.popLast() {
                    for other in neighbours[corner] ?? [] where !visited.contains(other) {
                        visited.insert(other)
                        pending.append(other)
                    }
                }
                continue
            }
            if chain.count >= 3 { outlines.append(chain.compactMap { points[$0] }) }
        }
        return outlines
    }

    private func drawGrid(_ context: inout GraphicsContext, size: CGSize) {
        // Graduation au mètre : c'est l'unité dans laquelle on raisonne, et elle donne
        // l'échelle sans avoir à écrire de cote partout. Un point par mètre, comme le fond d'un
        // tableau blanc : des lignes découpaient la pièce en carreaux. En dessous de 25 px/m elle
        // deviendrait un aplat, donc on l'espace.
        let step: Double = scale < 25 ? 5 : 1
        let radius = 1.25
        var dots = Path()
        let topLeft = transform.toModel(.zero)
        let bottomRight = transform.toModel(CGPoint(x: size.width, y: size.height))
        var x = (topLeft.x / step).rounded(.down) * step
        while x <= bottomRight.x {
            var y = (topLeft.y / step).rounded(.down) * step
            while y <= bottomRight.y {
                let center = transform.toView(CGPoint(x: x, y: y))
                dots.addEllipse(
                    in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
                )
                y += step
            }
            x += step
        }
        context.fill(dots, with: .color(PlanPalette.grid))
    }

    // MARK: - Murs

    /// Un trait fin et régulier sur la face intérieure, celle qui compte pour poser un meuble : l'épaisseur
    /// du mur reste dans le modèle (clic, cotes), elle n'alourdit plus le dessin.
    private func drawWalls(_ context: inout GraphicsContext) {
        var plain = Path()
        var selected = Path()
        for wall in layout.walls {
            let isSelected = selection.contains(.wall(wall.id))
            if isSelected {
                selected.move(to: transform.toView(wall.a))
                selected.addLine(to: transform.toView(wall.b))
            } else {
                plain.move(to: transform.toView(wall.a))
                plain.addLine(to: transform.toView(wall.b))
            }
        }
        context.stroke(
            plain, with: .color(PlanPalette.wall), style: .init(lineWidth: Self.wallLineWidth, lineCap: .round)
        )
        context.stroke(
            selected, with: .color(PlanPalette.selection),
            style: .init(lineWidth: Self.wallLineWidth + 2, lineCap: .round)
        )
    }

    static let wallLineWidth = 4.0

    private func addPolygon(_ points: [CGPoint], to path: inout Path) {
        guard let first = points.first else { return }
        path.move(to: transform.toView(first))
        for point in points.dropFirst() { path.addLine(to: transform.toView(point)) }
        path.closeSubpath()
    }

    private func drawWallLabels(_ context: inout GraphicsContext) {
        for wall in layout.walls {
            let isSelected = selection.contains(.wall(wall.id))
            // Les cotes de mur ne s'affichent qu'à la sélection, ou avec « toutes les cotes » : à
            // demeure, elles entouraient la pièce de chiffres qu'on ne lit qu'en la dessinant.
            guard showsAllLabels || isSelected else { continue }
            let a = transform.toView(wall.a)
            let b = transform.toView(wall.b)
            let middle = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
            // Un mur épais porte sa cote à l'extérieur : c'est là qu'on l'attend sur un plan,
            // et un texte sur l'aplat du mur se lirait mal. Un texte reste horizontal : il
            // faut s'écarter davantage d'un mur vertical que d'un mur horizontal.
            let normal = wall.outerNormal
            let reach = wall.thickness * scale + 9 + abs(normal.x) * 19
            let at = wall.thickness > 0
                ? CGPoint(x: middle.x + normal.x * reach, y: middle.y + normal.y * reach)
                : CGPoint(x: middle.x, y: middle.y - 9)
            context.draw(
                Text(String(format: "%.2f m", wall.length))
                    .font(.system(size: 10))
                    .foregroundStyle(isSelected ? PlanPalette.selection : PlanPalette.secondaryText),
                at: at
            )
        }
    }

    /// Les poignées de sommet. Elles ne s'affichent qu'en mode Sélection : pendant un tracé
    /// elles se confondraient avec les points du mur en cours.
    private func drawVertexHandles(_ context: inout GraphicsContext) {
        guard showsVertexHandles else { return }
        for vertex in uniqueWallVertices {
            let view = transform.toView(vertex)
            let isHovered = hoveredVertex.map {
                hypot($0.x - vertex.x, $0.y - vertex.y) < 0.002
            } ?? false
            let radius: CGFloat = isHovered ? 6.5 : 4
            let circle = Path(
                ellipseIn: CGRect(
                    x: view.x - radius, y: view.y - radius, width: radius * 2, height: radius * 2
                )
            )
            context.fill(circle, with: .color(isHovered ? PlanPalette.selection : PlanPalette.canvas))
            context.stroke(
                circle, with: .color(isHovered ? PlanPalette.selection : PlanPalette.ink.opacity(0.55)),
                lineWidth: 1.5
            )
        }
    }

    /// Les sommets sans doublon, au millimètre — un coin partagé par quatre segments ne
    /// doit dessiner qu'une poignée.
    private var uniqueWallVertices: [CGPoint] {
        var seen: Set<[Int]> = []
        var result: [CGPoint] = []
        for vertex in layout.wallVertices {
            let key = [Int((vertex.x * 1000).rounded()), Int((vertex.y * 1000).rounded())]
            if seen.insert(key).inserted { result.append(vertex) }
        }
        return result
    }

    // MARK: - Distances

    /// Le trait enceinte ↔ oreilles, avec la distance : la lecture directe de ce qui
    /// produit le délai suggéré.
    private func drawDistanceLines(_ context: inout GraphicsContext) {
        guard let listener = layout.listener else { return }
        let listenerView = transform.toView(listener.position)
        let listenerDesignated = selection.contains(.object(listener.id))
            || hoveredObject == listener.id

        for outputID in outputIDs {
            let speakers = layout.speakers(forOutput: outputID)
            guard !speakers.isEmpty else { continue }

            for speaker in speakers {
                let speakerView = transform.toView(speaker.position)
                var line = Path()
                line.move(to: speakerView)
                line.addLine(to: listenerView)
                context.stroke(
                    line, with: .color(PlanPalette.listening.opacity(0.55)),
                    style: .init(lineWidth: 1.5, dash: [5, 4])
                )

                // La cote ne s'affiche que pour l'objet désigné. Avec trois enceintes et
                // une position d'écoute, quatre étiquettes convergeaient au même endroit
                // et se rendaient mutuellement illisibles.
                let designated = showsAllLabels || listenerDesignated
                    || selection.contains(.object(speaker.id)) || hoveredObject == speaker.id
                guard designated else { continue }

                let distance = layout.distance(from: speaker, to: listener)
                let flat = hypot(
                    speaker.position.x - listener.position.x,
                    speaker.position.y - listener.position.y
                )
                // « 3D » n'apparaît que si la hauteur change vraiment la distance : sinon
                // la mention serait du bruit.
                let label = abs(distance - flat) > 0.02
                    ? String(format: "%.2f m (3D)", distance)
                    : String(format: "%.2f m", distance)
                drawHaloText(
                    Text(label).font(.subheadline).foregroundStyle(PlanPalette.listening),
                    at: CGPoint(
                        x: (speakerView.x + listenerView.x) / 2,
                        y: (speakerView.y + listenerView.y) / 2 - 8
                    ),
                    in: &context
                )
            }

            // Pour une paire stéréo, c'est la moyenne qui commande le délai : l'afficher
            // évite de croire que le réglage suit l'une des deux boîtes en particulier.
            if speakers.count > 1, showsAllLabels || listenerDesignated,
                let mean = layout.distanceToListener(outputID: outputID)
            {
                let centroid = speakers.reduce(CGPoint.zero) {
                    CGPoint(x: $0.x + $1.position.x, y: $0.y + $1.position.y)
                }
                let middle = transform.toView(
                    CGPoint(
                        x: centroid.x / Double(speakers.count),
                        y: centroid.y / Double(speakers.count)
                    )
                )
                drawHaloText(
                    Text(String(format: "moyenne %.2f m", mean))
                        .font(.system(size: 10, weight: .bold)).foregroundStyle(PlanPalette.listening),
                    at: CGPoint(
                        x: (middle.x + listenerView.x) / 2, y: (middle.y + listenerView.y) / 2 + 8
                    ),
                    in: &context
                )
            }
        }
    }

    // MARK: - Objets

    private func drawBody(of object: RoomObject, in context: inout GraphicsContext) {
        let center = transform.toView(object.position)
        let width = object.size.width * scale
        let height = object.size.height * scale
        let rect = CGRect(x: -width / 2, y: -height / 2, width: width, height: height)
        let isSelected = selection.contains(.object(object.id))
        let isDesignated = isSelected || hoveredObject == object.id
        let outline = outlinePath(of: object, in: rect)
        // Un lieu d'écoute non choisi reste visible et déplaçable, mais en retrait : c'est le lieu
        // choisi qui commande les distances tracées et les délais.
        let opacity = object.kind == .listener && object.id != layout.listener?.id ? 0.35 : 1

        context.drawLayer { layer in
            layer.opacity = opacity
            layer.translateBy(x: center.x, y: center.y)
            layer.rotate(by: .degrees(object.rotation))
            drawMaterial(of: object, in: rect, outline: outline, on: &layer)

            if isSelected {
                layer.stroke(outline, with: .color(PlanPalette.selection), lineWidth: 2.5)
            }
            // Le trait sur un bord marque l'avant du meuble : sans repère d'orientation, faire
            // tourner un canapé ne se voit pas. Seulement sur l'objet qu'on manipule : à
            // demeure, il n'aide personne et brouille la lecture des matières.
            if isDesignated, !object.isRound, !object.kind.hasNoAcousticHeight {
                var front = Path()
                front.move(to: CGPoint(x: -width / 2, y: -height / 2))
                front.addLine(to: CGPoint(x: width / 2, y: -height / 2))
                layer.stroke(front, with: .color(PlanPalette.selection), lineWidth: 2.5)
            }
        }
    }

    /// Une seule définition du contour sert au remplissage et à la sélection. Le L vient du
    /// modèle, qui s'en sert aussi pour le clic : les deux ne peuvent pas diverger.
    private func outlinePath(of object: RoomObject, in rect: CGRect) -> Path {
        switch object.shape {
        case .ellipse:
            return Path(ellipseIn: rect)
        case .lShape:
            return Path { path in
                let points = object.localPolygon.map { CGPoint(x: $0.x * scale, y: $0.y * scale) }
                guard let first = points.first else { return }
                path.move(to: first)
                for point in points.dropFirst() { path.addLine(to: point) }
                path.closeSubpath()
            }
        case .rectangle:
            let meters: Double = switch object.kind {
            case .armchair: 0.14
            case .decor: min(object.size.width, object.size.height) >= 0.25 ? 0.11 : 0.01
            case .chair, .sideTable: 0.05
            case .listener: 0.06
            default: 0.015
            }
            return Path(
                roundedRect: rect,
                cornerRadius: max(min(max(meters * scale, 1), min(rect.width, rect.height) / 3), 0)
            )
        }
    }

    /// Des aplats, sans contour ni détail : un plan qui se lit d'un coup d'œil, où seules les enceintes
    /// et le lieu d'écoute sont dessinés avec soin. Coussins, pieds de chaise, feuillages et motifs de
    /// tapis ont existé (jusqu'au 2026-11-10) ; Baptiste les a trouvés de trop.
    private func drawMaterial(
        of object: RoomObject, in rect: CGRect, outline: Path, on layer: inout GraphicsContext
    ) {
        func plain(_ color: Color) {
            layer.fill(outline, with: .color(color))
        }
        /// Un simple anneau : ce qui est posé là sans être un meuble.
        func ring(_ color: Color) {
            let side = min(rect.width, rect.height, 0.34 * scale)
            let disc = CGRect(x: -side / 2, y: -side / 2, width: side, height: side)
            layer.fill(Path(ellipseIn: disc), with: .color(PlanPalette.floor))
            layer.stroke(Path(ellipseIn: disc), with: .color(color), lineWidth: 1.75)
        }

        switch object.kind {
        case .sofa, .armchair: plain(PlanPalette.fabric)
        case .chair: plain(PlanPalette.chairSeat)
        case .plant: ring(PlanPalette.foliage)
        case .lamp: ring(PlanPalette.amber)
        case .console, .desk, .table, .sideboard, .shelf: plain(PlanPalette.wood)
        case .sideTable: plain(object.shape == .ellipse ? PlanPalette.wood : PlanPalette.paleWood)
        case .coffeeTable, .tvStand: plain(PlanPalette.darkWood)
        case .tv, .device, .radiator: plain(PlanPalette.charcoal)
        case .decor: plain(PlanPalette.taupe.opacity(0.7))
        case .rug:
            layer.fill(outline, with: .color(PlanPalette.rug))
            layer.stroke(outline, with: .color(PlanPalette.rugLine), style: .init(lineWidth: 1, dash: [5, 5]))
        case .door: drawDoor(object, in: rect, on: &layer)
        case .window: drawWindow(in: rect, on: &layer)
        case .speaker: drawSpeaker(object, in: rect, on: &layer)
        case .listener:
            // Un point : c'est de là que partent les distances. Sa taille reste en points, pour se
            // voir sur une pièce entière.
            let side = max(min(rect.width, rect.height) * 0.5, 16)
            let dot = CGRect(x: -side / 2, y: -side / 2, width: side, height: side)
            layer.fill(Path(ellipseIn: dot), with: .color(PlanPalette.listening))
        }
    }

    /// Le vantail ouvert le long du bord bas de l'emprise, le débattement en pointillés. La
    /// charnière est en bas à gauche, en bas à droite une fois inversée.
    private func drawDoor(
        _ object: RoomObject, in rect: CGRect, on layer: inout GraphicsContext
    ) {
        let side = object.isMirrored ? -1.0 : 1.0
        let hinge = CGPoint(x: -side * rect.width / 2, y: rect.maxY)

        var swing = Path()
        for step in 0...32 {
            let angle = Double(step) / 32 * .pi / 2
            let point = CGPoint(
                x: hinge.x + side * sin(angle) * rect.width, y: hinge.y - cos(angle) * rect.height
            )
            if step == 0 { swing.move(to: point) } else { swing.addLine(to: point) }
        }
        layer.stroke(
            swing, with: .color(PlanPalette.outline.opacity(0.65)),
            style: .init(lineWidth: 1.25, dash: [6, 5])
        )
        var leaf = Path()
        leaf.move(to: hinge)
        leaf.addLine(to: CGPoint(x: hinge.x + side * rect.width, y: hinge.y))
        layer.stroke(
            leaf, with: .color(PlanPalette.outline),
            style: .init(lineWidth: max(0.025 * scale, 2), lineCap: .round)
        )
    }

    /// Une percée dans le mur et ses deux vantaux coulissants, décalés l'un de l'autre.
    private func drawWindow(in rect: CGRect, on layer: inout GraphicsContext) {
        // Un trait de verre dans l'axe de la fenêtre : elle se devine, sans croisée ni dormant.
        let horizontal = rect.width >= rect.height
        var line = Path()
        line.move(to: horizontal ? CGPoint(x: rect.minX, y: rect.midY) : CGPoint(x: rect.midX, y: rect.minY))
        line.addLine(to: horizontal ? CGPoint(x: rect.maxX, y: rect.midY) : CGPoint(x: rect.midX, y: rect.maxY))
        layer.stroke(line, with: .color(PlanPalette.glass), style: .init(lineWidth: 3, lineCap: .round))
    }

    // MARK: - Enceintes

    /// Ce qui distingue les enceintes à l'œil. Le nom est le seul indice commun à une enceinte
    /// tirée de la bibliothèque et à une enceinte du plan chargé ; le protocole ne dirait rien
    /// d'une enceinte pas encore rattachée, qui est justement le cas de la Geneva éteinte.
    private enum SpeakerFamily {
        case geneva, homePod, other

        init(name: String) {
            let name = name.lowercased()
            if name.contains("geneva") || name.contains("aerosphere") {
                self = .geneva
            } else if name.contains("homepod") {
                self = .homePod
            } else {
                self = .other
            }
        }
    }

    /// Ce sont les objets dont tout dépend : ils doivent se trouver sans chercher, quel que soit le
    /// zoom. Le corps reste à l'échelle, pour juger d'un dégagement ; l'accent autour de lui reste
    /// en points, Ø 15 cm ne faisant que dix points sur une pièce entière.
    private func drawSpeaker(_ object: RoomObject, in rect: CGRect, on layer: inout GraphicsContext) {
        drawSpeakerAccent(around: rect, on: &layer)
        // Un disque sombre, cerné : le même pour tous les modèles. L'anneau dit que c'est une enceinte,
        // l'étiquette dit laquelle.
        layer.fill(Path(ellipseIn: rect), with: .color(PlanPalette.touchLight))
        layer.stroke(Path(ellipseIn: rect), with: .color(PlanPalette.touchDark), lineWidth: 1.5)
    }

    /// Un anneau fin et, plus loin, son écho : le son qui part, sans une seule couleur criarde.
    private func drawSpeakerAccent(around rect: CGRect, on layer: inout GraphicsContext) {
        let accent = PlanPalette.speakerAccent
        let ring = rect.insetBy(dx: -Self.speakerRingGap, dy: -Self.speakerRingGap)
        let echo = rect.insetBy(dx: -Self.speakerEchoGap, dy: -Self.speakerEchoGap)
        layer.fill(Path(ellipseIn: echo), with: .color(accent.opacity(0.1)))
        layer.stroke(Path(ellipseIn: echo), with: .color(accent.opacity(0.32)), lineWidth: 0.75)
        layer.stroke(Path(ellipseIn: ring), with: .color(accent), lineWidth: 1.25)
    }

    private static let speakerRingGap = 2.5
    private static let speakerEchoGap = 6.5

    // MARK: - Textes

    private func drawLabels(of object: RoomObject, in context: inout GraphicsContext) {
        let center = transform.toView(object.position)
        let width = object.size.width * scale
        let height = object.size.height * scale
        let isDesignated = selection.contains(.object(object.id)) || hoveredObject == object.id

        // Le nom n'apparaît que sur ce qui mérite d'être nommé à demeure, ou sur l'objet
        // désigné. C'est le principal remède à l'encombrement : sur un plan meublé, une
        // dizaine d'étiquettes permanentes se recouvrent et plus rien ne se lit. Même le mode
        // « toutes les cotes » épargne ce qui n'est qu'un encombrement sur un meuble.
        if case .speaker = object.kind {
            drawSpeakerTag(of: object, center: center, height: height, in: &context)
        }
        let namedOnDemand = showsAllLabels && object.kind != .decor
        let isSpeaker = object.kind.outputID != nil || { if case .speaker = object.kind { true } else { false } }()
        if !isSpeaker, namedOnDemand || isDesignated || hasPermanentName(object, width: width, height: height) {
            drawHaloText(
                Text(object.name.isEmpty ? object.kind.label : object.name)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white),
                at: nameAnchor(of: object, center: center, height: height),
                in: &context
            )
        }
        // La hauteur ne sert qu'au moment où on la règle : à la demande uniquement. Le mode
        // « toutes les cotes » se limite à celles qui entrent dans un calcul.
        let isInCalculation = object.kind.outputID != nil || object.kind == .listener
        if isDesignated && !object.kind.hasNoAcousticHeight || showsAllLabels && isInCalculation {
            drawHaloText(
                Text(String(format: "%.2f m", object.elevation))
                    .font(.system(size: 9)).foregroundStyle(.white.opacity(0.8)),
                at: CGPoint(x: center.x, y: center.y + height / 2 + 8),
                in: &context
            )
        }
    }

    /// Seuls les lieux d'écoute nommés gardent leur nom à demeure : c'est ce qui les distingue. Les
    /// enceintes ont leur étiquette, les meubles se nomment au survol ou à la sélection.
    private func hasPermanentName(_ object: RoomObject, width: Double, height: Double) -> Bool {
        object.kind == .listener && !object.name.isEmpty
    }

    /// L'étiquette d'une enceinte : son nom, et son volume si elle est dans la diffusion, dans une
    /// pastille sous son anneau.
    private func drawSpeakerTag(
        of object: RoomObject, center: CGPoint, height: Double, in context: inout GraphicsContext
    ) {
        let name = object.name.isEmpty ? object.kind.label : object.name
        var label = Text(name).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
        if let id = object.kind.outputID, let caption = speakerCaptions[id] {
            label = label + Text("  \(caption)")
                .font(.system(size: 11).monospacedDigit()).foregroundStyle(.white.opacity(0.62))
        }
        let resolved = context.resolve(label)
        let size = resolved.measure(in: CGSize(width: 240, height: 40))
        let tag = CGRect(
            x: center.x - size.width / 2 - 9, y: center.y + height / 2 + Self.speakerEchoGap + 6,
            width: size.width + 18, height: size.height + 8
        )
        let capsule = Path(roundedRect: tag, cornerRadius: tag.height / 2)
        context.fill(capsule, with: .color(.black.opacity(0.55)))
        context.stroke(capsule, with: .color(.white.opacity(0.16)), lineWidth: 0.75)
        context.draw(resolved, at: CGPoint(x: tag.midX, y: tag.midY))
    }

    private func nameAnchor(of object: RoomObject, center: CGPoint, height: Double) -> CGPoint {
        func rotated(_ offset: CGPoint) -> CGPoint {
            let angle = object.rotation * .pi / 180
            return CGPoint(
                x: center.x + (offset.x * cos(angle) - offset.y * sin(angle)) * scale,
                y: center.y + (offset.x * sin(angle) + offset.y * cos(angle)) * scale
            )
        }
        switch object.kind {
        case .rug:
            // Le centre d'un tapis est presque toujours sous un meuble.
            return rotated(CGPoint(x: 0, y: -object.size.height / 2 + 0.14))
        case .lamp:
            return CGPoint(x: center.x, y: center.y + height / 2 + 10)
        case .speaker:
            // Sous l'accent : le nom d'une enceinte ne doit pas masquer ce qu'elle désigne. Sauf sur
            // la sphère, assez grande pour le porter comme le font les autres meubles ronds : posé
            // dessous, il tomberait sur le fauteuil voisin dès que le plan se resserre.
            return SpeakerFamily(name: object.name) == .geneva
                ? center : CGPoint(x: center.x, y: center.y + height / 2 + Self.speakerEchoGap + 9)
        case .listener:
            // Sous le point, pas dessus.
            return CGPoint(x: center.x, y: center.y + 22)
        default:
            // Le centre d'un canapé d'angle tombe dans le vide de l'angle : le modèle sait où
            // se trouve sa partie assez large pour porter un texte.
            return rotated(object.iconOffset)
        }
    }

    /// Un texte qui reste lisible sur toutes les matières, du tissu clair au sol sombre.
    private func drawHaloText(
        _ text: Text, at point: CGPoint, in context: inout GraphicsContext
    ) {
        context.drawLayer { layer in
            layer.addFilter(.shadow(color: .black.opacity(0.95), radius: 1.5))
            layer.addFilter(.shadow(color: .black.opacity(0.75), radius: 2.5))
            layer.draw(text, at: point)
        }
    }
}
