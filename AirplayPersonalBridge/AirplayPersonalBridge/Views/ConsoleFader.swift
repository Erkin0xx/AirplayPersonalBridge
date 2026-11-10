//
//  ConsoleFader.swift
//  AirplayPersonalBridge
//

import SwiftUI

/// La correspondance entre un point du curseur vertical et sa valeur : hors de la vue pour être testée.
///
/// Le bas du rail vaut le minimum, le haut le maximum, linéairement en dB comme les autres curseurs de
/// l'app. Le remplissage garde un socle (`floor`) : au minimum il reste un trait de couleur, et l'icône
/// du volume général reste posée sur du blanc. Le haut du remplissage suit la main : c'est lui qu'on
/// attrape, pas un bouton.
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

/// Le curseur vertical de la console : un rail arrondi qui se remplit par le bas.
///
/// Écrit à la main, un `Slider` macOS ne se dressant pas à cette largeur. Ce qu'on perd en quittant le
/// contrôle système est rétabli explicitement, comme pour `PanelVolumeSlider` : flèches du clavier,
/// VoiceOver, anneau de focus. On le saisit n'importe où : la valeur va sous la main.
struct ConsoleFader: View {
    enum Look {
        /// Le volume général : blanc, l'icône du son posée dans le remplissage.
        case general
        /// Le volume d'une enceinte : la couleur de l'app.
        case speaker
    }

    @Binding var value: Double
    let range: ClosedRange<Double>
    /// Le pas d'un glissement ; `nil` laisse la valeur continue.
    var step: Double?
    /// Le pas d'une flèche du clavier, et d'un geste de VoiceOver.
    var keyStep: Double
    var look: Look = .speaker
    /// Le son ne passe pas (coupé, ou enceinte décochée) : le remplissage reste à sa place, éteint. C'est
    /// ce niveau-là que le rétablissement rendra, et le voir évite de se demander s'il a été perdu.
    var isSilenced = false
    /// Une valeur repérée d'un trait de chaque côté du rail : le 0 dB d'une enceinte.
    var mark: Double?
    var width: CGFloat = 72
    var cornerRadius: CGFloat = 24
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

    /// Ce qui reste rempli au minimum : la place de l'icône pour le général, un trait pour une enceinte.
    private var floor: CGFloat { look == .general ? 58 : 26 }

    var body: some View {
        GeometryReader { geometry in
            let height = geometry.size.height
            let fill = ConsoleFaderScale.fillHeight(for: value, in: range, trackHeight: height, floor: floor)
            ZStack(alignment: .bottom) {
                Color.white.opacity(isEnabled && (isHovering || isDragging) ? 0.19 : 0.14)
                Rectangle()
                    .fill(fillStyle)
                    .frame(height: fill)
                    .overlay(alignment: .top) { edge }
                    .overlay(alignment: .top) { grip }
                    .overlay(alignment: .bottom) { glyph }
                if let mark {
                    marks(
                        at: ConsoleFaderScale.fillHeight(for: mark, in: range, trackHeight: height, floor: floor)
                    )
                }
            }
            .clipShape(shape)
            .contentShape(shape)
            .gesture(drag(height: height))
        }
        .frame(width: width)
        .overlay {
            shape
                .inset(by: -3)
                .strokeBorder(BridgeTheme.rose, lineWidth: 2)
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

    private var fillStyle: AnyShapeStyle {
        if isSilenced { return AnyShapeStyle(PanelPalette.silencedFill) }
        // Blanc pour tous, comme les curseurs du Centre de contrôle : Baptiste ne veut pas de rose
        // sur les curseurs (2026-11-10). Le rose reste à l'état, pas aux réglages.
        return AnyShapeStyle(Color.white.opacity(look == .general ? 0.94 : 0.88))
    }

    /// Ce qui se pose sur le remplissage : sombre sur le blanc, clair sur le gris du silence.
    private var onFill: Color {
        isSilenced ? .white : .black
    }

    /// Un filet de lumière sur l'arête du remplissage coloré : il la détache du rail.
    @ViewBuilder
    private var edge: some View {
        if look == .speaker && !isSilenced {
            Rectangle()
                .fill(Color.white)
                .frame(height: 1)
                .accessibilityHidden(true)
        }
    }

    /// La prise, en haut du remplissage : elle dit qu'il se saisit, là où un bord droit ne dit rien.
    private var grip: some View {
        Capsule()
            .fill(onFill.opacity(isSilenced ? 0.22 : 0.34))
            .frame(width: 22, height: 4)
            .padding(.top, 8)
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
            .foregroundStyle(onFill.opacity(isSilenced ? 0.55 : 0.72))
            .frame(height: 26)
            .padding(.bottom, 14)
            .accessibilityHidden(true)
        }
    }

    /// Deux traits au bord du rail, à la hauteur de la valeur repérée : lisibles sur le rail comme sur le
    /// remplissage, sans barrer celui-ci.
    private func marks(at height: CGFloat) -> some View {
        HStack {
            Capsule().frame(width: 7, height: 1.5)
            Spacer()
            Capsule().frame(width: 7, height: 1.5)
        }
        .foregroundStyle(Color.white.opacity(0.5))
        .padding(.horizontal, 6)
        .padding(.bottom, max(height - 0.75, 0))
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
