//
//  HaloSphere.swift
//  AirplayPersonalBridge
//

import SwiftUI

/// La respiration du centre du halo, hors de la vue pour être testée. Rien n'y mesure le son : c'est un
/// témoin, pas un vumètre.
nonisolated enum HaloSphereMotion {
    /// Une inspiration et une expiration.
    static let breathPeriod: TimeInterval = 7.2
    /// De combien la lueur enfle en inspirant, en part du rayon du disque.
    static let breathDepth = 0.045
    /// Un tour complet de `spin`.
    static let spinPeriod: TimeInterval = 16

    /// De 0, expirée, à 1, inspirée, sans à-coup aux deux bouts.
    static func breath(at time: TimeInterval) -> Double {
        0.5 - 0.5 * cos(2 * Double.pi * time / breathPeriod)
    }

    /// L'échelle de ce qui respire à cet instant : jamais plus petite que 1, jamais plus grande que
    /// `1 + breathDepth`. L'anneau du volume, juste autour, compte dessus.
    static func scale(at time: TimeInterval) -> Double {
        1 + breathDepth * breath(at: time)
    }

    /// Un angle qui fait un tour par `spinPeriod`, en radians, dans `0..<2π`.
    static func spin(at time: TimeInterval) -> Double {
        let turns = time / spinPeriod
        return 2 * Double.pi * (turns - turns.rounded(.down))
    }
}

/// Le logo du pont qui ondule au centre du halo, comme un égaliseur lent : chaque barre a sa voix, deux
/// sinusoïdes de périodes sans commune mesure. Rien n'y mesure le son.
///
/// Les trois courses ne se recouvrent pas : le point reste sous les suspentes, les suspentes sous les
/// pylônes. Le profil du pont demeure à tout instant, quelles que soient les phases.
nonisolated enum HaloLogoMotion {
    /// Les courses, en unités du cadre de `BridgeGlyph` (pylône au repos : 14, suspente : 6, point : 2).
    static let pylonRange: ClosedRange<Double> = 11.6...14
    static let sideRange: ClosedRange<Double> = 4.6...11
    static let centerRange: ClosedRange<Double> = 2...4.4

    /// La voix d'une barre : une ondulation lente, et une seconde plus lente encore qui la module.
    struct Voice: Equatable {
        var period: TimeInterval
        var phase: Double
        var slowPeriod: TimeInterval
        var slowPhase: Double
    }

    /// La part de la seconde ondulation : assez pour que deux cycles ne se ressemblent pas.
    static let slowShare = 0.3

    /// De gauche à droite. Les périodes principales sont celles de la maquette (2,6 à 3,7 s).
    static let voices = [
        Voice(period: 3.2, phase: 0.4, slowPeriod: 7.3, slowPhase: 1.9),
        Voice(period: 2.6, phase: 2.1, slowPeriod: 6.1, slowPhase: 0.3),
        Voice(period: 2.9, phase: 4.4, slowPeriod: 5.3, slowPhase: 2.7),
        Voice(period: 3.1, phase: 5.2, slowPeriod: 6.7, slowPhase: 4.1),
        Voice(period: 3.7, phase: 3.0, slowPeriod: 8.3, slowPhase: 5.6),
    ]

    /// Où en est cette voix, de 0 à 1.
    static func swing(_ voice: Voice, at time: TimeInterval) -> Double {
        let fast = sin(2 * Double.pi * time / voice.period + voice.phase)
        let slow = sin(2 * Double.pi * time / voice.slowPeriod + voice.slowPhase)
        return 0.5 + 0.5 * ((1 - slowShare) * fast + slowShare * slow)
    }

    private static func height(in range: ClosedRange<Double>, _ voice: Voice, at time: TimeInterval) -> CGFloat {
        CGFloat(range.lowerBound + (range.upperBound - range.lowerBound) * swing(voice, at: time))
    }

    /// Les cinq barres à cet instant.
    static func bars(at time: TimeInterval) -> BridgeGlyph.Bars {
        BridgeGlyph.Bars(
            leftPylon: height(in: pylonRange, voices[0], at: time),
            left: height(in: sideRange, voices[1], at: time),
            center: height(in: centerRange, voices[2], at: time),
            right: height(in: sideRange, voices[3], at: time),
            rightPylon: height(in: pylonRange, voices[4], at: time)
        )
    }
}

/// Le triangle « lecture » du halo au repos, coins arrondis : un triangle engraissé d'une demi-épaisseur
/// de trait, chaque sommet remplacé par un arc. En parts du diamètre du disque, centre à l'origine.
nonisolated enum HaloPlayMark {
    /// Les sommets, dans le sens horaire à l'écran : la pointe à droite, décalée pour que le triangle
    /// paraisse centré.
    static let vertices = [
        CGPoint(x: -0.03, y: -0.08), CGPoint(x: 0.0933, y: 0), CGPoint(x: -0.03, y: 0.08),
    ]
    /// Le rayon des coins : ce dont le triangle déborde de ses sommets.
    static let cornerRadius: CGFloat = 0.0133

    /// Le tracé pour un disque de ce diamètre, centré en `center` : un seul contour, convexe.
    static func path(diameter: CGFloat, center: CGPoint = .zero) -> CGPath {
        let path = CGMutablePath()
        let points = vertices.map { CGPoint(x: center.x + $0.x * diameter, y: center.y + $0.y * diameter) }
        let radius = cornerRadius * diameter
        var index = 0
        while index < points.count {
            let before = points[(index + points.count - 1) % points.count]
            let corner = points[index]
            let after = points[(index + 1) % points.count]
            // La normale sortante de chaque arête, pour un contour horaire à l'écran (y vers le bas) :
            // l'arc du coin va de l'une à l'autre.
            let arriving = atan2(-(corner.x - before.x), corner.y - before.y)
            let leaving = atan2(-(after.x - corner.x), after.y - corner.y)
            path.addArc(center: corner, radius: radius, startAngle: arriving, endAngle: leaving, clockwise: false)
            index += 1
        }
        path.closeSubpath()
        return path
    }
}

/// La matière du centre du halo : un disque de verre noir (« Darkshells »), et, quand un son part, la lueur
/// du fond qui passe au travers — rose-orangé dans le bas, violette en haut, sans rayure ni filet.
///
/// Tout est décrit en **rayons de disque**, centre à l'origine, x vers la droite, y vers le bas, et en
/// fonctions pures : le dessin (`HaloSphere`) en tire ses dégradés, et les tests vérifient sur les mêmes
/// nombres que le logo reste lisible à tout instant.
nonisolated enum HaloGlass {
    /// Une couleur sRGB, telle que l'écran la compose : les couches s'y posent l'une sur l'autre.
    struct RGB: Equatable {
        var red: Double
        var green: Double
        var blue: Double

        init(hex: UInt32) {
            red = Double((hex >> 16) & 0xFF) / 255
            green = Double((hex >> 8) & 0xFF) / 255
            blue = Double(hex & 0xFF) / 255
        }

        /// Pose `color` par-dessus, à cette opacité.
        mutating func lay(_ color: RGB, alpha: Double) {
            red += (color.red - red) * alpha
            green += (color.green - green) * alpha
            blue += (color.blue - blue) * alpha
        }

        mutating func lighten(by amount: Double) {
            red = min(red + amount, 1)
            green = min(green + amount, 1)
            blue = min(blue + amount, 1)
        }

        /// La luminance relative, de 0 à 1.
        var luminance: Double {
            0.2126 * Self.linear(red) + 0.7152 * Self.linear(green) + 0.0722 * Self.linear(blue)
        }

        private static func linear(_ value: Double) -> Double {
            value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
    }

    /// Un arrêt de dégradé : sa place de 0 à 1, et l'opacité de sa teinte.
    struct Stop: Equatable {
        var location: Double
        var alpha: Double
    }

    /// L'opacité entre deux arrêts, comme un dégradé la calcule.
    static func alpha(in stops: [Stop], at location: Double) -> Double {
        guard let first = stops.first, let last = stops.last else { return 0 }
        if location <= first.location { return first.alpha }
        var index = 1
        while index < stops.count {
            let before = stops[index - 1]
            let after = stops[index]
            if location <= after.location {
                let share = (location - before.location) / max(after.location - before.location, 1e-9)
                return before.alpha + (after.alpha - before.alpha) * share
            }
            index += 1
        }
        return last.alpha
    }

    // MARK: Verre

    /// Le fond du disque, du haut vers le bas : presque noir.
    static let groundTop: UInt32 = 0x0C0C0F
    static let groundBottom: UInt32 = 0x060608

    static func ground(y: Double) -> RGB {
        var color = RGB(hex: groundTop)
        color.lay(RGB(hex: groundBottom), alpha: min(max((y + 1) / 2, 0), 1))
        return color
    }

    /// Le voile gris en haut du disque : une ellipse centrée sur son sommet, qui meurt avant le logo.
    static let veilTint: UInt32 = 0xD6DAE2
    static let veilCenter = CGPoint(x: 0, y: -1)
    static let veilRadii = CGSize(width: 1.6, height: 1.1)
    static func veilStops(isLive: Bool) -> [Stop] {
        let peak = isLive ? 0.2 : 0.22
        return [
            Stop(location: 0, alpha: peak), Stop(location: 0.2, alpha: peak * 0.66),
            Stop(location: 0.45, alpha: peak * 0.3), Stop(location: 0.6, alpha: peak * 0.1),
            Stop(location: 0.72, alpha: 0), Stop(location: 1, alpha: 0),
        ]
    }

    /// Le creux sombre sous le logo, en diffusion : aucune lueur ne doit le noyer.
    static let wellTint: UInt32 = 0x060608
    static let wellRadius = 1.414
    static let wellStops = [
        Stop(location: 0, alpha: 0.64), Stop(location: 0.15, alpha: 0.56), Stop(location: 0.3, alpha: 0.42),
        Stop(location: 0.44, alpha: 0.18), Stop(location: 0.52, alpha: 0.06), Stop(location: 0.58, alpha: 0),
        Stop(location: 1, alpha: 0),
    ]

    /// Le liseré de la lèvre, de haut en bas : net au sommet, presque éteint au pied.
    static let lipStops = [
        Stop(location: 0, alpha: 0.95), Stop(location: 0.14, alpha: 0.35), Stop(location: 0.4, alpha: 0.06),
        Stop(location: 1, alpha: 0.03),
    ]

    /// Le grain posé sur le verre, en part de celui du fond : il casse les paliers des dégradés sombres.
    static let grainShare = 0.5

    // MARK: Lueurs

    /// Une lueur : une tache floue, elliptique, qui dérive lentement et revient.
    struct Light: Equatable {
        var tint: UInt32
        var alpha: Double
        /// Sa place et ses demi-axes à l'instant 0.
        var center: CGPoint
        var radii: CGSize
        /// Jusqu'où elle dérive à mi-cycle, et de combien elle enfle.
        var drift: CGVector
        var swell: Double
        var period: TimeInterval
    }

    /// Le rose du fond dans le bas du disque, une braise orangée à sa gauche, le violet en haut à droite.
    /// Les places, les teintes et les rythmes sont ceux de la maquette ; les demi-axes sont élargis de ce
    /// que son flou ajoutait.
    static let lights = [
        Light(
            tint: 0xDF3880, alpha: 0.85, center: CGPoint(x: -0.2, y: 0.7), radii: CGSize(width: 1.15, height: 0.9),
            drift: CGVector(dx: 0.27, dy: -0.12), swell: 0.15, period: 11
        ),
        Light(
            tint: 0x7B2CA0, alpha: 0.72, center: CGPoint(x: 0.6, y: -0.8), radii: CGSize(width: 1.0, height: 0.93),
            drift: CGVector(dx: -0.227, dy: 0.2), swell: 0.2, period: 14
        ),
        Light(
            tint: 0xF26A3D, alpha: 0.36, center: CGPoint(x: -0.533, y: 0.62),
            radii: CGSize(width: 0.6, height: 0.5), drift: CGVector(dx: 0.227, dy: -0.1), swell: 0.2, period: 9
        ),
    ]

    /// La part des lueurs qui reste quand la session tient sans son audible : voilées, et figées.
    static let veiledShare = 0.45
    /// L'instant où elles se figent alors : leur place de dessin.
    static let stillTime: TimeInterval = 0

    /// Le profil d'une lueur, de son cœur (0) à son bord (1) : une cloche, sans arête nulle part.
    static func falloff(_ share: Double) -> Double {
        guard share < 1 else { return 0 }
        let kept = 1 - share * share
        return kept * kept
    }

    /// Où en est une lueur de sa dérive : 0 à l'instant 0, 1 à mi-cycle, sans à-coup.
    static func travel(of light: Light, at time: TimeInterval) -> Double {
        0.5 - 0.5 * cos(2 * Double.pi * time / light.period)
    }

    /// La place et les demi-axes de cette lueur à cet instant.
    static func pose(of light: Light, at time: TimeInterval) -> (center: CGPoint, radii: CGSize) {
        let travel = travel(of: light, at: time)
        let scale = 1 + light.swell * travel
        return (
            CGPoint(x: light.center.x + light.drift.dx * travel, y: light.center.y + light.drift.dy * travel),
            CGSize(width: light.radii.width * scale, height: light.radii.height * scale)
        )
    }

    private static func share(x: Double, y: Double, center: CGPoint, radii: CGSize) -> Double {
        let across = (x - Double(center.x)) / Double(radii.width)
        let down = (y - Double(center.y)) / Double(radii.height)
        return (across * across + down * down).squareRoot()
    }

    // MARK: Lisibilité

    /// La demi-étendue du logo sur le disque, en rayons (`HaloSphere` lui donne 0,364 × 0,328 diamètre).
    static let glyphHalfSize = CGSize(width: 0.364, height: 0.328)

    /// La couleur du verre **derrière** ce point, telle que le disque la compose en diffusion : le fond,
    /// les lueurs dans leurs poses, le voile, le creux, puis le grain à son plus clair.
    static func backdrop(x: Double, y: Double, time: TimeInterval, isAudible: Bool = true) -> RGB {
        var color = ground(y: y)
        for light in lights {
            let pose = pose(of: light, at: isAudible ? time : stillTime)
            let strength = light.alpha * (isAudible ? 1 : veiledShare)
            color.lay(
                RGB(hex: light.tint),
                alpha: strength * falloff(share(x: x, y: y, center: pose.center, radii: pose.radii))
            )
        }
        color.lay(
            RGB(hex: veilTint),
            alpha: alpha(in: veilStops(isLive: true), at: share(x: x, y: y, center: veilCenter, radii: veilRadii))
        )
        color.lay(RGB(hex: wellTint), alpha: alpha(in: wellStops, at: (x * x + y * y).squareRoot() / wellRadius))
        color.lighten(by: GrainientField.grainAmplitude * grainShare)
        return color
    }
}

/// Le centre du halo : un disque de verre noir sobre, qui porte la commande Diffuser / Arrêter.
///
/// Les allures. `resting` : le verre noir, un liseré sur la lèvre, un voile gris en haut, et le triangle
/// « lecture ». Une transition (`glyph == .connecting`) : les trois points qui pulsent, sur le même verre.
/// `live` et audible : le logo du pont ondule comme un égaliseur lent, le verre prend la lueur rose du
/// fond, qui dérive, et une lueur respire autour. `live` sans son audible (son coupé, capture muette) : la
/// session tient, le logo est là, immobile, les lueurs voilées et figées — la couleur qui bouge veut dire
/// « ça joue », et ne doit pas le prétendre.
///
/// Tout est en dégradés, dans des `Canvas` : un filtre de flou ne se rend pas hors écran, et rien n'est à
/// cuire. **Le verre est immobile et ne se redessine pas** (`HaloGlassPlate`) : seuls les lueurs et le logo
/// suivent l'horloge.
struct HaloSphere: View {
    enum Look: Equatable {
        case resting
        case live
    }

    let look: Look
    /// Un son part vraiment : le centre vit.
    let isAudible: Bool
    /// Ce que porte le centre : la commande (triangle au repos, pont en diffusion), ou les trois points
    /// d'une transition.
    let glyph: BridgeGlyph.Variant
    let diameter: CGFloat
    /// Un instant imposé, pour un rendu d'essai : le centre s'y fige. `nil` dans l'app.
    var frozenTime: TimeInterval?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Fenêtre à l'arrière-plan : le centre s'arrête, personne ne le regarde.
    @Environment(\.appearsActive) private var appearsActive

    /// L'instant posé quand rien ne bouge : expirée, les lueurs à leur place de dessin.
    static let stillTime = HaloGlass.stillTime
    /// Des mouvements de plusieurs secondes : vingt images par seconde leur suffisent.
    static let frameInterval: TimeInterval = 1 / 20
    /// Le dessin déborde du disque : la lueur et l'ombre portée.
    static let canvasShare: CGFloat = 2.2
    /// Le cadre du logo, en parts du diamètre.
    static let glyphShare = CGSize(width: 0.364, height: 0.328)

    private var isAlive: Bool { look == .live && isAudible }
    private var isAnimated: Bool { isAlive && !reduceMotion && frozenTime == nil }

    var body: some View {
        ZStack {
            HaloGlassPlate(part: .back, look: look, diameter: diameter).equatable()
            if look == .live {
                Group {
                    if isAnimated {
                        TimelineView(.animation(minimumInterval: Self.frameInterval, paused: !appearsActive)) {
                            lights(at: $0.date.timeIntervalSinceReferenceDate)
                        }
                        .transition(.opacity)
                    } else {
                        lights(at: frozenTime ?? Self.stillTime).transition(.opacity)
                    }
                }
                .frame(width: diameter * Self.canvasShare, height: diameter * Self.canvasShare)
            }
            HaloGlassPlate(part: .front, look: look, diameter: diameter).equatable()
            marks
        }
        .frame(width: diameter, height: diameter)
        // Le son coupé ou rétabli : les lueurs se voilent et le logo se pose, sans saut.
        .animation(reduceMotion ? nil : .smooth(duration: 0.45), value: isAnimated)
        .animation(reduceMotion ? nil : .smooth(duration: 0.3), value: glyph)
    }

    private func lights(at time: TimeInterval) -> some View {
        Canvas { context, size in
            Self.drawLights(
                in: &context, center: CGPoint(x: size.width / 2, y: size.height / 2), radius: diameter / 2,
                isAudible: isAudible, time: time
            )
        }
    }

    // MARK: - Glyphe

    @ViewBuilder
    private var marks: some View {
        switch glyph {
        case .connecting:
            Group {
                if reduceMotion {
                    bridge(BridgeGlyph.marks(.connecting))
                } else {
                    TimelineView(.animation(minimumInterval: 1 / 15, paused: !appearsActive)) { timeline in
                        bridge(BridgeGlyph.marks(.connecting)).opacity(
                            0.55 + 0.45 * abs(sin(timeline.date.timeIntervalSinceReferenceDate * 2.4))
                        )
                    }
                }
            }
            .transition(.opacity)
        case .idle, .streaming:
            if look == .resting {
                Path(HaloPlayMark.path(diameter: diameter, center: CGPoint(x: diameter / 2, y: diameter / 2)))
                    .fill(Color.white)
                    .frame(width: diameter, height: diameter)
                    .transition(.opacity)
            } else if isAnimated {
                TimelineView(.animation(minimumInterval: Self.frameInterval, paused: !appearsActive)) { timeline in
                    logo(HaloLogoMotion.bars(at: timeline.date.timeIntervalSinceReferenceDate))
                }
                .transition(.opacity)
            } else {
                // Figé pour un rendu d'essai, le logo est pris dans son mouvement ; sinon il est au repos.
                logo(isAlive ? frozenTime.map(HaloLogoMotion.bars(at:)) ?? .rest : .rest)
                    .transition(.opacity)
            }
        default:
            bridge(BridgeGlyph.marks(glyph)).transition(.opacity)
        }
    }

    private func logo(_ bars: BridgeGlyph.Bars) -> some View {
        bridge(BridgeGlyph.marks(bars: bars))
            // Une ombre sombre le détache d'une lueur qui monterait derrière lui.
            .shadow(color: .black.opacity(0.45), radius: 6, y: 1)
    }

    private func bridge(_ path: CGPath) -> some View {
        BridgeGlyphShape(path: path)
            .fill(Color.white, style: FillStyle(eoFill: true))
            .frame(width: diameter * Self.glyphShare.width, height: diameter * Self.glyphShare.height)
    }

    // MARK: - Dessin

    private static func square(_ center: CGPoint, _ radius: CGFloat) -> CGRect {
        CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
    }

    private static func color(_ tint: UInt32, _ alpha: Double) -> Color {
        BridgeTheme.color(tint).opacity(alpha)
    }

    private static func gradient(_ stops: [HaloGlass.Stop], tint: UInt32) -> Gradient {
        Gradient(stops: stops.map { .init(color: color(tint, $0.alpha), location: $0.location) })
    }

    /// Une ellipse en dégradé radial, dont les arrêts courent du centre (0) au bord (1).
    private static func fillEllipse(
        in context: GraphicsContext, center: CGPoint, radii: CGSize, gradient: Gradient
    ) {
        var ellipse = context
        ellipse.translateBy(x: center.x, y: center.y)
        ellipse.scaleBy(x: radii.width, y: radii.height)
        ellipse.fill(
            Path(ellipseIn: CGRect(x: -1, y: -1, width: 2, height: 2)),
            with: .radialGradient(gradient, center: .zero, startRadius: 0, endRadius: 1)
        )
    }

    /// Le profil d'une lueur, échantillonné sur la fonction que les tests vérifient.
    private static let falloffStops: [HaloGlass.Stop] = (0...14).map { step in
        let share = Double(step) / 14
        return HaloGlass.Stop(location: share, alpha: HaloGlass.falloff(share))
    }

    /// La lueur autour du disque : elle part de son bord et meurt vite.
    static let glowReach = 1.5
    static let glowTint: UInt32 = 0xDF3880
    private static let glowStops: [HaloGlass.Stop] = {
        let edge = 1 / glowReach
        var stops = [HaloGlass.Stop(location: 0, alpha: 1), HaloGlass.Stop(location: edge * 0.9, alpha: 1)]
        for step in 0...8 {
            let share = Double(step) / 8
            stops.append(HaloGlass.Stop(location: edge + (1 - edge) * share, alpha: (1 - share) * (1 - share)))
        }
        return stops
    }()

    /// Le verre sous les lueurs : l'ombre portée et le fond du disque.
    static func drawBack(in context: inout GraphicsContext, center: CGPoint, radius: CGFloat) {
        // L'ombre portée : sous le disque, pas autour.
        let shadowCenter = CGPoint(x: center.x, y: center.y + radius * 0.22)
        let shadowRadius = radius * 1.3
        context.fill(
            Path(ellipseIn: square(shadowCenter, shadowRadius)),
            with: .radialGradient(
                Gradient(stops: [
                    .init(color: .black.opacity(0.46), location: 0),
                    .init(color: .black.opacity(0.4), location: 0.6),
                    .init(color: .black.opacity(0.24), location: 0.76),
                    .init(color: .black.opacity(0.1), location: 0.88),
                    .init(color: .black.opacity(0.03), location: 0.96),
                    .init(color: .black.opacity(0), location: 1),
                ]),
                center: shadowCenter, startRadius: 0, endRadius: shadowRadius
            )
        )
        context.fill(
            Path(ellipseIn: square(center, radius)),
            with: .linearGradient(
                Gradient(colors: [
                    BridgeTheme.color(HaloGlass.groundTop), BridgeTheme.color(HaloGlass.groundBottom),
                ]),
                startPoint: CGPoint(x: center.x, y: center.y - radius),
                endPoint: CGPoint(x: center.x, y: center.y + radius)
            )
        )
    }

    /// Ce qui bouge : la lueur autour du disque, puis celles du fond à travers le verre. Sans son audible,
    /// elles restent où le dessin les pose, voilées, et rien ne luit autour.
    static func drawLights(
        in context: inout GraphicsContext, center: CGPoint, radius: CGFloat, isAudible: Bool, time: TimeInterval
    ) {
        let disc = Path(ellipseIn: square(center, radius))
        if isAudible {
            let breath = HaloSphereMotion.breath(at: time)
            let reach = radius * glowReach * HaloSphereMotion.scale(at: time)
            var around = context
            // Hors du disque seulement : dessous, le verre est opaque.
            var outside = Path(square(center, reach + 1))
            outside.addPath(disc)
            around.clip(to: outside, style: FillStyle(eoFill: true))
            around.opacity = 0.26 + 0.22 * breath
            around.fill(
                Path(ellipseIn: square(center, reach)),
                with: .radialGradient(
                    gradient(glowStops, tint: glowTint), center: center, startRadius: 0, endRadius: reach
                )
            )
        }
        var inside = context
        inside.clip(to: disc)
        inside.opacity = isAudible ? 1 : HaloGlass.veiledShare
        for light in HaloGlass.lights {
            let pose = HaloGlass.pose(of: light, at: isAudible ? time : stillTime)
            fillEllipse(
                in: inside,
                center: CGPoint(x: center.x + pose.center.x * radius, y: center.y + pose.center.y * radius),
                radii: CGSize(width: pose.radii.width * radius, height: pose.radii.height * radius),
                gradient: Gradient(stops: falloffStops.map {
                    .init(color: color(light.tint, light.alpha * $0.alpha), location: $0.location)
                })
            )
        }
    }

    /// Le verre par-dessus les lueurs : le voile du haut, le creux sous le logo, le grain, le liseré.
    static func drawFront(in context: inout GraphicsContext, center: CGPoint, radius: CGFloat, look: Look) {
        let disc = Path(ellipseIn: square(center, radius))
        var inside = context
        inside.clip(to: disc)
        fillEllipse(
            in: inside,
            center: CGPoint(
                x: center.x + HaloGlass.veilCenter.x * radius, y: center.y + HaloGlass.veilCenter.y * radius
            ),
            radii: CGSize(width: HaloGlass.veilRadii.width * radius, height: HaloGlass.veilRadii.height * radius),
            gradient: gradient(HaloGlass.veilStops(isLive: look == .live), tint: HaloGlass.veilTint)
        )
        if look == .live {
            let reach = radius * HaloGlass.wellRadius
            fillEllipse(
                in: inside, center: center, radii: CGSize(width: reach, height: reach),
                gradient: gradient(HaloGlass.wellStops, tint: HaloGlass.wellTint)
            )
        }
        if let grain = GrainientBackground.grain {
            var grainy = inside
            grainy.opacity = HaloGlass.grainShare
            grainy.fill(disc, with: .tiledImage(Image(decorative: grain, scale: 2)))
        }

        // Le liseré : un anneau fin, net sur la lèvre haute, qui s'éteint en descendant.
        let lip = max(1.25, radius * 0.01)
        var ring = disc
        ring.addPath(Path(ellipseIn: square(center, radius - lip)))
        context.fill(
            ring,
            with: .linearGradient(
                gradient(HaloGlass.lipStops, tint: 0xFFFFFF),
                startPoint: CGPoint(x: center.x, y: center.y - radius),
                endPoint: CGPoint(x: center.x, y: center.y + radius)
            ),
            style: FillStyle(eoFill: true)
        )
    }
}

/// Une moitié immobile du verre : dessinée une fois, et laissée tranquille tant que ni l'allure ni la
/// taille ne changent. `back` passe sous les lueurs, `front` par-dessus.
struct HaloGlassPlate: View, Equatable {
    enum Part: Equatable {
        case back
        case front
    }

    let part: Part
    let look: HaloSphere.Look
    let diameter: CGFloat

    var body: some View {
        Canvas { context, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            switch part {
            case .back:
                HaloSphere.drawBack(in: &context, center: center, radius: diameter / 2)
            case .front:
                HaloSphere.drawFront(in: &context, center: center, radius: diameter / 2, look: look)
            }
        }
        .frame(width: diameter * HaloSphere.canvasShare, height: diameter * HaloSphere.canvasShare)
    }
}

/// Le halo est la commande Diffuser / Arrêter : il cède sous le doigt, et s'efface quand il ne répond pas.
struct HaloSphereButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(isEnabled ? 1 : 0.72)
            .contentShape(Circle())
            .contentShape(.focusEffect, Circle())
            .animation(PanelMotion.quick(reduceMotion: reduceMotion), value: configuration.isPressed)
    }
}
