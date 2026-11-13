//
//  ConsoleFader.swift
//  AirplayPersonalBridge
//

import SwiftUI

/// La correspondance entre un point du curseur vertical et sa valeur : hors de la vue pour être testée.
///
/// Le bas du rail vaut le minimum, le haut le maximum, linéairement en dB comme les autres curseurs de
/// l'app. Le remplissage garde un socle (`floor`) : au minimum il reste un pied de voile sous le trait du
/// niveau, et la place de l'icône du volume général. Le haut du remplissage suit la main : c'est lui
/// qu'on attrape.
enum ConsoleFaderScale {
    /// La part de la course parcourue : 0 au minimum, 1 au maximum, bornée.
    static func fraction(of value: Double, in range: ClosedRange<Double>) -> Double {
        let span = range.upperBound - range.lowerBound
        guard span > 0, value.isFinite else { return 0 }
        return min(max((value - range.lowerBound) / span, 0), 1)
    }

    /// La hauteur du remplissage pour cette valeur, socle compris.
    static func fillHeight(
        for value: Double, in range: ClosedRange<Double>, trackHeight: CGFloat, floor: CGFloat
    ) -> CGFloat {
        let base = min(max(floor, 0), max(trackHeight, 0))
        return base + max(trackHeight - base, 0) * fraction(of: value, in: range)
    }

    /// La valeur que désigne un point du rail. `y` part du haut de la vue, comme la position d'un geste ;
    /// au-dessus du rail c'est le maximum, sous le socle le minimum. `nil` si le rail n'a pas de course :
    /// il n'y a alors rien à lire, et la valeur ne doit pas bouger.
    static func value(
        atY y: CGFloat, trackHeight: CGFloat, floor: CGFloat, in range: ClosedRange<Double>, step: Double?
    ) -> Double? {
        let base = max(floor, 0)
        let travel = trackHeight - base
        guard travel > 0, y.isFinite else { return nil }
        // Hors du rail, la position sort de 0…1 : ce sont les bornes de la valeur qui la retiennent.
        let position = (trackHeight - y - base) / travel
        let raw = range.lowerBound + Double(position) * (range.upperBound - range.lowerBound)
        return snapped(raw, to: step, in: range)
    }

    /// Ramenée au pas, puis aux bornes : une borne qui n'est pas un multiple du pas reste atteignable.
    static func snapped(_ value: Double, to step: Double?, in range: ClosedRange<Double>) -> Double {
        var result = value
        if let step, step > 0 { result = (value / step).rounded() * step }
        return min(max(result, range.lowerBound), range.upperBound)
    }

    /// Un pas du clavier ou de VoiceOver.
    static func stepped(
        _ value: Double, by delta: Double, in range: ClosedRange<Double>, step: Double?
    ) -> Double {
        snapped(value + delta, to: step, in: range)
    }
}

/// Le curseur vertical de la console : une coque noire à liseré (`Darkshell`), où le niveau est un voile
/// gris sous un trait blanc qui porte la prise.
///
/// Écrit à la main, un `Slider` macOS ne se dressant pas à cette largeur. Ce qu'on perd en quittant le
/// contrôle système est rétabli explicitement, comme pour `PanelVolumeSlider` : flèches du clavier,
/// VoiceOver, anneau de focus. On le saisit n'importe où : la valeur va sous la main.
struct ConsoleFader: View {
    enum Look {
        /// Le volume général : l'icône du son posée au pied du rail.
        case general
        /// Le volume d'une enceinte.
        case speaker
    }

    @Binding var value: Double
    let range: ClosedRange<Double>
    /// Le pas d'un glissement ; `nil` laisse la valeur continue.
    var step: Double?
    /// Le pas d'une flèche du clavier, et d'un geste de VoiceOver.
    var keyStep: Double
    var look: Look = .speaker
    /// Le son ne passe pas (coupé, ou enceinte décochée) : le voile reste à sa place, éteint, sous un trait
    /// gris. C'est
    /// ce niveau-là que le rétablissement rendra, et le voir évite de se demander s'il a été perdu.
    var isSilenced = false
    /// Une valeur repérée d'un trait de chaque côté du rail : le 0 dB d'une enceinte.
    var mark: Double?
    var width: CGFloat = 72
    var cornerRadius: CGFloat = 24
    /// Les mesures du trait, de la prise et du repère : celles de la console, ou plus fines (le widget).
    var metrics = DarkshellFaderMetrics.console
    /// Pour VoiceOver.
    let label: String
    let valueText: String

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var isFocused: Bool
    @State private var isHovering = false
    @State private var isDragging = false
    /// Le clic donne aussi le focus, mais l'anneau n'a de sens que pour qui navigue au clavier.
    @State private var isPointerFocus = false

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }

    /// Ce qui reste rempli au minimum : la place de l'icône pour le général, un pied de voile pour une
    /// enceinte.
    private var floor: CGFloat { metrics.floor ?? (look == .general ? 58 : 26) }

    var body: some View {
        GeometryReader { geometry in
            let height = geometry.size.height
            let fill = ConsoleFaderScale.fillHeight(for: value, in: range, trackHeight: height, floor: floor)
            let level = DarkshellFaderGeometry.levelY(fill: fill, trackHeight: height)
            ZStack(alignment: .top) {
                shape.fill(Darkshell.ground)
                // Tout ce qui vit dans la coque s'arrête au liseré, qui reste entier quel que soit le niveau.
                ZStack(alignment: .top) {
                    if isEnabled && (isHovering || isDragging) { Darkshell.hoverLift }
                    Rectangle()
                        .fill(Darkshell.veilGradient(isSilenced: isSilenced, from: .top, to: .bottom))
                        .frame(height: DarkshellFaderGeometry.veilHeight(fill: fill, trackHeight: height))
                        .offset(y: level)
                    if let mark {
                        marks(
                            atY: DarkshellFaderGeometry.markY(
                                fill: ConsoleFaderScale.fillHeight(
                                    for: mark, in: range, trackHeight: height, floor: floor
                                ),
                                trackHeight: height
                            )
                        )
                    }
                    Rectangle()
                        .fill(levelColor)
                        .frame(height: metrics.lineThickness)
                        .offset(y: level)
                    grip(
                        centerY: DarkshellFaderGeometry.gripCenterY(
                            levelY: level, trackHeight: height, gripHeight: metrics.grip.height,
                            lineThickness: metrics.lineThickness
                        )
                    )
                }
                .frame(width: geometry.size.width, height: height, alignment: .top)
                .overlay(alignment: .bottom) { glyph }
                .clipShape(shape.inset(by: Darkshell.lipWidth))
                shape.strokeBorder(Darkshell.lipGradient(.fader), lineWidth: Darkshell.lipWidth)
            }
            .contentShape(shape)
            .gesture(drag(height: height))
        }
        // L'ombre portée de la coque sur la tuile : dessous, elle ne change rien à la place prise.
        .background {
            shape
                .fill(Color.black)
                .shadow(color: .black.opacity(0.32), radius: metrics.shadowRadius, y: metrics.shadowY)
                .accessibilityHidden(true)
        }
        .frame(width: width)
        .overlay {
            shape
                .inset(by: -3)
                // Blanc : pas de rose sur une commande, même pour dire qu'elle a le focus.
                .strokeBorder(Color.white.opacity(0.9), lineWidth: 2)
                .opacity(isFocused && !isPointerFocus ? 1 : 0)
        }
        .onHover { isHovering = $0 }
        .animation(PanelMotion.quick(reduceMotion: reduceMotion), value: isHovering)
        .animation(PanelMotion.standard(reduceMotion: reduceMotion), value: isSilenced)
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
        .accessibilityElement()
        .accessibilityLabel(label)
        .accessibilityValue(valueText)
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: adjust(by: keyStep)
            case .decrement: adjust(by: -keyStep)
            @unknown default: break
            }
        }
    }

    // MARK: Dessin

    /// Le trait du niveau et sa prise : blancs, gris quand le son ne passe pas.
    private var levelColor: Color {
        Darkshell.levelColor(isSilenced: isSilenced)
    }

    /// La prise, à cheval sur le trait du niveau : elle dit qu'il se saisit, là où un trait seul ne dit
    /// rien.
    private func grip(centerY: CGFloat) -> some View {
        Capsule()
            .fill(levelColor)
            .shadow(color: .black.opacity(0.6), radius: metrics.gripShadowRadius, y: metrics.gripShadowY)
            .frame(width: metrics.grip.width, height: metrics.grip.height)
            .offset(y: centerY - metrics.grip.height / 2)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var glyph: some View {
        if look == .general {
            Group {
                if isSilenced {
                    Image(systemName: PanelMuteButton.symbol)
                } else {
                    Image(
                        systemName: "speaker.wave.3.fill",
                        variableValue: ConsoleFaderScale.fraction(of: value, in: range)
                    )
                }
            }
            .font(.title2.weight(.medium))
            .foregroundStyle(Color.white.opacity(isSilenced ? 0.5 : 0.9))
            .frame(height: 26)
            .padding(.bottom, 14)
            .accessibilityHidden(true)
        }
    }

    /// Deux tirets au bord du rail, à la hauteur de la valeur repérée : lisibles sur le noir comme sur le
    /// voile, sans barrer celui-ci.
    private func marks(atY y: CGFloat) -> some View {
        HStack {
            Rectangle().frame(width: metrics.mark.width, height: metrics.mark.height)
            Spacer(minLength: 0)
            Rectangle().frame(width: metrics.mark.width, height: metrics.mark.height)
        }
        .foregroundStyle(Darkshell.markColor.opacity(isSilenced ? 0.5 : 1))
        .padding(.horizontal, Darkshell.lipWidth + metrics.markInset)
        .offset(y: y)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    // MARK: Gestes

    private func drag(height: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { drag in
                isDragging = true
                isPointerFocus = true
                let target = ConsoleFaderScale.value(
                    atY: drag.location.y, trackHeight: height, floor: floor, in: range, step: step
                )
                // Toujours écrit, même sans changement : saisir le curseur du général, c'est vouloir
                // entendre, et c'est cette écriture qui rétablit un son coupé.
                if let target { value = target }
            }
            .onEnded { _ in isDragging = false }
    }

    private func adjust(by delta: Double) {
        value = ConsoleFaderScale.stepped(value, by: delta, in: range, step: step)
    }
}
