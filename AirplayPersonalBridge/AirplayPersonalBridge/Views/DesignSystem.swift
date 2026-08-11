//
//  DesignSystem.swift
//  AirplayPersonalBridge
//

import AppKit
import SwiftUI

/// Les jetons de shadcn/ui, thème « zinc » par défaut, transposés en natif.
///
/// Les valeurs sont les HSL exactes du thème d'origine plutôt qu'un à-peu-près : c'est ce
/// qui fait qu'un système de design se reconnaît. Chaque couleur est un `NSColor`
/// dynamique, donc résolue par le système selon l'apparence — y compris dans un `Canvas`,
/// où un `@Environment(\.colorScheme)` ne serait pas disponible.
///
/// À savoir : adopter ce vocabulaire visuel remplace les contrôles standard de macOS par
/// des équivalents dessinés. On y gagne une identité cohérente, on y perd le comportement
/// natif que le système fait évoluer pour nous. Les composants ci-dessous rétablissent donc
/// explicitement ce qui compte le plus — accessibilité, réglage au clavier, survol.
enum Theme {
    static let background = dynamic(light: (0, 0, 1.00), dark: (240, 0.10, 0.039))
    static let foreground = dynamic(light: (240, 0.10, 0.039), dark: (0, 0, 0.98))
    static let card = dynamic(light: (0, 0, 1.00), dark: (240, 0.10, 0.055))
    static let muted = dynamic(light: (240, 0.048, 0.959), dark: (240, 0.037, 0.159))
    static let mutedForeground = dynamic(light: (240, 0.038, 0.461), dark: (240, 0.05, 0.649))
    static let border = dynamic(light: (240, 0.059, 0.90), dark: (240, 0.037, 0.185))
    static let primary = dynamic(light: (240, 0.059, 0.10), dark: (0, 0, 0.98))
    static let primaryForeground = dynamic(light: (0, 0, 0.98), dark: (240, 0.059, 0.10))
    static let accent = dynamic(light: (240, 0.048, 0.939), dark: (240, 0.037, 0.199))
    static let destructive = dynamic(light: (0, 0.842, 0.602), dark: (0, 0.628, 0.45))
    static let ring = dynamic(light: (240, 0.059, 0.10), dark: (240, 0.049, 0.839))

    /// Couleurs d'état. shadcn ne les définit pas : elles viennent du besoin métier
    /// (pastilles de session, traits de distance) et suivent la même logique de teinte.
    static let success = dynamic(light: (142, 0.71, 0.35), dark: (142, 0.65, 0.45))
    static let warning = dynamic(light: (38, 0.92, 0.45), dark: (38, 0.92, 0.55))
    static let info = dynamic(light: (217, 0.91, 0.55), dark: (217, 0.91, 0.62))

    /// `--radius: 0.5rem`, et ses dérivés `calc(var(--radius) - 2px)` / `- 4px`.
    enum Radius {
        static let lg: CGFloat = 8
        static let md: CGFloat = 6
        static let sm: CGFloat = 4
        static let full: CGFloat = 999
    }

    enum Font {
        static let title = SwiftUI.Font.system(size: 15, weight: .semibold)
        static let body = SwiftUI.Font.system(size: 13)
        static let medium = SwiftUI.Font.system(size: 13, weight: .medium)
        static let small = SwiftUI.Font.system(size: 12)
        static let tiny = SwiftUI.Font.system(size: 11)
        static let mono = SwiftUI.Font.system(size: 12, design: .monospaced)
    }

    /// HSL → couleur dynamique. SwiftUI ne connaît que le TSV (`hue/saturation/brightness`),
    /// qui n'est pas le TSL du web : convertir à la main évite des teintes délavées.
    private static func dynamic(
        light: (Double, Double, Double), dark: (Double, Double, Double)
    ) -> Color {
        Color(
            nsColor: NSColor(name: nil) { appearance in
                let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                let (h, s, l) = isDark ? dark : light
                return NSColor(hslHue: h, saturation: s, lightness: l)
            }
        )
    }
}

extension NSColor {
    fileprivate convenience init(hslHue: Double, saturation: Double, lightness: Double) {
        let chroma = (1 - abs(2 * lightness - 1)) * saturation
        let huePrime = hslHue.truncatingRemainder(dividingBy: 360) / 60
        let x = chroma * (1 - abs(huePrime.truncatingRemainder(dividingBy: 2) - 1))
        let (r1, g1, b1): (Double, Double, Double) =
            switch huePrime {
            case ..<1: (chroma, x, 0)
            case ..<2: (x, chroma, 0)
            case ..<3: (0, chroma, x)
            case ..<4: (0, x, chroma)
            case ..<5: (x, 0, chroma)
            default: (chroma, 0, x)
            }
        let m = lightness - chroma / 2
        self.init(srgbRed: r1 + m, green: g1 + m, blue: b1 + m, alpha: 1)
    }
}

// MARK: - Carte

/// Le conteneur `Card` : fond, bordure d'un point, coins arrondis. Pas d'ombre — shadcn
/// s'appuie sur la bordure, ce qui reste lisible sur fond sombre là où une ombre disparaît.
struct Card<Content: View>: View {
    var padding: CGFloat = 12
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.Radius.lg))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.lg)
                    .strokeBorder(Theme.border, lineWidth: 1)
            }
    }
}

// MARK: - Boutons

enum ShadVariant {
    case primary, secondary, outline, ghost, destructive
}

struct ShadButtonStyle: ButtonStyle {
    var variant: ShadVariant = .secondary
    var size: Size = .default
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    enum Size {
        case small, `default`, large

        var height: CGFloat {
            switch self {
            case .small: 26
            case .default: 30
            case .large: 36
            }
        }

        var padding: CGFloat {
            switch self {
            case .small: 9
            case .default: 12
            case .large: 16
            }
        }
    }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.Font.medium)
            .foregroundStyle(foreground)
            .padding(.horizontal, size.padding)
            .frame(height: size.height)
            .background(background(pressed: configuration.isPressed))
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
            .overlay {
                if variant == .outline {
                    RoundedRectangle(cornerRadius: Theme.Radius.md)
                        .strokeBorder(Theme.border, lineWidth: 1)
                }
            }
            .opacity(isEnabled ? 1 : 0.5)
            .onHover { isHovering = $0 }
            // shadcn signale l'état pressé par une opacité réduite plutôt qu'un
            // enfoncement : on reproduit le même signal.
            .animation(.easeOut(duration: 0.12), value: isHovering)
    }

    private var foreground: Color {
        switch variant {
        case .primary: Theme.primaryForeground
        case .destructive: .white
        default: Theme.foreground
        }
    }

    @ViewBuilder
    private func background(pressed: Bool) -> some View {
        let dim = pressed ? 0.75 : (isHovering ? 0.9 : 1.0)
        switch variant {
        case .primary: Theme.primary.opacity(dim)
        case .destructive: Theme.destructive.opacity(dim)
        case .secondary: Theme.muted.opacity(pressed ? 0.7 : (isHovering ? 0.85 : 1))
        case .outline: isHovering ? Theme.accent : Color.clear
        case .ghost: isHovering ? Theme.accent : Color.clear
        }
    }
}

extension View {
    func shadButton(_ variant: ShadVariant = .secondary, size: ShadButtonStyle.Size = .default)
        -> some View
    {
        buttonStyle(ShadButtonStyle(variant: variant, size: size))
    }
}

// MARK: - Badge

struct ShadBadge: View {
    let text: String
    var variant: ShadVariant = .secondary

    var body: some View {
        Text(text)
            .font(Theme.Font.tiny.weight(.medium))
            .foregroundStyle(variant == .primary ? Theme.primaryForeground : Theme.foreground)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(
                variant == .primary ? Theme.primary : Theme.muted,
                in: Capsule()
            )
            .overlay {
                if variant == .outline { Capsule().strokeBorder(Theme.border, lineWidth: 1) }
            }
    }
}

// MARK: - Curseur

/// Le curseur de shadcn : rail fin, pastille bordée.
///
/// Écrit à la main faute de pouvoir styler `Slider` sur macOS. Le réglage au clavier et la
/// description accessible sont donc rétablis explicitement — c'est précisément ce qu'on perd
/// en quittant le contrôle système, et le laisser tomber en silence serait une régression.
struct ShadSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double?

    @State private var isHovering = false

    private var fraction: Double {
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return 0 }
        return min(max((value - range.lowerBound) / span, 0), 1)
    }

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let thumb: CGFloat = 14
            let travel = max(width - thumb, 1)

            ZStack(alignment: .leading) {
                Capsule().fill(Theme.muted).frame(height: 5)
                Capsule()
                    .fill(Theme.primary)
                    .frame(width: thumb / 2 + travel * fraction, height: 5)
                Circle()
                    .fill(Theme.background)
                    .overlay { Circle().strokeBorder(Theme.primary, lineWidth: 2) }
                    .frame(width: thumb, height: thumb)
                    .offset(x: travel * fraction)
                    .shadow(color: .black.opacity(isHovering ? 0.18 : 0), radius: 3, y: 1)
            }
            .frame(height: thumb)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .onHover { isHovering = $0 }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        let position = min(max(drag.location.x - thumb / 2, 0), travel) / travel
                        set(range.lowerBound + position * (range.upperBound - range.lowerBound))
                    }
            )
        }
        .frame(height: 18)
        .accessibilityElement()
        .accessibilityValue(String(format: "%.1f", value))
        .accessibilityAdjustableAction { direction in
            let increment = step ?? (range.upperBound - range.lowerBound) / 40
            switch direction {
            case .increment: set(value + increment)
            case .decrement: set(value - increment)
            @unknown default: break
            }
        }
    }

    private func set(_ newValue: Double) {
        var clamped = min(max(newValue, range.lowerBound), range.upperBound)
        if let step { clamped = (clamped / step).rounded() * step }
        value = clamped
    }
}

// MARK: - Interrupteur

struct ShadSwitch: View {
    @Binding var isOn: Bool

    var body: some View {
        Capsule()
            .fill(isOn ? Theme.primary : Theme.muted)
            .frame(width: 34, height: 20)
            .overlay(alignment: isOn ? .trailing : .leading) {
                Circle()
                    .fill(isOn ? Theme.primaryForeground : Theme.background)
                    .frame(width: 16, height: 16)
                    .padding(2)
                    .shadow(color: .black.opacity(0.15), radius: 1, y: 0.5)
            }
            .overlay { Capsule().strokeBorder(Theme.border, lineWidth: isOn ? 0 : 1) }
            .contentShape(Capsule())
            .onTapGesture { withAnimation(.easeOut(duration: 0.15)) { isOn.toggle() } }
            .accessibilityElement()
            .accessibilityAddTraits(.isToggle)
            .accessibilityValue(isOn ? "activé" : "désactivé")
    }
}

// MARK: - Onglets

/// L'équivalent de `Tabs` : un fond creux, l'onglet actif porté par une carte.
struct ShadTabs<T: Hashable>: View {
    @Binding var selection: T
    let items: [(value: T, label: String)]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(items, id: \.value) { item in
                let isSelected = selection == item.value
                Text(item.label)
                    .font(Theme.Font.medium)
                    .foregroundStyle(isSelected ? Theme.foreground : Theme.mutedForeground)
                    .padding(.horizontal, 10)
                    .frame(height: 24)
                    .background {
                        if isSelected {
                            RoundedRectangle(cornerRadius: Theme.Radius.sm)
                                .fill(Theme.background)
                                .shadow(color: .black.opacity(0.08), radius: 1, y: 1)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { selection = item.value }
            }
        }
        .padding(2)
        .background(Theme.muted, in: RoundedRectangle(cornerRadius: Theme.Radius.md))
    }
}

// MARK: - Divers

struct ShadSeparator: View {
    var body: some View {
        Rectangle().fill(Theme.border).frame(height: 1)
    }
}

extension View {
    /// Le libellé de champ de shadcn : petit, medium, couleur de premier plan.
    func shadLabel() -> some View {
        font(Theme.Font.small.weight(.medium)).foregroundStyle(Theme.foreground)
    }

    /// Le texte d'appoint : `text-muted-foreground`.
    func shadMuted() -> some View {
        font(Theme.Font.small).foregroundStyle(Theme.mutedForeground)
    }
}
