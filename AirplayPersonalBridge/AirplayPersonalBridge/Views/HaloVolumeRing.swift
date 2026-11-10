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

    static let lineWidth: CGFloat = 5
    static let knobDiameter: CGFloat = 18
    /// La demi-largeur de la bande qui répond à la souris, de part et d'autre du trait.
    static let grabHalfWidth: CGFloat = HaloMetrics.ringOverhang - 3
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
            Circle()
                .stroke(Color.white.opacity(isLive ? 0.16 : 0.12), lineWidth: Self.lineWidth)
                .frame(width: radius * 2, height: radius * 2)
            // Coupé, l'arc reste où il était, éteint : c'est ce niveau-là que le rétablissement rendra.
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(arcColor, style: StrokeStyle(lineWidth: Self.lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .frame(width: radius * 2, height: radius * 2)
            Circle()
                .fill(isMuted ? Color(white: 0.72) : Color.white)
                .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
                .frame(width: Self.knobDiameter, height: Self.knobDiameter)
                .scaleEffect(isActive ? 1.18 : 1)
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

    private var arcColor: Color {
        if isMuted { return Color.white.opacity(0.26) }
        return Color.white.opacity(isLive ? 1 : 0.6)
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
