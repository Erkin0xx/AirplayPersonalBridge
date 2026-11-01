//
//  PanelControls.swift
//  AirplayPersonalBridge
//

import AppKit
import SwiftUI

/// La grille du panneau : une colonne de pastilles, une colonne de texte, sur un pas de 4 pt.
///
/// Tout s'y aligne : pastille d'état, icône du volume et pastilles d'enceintes partagent le même axe,
/// noms et titres le même bord. Ce n'est pas un détail : c'est ce qui donne à une pile de contrôles
/// hétérogènes l'air d'un seul objet.
enum PanelMetrics {
    static let width: CGFloat = 320
    /// Du bord du panneau au contenu.
    static let margin: CGFloat = 12
    /// Du bord du panneau à la surbrillance d'une rangée : le reste de la marge passe à l'intérieur.
    static let rowInset: CGFloat = 6
    /// Concentrique au panneau, dont le rayon vaut environ 16 pt : 16 − 6 de retrait.
    static let rowRadius: CGFloat = 10
    static let pastille: CGFloat = 28
    static let columnGap: CGFloat = 10
    /// Le bord gauche des textes, depuis la marge.
    static let textColumn: CGFloat = pastille + columnGap
}

/// Les couleurs propres au panneau, toutes dérivées du premier plan sémantique : elles restent justes
/// sur le matériau du système, clair comme sombre, là où une valeur fixe viserait un fond supposé.
enum PanelPalette {
    /// Le fond d'une pastille au repos.
    static let quietFill = Color.primary.opacity(0.09)
    static let hover = Color.primary.opacity(0.07)
    static let press = Color.primary.opacity(0.12)
    /// Le rail du curseur, plus creux que le survol : il doit se lire comme un logement.
    static let track = Color.primary.opacity(0.13)

    /// L'orange et le rouge système sont faits pour des aplats : en texte de 11 pt sur un fond clair,
    /// ils passent sous le seuil de lecture. Le mode clair prend donc une nuance plus sombre.
    static let warningText = adaptive(light: NSColor(srgbRed: 0.68, green: 0.36, blue: 0, alpha: 1), dark: .systemOrange)
    static let criticalText = adaptive(light: NSColor(srgbRed: 0.78, green: 0.13, blue: 0.12, alpha: 1), dark: .systemRed)

    private static func adaptive(light: NSColor, dark: NSColor) -> Color {
        Color(
            nsColor: NSColor(name: nil) { appearance in
                appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            }
        )
    }
}

enum PanelMotion {
    /// Courte et douce, ou rien du tout si l'utilisateur a demandé moins de mouvement.
    static func standard(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .smooth(duration: 0.22)
    }

    /// Pour ce qui répond à la main : survol, pression.
    static func quick(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .easeOut(duration: 0.12)
    }
}

enum PanelFormat {
    /// Avec le signe moins typographique et la virgule du français.
    static func decibels(_ value: Double, fractionDigits: Int = 0, signed: Bool = false) -> String {
        let number = value.formatted(
            .number
                .precision(.fractionLength(fractionDigits))
                .sign(strategy: signed ? .always(includingZero: false) : .automatic)
                .locale(Locale(identifier: "fr_FR"))
        )
        return "\(number.replacingOccurrences(of: "-", with: "−")) dB"
    }
}

extension EnvironmentValues {
    /// Le verre lit ce que le serveur de fenêtres compose derrière lui : hors écran, il ne dessine
    /// rien. Le rendu d'essai pose donc à sa place un aplat de même forme, pour juger de la mise en
    /// page. L'app ne le pose jamais.
    @Entry var panelSimulatesGlass = false
}

// MARK: - Commande principale

/// La seule commande de l'en-tête : une capsule de verre, teintée quand elle invite à agir.
struct PanelCommandButtonStyle: ButtonStyle {
    /// La teinte du verre. `nil` donne un verre neutre : arrêter ne doit pas appeler le clic autant
    /// que démarrer.
    var tint: Color?
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.panelSimulatesGlass) private var simulatesGlass

    func makeBody(configuration: Configuration) -> some View {
        let label = configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(tint == nil ? Color.primary : Color.white)
            .padding(.horizontal, 12)
            .frame(height: PanelMetrics.pastille)
            .contentShape(Capsule())
        return Group {
            if simulatesGlass {
                label.background(tint ?? PanelPalette.track, in: Capsule())
            } else {
                label.glassEffect(glass, in: .capsule)
            }
        }
        .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.45)
    }

    private var glass: Glass {
        let base = Glass.regular.interactive(isEnabled)
        return tint.map { base.tint($0) } ?? base
    }
}

// MARK: - Volume master

/// Le curseur épais du Centre de contrôle : l'icône à l'intérieur, et un clic dessus coupe le son.
///
/// Écrit à la main, un `Slider` macOS ne se laissant pas épaissir. Ce qu'on perd en quittant le
/// contrôle système est donc rétabli explicitement : flèches du clavier, VoiceOver, anneau de focus.
///
/// La valeur reste linéaire en dB, comme celle du curseur de la fenêtre : les deux bougent ensemble.
struct PanelVolumeSlider: View {
    @Binding var decibels: Double
    @Binding var isMuted: Bool
    let range: ClosedRange<Double>
    /// Pour le rendu hors écran, où le survol n'existe pas.
    var showsValue = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var isFocused: Bool
    @State private var isHovering = false
    @State private var isDragging = false
    /// Le clic donne aussi le focus, mais l'anneau n'a de sens que pour qui navigue au clavier.
    @State private var isPointerFocus = false

    private let height = PanelMetrics.pastille
    private let keyStep = 1.5

    /// Coupé, le curseur redescend à zéro comme celui du système ; le réglage reste en mémoire et
    /// revient au rétablissement.
    private var fraction: Double {
        guard !isMuted else { return 0 }
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return 0 }
        return min(max((decibels - range.lowerBound) / span, 0), 1)
    }

    private var valueText: String {
        isMuted ? "Son coupé" : PanelFormat.decibels(decibels)
    }

    var body: some View {
        ZStack(alignment: .leading) {
            track
            muteButton
        }
        .frame(height: height)
        .accessibilityElement(children: .contain)
        .animation(PanelMotion.standard(reduceMotion: reduceMotion), value: isMuted)
    }

    // MARK: Rail

    private var track: some View {
        GeometryReader { geometry in
            let travel = max(geometry.size.width - height, 1)
            let offset = travel * fraction

            ZStack(alignment: .leading) {
                Capsule().fill(PanelPalette.track)
                Capsule()
                    .fill(.white.opacity(0.92))
                    .frame(width: offset + height)
                Circle()
                    .fill(.white)
                    .shadow(color: .black.opacity(0.28), radius: 2.5, y: 0.5)
                    .overlay { Circle().strokeBorder(.black.opacity(0.05), lineWidth: 0.5) }
                    .frame(width: height, height: height)
                    .offset(x: offset)
                valueLabel(width: geometry.size.width, knobEnd: offset + height)
            }
            .contentShape(Capsule())
            .gesture(drag(travel: travel))
        }
        .overlay {
            Capsule()
                .strokeBorder(Color.accentColor, lineWidth: 2)
                .padding(-3)
                .opacity(isFocused && !isPointerFocus ? 1 : 0)
        }
        .onHover { isHovering = $0 }
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
        .accessibilityLabel("Volume master")
        .accessibilityValue(valueText)
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: adjust(by: keyStep)
            case .decrement: adjust(by: -keyStep)
            @unknown default: break
            }
        }
    }

    /// La valeur n'apparaît qu'à la main, ou tant que le son est coupé : c'est le seul moment où
    /// elle dit quelque chose. Elle se loge dans le rail vide, ou dans le remplissage s'il l'a
    /// recouvert, avec le contraste qui va chaque fois.
    private func valueLabel(width: CGFloat, knobEnd: CGFloat) -> some View {
        let room: CGFloat = 62
        let fitsInTrack = knobEnd + room < width
        return Text(valueText)
            .font(.system(size: 11, weight: .medium).monospacedDigit())
            .foregroundStyle(fitsInTrack ? AnyShapeStyle(.secondary) : AnyShapeStyle(.black.opacity(0.55)))
            .lineLimit(1)
            .frame(width: room, alignment: fitsInTrack ? .trailing : .leading)
            .offset(x: fitsInTrack ? width - room - 12 : knobEnd - height - room + 8)
            .opacity(isMuted || isHovering || isDragging || showsValue ? 1 : 0)
            .animation(PanelMotion.quick(reduceMotion: reduceMotion), value: isHovering)
            .accessibilityHidden(true)
            .allowsHitTesting(false)
    }

    private func drag(travel: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { drag in
                isDragging = true
                isPointerFocus = true
                let position = min(max(drag.location.x - height / 2, 0), travel) / travel
                let span = range.upperBound - range.lowerBound
                // Saisir le curseur, c'est vouloir entendre : un son coupé se rétablit.
                if isMuted { isMuted = false }
                decibels = range.lowerBound + position * span
            }
            .onEnded { _ in isDragging = false }
    }

    private func adjust(by delta: Double) {
        if isMuted { isMuted = false }
        decibels = min(max(decibels + delta, range.lowerBound), range.upperBound)
    }

    // MARK: Icône

    private var muteButton: some View {
        Button {
            isMuted.toggle()
        } label: {
            Group {
                if isMuted {
                    Image(systemName: "speaker.slash.fill")
                } else {
                    Image(systemName: "speaker.wave.3.fill", variableValue: fraction)
                }
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.black.opacity(0.65))
            .frame(width: height, height: height)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(isMuted ? "Rétablir le son" : "Couper le son")
        .accessibilityLabel(isMuted ? "Rétablir le son" : "Couper le son")
    }
}

// MARK: - Rangées

/// Une ligne de type menu macOS : tout est cliquable, et le survol le dit.
struct PanelMenuRowStyle: ButtonStyle {
    @State private var isHovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, PanelMetrics.margin - PanelMetrics.rowInset)
            .frame(minHeight: 26)
            .contentShape(Rectangle())
            .background {
                RoundedRectangle(cornerRadius: PanelMetrics.rowRadius - 2, style: .continuous)
                    .fill(
                        configuration.isPressed
                            ? PanelPalette.press
                            : (isHovering ? PanelPalette.hover : .clear)
                    )
            }
            .onHover { isHovering = $0 }
            .animation(PanelMotion.quick(reduceMotion: reduceMotion), value: isHovering)
    }
}

/// Une option en retrait : le libellé à gauche et l'interrupteur au bord, comme dans les Réglages
/// Système. Un `Toggle` seul collerait son interrupteur au texte, et ces lignes n'auraient plus de
/// colonne commune.
struct PanelOptionToggle: View {
    let title: String
    @Binding var isOn: Bool
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(isEnabled ? .primary : .secondary)
                .accessibilityHidden(true)
            Spacer(minLength: 4)
            Toggle(title, isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
        }
    }
}

/// Le titre discret d'une section, à la manière des menus de macOS.
struct PanelSectionTitle: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .accessibilityAddTraits(.isHeader)
    }
}

/// Le filet d'un groupe à l'autre, en retrait des bords comme ceux des menus.
struct PanelSeparator: View {
    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.1))
            .frame(height: 1)
            .padding(.horizontal, PanelMetrics.margin)
            .accessibilityHidden(true)
    }
}

// MARK: - Alertes

/// Une alerte du panneau : le titre dit ce qui se passe, le détail quoi en penser, le lien mène là où
/// ça se règle.
///
/// Une information reste neutre : « rien ne joue » n'appelle aucun geste, et la teinter ferait passer
/// un état normal pour un problème.
struct PanelNotice: View {
    let severity: CaptureAlert.Severity
    let title: String
    var detail: String?
    var actionTitle: String?
    var action: () -> Void = {}

    /// Centrée sur l'axe des pastilles, une fois retiré le retrait du fond de l'alerte.
    private static let iconColumn = PanelMetrics.pastille - 12

    var body: some View {
        // L'icône sur l'axe des pastilles, le texte sur la colonne des noms : l'alerte s'inscrit dans
        // la grille au lieu d'en ouvrir une autre.
        HStack(alignment: .firstTextBaseline, spacing: PanelMetrics.textColumn - Self.iconColumn - 6) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: Self.iconColumn)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                if let detail {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let actionTitle {
                    Button(actionTitle, action: action)
                        .buttonStyle(.link)
                        .font(.system(size: 11, weight: .medium))
                        .padding(.top, 2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 6)
        .background(background, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private var symbol: String {
        switch severity {
        case .info: "info.circle.fill"
        case .warning: "exclamationmark.circle.fill"
        case .critical: "exclamationmark.triangle.fill"
        }
    }

    private var tint: Color {
        switch severity {
        case .info: .secondary
        case .warning: .orange
        case .critical: .red
        }
    }

    private var background: Color {
        switch severity {
        case .info: PanelPalette.hover
        case .warning: Color.orange.opacity(0.14)
        case .critical: Color.red.opacity(0.14)
        }
    }
}
