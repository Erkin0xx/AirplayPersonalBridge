//
//  HaloVolumeRing.swift
//  AirplayPersonalBridge
//

import SwiftUI

/// Le passage de l'angle au volume, hors de la vue pour être testé.
///
/// L'anneau fait un tour complet : le minimum et le maximum se touchent en haut. C'est là que tout se
/// joue. Lu naïvement, un geste qui dépasse le maximum d'un degré retomberait au minimum, et le son
/// s'éteindrait sous la main. La course suivie pendant un geste (`follow`) est donc **déroulée** : elle
/// continue au-delà de 1 ou en deçà de 0 quand la main passe le haut de l'anneau, et c'est seulement la
/// valeur qu'on en tire qui est bornée. La main peut dépasser, le volume reste en butée.
nonisolated enum HaloRingGeometry {
    /// Où est ce point sur l'anneau : 0 en haut, 0,25 à droite, 0,5 en bas, 0,75 à gauche. Toujours
    /// dans `0..<1`.
    static func turn(of point: CGPoint, around center: CGPoint) -> Double {
        // L'axe des y descend : le haut de l'anneau est à `center.y − rayon`.
        let angle = atan2(Double(point.x - center.x), Double(center.y - point.y))
        let turn = angle / (2 * Double.pi)
        let wrapped = turn < 0 ? turn + 1 : turn
        return wrapped >= 1 ? 0 : wrapped
    }

    /// La part de l'anneau remplie pour ce volume, de 0 à 1.
    static func fraction(forDecibels decibels: Double, in range: ClosedRange<Double>) -> Double {
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return 0 }
        return min(max((decibels - range.lowerBound) / span, 0), 1)
    }

    /// Le volume pour cette course. Bornée : une course déroulée au-delà d'un bout donne ce bout.
    static func decibels(forCourse course: Double, in range: ClosedRange<Double>) -> Double {
        let fraction = min(max(course, 0), 1)
        return range.lowerBound + fraction * (range.upperBound - range.lowerBound)
    }

    /// Jusqu'où la course se déroule au-delà de chaque bout : un demi-tour. La main peut passer le
    /// haut de l'anneau et revenir sans que le volume quitte sa butée.
    static let slack = 0.5
    /// La portée du bouton, en part de tour : un clic à cette distance du bouton le saisit.
    static let knobReach = 0.04

    /// Le début d'un geste. Sur le bouton, il le saisit là où il est, même à cheval sur le haut de
    /// l'anneau : au maximum, cliquer le bouton ne fait pas tomber le volume au minimum. Ailleurs sur
    /// l'anneau, le volume va où l'on a cliqué.
    static func grab(turn: Double, currentFraction: Double) -> Double {
        let near = nearest(turn: turn, to: currentFraction)
        return abs(near - currentFraction) <= knobReach ? near : turn
    }

    /// La suite d'un geste : la course la plus proche de la précédente pour cet angle, à un tour près.
    /// C'est ce qui empêche de sauter d'un bout à l'autre en passant le haut de l'anneau.
    static func follow(course: Double, turn: Double) -> Double {
        min(max(nearest(turn: turn, to: course), -slack), 1 + slack)
    }

    /// Parmi `turn − 1`, `turn` et `turn + 1`, celui qui est le plus près de `course`.
    private static func nearest(turn: Double, to course: Double) -> Double {
        var best = turn
        for candidate in [turn - 1, turn + 1] where abs(candidate - course) < abs(best - course) {
            best = candidate
        }
        return best
    }

    /// Le point de l'anneau pour cette part, dans le sens horaire depuis le haut.
    static func point(forFraction fraction: Double, center: CGPoint, radius: Double) -> CGPoint {
        let angle = 2 * Double.pi * fraction
        return CGPoint(x: center.x + radius * sin(angle), y: center.y - radius * cos(angle))
    }
}

/// Le volume général, en anneau autour du halo : un rail fin, un arc pour le niveau, un bouton au bout.
///
/// Écrit à la main, aucun contrôle système n'étant circulaire. Ce qu'on perd en quittant le contrôle
/// système est rétabli explicitement, comme pour `PanelVolumeSlider` : flèches du clavier, VoiceOver,
/// anneau de focus. La valeur reste linéaire en dB, comme les autres commandes du volume général : elles
/// bougent ensemble.
struct HaloVolumeRing: View {
    @Binding var decibels: Double
    @Binding var isMuted: Bool
    let range: ClosedRange<Double>
    /// Le rayon de l'anneau, au milieu de son trait.
    let radius: CGFloat
    /// Un son part : l'arc est plein. Au repos il s'efface un peu, la sphère grise ne doit pas être
    /// éclipsée par son réglage.
    var isLive = false
    /// Le niveau auquel le clic droit ramène.
    var defaultDecibels = BridgeState.defaultMasterVolumeDB

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var isFocused: Bool
    @State private var isHovering = false
    /// La course déroulée du geste en cours (`HaloRingGeometry.follow`). `nil` hors d'un geste.
    @State private var course: Double?
    /// Le clic donne aussi le focus, mais l'anneau de focus n'a de sens que pour qui navigue au clavier.
    @State private var isPointerFocus = false

    /// Un tube plutôt qu'un trait : il lui faut un peu d'épaisseur pour montrer son profil.
    static let lineWidth: CGFloat = 6
    static let knobDiameter: CGFloat = 18
    /// De combien la prise grossit sous la souris.
    static let knobGrowth: CGFloat = 1.18
    /// La demi-largeur de la bande qui répond à la souris, de part et d'autre du trait. Assez large pour se saisir au doigt près, assez étroite pour laisser la plus petite sphère, inspirée,
    /// hors de la bande : un clic au bord de la sphère doit lancer la diffusion, pas régler le volume.
    static let grabHalfWidth: CGFloat = 13
    /// Le pas des flèches et de VoiceOver, celui du curseur du panneau.
    private let keyStep = 1.5

    /// Le côté du carré qu'occupe l'anneau, bouton et anneau de focus compris.
    static func side(forRadius radius: CGFloat) -> CGFloat {
        2 * (radius + HaloMetrics.ringOverhang)
    }

    private var fraction: Double {
        HaloRingGeometry.fraction(forDecibels: decibels, in: range)
    }

    private var valueText: String {
        isMuted ? "Son coupé" : PanelFormat.decibels(decibels)
    }

    var body: some View {
        let side = Self.side(forRadius: radius)
        let center = CGPoint(x: side / 2, y: side / 2)
        let knob = HaloRingGeometry.point(forFraction: fraction, center: center, radius: Double(radius))
        let isActive = isHovering || course != nil

        ZStack {
            // La piste, et sous elle l'arc éteint : coupé, il reste où il était, c'est ce niveau-là que
            // le rétablissement rendra.
            Canvas { context, _ in
                HaloRingPaint.drawTrack(in: &context, center: center, radius: radius, fraction: fraction)
            }
            // L'arc allumé, par-dessus : il s'efface au repos et s'éteint quand le son est coupé.
            Canvas { context, _ in
                HaloRingPaint.drawLitArc(in: &context, center: center, radius: radius, fraction: fraction)
            }
            .opacity(HaloRingPaint.litOpacity(isMuted: isMuted, isLive: isLive))
            HaloRingKnob(isMuted: isMuted)
                .frame(width: Self.knobDiameter, height: Self.knobDiameter)
                .scaleEffect(isActive ? Self.knobGrowth : 1)
                .position(knob)
            // L'anneau de focus du clavier, hors du trait.
            Circle()
                .strokeBorder(BridgeTheme.accent, lineWidth: 2)
                .frame(width: side, height: side)
                .opacity(isFocused && !isPointerFocus ? 1 : 0)
        }
        .frame(width: side, height: side)
        // Seule la bande de l'anneau répond : le centre est à la sphère, qui est un bouton.
        .contentShape(
            .interaction, HaloRingBand(radius: radius, halfWidth: Self.grabHalfWidth), eoFill: true
        )
        .gesture(drag(center: center))
        .onHover { isHovering = $0 }
        .animation(PanelMotion.quick(reduceMotion: reduceMotion), value: isActive)
        .animation(PanelMotion.standard(reduceMotion: reduceMotion), value: isMuted)
        .focusable(interactions: .edit)
        .focused($isFocused)
        .focusEffectDisabled()
        .onChange(of: isFocused) { _, focused in
            if !focused { isPointerFocus = false }
        }
        .onKeyPress(keys: [.leftArrow, .downArrow, .rightArrow, .upArrow]) { press in
            let isUp = press.key == .rightArrow || press.key == .upArrow
            adjust(by: isUp ? keyStep : -keyStep)
            return .handled
        }
        // Le double-clic du bouton rotatif d'avant : le menu le garde, comme dans la barre latérale.
        .contextMenu {
            Button("Revenir à \(PanelFormat.decibels(defaultDecibels))") { decibels = defaultDecibels }
        }
        .help("Volume de toutes les enceintes : glisse autour de l'anneau. Clic droit : revenir au niveau de départ.")
        .accessibilityElement()
        .accessibilityLabel("Volume général")
        .accessibilityValue(valueText)
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: adjust(by: keyStep)
            case .decrement: adjust(by: -keyStep)
            @unknown default: break
            }
        }
    }

    private func drag(center: CGPoint) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { drag in
                isPointerFocus = true
                let turn = HaloRingGeometry.turn(of: drag.location, around: center)
                let next =
                    course.map { HaloRingGeometry.follow(course: $0, turn: turn) }
                    ?? HaloRingGeometry.grab(turn: turn, currentFraction: fraction)
                course = next
                // Saisir l'anneau, c'est vouloir entendre : un son coupé se rétablit.
                if isMuted { isMuted = false }
                decibels = HaloRingGeometry.decibels(forCourse: next, in: range)
            }
            .onEnded { _ in course = nil }
    }

    private func adjust(by delta: Double) {
        if isMuted { isMuted = false }
        decibels = min(max(decibels + delta, range.lowerBound), range.upperBound)
    }
}

/// La matière de l'anneau, hors de la vue : un tube de verre sombre pour la piste, un tube blanc pour le
/// niveau. Pas de couleur du thème ici : un réglage reste blanc, seule sa matière change.
enum HaloRingPaint {
    /// Ce qui dépasse du trait, au plus : le halo froid de l'arc allumé. Doit tenir dans
    /// `HaloMetrics.ringOverhang`, comme le bouton.
    static let haloReach: CGFloat = 7

    /// L'opacité de l'arc allumé : plein quand un son part, en retrait au repos, éteint quand le son est
    /// coupé — l'arc gris de la piste prend alors sa place.
    static func litOpacity(isMuted: Bool, isLive: Bool) -> Double {
        if isMuted { return 0 }
        return isLive ? 1 : 0.62
    }

    /// Les arrêts du dégradé qui court le long de l'arc rempli, pour un dégradé conique parti du haut :
    /// d'un blanc bleuté à l'origine au blanc pur à la pointe. Au-delà de la pointe, la couleur reste
    /// celle de la pointe le temps de son bout arrondi, puis revient à celle de l'origine, dont le bout
    /// arrondi déborde de l'autre côté du haut. Les places sont croissantes, quel que soit le niveau.
    static func arcStops(fraction: Double) -> [(location: Double, tone: Double)] {
        let end = min(max(fraction, 0), 1)
        let cap = min(end + 0.03, max(end, 0.985))
        return [(0, 0), (end * 0.55, 0.45), (end, 1), (cap, 1), (1, 0)]
    }

    private static let coolEdge = (red: 0.608, green: 0.769, blue: 0.886)  // #9BC4E2

    /// Du blanc bleuté (`tone` 0) au blanc pur (`tone` 1), en composantes sRGB.
    static func bodyComponents(tone: Double) -> (red: Double, green: Double, blue: Double) {
        let share = min(max(tone, 0), 1)
        return (
            coolEdge.red + (1 - coolEdge.red) * share, coolEdge.green + (1 - coolEdge.green) * share,
            coolEdge.blue + (1 - coolEdge.blue) * share
        )
    }

    static func bodyColor(tone: Double) -> Color {
        let color = bodyComponents(tone: tone)
        return Color(.sRGB, red: color.red, green: color.green, blue: color.blue)
    }

    private static func arc(center: CGPoint, radius: CGFloat, from start: Double = 0, to end: Double) -> Path {
        var path = Path()
        path.addArc(
            center: center, radius: radius, startAngle: .degrees(-90 + 360 * start),
            endAngle: .degrees(-90 + 360 * end), clockwise: false
        )
        return path
    }

    private static func circle(center: CGPoint, radius: CGFloat) -> Path {
        Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
    }

    /// Un liseré qui n'existe qu'en haut à gauche, d'où vient la lumière, et s'éteint le long de la courbe.
    private static func lip(_ color: Color, center: CGPoint) -> GraphicsContext.Shading {
        .conicGradient(
            Gradient(stops: [
                .init(color: color.opacity(0), location: 0),
                .init(color: color.opacity(0), location: 0.24),
                .init(color: color, location: 0.5),
                .init(color: color.opacity(0), location: 0.76),
                .init(color: color.opacity(0), location: 1),
            ]),
            // La couture en bas à droite, à l'opposé de la lumière.
            center: center, angle: .degrees(45)
        )
    }

    /// La piste vide : un tube de verre noir, un peu translucide pour vivre sur le fond, et son liseré
    /// gris vers le bord intérieur. Par-dessus, l'arc éteint du niveau.
    static func drawTrack(in context: inout GraphicsContext, center: CGPoint, radius: CGFloat, fraction: Double) {
        let width = HaloVolumeRing.lineWidth
        let ring = circle(center: center, radius: radius)
        context.stroke(ring, with: .color(Color(.sRGB, red: 0.043, green: 0.043, blue: 0.047, opacity: 0.66)), lineWidth: width)
        // Un rien de clair partout : sur un fond presque noir, le tube se devinerait à peine.
        context.stroke(ring, with: .color(.white.opacity(0.05)), lineWidth: width)
        if fraction > 0 {
            context.stroke(
                arc(center: center, radius: radius, to: fraction), with: .color(.white.opacity(0.2)),
                style: StrokeStyle(lineWidth: width, lineCap: .round)
            )
        }
        let grey = Color(.sRGB, red: 0.627, green: 0.635, blue: 0.639)  // #A0A2A3
        context.stroke(
            circle(center: center, radius: radius - width * 0.5 + 0.9), with: lip(grey.opacity(0.95), center: center),
            lineWidth: 1
        )
        // L'autre lèvre, à peine : le tube a deux bords.
        context.stroke(
            circle(center: center, radius: radius + width * 0.5 - 0.5), with: lip(grey.opacity(0.3), center: center),
            lineWidth: 0.75
        )
    }

    /// L'arc rempli : un tube blanc, plus clair en son milieu et bleuté sur ses bords, un trait
    /// spéculaire, et un halo froid très discret.
    static func drawLitArc(in context: inout GraphicsContext, center: CGPoint, radius: CGFloat, fraction: Double) {
        guard fraction > 0 else { return }
        let width = HaloVolumeRing.lineWidth
        let path = arc(center: center, radius: radius, to: fraction)
        let cool = Color(.sRGB, red: 0.412, green: 0.565, blue: 0.718)  // #6990B7

        // Le halo : des traits de plus en plus larges, de moins en moins denses. Un flou ne se rend pas
        // hors écran.
        var step = 1
        while step <= 7 {
            let reach = haloReach * CGFloat(step) / 7
            context.stroke(
                path, with: .color(cool.opacity(0.05)),
                style: StrokeStyle(lineWidth: width + reach * 2, lineCap: .round)
            )
            step += 1
        }

        // Le corps, du blanc bleuté de l'origine au blanc pur de la pointe.
        let stops = arcStops(fraction: fraction)
        let body = Gradient(stops: stops.map { .init(color: bodyColor(tone: $0.tone), location: $0.location) })
        context.stroke(
            path, with: .conicGradient(body, center: center, angle: .degrees(-90)),
            style: StrokeStyle(lineWidth: width, lineCap: .round)
        )
        // Le profil du tube : son milieu est plus clair que ses bords.
        context.stroke(
            path, with: .color(.white.opacity(0.55)),
            style: StrokeStyle(lineWidth: width * 0.5, lineCap: .round)
        )
        // Le trait spéculaire, du côté de la lumière : vers le dedans.
        context.stroke(
            arc(center: center, radius: radius - width * 0.2, to: fraction), with: .color(.white),
            style: StrokeStyle(lineWidth: 1.1, lineCap: .round)
        )
        // Une ombre fine sur l'autre bord : c'est elle qui donne le rond du tube.
        let shade = Color(.sRGB, red: 0.196, green: 0.337, blue: 0.510)  // #325682
        context.stroke(
            arc(center: center, radius: radius + width * 0.5 - 0.5, to: fraction), with: .color(shade.opacity(0.32)),
            style: StrokeStyle(lineWidth: 1, lineCap: .round)
        )
    }
}

/// La prise de l'anneau : une bille de verre blanc, avec son reflet et une ombre fine.
private struct HaloRingKnob: View {
    let isMuted: Bool

    var body: some View {
        Circle()
            .fill(
                RadialGradient(
                    colors: isMuted
                        ? [Color(white: 0.84), Color(white: 0.66), Color(white: 0.5)]
                        : [.white, Color(.sRGB, red: 0.95, green: 0.97, blue: 0.985), Color(.sRGB, red: 0.74, green: 0.82, blue: 0.89)],
                    center: UnitPoint(x: 0.36, y: 0.3), startRadius: 0, endRadius: HaloVolumeRing.knobDiameter * 0.78
                )
            )
            .overlay {
                // Le liseré, plus net du côté de la lumière.
                Circle().strokeBorder(
                    LinearGradient(
                        colors: [.white.opacity(isMuted ? 0.5 : 1), .white.opacity(0.1)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
            }
            .overlay(alignment: .topLeading) {
                // Le reflet de la bille.
                Ellipse()
                    .fill(Color.white.opacity(isMuted ? 0.35 : 0.95))
                    .frame(width: HaloVolumeRing.knobDiameter * 0.3, height: HaloVolumeRing.knobDiameter * 0.2)
                    .rotationEffect(.degrees(-35))
                    .offset(x: HaloVolumeRing.knobDiameter * 0.2, y: HaloVolumeRing.knobDiameter * 0.18)
            }
            .shadow(color: .black.opacity(0.45), radius: 3, y: 1)
    }
}

/// La bande de l'anneau qui répond à la souris : deux cercles, à remplir en règle pair-impair.
private struct HaloRingBand: Shape {
    let radius: CGFloat
    let halfWidth: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        for reach in [radius + halfWidth, max(radius - halfWidth, 0)] {
            path.addEllipse(
                in: CGRect(x: rect.midX - reach, y: rect.midY - reach, width: reach * 2, height: reach * 2)
            )
        }
        return path
    }
}
