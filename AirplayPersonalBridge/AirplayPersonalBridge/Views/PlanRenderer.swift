//
//  PlanRenderer.swift
//  AirplayPersonalBridge
//

import AppKit
import SwiftUI

/// Les matières du plan, prélevées sur le plan d'origine de Baptiste.
///
/// Elles complètent le thème sans le remplacer : ce que `Theme` décrit (fond, grille, états)
/// reste à lui. Du bois reste du bois en mode clair comme en mode sombre, d'où des couleurs
/// fixes ; seuls le mur, le tapis et le contour, qui se détachent du fond, changent avec lui.
enum PlanPalette {
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
    static let geneva = fixed(0x7FC241)
    static let homePod = fixed(0xFFF23A)

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
    var backgroundImage: NSImage?

    private var scale: Double { transform.scale }

    func draw(in context: inout GraphicsContext, size: CGSize) {
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
                    Path(rect), with: .color(Theme.info),
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

    private func drawGrid(_ context: inout GraphicsContext, size: CGSize) {
        // Graduation au mètre : c'est l'unité dans laquelle on raisonne, et elle donne
        // l'échelle sans avoir à écrire de cote partout. En dessous de 25 px/m elle
        // deviendrait un aplat, donc on l'espace.
        let step: Double = scale < 25 ? 5 : 1
        var path = Path()
        let topLeft = transform.toModel(.zero)
        let bottomRight = transform.toModel(CGPoint(x: size.width, y: size.height))
        var x = (topLeft.x / step).rounded(.down) * step
        while x <= bottomRight.x {
            let viewX = transform.toView(CGPoint(x: x, y: 0)).x
            path.move(to: CGPoint(x: viewX, y: 0))
            path.addLine(to: CGPoint(x: viewX, y: size.height))
            x += step
        }
        var y = (topLeft.y / step).rounded(.down) * step
        while y <= bottomRight.y {
            let viewY = transform.toView(CGPoint(x: 0, y: y)).y
            path.move(to: CGPoint(x: 0, y: viewY))
            path.addLine(to: CGPoint(x: size.width, y: viewY))
            y += step
        }
        context.stroke(path, with: .color(Theme.border.opacity(0.7)), lineWidth: 1)
    }

    // MARK: - Murs

    private func drawWalls(_ context: inout GraphicsContext) {
        // Les corps de mur ordinaires sont remplis d'un seul tenant : remplis un par un, deux
        // onglets voisins laisseraient voir un fil d'antialiasing à chaque angle.
        var bodies = Path()
        for wall in layout.walls where !selection.contains(.wall(wall.id)) {
            addPolygon(layout.wallBody(wall), to: &bodies)
        }
        context.fill(bodies, with: .color(PlanPalette.wall))

        for wall in layout.walls {
            let isSelected = selection.contains(.wall(wall.id))
            let body = layout.wallBody(wall)
            if body.isEmpty {
                var line = Path()
                line.move(to: transform.toView(wall.a))
                line.addLine(to: transform.toView(wall.b))
                context.stroke(
                    line,
                    with: .color(isSelected ? Theme.info : PlanPalette.wall),
                    style: .init(lineWidth: isSelected ? 8 : 6, lineCap: .round)
                )
            } else if isSelected {
                var selected = Path()
                addPolygon(body, to: &selected)
                context.fill(selected, with: .color(Theme.info))
            }
            if wall.paint == .sage { drawPaint(of: wall, in: &context) }
        }
    }

    /// La peinture se voit en liseré sur la face intérieure, par-dessus ce qui y est adossé.
    private func drawPaint(of wall: RoomLayout.WallSegment, in context: inout GraphicsContext) {
        let depth = 0.045
        let normal = wall.outerNormal
        let strip = [
            wall.a, wall.b,
            CGPoint(x: wall.b.x - normal.x * depth, y: wall.b.y - normal.y * depth),
            CGPoint(x: wall.a.x - normal.x * depth, y: wall.a.y - normal.y * depth),
        ]
        var path = Path()
        addPolygon(strip, to: &path)
        context.fill(path, with: .color(PlanPalette.sage))
    }

    private func addPolygon(_ points: [CGPoint], to path: inout Path) {
        guard let first = points.first else { return }
        path.move(to: transform.toView(first))
        for point in points.dropFirst() { path.addLine(to: transform.toView(point)) }
        path.closeSubpath()
    }

    private func drawWallLabels(_ context: inout GraphicsContext) {
        for wall in layout.walls {
            let isSelected = selection.contains(.wall(wall.id))
            // Les cotes de mur ne s'affichent qu'à la sélection ou une fois assez zoomé :
            // sur une pièce entière tenant dans la fenêtre, elles se chevauchaient toutes.
            guard showsAllLabels || isSelected || scale >= 45 else { continue }
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
                    .foregroundStyle(isSelected ? Theme.info : Theme.mutedForeground),
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
            context.fill(circle, with: .color(isHovered ? Theme.info : Theme.background))
            context.stroke(
                circle, with: .color(isHovered ? Theme.info : Theme.foreground.opacity(0.55)),
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
                    line, with: .color(Theme.warning.opacity(0.55)),
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
                    Text(label).font(Theme.Font.tiny).foregroundStyle(Theme.warning),
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
                        .font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.warning),
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

        context.drawLayer { layer in
            layer.translateBy(x: center.x, y: center.y)
            layer.rotate(by: .degrees(object.rotation))
            drawMaterial(of: object, in: rect, outline: outline, on: &layer)

            if isSelected {
                layer.stroke(outline, with: .color(Theme.info), lineWidth: 2.5)
            }
            // Le trait sur un bord marque l'avant du meuble : sans repère d'orientation, faire
            // tourner un canapé ne se voit pas. Seulement sur l'objet qu'on manipule : à
            // demeure, il n'aide personne et brouille la lecture des matières.
            if isDesignated, !object.isRound, !object.kind.hasNoAcousticHeight {
                var front = Path()
                front.move(to: CGPoint(x: -width / 2, y: -height / 2))
                front.addLine(to: CGPoint(x: width / 2, y: -height / 2))
                layer.stroke(front, with: .color(Theme.info), lineWidth: 2.5)
            }
        }
        if object.kind == .listener {
            drawListenerFigure(&context, at: center, rotation: object.rotation)
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

    private func drawMaterial(
        of object: RoomObject, in rect: CGRect, outline: Path, on layer: inout GraphicsContext
    ) {
        func plain(_ color: Color) {
            layer.fill(outline, with: .color(color))
            layer.stroke(outline, with: .color(PlanPalette.outline), lineWidth: 1)
        }

        switch object.kind {
        case .sofa: drawSofa(object, in: rect, outline: outline, on: &layer)
        case .armchair: drawArmchair(in: rect, outline: outline, on: &layer)
        case .chair: drawChair(object, in: rect, outline: outline, on: &layer)
        case .plant: drawPlant(in: rect, on: &layer)
        case .lamp: drawLamp(in: rect, on: &layer)
        case .console, .desk:
            plain(PlanPalette.wood)
        case .table:
            plain(PlanPalette.wood)
            if object.shape == .ellipse { drawTableBase(in: rect, on: &layer) }
        case .sideTable:
            plain(object.shape == .ellipse ? PlanPalette.wood : PlanPalette.paleWood)
            if object.shape == .ellipse { drawInnerRing(of: rect, on: &layer) }
        case .coffeeTable:
            plain(PlanPalette.darkWood)
            if object.shape == .ellipse { drawInnerRing(of: rect, on: &layer) }
        case .tvStand:
            plain(PlanPalette.darkWood)
        case .sideboard:
            plain(PlanPalette.wood)
            drawSideboardFront(in: rect, on: &layer)
        case .tv: drawTV(in: rect, on: &layer)
        case .shelf: drawShelf(in: rect, outline: outline, on: &layer)
        case .decor: drawDecor(object, in: rect, outline: outline, on: &layer)
        case .rug: drawRug(in: rect, on: &layer)
        case .door: drawDoor(object, in: rect, on: &layer)
        case .window: drawWindow(in: rect, on: &layer)
        case .radiator: drawRadiator(in: rect, on: &layer)
        case .device:
            layer.fill(outline, with: .color(PlanPalette.charcoal))
            layer.stroke(outline, with: .color(PlanPalette.outline.opacity(0.6)), lineWidth: 1)
        case .speaker: drawSpeaker(object, in: rect, on: &layer)
        case .listener:
            layer.fill(outline, with: .color(Theme.warning.opacity(0.22)))
            layer.stroke(outline, with: .color(Theme.warning.opacity(0.6)), lineWidth: 1)
        }
    }

    /// Dossier le long du bord avant, accoudoir à l'opposé du retour, coussins séparés.
    private func drawSofa(
        _ object: RoomObject, in rect: CGRect, outline: Path, on layer: inout GraphicsContext
    ) {
        layer.fill(outline, with: .color(PlanPalette.fabric))
        let back = 0.20 * scale
        let arm = 0.20 * scale
        var shade = Path(CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: back))
        var seams = Path()

        func seam(atX x: Double, bottom: Double) {
            seams.move(to: CGPoint(x: x, y: rect.minY + back))
            seams.addLine(to: CGPoint(x: x, y: bottom))
        }

        if object.shape == .lShape {
            let thickness = min(max(object.armThickness, 0.05), min(object.size.width, object.size.height))
                * scale
            let bottom = rect.minY + thickness
            let seatsStart = object.isMirrored ? rect.minX + arm : rect.minX + thickness
            let seatsEnd = object.isMirrored ? rect.maxX - thickness : rect.maxX - arm
            shade.addRect(
                CGRect(
                    x: object.isMirrored ? rect.minX : rect.maxX - arm, y: rect.minY + back,
                    width: arm, height: thickness - back
                )
            )
            seam(atX: (seatsStart + seatsEnd) / 2, bottom: bottom)
            seam(atX: object.isMirrored ? seatsEnd : seatsStart, bottom: bottom)
            seam(atX: object.isMirrored ? seatsStart : seatsEnd, bottom: bottom)
        } else {
            shade.addRect(CGRect(x: rect.minX, y: rect.minY, width: arm, height: rect.height))
            shade.addRect(CGRect(x: rect.maxX - arm, y: rect.minY, width: arm, height: rect.height))
            let seats = rect.width - arm * 2
            let count = max(Int((seats / (0.75 * scale)).rounded()), 1)
            for index in 0...count {
                seam(atX: rect.minX + arm + seats * Double(index) / Double(count), bottom: rect.maxY)
            }
        }

        var clipped = layer
        clipped.clip(to: outline)
        clipped.fill(shade, with: .color(PlanPalette.fabricShade))
        clipped.stroke(seams, with: .color(PlanPalette.glass.opacity(0.7)), lineWidth: 1)
        layer.stroke(outline, with: .color(PlanPalette.outline), lineWidth: 1)
    }

    /// Le coussin est décalé vers l'avant : le dossier, sur le bord avant du repère comme pour
    /// toutes les assises, est plus épais que le reste du corps.
    private func drawArmchair(in rect: CGRect, outline: Path, on layer: inout GraphicsContext) {
        layer.fill(outline, with: .color(PlanPalette.charcoal))
        layer.stroke(outline, with: .color(PlanPalette.outline.opacity(0.55)), lineWidth: 1)
        let cushion = rect.insetBy(dx: rect.width * 0.20, dy: rect.height * 0.20)
            .offsetBy(dx: 0, dy: rect.height * 0.075)
        let path = Path(roundedRect: cushion, cornerRadius: cushion.width * 0.22)
        layer.fill(path, with: .color(PlanPalette.fabric))
        layer.stroke(path, with: .color(PlanPalette.glass.opacity(0.8)), lineWidth: 1)
    }

    /// Une assise et un dossier sombre sur le bord avant. Ronde (chaise de bureau), elle a un
    /// dossier en arc : c'est lui, là encore, qui donne le sens.
    private func drawChair(
        _ object: RoomObject, in rect: CGRect, outline: Path, on layer: inout GraphicsContext
    ) {
        if object.shape == .ellipse {
            layer.fill(outline, with: .color(PlanPalette.fabric))
            layer.stroke(outline, with: .color(PlanPalette.outline), lineWidth: 1)
            let radius = rect.width / 2 + 0.015 * scale
            var arc = Path()
            for step in 0...24 {
                let angle = (-132 + 84 * Double(step) / 24) * .pi / 180
                let point = CGPoint(x: cos(angle) * radius, y: sin(angle) * radius)
                if step == 0 { arc.move(to: point) } else { arc.addLine(to: point) }
            }
            layer.stroke(
                arc, with: .color(PlanPalette.charcoal),
                style: .init(lineWidth: max(0.045 * scale, 2), lineCap: .round)
            )
            return
        }
        let backDepth = min(0.07 * scale, rect.height * 0.3)
        let seat = CGRect(
            x: rect.minX, y: rect.minY + backDepth, width: rect.width,
            height: rect.height - backDepth
        )
        let seatPath = Path(roundedRect: seat, cornerRadius: min(0.05 * scale, seat.width / 3))
        let backPath = Path(
            roundedRect: CGRect(
                x: rect.minX - 0.005 * scale, y: rect.minY, width: rect.width + 0.01 * scale,
                height: backDepth
            ),
            cornerRadius: min(0.02 * scale, backDepth / 2)
        )
        layer.fill(backPath, with: .color(PlanPalette.charcoal))
        layer.stroke(backPath, with: .color(PlanPalette.outline.opacity(0.55)), lineWidth: 1)
        layer.fill(seatPath, with: .color(PlanPalette.chairSeat))
        layer.stroke(seatPath, with: .color(PlanPalette.outline), lineWidth: 1)
    }

    /// Le feuillage reste translucide et en pointillés : il passe au-dessus des meubles
    /// voisins sans les masquer, ce qui est exactement ce qu'il fait dans la pièce.
    private func drawPlant(in rect: CGRect, on layer: inout GraphicsContext) {
        let radius = rect.width / 2
        let crown = Path(ellipseIn: rect)
        layer.fill(crown, with: .color(PlanPalette.foliage.opacity(0.24)))
        layer.stroke(
            crown, with: .color(PlanPalette.foliage),
            style: .init(lineWidth: 1.5, dash: [4, 4])
        )
        let potRadius = radius * RoomObject.plantPotRatio
        var branches = Path()
        let spread: [(angle: Double, reach: Double)] = [
            (-118, 0.92), (-82, 0.72), (-32, 0.86), (18, 0.84), (72, 0.74), (122, 0.92), (176, 0.78),
        ]
        for branch in spread {
            let angle = branch.angle * .pi / 180
            branches.move(to: CGPoint(x: cos(angle) * potRadius, y: sin(angle) * potRadius))
            branches.addLine(
                to: CGPoint(x: cos(angle) * radius * branch.reach, y: sin(angle) * radius * branch.reach)
            )
        }
        layer.stroke(branches, with: .color(PlanPalette.foliage), lineWidth: 1.5)
        let pot = Path(
            ellipseIn: CGRect(
                x: -potRadius, y: -potRadius, width: potRadius * 2, height: potRadius * 2
            )
        )
        layer.fill(pot, with: .color(PlanPalette.charcoal))
        layer.stroke(pot, with: .color(PlanPalette.amber), lineWidth: max(0.02 * scale, 2))
    }

    /// Le socle vu du dessus. Une petite lampe posée se réduit à un disque et un point : un
    /// anneau de plus ne serait plus lisible à cette taille.
    private func drawLamp(in rect: CGRect, on layer: inout GraphicsContext) {
        let radius = rect.width / 2
        let dot = max(radius * 0.16, 2)
        let center = Path(ellipseIn: CGRect(x: -dot, y: -dot, width: dot * 2, height: dot * 2))
        if rect.width < 0.3 * scale {
            let disc = Path(ellipseIn: rect)
            layer.fill(disc, with: .color(PlanPalette.charcoal))
            layer.stroke(disc, with: .color(PlanPalette.glass), lineWidth: 1)
            layer.fill(center, with: .color(PlanPalette.amber))
            return
        }
        layer.stroke(
            Path(ellipseIn: rect), with: .color(PlanPalette.outline.opacity(0.6)), lineWidth: 1
        )
        let shade = Path(ellipseIn: rect.insetBy(dx: radius * 0.19, dy: radius * 0.19))
        layer.fill(shade, with: .color(PlanPalette.charcoal))
        layer.stroke(shade, with: .color(PlanPalette.amber), lineWidth: max(0.02 * scale, 2))
        layer.fill(center, with: .color(PlanPalette.amber))
    }

    /// Le piétement en étoile d'une table ronde, en filigrane sous le plateau.
    private func drawTableBase(in rect: CGRect, on layer: inout GraphicsContext) {
        var star = Path()
        for degrees in [0.0, 45.0, 135.0] {
            let angle = degrees * .pi / 180
            let reach = rect.width / 2 * (degrees == 0 ? 0.92 : 0.58)
            star.move(to: CGPoint(x: -cos(angle) * reach, y: -sin(angle) * reach))
            star.addLine(to: CGPoint(x: cos(angle) * reach, y: sin(angle) * reach))
        }
        layer.stroke(star, with: .color(PlanPalette.outline.opacity(0.35)), lineWidth: 1)
    }

    private func drawInnerRing(of rect: CGRect, on layer: inout GraphicsContext) {
        layer.stroke(
            Path(ellipseIn: rect.insetBy(dx: rect.width * 0.09, dy: rect.height * 0.09)),
            with: .color(PlanPalette.outline.opacity(0.4)), lineWidth: 1
        )
    }

    /// Les cannelures de la façade, sur le bord avant.
    private func drawSideboardFront(in rect: CGRect, on layer: inout GraphicsContext) {
        var ticks = Path()
        let spacing = 0.073 * scale
        var x = rect.minX + spacing
        while x < rect.maxX - spacing / 2 {
            ticks.move(to: CGPoint(x: x, y: rect.minY + 0.015 * scale))
            ticks.addLine(to: CGPoint(x: x, y: rect.minY + 0.10 * scale))
            x += spacing
        }
        layer.stroke(ticks, with: .color(PlanPalette.outline.opacity(0.5)), lineWidth: 1)
    }

    private func drawTV(in rect: CGRect, on layer: inout GraphicsContext) {
        var shape = Path(rect)
        // Les deux pieds, seuls à dépasser de la dalle vue du dessus.
        for side in [-1.0, 1.0] {
            shape.addRect(
                CGRect(
                    x: side * rect.width * 0.36 - 0.02 * scale, y: rect.minY - 0.05 * scale,
                    width: 0.04 * scale, height: rect.height + 0.07 * scale
                )
            )
        }
        layer.fill(shape, with: .color(PlanPalette.charcoal))
    }

    private func drawShelf(in rect: CGRect, outline: Path, on layer: inout GraphicsContext) {
        layer.fill(outline, with: .color(PlanPalette.slate))
        let frontDepth = rect.height * 0.22
        layer.fill(
            Path(CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: frontDepth)),
            with: .color(PlanPalette.charcoal)
        )
        var dividers = Path()
        dividers.move(to: CGPoint(x: rect.minX, y: rect.minY + frontDepth))
        dividers.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + frontDepth))
        let count = max(Int((rect.width / (0.27 * scale)).rounded()), 1)
        for index in 1..<max(count, 2) {
            let x = rect.minX + rect.width * Double(index) / Double(count)
            dividers.move(to: CGPoint(x: x, y: rect.minY + frontDepth))
            dividers.addLine(to: CGPoint(x: x, y: rect.maxY))
        }
        layer.stroke(dividers, with: .color(PlanPalette.outline.opacity(0.6)), lineWidth: 1)
        layer.stroke(outline, with: .color(PlanPalette.outline.opacity(0.6)), lineWidth: 1)
    }

    /// Un objet assez grand pour avoir une matière (un pouf) en a une ; le reste n'est qu'un
    /// encombrement sur un meuble, et reste discret.
    private func drawDecor(
        _ object: RoomObject, in rect: CGRect, outline: Path, on layer: inout GraphicsContext
    ) {
        if object.shape == .rectangle, min(object.size.width, object.size.height) >= 0.25 {
            layer.fill(outline, with: .color(PlanPalette.taupe))
            layer.stroke(outline, with: .color(PlanPalette.outline), lineWidth: 1.5)
            let hollow = Path(ellipseIn: rect.insetBy(dx: rect.width * 0.23, dy: rect.height * 0.24))
            layer.fill(hollow, with: .color(PlanPalette.taupeShade))
            return
        }
        layer.fill(outline, with: .color(PlanPalette.charcoal))
        layer.stroke(outline, with: .color(PlanPalette.outline.opacity(0.55)), lineWidth: 1)
    }

    /// Le tapis : un aplat, une bordure en pointillés et un motif de bandes. Ces traits restent
    /// très discrets : il passe sous tout le reste et ne doit jamais attirer l'œil.
    private func drawRug(in rect: CGRect, on layer: inout GraphicsContext) {
        let shape = Path(rect)
        layer.fill(shape, with: .color(PlanPalette.rug))
        layer.stroke(shape, with: .color(PlanPalette.rugLine), lineWidth: 1)

        let inset = 0.07 * scale
        layer.stroke(
            Path(rect.insetBy(dx: inset, dy: inset)), with: .color(PlanPalette.rugLine),
            style: .init(lineWidth: 1, dash: [5, 5])
        )

        // Le motif est symétrique : des bandes, dont les deux plus éloignées du centre se
        // rejoignent en courbe au milieu de chaque rive.
        var stripes = Path()
        let margin = 0.18 * scale
        func y(_ fraction: Double) -> Double { rect.minY + fraction * rect.height }
        for fraction in [0.31, 0.375, 0.44, 0.56, 0.625, 0.69] {
            stripes.move(to: CGPoint(x: rect.minX + margin, y: y(fraction)))
            stripes.addLine(to: CGPoint(x: rect.maxX - margin, y: y(fraction)))
        }
        for (outer, meet) in [(0.18, 0.31), (0.245, 0.31), (0.82, 0.69), (0.755, 0.69)] {
            let spread = (outer == 0.18 || outer == 0.82) ? 0.11 : 0.17
            for side in [-1.0, 1.0] {
                let start = side * rect.width * 0.5 - side * margin
                let turn = side * rect.width * spread
                stripes.move(to: CGPoint(x: start, y: y(outer)))
                stripes.addLine(to: CGPoint(x: turn, y: y(outer)))
                stripes.addQuadCurve(
                    to: CGPoint(x: 0, y: y(meet)),
                    control: CGPoint(x: turn * 0.35, y: y(outer))
                )
            }
        }
        layer.stroke(stripes, with: .color(PlanPalette.rugLine), lineWidth: 1)
    }

    /// Le vantail ouvert le long du bord bas de l'emprise, le débattement en pointillés. La
    /// charnière est en bas à gauche, en bas à droite une fois inversée.
    private func drawDoor(
        _ object: RoomObject, in rect: CGRect, on layer: inout GraphicsContext
    ) {
        let side = object.isMirrored ? -1.0 : 1.0
        let hinge = CGPoint(x: -side * rect.width / 2, y: rect.maxY)

        // Le dormant : là où un mur épais s'arrête à la charnière, son épaisseur fait le tour
        // de l'angle. Sans lui, l'ouverture paraît mordre dans le coin de la pièce.
        let angle = object.rotation * .pi / 180
        let hingeInRoom = CGPoint(
            x: object.position.x + (hinge.x * cos(angle) - hinge.y * sin(angle)) / scale,
            y: object.position.y + (hinge.x * sin(angle) + hinge.y * cos(angle)) / scale
        )
        let frame = layout.walls.first { wall in
            wall.thickness > 0 && [wall.a, wall.b].contains {
                hypot($0.x - hingeInRoom.x, $0.y - hingeInRoom.y) < 0.002
            }
        }?.thickness
        if let frame {
            let depth = frame * scale
            layer.fill(
                Path(
                    CGRect(
                        x: side > 0 ? hinge.x - depth : hinge.x, y: hinge.y,
                        width: depth, height: depth
                    )
                ),
                with: .color(PlanPalette.wall)
            )
        }

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
        layer.fill(Path(rect), with: .color(Theme.background))
        layer.stroke(Path(rect), with: .color(PlanPalette.outline), lineWidth: 1)
        let paneHeight = max(rect.height * 0.2, 1.5)
        let panes = [
            CGRect(
                x: rect.minX + rect.width * 0.01, y: rect.minY + rect.height * 0.3 - paneHeight / 2,
                width: rect.width * 0.54, height: paneHeight
            ),
            CGRect(
                x: rect.minX + rect.width * 0.45, y: rect.minY + rect.height * 0.7 - paneHeight / 2,
                width: rect.width * 0.54, height: paneHeight
            ),
        ]
        for pane in panes {
            layer.fill(Path(pane), with: .color(PlanPalette.glass))
            layer.stroke(Path(pane), with: .color(PlanPalette.outline), lineWidth: 0.75)
        }
    }

    private func drawRadiator(in rect: CGRect, on layer: inout GraphicsContext) {
        layer.fill(Path(rect), with: .color(Theme.background))
        var hatch = Path()
        let spacing = 0.06 * scale
        var x = rect.minX - rect.height
        while x < rect.maxX {
            hatch.move(to: CGPoint(x: x, y: rect.maxY))
            hatch.addLine(to: CGPoint(x: x + rect.height, y: rect.minY))
            x += spacing
        }
        var clipped = layer
        clipped.clip(to: Path(rect))
        clipped.stroke(hatch, with: .color(PlanPalette.outline.opacity(0.75)), lineWidth: 1)
        layer.stroke(Path(rect), with: .color(PlanPalette.outline), lineWidth: 1)
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

    /// Ce sont les trois objets dont tout dépend : ils doivent se trouver sans chercher, quel
    /// que soit le zoom. Le disque reste à l'échelle pour juger d'un dégagement ; la croix des
    /// HomePod, elle, ne descend pas sous une taille lisible, Ø 15 cm ne faisant que dix
    /// points sur une pièce entière.
    private func drawSpeaker(_ object: RoomObject, in rect: CGRect, on layer: inout GraphicsContext) {
        let disc = Path(ellipseIn: rect)
        switch SpeakerFamily(name: object.name) {
        case .geneva:
            layer.fill(disc, with: .color(PlanPalette.geneva))
            layer.stroke(disc, with: .color(.black.opacity(0.45)), lineWidth: 1.5)
            layer.stroke(
                Path(ellipseIn: rect.insetBy(dx: rect.width * 0.3, dy: rect.height * 0.3)),
                with: .color(.black.opacity(0.3)), lineWidth: 1.25
            )
        case .homePod:
            layer.fill(disc, with: .color(PlanPalette.charcoal))
            layer.stroke(disc, with: .color(PlanPalette.homePod), lineWidth: 1)
            let reach = max(rect.width * 0.9, 10)
            var cross = Path()
            cross.move(to: CGPoint(x: -reach, y: -reach))
            cross.addLine(to: CGPoint(x: reach, y: reach))
            cross.move(to: CGPoint(x: -reach, y: reach))
            cross.addLine(to: CGPoint(x: reach, y: -reach))
            // Le liseré sombre : le jaune seul se perd sur un plateau de bois clair.
            let width = max(rect.width * 0.34, 4.5)
            layer.stroke(
                cross, with: .color(.black.opacity(0.65)),
                style: .init(lineWidth: width + 2, lineCap: .round)
            )
            layer.stroke(
                cross, with: .color(PlanPalette.homePod),
                style: .init(lineWidth: width, lineCap: .round)
            )
        case .other:
            layer.fill(disc, with: .color(Theme.info.opacity(0.75)))
            layer.stroke(disc, with: .color(Theme.info), lineWidth: 1.5)
        }
    }

    /// La position d'écoute, dessinée **vue de dessus**.
    ///
    /// Le symbole système `figure.seated.side` est une silhouette de profil : posée sur un
    /// plan vu du dessus, elle jure avec tout le reste et ne dit pas où sont les oreilles —
    /// qui sont pourtant le seul point qui compte ici, puisque toutes les distances y
    /// aboutissent. On dessine donc des épaules, une tête, deux oreilles et le regard.
    private func drawListenerFigure(
        _ context: inout GraphicsContext, at point: CGPoint, rotation: Double
    ) {
        // Tailles anthropométriques ramenées à l'échelle du plan, bornées pour rester
        // lisibles quand on dézoome.
        let head = max(7, min(0.18 * scale, 26))
        let shoulders = head * 2.1

        context.drawLayer { layer in
            layer.translateBy(x: point.x, y: point.y)
            layer.rotate(by: .degrees(rotation))

            // Épaules : une ellipse large et peu profonde, qui donne l'orientation.
            layer.fill(
                Path(
                    ellipseIn: CGRect(
                        x: -shoulders / 2, y: -head * 0.35, width: shoulders, height: head * 1.15
                    )
                ),
                with: .color(Theme.warning.opacity(0.85))
            )

            // Tête.
            let headRect = CGRect(x: -head / 2, y: -head / 2, width: head, height: head)
            layer.fill(Path(ellipseIn: headRect), with: .color(Theme.warning))
            layer.stroke(
                Path(ellipseIn: headRect), with: .color(Theme.foreground.opacity(0.55)), lineWidth: 1
            )

            // Les deux oreilles : c'est là qu'arrivent les distances calculées.
            let ear = max(2, head * 0.17)
            for side in [-1.0, 1.0] {
                layer.fill(
                    Path(
                        ellipseIn: CGRect(
                            x: side * head * 0.5 - ear / 2, y: -ear / 2,
                            width: ear, height: ear * 1.6
                        )
                    ),
                    with: .color(Theme.foreground.opacity(0.6))
                )
            }

            // Nez : un petit triangle vers l'avant, qui dit dans quel sens on regarde.
            var nose = Path()
            nose.move(to: CGPoint(x: -head * 0.18, y: -head * 0.45))
            nose.addLine(to: CGPoint(x: 0, y: -head * 0.72))
            nose.addLine(to: CGPoint(x: head * 0.18, y: -head * 0.45))
            nose.closeSubpath()
            layer.fill(nose, with: .color(Theme.warning))
        }
    }

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
        let namedOnDemand = showsAllLabels && object.kind != .decor
        if namedOnDemand || isDesignated || hasPermanentName(object, width: width, height: height) {
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

    private func hasPermanentName(_ object: RoomObject, width: Double, height: Double) -> Bool {
        switch object.kind {
        case .speaker:
            return true
        case .sofa, .armchair, .table, .sideboard, .desk, .tvStand, .rug, .plant:
            return max(width, height) >= 36
        case .lamp:
            return object.size.width >= 0.3 && width >= 18
        default:
            return false
        }
    }

    /// Où poser le nom, dans le repère de l'écran : le texte reste horizontal même quand le
    /// meuble ne l'est pas, le point d'ancrage suit sa rotation.
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
            // Sous la marque : le nom d'une enceinte ne doit pas masquer ce qu'elle désigne.
            let reach = SpeakerFamily(name: object.name) == .homePod
                ? max(object.size.width * scale * 0.9, 10) : object.size.height * scale / 2
            return SpeakerFamily(name: object.name) == .geneva
                ? center : CGPoint(x: center.x, y: center.y + reach + 11)
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
