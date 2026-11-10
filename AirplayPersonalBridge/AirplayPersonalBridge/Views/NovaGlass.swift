//
//  NovaGlass.swift
//  AirplayPersonalBridge
//

import CoreGraphics
import Foundation
import os

/// La matière de la sphère du halo : une bille de verre presque noir, qui ne montre que ses reflets.
///
/// Le vocabulaire vient d'une étude de dégradés de verre sombre (aucune image n'en est reprise, tout est
/// calculé ici) : des nappes lisses qui montent du noir vers une couleur puis vers un cœur clair, allongées
/// le long d'un ruban courbe ; des filets très fins et nets qui longent ces nappes ; un petit éclat chaud ;
/// un liseré de bord. Ce qui n'est pas éclairé est noir.
///
/// Tout est décrit en **rayons de sphère**, centre à l'origine, x vers la droite, y vers le bas. Les
/// fonctions sont pures : elles servent à cuire les textures une fois (`NovaGlassTextures`) et à vérifier,
/// dans les tests, que le logo reste lisible à tout instant.
nonisolated enum NovaGlass {
    /// Une couleur en lumière linéaire, qu'on peut additionner.
    struct RGB: Equatable {
        var red = 0.0
        var green = 0.0
        var blue = 0.0

        static let black = RGB()

        /// Depuis un code sRGB `0xRRGGBB`.
        init(hex: UInt32) {
            red = NovaGlass.decode(Double((hex >> 16) & 0xFF) / 255)
            green = NovaGlass.decode(Double((hex >> 8) & 0xFF) / 255)
            blue = NovaGlass.decode(Double(hex & 0xFF) / 255)
        }

        init(red: Double = 0, green: Double = 0, blue: Double = 0) {
            self.red = red
            self.green = green
            self.blue = blue
        }

        /// La luminance relative, de 0 à 1 pour une couleur affichable.
        var luminance: Double { 0.2126 * red + 0.7152 * green + 0.0722 * blue }

        mutating func add(_ other: RGB, gain: Double) {
            red += other.red * gain
            green += other.green * gain
            blue += other.blue * gain
        }
    }

    static func decode(_ value: Double) -> Double {
        value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }

    static func encode(_ value: Double) -> Double {
        let clamped = min(max(value, 0), 1)
        return clamped <= 0.003_130_8 ? clamped * 12.92 : 1.055 * pow(clamped, 1 / 2.4) - 0.055
    }

    // MARK: - Reflets

    /// Un reflet : une tache gaussienne, étroite en travers du ruban et longue dans son sens.
    struct Streak {
        /// Sa place en travers du ruban, et sa demi-largeur.
        let across: Double
        let width: Double
        /// Sa place le long du ruban, et sa demi-longueur.
        let along: Double
        let length: Double
        let color: RGB
        let gain: Double
    }

    /// Les reflets vont par couches : chacune glisse à son rythme, et c'est ce décalage qui fait le verre.
    enum Layer: Int, CaseIterable {
        /// La nappe rose et son cœur surexposé.
        case sheets
        /// La nappe froide et l'éclat chaud.
        case accents
        /// Les filets.
        case hairlines
    }

    /// L'inclinaison du ruban : il monte vers la gauche.
    static let tilt = -24 * Double.pi / 180
    /// Le sens du ruban, vecteur unité : les couches glissent le long de lui.
    static let along = CGVector(dx: cos(tilt), dy: -sin(tilt))

    /// Le fond de la bille, là où rien ne se reflète.
    static let base = RGB(hex: 0x020207)

    /// La nappe principale passe **sous** le logo et la nappe froide **au-dessus** : le centre reste sombre.
    /// Plus près du centre (0,34 et −0,18), le cœur surexposé passait derrière le glyphe et le noyait.
    static func streaks(of layer: Layer) -> [Streak] {
        switch layer {
        case .sheets:
            [
                Streak(across: 0.64, width: 0.21, along: 0.05, length: 0.75, color: RGB(hex: 0xDF3880), gain: 0.95),
                Streak(across: 0.69, width: 0.062, along: -0.08, length: 0.55, color: RGB(hex: 0xFFD9E8), gain: 0.95),
            ]
        case .accents:
            [
                Streak(across: -0.44, width: 0.17, along: 0.22, length: 0.60, color: RGB(hex: 0x3A65B5), gain: 0.62),
                Streak(across: -0.50, width: 0.045, along: 0.30, length: 0.40, color: RGB(hex: 0xA9C6F2), gain: 0.42),
                Streak(across: -0.69, width: 0.042, along: -0.32, length: 0.30, color: RGB(hex: 0xF0903E), gain: 0.85),
            ]
        case .hairlines:
            [
                Streak(across: 0.84, width: 0.016, along: 0.10, length: 0.62, color: RGB(hex: 0xC5DAE6), gain: 0.90),
                Streak(across: 0.905, width: 0.009, along: 0.00, length: 0.52, color: RGB(hex: 0x6990B7), gain: 0.85),
                Streak(across: 0.40, width: 0.010, along: 0.18, length: 0.55, color: RGB(hex: 0x8A3A78), gain: 0.60),
                Streak(across: -0.27, width: 0.011, along: 0.15, length: 0.50, color: RGB(hex: 0x325682), gain: 0.80),
                Streak(across: -0.80, width: 0.009, along: 0.05, length: 0.45, color: RGB(hex: 0x6990B7), gain: 0.55),
            ]
        }
    }

    /// Le repère du ruban en ce point : `across` en travers, courbé, et `along` dans son sens.
    static func ribbon(x: Double, y: Double) -> (across: Double, along: Double) {
        let flat = x * sin(tilt) + y * cos(tilt)
        let along = x * cos(tilt) - y * sin(tilt)
        return (flat + 0.22 * along * along + 0.10 * sin(2.2 * along + 0.6), along)
    }

    /// Ce que cette couche renvoie en ce point, dans sa pose de repos.
    static func radiance(of layer: Layer, x: Double, y: Double) -> RGB {
        let place = ribbon(x: x, y: y)
        var sum = RGB.black
        for streak in streaks(of: layer) {
            let across = (place.across - streak.across) / streak.width
            let along = (place.along - streak.along) / streak.length
            let exponent = across * across + along * along
            // Au-delà, moins d'un niveau sur 255 : rien à ajouter.
            guard exponent < 12 else { continue }
            sum.add(streak.color, gain: streak.gain * exp(-exponent))
        }
        return sum
    }

    // MARK: - Bord

    /// De combien ce point regarde vers le haut gauche, d'où vient la lumière : 1 en plein haut gauche,
    /// 0 à partir de `reach` (en cosinus) de cette direction.
    private static func upperLeft(x: Double, y: Double, reach: Double) -> Double {
        let distance = (x * x + y * y).squareRoot()
        guard distance > 1e-9 else { return 0 }
        let facing = -(x + y) / (distance * 2.0.squareRoot())
        return min(max((facing - reach) / (1 - reach), 0), 1)
    }

    private static func band(_ value: Double, center: Double, width: Double) -> Double {
        let offset = (value - center) / width
        return exp(-offset * offset)
    }

    /// Le bord de la bille allumée : une teinte violette qui monte vers le contour, et un liseré clair et
    /// fin, tous deux en haut à gauche seulement. Immobile : c'est la lumière de la pièce, pas le reflet.
    static func rim(x: Double, y: Double) -> RGB {
        let distance = (x * x + y * y).squareRoot()
        guard distance < 1.02 else { return .black }
        let depth = (1 - min(distance, 1) * min(distance, 1)).squareRoot()
        let fresnel = pow(1 - depth, 3)
        var sum = RGB.black
        // Tout autour, à peine : la lueur rose de la bille se reprend sur son contour.
        // Sans elle, le tout dernier pixel resterait noir et cernerait la bille d'un trait.
        sum.add(RGB(hex: 0xDF3880), gain: 0.30 * fresnel * (1 - depth) + 0.55 * band(distance, center: 1, width: 0.014))
        sum.add(RGB(hex: 0x7B2CA0), gain: 0.60 * fresnel * upperLeft(x: x, y: y, reach: -0.55))
        let lip = upperLeft(x: x, y: y, reach: 0.25)
        sum.add(RGB(hex: 0xF3F6FA), gain: 1.25 * band(distance, center: 0.986, width: 0.011) * lip * lip)
        return sum
    }

    /// La bille au repos : le même verre, éteint. Un voile gris qui meurt vers le centre et un seul liseré
    /// blanc sur la lèvre, qui s'éteint le long de la courbe.
    static func resting(x: Double, y: Double) -> RGB {
        let distance = (x * x + y * y).squareRoot()
        var sum = RGB(hex: 0x060608)
        guard distance < 1.02 else { return sum }
        let depth = (1 - min(distance, 1) * min(distance, 1)).squareRoot()
        let veil = upperLeft(x: x, y: y, reach: -0.7)
        sum.add(RGB(hex: 0x9A9C9E), gain: 0.34 * pow(1 - depth, 1.15) * veil * veil)
        // Le fantôme de la nappe : on devine où la couleur reviendra.
        let place = ribbon(x: x, y: y)
        let ghost = band(place.across, center: 0.64, width: 0.20) * band(place.along, center: 0.05, length: 0.75)
        sum.add(RGB(hex: 0x8E9094), gain: 0.07 * ghost)
        let lip = upperLeft(x: x, y: y, reach: 0.05)
        sum.add(RGB(hex: 0xF3F6FA), gain: 1.1 * band(distance, center: 0.986, width: 0.010) * lip * lip)
        // Le contour, à peine : la bille éteinte garde son bord sur un fond presque noir.
        sum.add(RGB(hex: 0x9A9C9E), gain: 0.10 * band(distance, center: 1, width: 0.014))
        return sum
    }

    private static func band(_ value: Double, center: Double, length: Double) -> Double {
        band(value, center: center, width: length)
    }

    // MARK: - Lisibilité du logo

    /// Le creux sombre sous le logo : son opacité en ce point, de 0 à `wellDepth`. Une ellipse douce, un
    /// peu plus large que le glyphe.
    static let wellDepth = 0.7
    static let wellRadii = CGSize(width: 0.74, height: 0.64)
    /// La part du rayon du creux où il est à son plein : le logo y tient presque entier.
    static let wellPlateau = 0.35

    static func wellAlpha(x: Double, y: Double) -> Double {
        let distance = ((x / wellRadii.width) * (x / wellRadii.width)
            + (y / wellRadii.height) * (y / wellRadii.height)).squareRoot()
        return wellAlpha(atShare: distance)
    }

    /// Le même creux, en part de son rayon : c'est ce que le dégradé du dessin échantillonne.
    static func wellAlpha(atShare share: Double) -> Double {
        let inside = min(max((1 - share) / (1 - wellPlateau), 0), 1)
        return wellDepth * inside * inside * (3 - 2 * inside)
    }

    /// La demi-étendue du logo sur la sphère, en rayons (`HaloSphere` lui donne 0,364 × 0,328 diamètre).
    static let glyphHalfSize = CGSize(width: 0.364, height: 0.328)

    /// La luminance du verre **derrière** ce point à cet instant, telle que la sphère la compose : les
    /// couches additionnées dans leurs poses, le bord, puis le creux. `veil` est l'opacité des couches
    /// (1 quand un son part).
    static func backdropLuminance(x: Double, y: Double, time: TimeInterval, veil: Double = 1) -> Double {
        var red = encode(base.red)
        var green = encode(base.green)
        var blue = encode(base.blue)
        let point = CGPoint(x: x, y: y)
        for layer in Layer.allCases {
            let pose = NovaGlassMotion.pose(of: layer, at: time)
            let local = point.applying(NovaGlassMotion.transform(for: pose).inverted())
            let light = radiance(of: layer, x: Double(local.x), y: Double(local.y))
            red += veil * encode(light.red)
            green += veil * encode(light.green)
            blue += veil * encode(light.blue)
        }
        let edge = rim(x: x, y: y)
        red += encode(edge.red)
        green += encode(edge.green)
        blue += encode(edge.blue)
        let kept = 1 - wellAlpha(x: x, y: y)
        return RGB(
            red: decode(min(red, 1) * kept), green: decode(min(green, 1) * kept),
            blue: decode(min(blue, 1) * kept)
        ).luminance
    }
}

/// Le mouvement des reflets : lent, borné, et qui revient exactement à son point de départ.
nonisolated enum NovaGlassMotion {
    /// Un cycle complet. Tout y est en harmoniques entières : une période plus tard, la même image.
    static let period: TimeInterval = 50
    /// De combien une couche pivote au plus autour du centre, en radians.
    static let maxAngle = 6 * Double.pi / 180
    /// De combien elle glisse au plus le long du ruban, en rayons.
    static let maxSlide = 0.10

    struct Pose: Equatable {
        var angle: Double
        var slide: Double
    }

    /// La phase du cycle, dans `0..<2π`.
    static func phase(at time: TimeInterval) -> Double {
        let turns = time / period
        return 2 * Double.pi * (turns - turns.rounded(.down))
    }

    /// La pose de cette couche à cet instant. À l'instant 0 la nappe principale est à sa place de dessin.
    static func pose(of layer: NovaGlass.Layer, at time: TimeInterval) -> Pose {
        let phase = phase(at: time)
        switch layer {
        case .sheets:
            return Pose(angle: maxAngle * sin(phase), slide: maxSlide * sin(2 * phase))
        case .accents:
            return Pose(angle: -0.75 * maxAngle * sin(phase + 1.1), slide: -maxSlide * sin(phase + 0.5))
        case .hairlines:
            return Pose(angle: 0.6 * maxAngle * sin(2 * phase + 2.3), slide: 0.8 * maxSlide * sin(phase + 3.6))
        }
    }

    /// Du repère de repos de la couche à celui de la sphère, en rayons : glisser le long du ruban, puis
    /// pivoter autour du centre. Le dessin et le calcul de lisibilité passent tous deux par ici.
    static func transform(for pose: Pose) -> CGAffineTransform {
        CGAffineTransform(rotationAngle: pose.angle)
            .translatedBy(x: pose.slide * NovaGlass.along.dx, y: pose.slide * NovaGlass.along.dy)
    }
}

/// Les textures de la sphère, cuites une fois : la recette exacte, filets compris, qu'aucun dégradé
/// vectoriel ne rend. Les dessiner ensuite ne coûte qu'une image tournée par couche.
nonisolated enum NovaGlassTextures {
    /// Jusqu'où une couche est calculée, en rayons : assez pour couvrir la bille une fois glissée.
    static let layerExtent = 1.14
    static let layerSide = 640
    static let discSide = 600

    /// Les textures cuites. Des `CGImage` immuables : elles passent d'un fil à l'autre sans risque.
    struct Baked: @unchecked Sendable {
        /// Une par `NovaGlass.Layer`, dans l'ordre de ses cas.
        let layers: [CGImage]
        let rim: CGImage
        let resting: CGImage
    }

    /// Près de deux millions de points, chacun une somme d'exponentielles : **jamais sur le fil
    /// principal**. Cuites là au premier dessin, elles figeaient la fenêtre à son ouverture, et en test
    /// le MainActor que toutes les suites partagent, plusieurs secondes.
    private static let baking = Task.detached(priority: .userInitiated) {
        let baked = bakeAll()
        ready.withLock { $0 = baked }
        return baked
    }

    private static let ready = OSAllocatedUnfairLock<Baked?>(initialState: nil)

    /// Les textures si elles sont prêtes, sans attendre. Lance la cuisson si elle ne l'est pas.
    static var bakedIfReady: Baked? {
        _ = baking
        return ready.withLock { $0 }
    }

    /// Les textures, une fois cuites.
    static func baked() async -> Baked {
        await baking.value
    }

    /// Pour un rendu hors écran, qui ne repasse pas par la vue : cuit sur place si rien n'est prêt.
    @discardableResult
    static func bakedNow() -> Baked {
        if let baked = ready.withLock({ $0 }) { return baked }
        let baked = bakeAll()
        ready.withLock { $0 = baked }
        return baked
    }

    private static func bakeAll() -> Baked {
        Baked(
            layers: NovaGlass.Layer.allCases.map { layer in
                bake(side: layerSide, extent: layerExtent) { NovaGlass.radiance(of: layer, x: $0, y: $1) }
            },
            rim: bake(side: discSide, extent: 1, NovaGlass.rim),
            resting: bake(side: discSide, extent: 1, NovaGlass.resting)
        )
    }

    /// Calcule une image carrée qui couvre `−extent...extent` rayons.
    static func bake(side: Int, extent: Double, _ radiance: (Double, Double) -> NovaGlass.RGB) -> CGImage {
        var pixels = [UInt8](repeating: 255, count: side * side * 4)
        let step = 2 * extent / Double(side)
        var row = 0
        while row < side {
            let y = -extent + (Double(row) + 0.5) * step
            var column = 0
            while column < side {
                let x = -extent + (Double(column) + 0.5) * step
                let light = radiance(x, y)
                let index = (row * side + column) * 4
                pixels[index] = UInt8(NovaGlass.encode(light.red) * 255 + 0.5)
                pixels[index + 1] = UInt8(NovaGlass.encode(light.green) * 255 + 0.5)
                pixels[index + 2] = UInt8(NovaGlass.encode(light.blue) * 255 + 0.5)
                column += 1
            }
            row += 1
        }
        let provider = CGDataProvider(data: Data(pixels) as CFData)
        let image = provider.flatMap {
            CGImage(
                width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: side * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                provider: $0, decode: nil, shouldInterpolate: true, intent: .defaultIntent
            )
        }
        guard let image else { fatalError("Une texture de verre se construit toujours : dimensions constantes") }
        return image
    }
}
