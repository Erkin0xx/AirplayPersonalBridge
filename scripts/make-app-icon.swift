// Génère l'icône d'app à partir du glyphe de la barre de menus, toutes tailles comprises.
//
// À lancer depuis la racine du dépôt :
//
//   swiftc -parse-as-library scripts/make-app-icon.swift \
//       AirplayPersonalBridge/AirplayPersonalBridge/Views/BridgeGlyph.swift -o /tmp/make-app-icon \
//     && /tmp/make-app-icon
//
// Deux fichiers plutôt que `swift scripts/make-app-icon.swift` : la géométrie vit dans
// `BridgeGlyph.swift`, celui-là même que l'app compile. Une copie collée ici finirait par diverger,
// et l'icône d'app et celle de la barre de menus ne seraient plus le même dessin.
//
// CoreGraphics et ImageIO, rien d'autre : pas d'outil à installer, pas d'image source à conserver.
// Un argument facultatif désigne un autre dossier de sortie, pour essayer sans toucher au dépôt.

import CoreGraphics
import Foundation
import ImageIO

/// La grille des icônes macOS : un corps de 824 sur un canevas de 1024, le reste pour l'ombre.
private enum Grid {
    static let canvas: CGFloat = 1024
    static let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    static let cornerRadius: CGFloat = 185.4
}

private enum Ink {
    // La palette rose, choisie par Baptiste le 2026-11-10 parmi neuf (l'icône était bleu-vert avant).
    static let top = color(0x4A2A40)
    static let bottom = color(0x1A0A14)
    /// La teinte de la lueur : pleine au centre, transparente au bord.
    static let glowHex: UInt32 = 0xFF5FA2
    static let glow = color(glowHex, alpha: 0.38)
    static let pylonTop = color(0xFFFFFF)
    static let pylonBottom = color(0xFFE3EE)
    static let hangerTop = color(0xFFB3D1)
    static let hangerBottom = color(0xFF4F93)

    static func color(_ hex: UInt32, alpha: CGFloat = 1) -> CGColor {
        CGColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha
        )
    }
}

@main
struct MakeAppIcon {
    /// Le nom du fichier et sa taille en pixels, dans l'ordre du `Contents.json`.
    private static let sizes: [(points: Int, scale: Int)] = [
        (16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2),
    ]

    static func main() throws {
        let defaultFolder = "AirplayPersonalBridge/AirplayPersonalBridge/Assets.xcassets/AppIcon.appiconset"
        let folder = URL(
            fileURLWithPath: CommandLine.arguments.dropFirst().first ?? defaultFolder, isDirectory: true
        )
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        var images: [[String: String]] = []
        for size in sizes {
            let name = "icon-\(size.points)@\(size.scale)x.png"
            let image = try render(pixels: size.points * size.scale)
            try writePNG(image, to: folder.appending(path: name))
            images.append([
                "filename": name, "idiom": "mac", "scale": "\(size.scale)x",
                "size": "\(size.points)x\(size.points)",
            ])
        }
        let contents: [String: Any] = [
            "images": images,
            "info": ["author": "xcode", "version": 1],
        ]
        let json = try JSONSerialization.data(
            withJSONObject: contents, options: [.prettyPrinted, .sortedKeys]
        )
        try json.write(to: folder.appending(path: "Contents.json"))
        print("Icône écrite dans \(folder.path)")
    }

    private static func render(pixels: Int) throws -> CGImage {
        guard
            let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
            let context = CGContext(
                data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else { throw IconError.context }

        context.setShouldAntialias(true)
        context.interpolationQuality = .high
        let scale = CGFloat(pixels) / Grid.canvas
        context.scaleBy(x: scale, y: scale)
        // Le repère de l'écran, y vers le bas : c'est celui de la géométrie du glyphe.
        context.translateBy(x: 0, y: Grid.canvas)
        context.scaleBy(x: 1, y: -1)

        // Sous 64 pixels, l'ombre, le reflet et le câble ne seraient plus que du flou : on les
        // retire, et le glyphe grossit pour compenser, comme le font les icônes de Apple.
        let isSmall = pixels <= 64
        drawBody(in: context, isSmall: isSmall)
        drawGlyph(in: context, isSmall: isSmall, pixels: pixels)
        if !isSmall { drawEdge(in: context) }

        guard let image = context.makeImage() else { throw IconError.image }
        return image
    }

    private static func drawBody(in context: CGContext, isSmall: Bool) {
        let body = squircle(Grid.body, radius: Grid.cornerRadius)

        if !isSmall {
            context.saveGState()
            context.setShadow(
                offset: CGSize(width: 0, height: -12), blur: 28,
                color: Ink.color(0x000000, alpha: 0.32)
            )
            context.addPath(body)
            context.setFillColor(Ink.bottom)
            context.fillPath()
            context.restoreGState()
        }

        context.saveGState()
        context.addPath(body)
        context.clip()
        fillVertical(context, in: Grid.body, top: Ink.top, bottom: Ink.bottom)

        // La lueur sous le pont : d'où vient l'impression de profondeur, et le seul endroit où la
        // couleur de l'app s'étale.
        let center = CGPoint(x: Grid.canvas / 2, y: Grid.canvas * 0.60)
        drawRadial(
            context, center: center, radius: 470,
            inner: Ink.glow, outer: Ink.color(Ink.glowHex, alpha: 0)
        )
        context.restoreGState()
    }

    private static func drawGlyph(in context: CGContext, isSmall: Bool, pixels: Int) {
        // Le pas de 32 tombe juste sur la grille de pixels : une barre du glyphe (2 unités) y couvre
        // 1, 2 ou 4 pixels entiers en 16, 32 et 64. À ces tailles, un pixel à cheval se paie en flou.
        let unit: CGFloat = isSmall ? 32 : 27
        var origin = CGPoint(
            x: (Grid.canvas - BridgeGlyph.canvas.width * unit) / 2,
            y: (Grid.canvas - BridgeGlyph.canvas.height * unit) / 2
        )
        // En 16 pixels, le glyphe en fait 10 et ses barres tombent à cheval : on le décale d'un
        // demi-pixel, invisible à cette taille, contrairement au flou.
        if pixels == 16 { origin.x += Grid.canvas / 16 / 2 }
        context.saveGState()
        context.translateBy(x: origin.x, y: origin.y)
        context.scaleBy(x: unit, y: unit)

        let span = CGRect(origin: .zero, size: BridgeGlyph.canvas)

        if !isSmall {
            // Le câble que les suspentes laissent deviner : le pont se révèle à qui a la place de le
            // voir. Trop fin pour la barre de menus, il n'existe que sur la grande icône.
            let cable = CGMutablePath()
            cable.move(to: CGPoint(x: 2, y: 3.4))
            cable.addQuadCurve(to: CGPoint(x: 18, y: 3.4), control: CGPoint(x: 10, y: 11.4))
            context.addPath(cable)
            context.setLineWidth(0.34)
            context.setLineCap(.round)
            context.setStrokeColor(Ink.color(0xFFFFFF, alpha: 0.32))
            context.strokePath()
        }

        func fill(_ path: CGPath, top: CGColor, bottom: CGColor) {
            context.saveGState()
            context.addPath(path)
            context.clip()
            fillVertical(context, in: span.insetBy(dx: 0, dy: 2), top: top, bottom: bottom)
            context.restoreGState()
        }

        // L'ombre portée de l'ensemble, dessinée à part : l'attacher au dégradé la ferait perdre,
        // le découpage effaçant ce qui déborde.
        if !isSmall {
            context.saveGState()
            context.setShadow(
                offset: CGSize(width: 0, height: -10 * context.ctm.d.magnitude / unit), blur: 24,
                color: Ink.color(0x000000, alpha: 0.45)
            )
            context.addPath(BridgeGlyph.marks(.idle))
            context.setFillColor(Ink.pylonBottom)
            context.fillPath()
            context.restoreGState()
        }
        fill(BridgeGlyph.hangers(), top: Ink.hangerTop, bottom: Ink.hangerBottom)
        fill(BridgeGlyph.pylons(), top: Ink.pylonTop, bottom: Ink.pylonBottom)
        context.restoreGState()
    }

    /// Le liseré du verre : une lumière qui vient du haut et s'éteint en descendant, à l'intérieur du
    /// bord. C'est le détail qui fait passer un aplat pour un objet.
    private static func drawEdge(in context: CGContext) {
        let body = squircle(Grid.body, radius: Grid.cornerRadius)
        let lineWidth: CGFloat = 4
        context.saveGState()
        context.addPath(body)
        context.clip()
        context.addPath(body)
        context.setLineWidth(lineWidth * 2)
        context.replacePathWithStrokedPath()
        context.clip()
        fillVertical(
            context, in: Grid.body,
            top: Ink.color(0xFFFFFF, alpha: 0.36), bottom: Ink.color(0xFFFFFF, alpha: 0.05)
        )
        context.restoreGState()

        // Le reflet du haut, très léger : il ne doit pas se voir, seulement manquer s'il disparaissait.
        context.saveGState()
        context.addPath(body)
        context.clip()
        let sheen = CGRect(x: Grid.body.minX, y: Grid.body.minY, width: Grid.body.width, height: 380)
        fillVertical(
            context, in: sheen,
            top: Ink.color(0xFFFFFF, alpha: 0.10), bottom: Ink.color(0xFFFFFF, alpha: 0)
        )
        context.restoreGState()
    }

    private static func fillVertical(
        _ context: CGContext, in rect: CGRect, top: CGColor, bottom: CGColor
    ) {
        guard
            let gradient = CGGradient(
                colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [top, bottom] as CFArray,
                locations: [0, 1]
            )
        else { return }
        context.drawLinearGradient(
            gradient, start: CGPoint(x: rect.midX, y: rect.minY),
            end: CGPoint(x: rect.midX, y: rect.maxY), options: []
        )
    }

    private static func drawRadial(
        _ context: CGContext, center: CGPoint, radius: CGFloat, inner: CGColor, outer: CGColor
    ) {
        guard
            let gradient = CGGradient(
                colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [inner, outer] as CFArray,
                locations: [0, 1]
            )
        else { return }
        context.drawRadialGradient(
            gradient, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius,
            options: []
        )
    }

    /// Le coin continu des icônes d'Apple : un `addRoundedRect` a un arc de cercle, et sa cassure de
    /// courbure se voit à cette taille. Les coefficients sont ceux du tracé de `UIBezierPath`.
    private static func squircle(_ rect: CGRect, radius r: CGFloat) -> CGPath {
        let path = CGMutablePath()
        typealias Offset = (CGFloat, CGFloat)
        func point(_ corner: (x: CGFloat, y: CGFloat), _ sign: (x: CGFloat, y: CGFloat), _ offset: Offset)
            -> CGPoint
        {
            CGPoint(x: corner.x + sign.x * offset.0 * r, y: corner.y + sign.y * offset.1 * r)
        }
        /// Un coin, parcouru du côté `a` vers le côté `b`.
        func addCorner(_ corner: (x: CGFloat, y: CGFloat), _ sign: (x: CGFloat, y: CGFloat), swap: Bool) {
            func p(_ a: CGFloat, _ b: CGFloat) -> CGPoint {
                point(corner, sign, swap ? (b, a) : (a, b))
            }
            path.addLine(to: p(1.52866483, 0))
            path.addCurve(to: p(0.66993427, 0.06549600), control1: p(1.08849323, 0), control2: p(0.86840689, 0))
            path.addLine(to: p(0.63149399, 0.07491100))
            path.addCurve(to: p(0.07491176, 0.63149399), control1: p(0.37282392, 0.16905899), control2: p(0.16906013, 0.37282401))
            path.addCurve(to: p(0, 1.52866483), control1: p(0, 0.86840701), control2: p(0, 1.08849299))
        }
        path.move(to: CGPoint(x: rect.minX + 1.52866483 * r, y: rect.minY))
        addCorner((rect.maxX, rect.minY), (-1, 1), swap: false)
        addCorner((rect.maxX, rect.maxY), (-1, -1), swap: true)
        addCorner((rect.minX, rect.maxY), (1, -1), swap: false)
        addCorner((rect.minX, rect.minY), (1, 1), swap: true)
        path.closeSubpath()
        return path
    }

    private static func writePNG(_ image: CGImage, to url: URL) throws {
        guard
            let destination = CGImageDestinationCreateWithURL(
                url as CFURL, "public.png" as CFString, 1, nil
            )
        else { throw IconError.destination(url.path) }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw IconError.destination(url.path) }
    }

    private enum IconError: Error {
        case context
        case image
        case destination(String)
    }
}
