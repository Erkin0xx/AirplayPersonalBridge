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
    /// Le rayon du panneau, déclaré comme forme de conteneur : les surbrillances proches de ses coins
    /// en dérivent (`ConcentricRectangle`).
    static let panelRadius: CGFloat = 16
    /// Concentrique au panneau : 16 − 6 de retrait.
    static let rowRadius: CGFloat = panelRadius - rowInset
    static let pastille: CGFloat = 28
    static let columnGap: CGFloat = 10
    /// Le bord gauche des textes, depuis la marge.
    static let textColumn: CGFloat = pastille + columnGap
    /// Du bord du panneau à la carte d'une fenêtre surgissante (`PanelPopup`).
    static let popupInset: CGFloat = 8
    static let popupRadius: CGFloat = 14
    /// La hauteur de la pointe qui relie la carte à sa rangée.
    static let popupBeak: CGFloat = 7
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
    /// Le remplissage du master pendant le silence : un gris, là où il est blanc en temps normal.
    static let silencedFill = Color.primary.opacity(0.16)
    /// Le fond d'un tiroir déplié sous une rangée : plus discret que le survol, qu'il ne doit pas imiter.
    static let tray = Color.primary.opacity(0.05)

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

    /// Pour une carte qui surgit : un ressort, à peine rebondi.
    static func popup(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .spring(duration: 0.3, bounce: 0.22)
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
            .font(.callout.weight(.medium))
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

/// Le curseur épais du Centre de contrôle, l'icône à l'intérieur.
///
/// Écrit à la main, un `Slider` macOS ne se laissant pas épaissir. Ce qu'on perd en quittant le
/// contrôle système est donc rétabli explicitement : flèches du clavier, VoiceOver, anneau de focus.
///
/// La valeur reste linéaire en dB, comme celle du curseur de la fenêtre : les deux bougent ensemble.
///
/// Le silence se commande d'abord par `PanelMuteButton`, à côté : un clic sur l'icône du curseur le
/// faisait déjà, mais rien ne disait qu'on pouvait cliquer là, et Baptiste ne l'avait pas vu. Ce clic
/// reste un raccourci à la souris, sans doubler le bouton pour VoiceOver ni pour le clavier.
struct PanelVolumeSlider: View {
    @Binding var decibels: Double
    @Binding var isMuted: Bool
    let range: ClosedRange<Double>
    /// Pour le rendu hors écran, où le survol n'existe pas.
    var showsValue = false
    /// La matière : celle du panneau, ou la coque noire de la vue Console. Les gestes, le clavier et
    /// VoiceOver sont les mêmes.
    var look: ControlLook = .panel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var isFocused: Bool
    @State private var isHovering = false
    @State private var isDragging = false
    /// Le clic donne aussi le focus, mais l'anneau n'a de sens que pour qui navigue au clavier.
    @State private var isPointerFocus = false

    private let height = PanelMetrics.pastille
    private let keyStep = 1.5

    /// Coupé, le curseur reste où il était, éteint : c'est ce niveau-là que le rétablissement rendra,
    /// et le voir évite de se demander s'il a été perdu. Le bouton de la fenêtre fait de même.
    private var fraction: Double {
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
                switch look {
                case .panel:
                    Capsule().fill(PanelPalette.track)
                    Capsule()
                        .fill(isMuted ? AnyShapeStyle(PanelPalette.silencedFill) : AnyShapeStyle(.white.opacity(0.92)))
                        .frame(width: offset + height)
                    Circle()
                        .fill(.white)
                        .shadow(color: .black.opacity(0.28), radius: 2.5, y: 0.5)
                        .overlay { Circle().strokeBorder(.black.opacity(0.05), lineWidth: 0.5) }
                        .frame(width: height, height: height)
                        .offset(x: offset)
                case .darkshell:
                    DarkshellBar(
                        knobOffset: offset, knob: height, width: geometry.size.width, isSilenced: isMuted,
                        isLit: isHovering || isDragging, symbol: glyph
                    )
                }
                valueLabel(width: geometry.size.width, knobEnd: offset + height)
            }
            .contentShape(Capsule())
            .gesture(drag(travel: travel))
        }
        .overlay {
            Capsule()
                // Dans la console, pas de rose sur une commande : l'anneau y est blanc.
                .strokeBorder(look == .darkshell ? Color.white.opacity(0.9) : BridgeTheme.accent, lineWidth: 2)
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
        // Le remplissage du silence est gris : le secondaire s'y lit, en clair comme en sombre.
        // La coque noire n'a pas de remplissage clair : sur le voile, le texte reste clair.
        let onLightFill = !fitsInTrack && !isMuted && look == .panel
        // Un curseur très court (la barre de lecture d'une petite fenêtre) n'a de place ni dans le rail
        // ni dans le remplissage : la valeur déborderait sur ce qui précède le curseur.
        let fitsSomewhere = fitsInTrack || knobEnd - height - room + 8 >= 0
        return Text(valueText)
            .font(.subheadline.weight(.medium).monospacedDigit())
            .foregroundStyle(onLightFill ? AnyShapeStyle(.black.opacity(0.55)) : AnyShapeStyle(.secondary))
            .lineLimit(1)
            .frame(width: room, alignment: fitsInTrack ? .trailing : .leading)
            .offset(x: fitsInTrack ? width - room - 12 : knobEnd - height - room + 8)
            .opacity(fitsSomewhere && (isMuted || isHovering || isDragging || showsValue) ? 1 : 0)
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

    /// Un bouton plutôt qu'un dessin : sans lui, un clic sur l'icône tomberait sur le rail et mettrait
    /// le master au minimum, perdant le niveau que le silence devait garder. Caché à VoiceOver et hors
    /// du parcours au clavier, où `PanelMuteButton` tient ce rôle avec un libellé explicite.
    private var glyph: Image {
        isMuted
            ? Image(systemName: PanelMuteButton.symbol)
            : Image(systemName: "speaker.wave.3.fill", variableValue: fraction)
    }

    private var muteButton: some View {
        Button {
            isMuted.toggle()
        } label: {
            glyph
                .font(.callout.weight(.medium))
                // Coupé, l'icône se pose sur le remplissage gris et non plus sur le blanc du curseur.
                .foregroundStyle(isMuted ? AnyShapeStyle(.secondary) : AnyShapeStyle(.black.opacity(0.65)))
                .frame(width: height, height: height)
                // Dans la coque noire, c'est le rail qui dessine l'icône, claire ou sombre selon ce qu'elle
                // recouvre : le bouton ne garde que sa surface.
                .opacity(look == .darkshell ? 0 : 1)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .help(isMuted ? "Rétablir le son des enceintes" : "Couper le son des enceintes")
        .accessibilityHidden(true)
    }
}

/// Le silence des enceintes, en bouton à part, au bout du curseur master.
///
/// Il ne joue que sur le volume envoyé (`BridgeState.isMuted`, −144 dB sur le fil) : les sessions
/// restent ouvertes, et rétablir le son rend aussitôt le niveau d'avant. **À ne pas confondre avec
/// « Couper le son du Mac »**, qui éteint la sortie de ce Mac pendant que les enceintes jouent : d'où
/// le complément des enceintes dans le libellé, et jamais un « Couper le son » tout court.
///
/// L'icône ne change pas d'un état à l'autre : elle dit ce que fait le bouton, et c'est le fond qui dit
/// s'il est enclenché, comme les commandes du Centre de contrôle.
struct PanelMuteButton: View {
    @Binding var isMuted: Bool
    /// La matière : celle du panneau, ou la coque noire de la vue Console.
    var look: ControlLook = .panel

    static let symbol = "speaker.slash.fill"
    static let title = "Couper le son des enceintes"

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    var body: some View {
        Button {
            isMuted.toggle()
        } label: {
            Image(systemName: Self.symbol)
                .font(.callout.weight(.semibold))
                .foregroundStyle(foreground)
                .frame(width: PanelMetrics.pastille, height: PanelMetrics.pastille)
                .background {
                    switch look {
                    case .panel: Circle().fill(background)
                    case .darkshell: DarkshellDisc(isOn: isMuted, isHovering: isHovering)
                    }
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(PanelMotion.quick(reduceMotion: reduceMotion), value: isHovering)
        .animation(PanelMotion.standard(reduceMotion: reduceMotion), value: isMuted)
        .help(isMuted ? "Rétablir le son des enceintes" : "\(Self.title), sans les déconnecter")
        .accessibilityLabel(Self.title)
        .accessibilityValue(isMuted ? "activé" : "désactivé")
        .accessibilityHint("Les enceintes restent connectées.")
        .accessibilityAddTraits(.isToggle)
    }

    /// Enclenché dans la console : un disque blanc, donc une icône sombre.
    private var foreground: Color {
        switch look {
        case .panel: isMuted ? Color.white : Color.primary.opacity(0.75)
        case .darkshell: isMuted ? Color.black.opacity(0.85) : Color.white.opacity(0.9)
        }
    }

    private var background: AnyShapeStyle {
        if isMuted { return AnyShapeStyle(BridgeTheme.accent) }
        return AnyShapeStyle(isHovering ? PanelPalette.press : PanelPalette.quietFill)
    }
}

// MARK: - Rangées

/// Une ligne de type menu macOS : tout est cliquable, et le survol le dit.
struct PanelMenuRowStyle: ButtonStyle {
    /// La rangée garde sa surbrillance tant que ce qu'elle a ouvert est à l'écran.
    var isActive = false
    @State private var isHovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, PanelMetrics.margin - PanelMetrics.rowInset)
            .frame(minHeight: 26)
            .contentShape(Rectangle())
            .background {
                // Au milieu du panneau, le rayon minimal ; contre ses coins (« Quitter », tout en bas), le
                // rayon concentrique au panneau, comme la surbrillance des menus de macOS 26.
                ConcentricRectangle(corners: .concentric(minimum: .fixed(PanelMetrics.rowRadius - 2)))
                    .fill(
                        configuration.isPressed
                            ? PanelPalette.press
                            : (isHovering || isActive ? PanelPalette.hover : .clear)
                    )
            }
            .onHover { isHovering = $0 }
            .animation(PanelMotion.quick(reduceMotion: reduceMotion), value: isHovering)
            .animation(PanelMotion.quick(reduceMotion: reduceMotion), value: isActive)
    }
}

/// Une option en retrait : le libellé à gauche et l'interrupteur au bord, comme dans les Réglages
/// Système. Un `Toggle` seul collerait son interrupteur au texte, et ces lignes n'auraient plus de
/// colonne commune.
struct PanelOptionToggle: View {
    let title: String
    /// Une précision sous le libellé, quand il pourrait se confondre avec une autre commande.
    var detail: String?
    /// Ce que VoiceOver annonce, quand le libellé visible se lit mal à voix haute.
    var accessibilityTitle: String?
    @Binding var isOn: Bool
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.callout)
                    .foregroundStyle(isEnabled ? .primary : .secondary)
                if let detail {
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            // La barre latérale de la fenêtre limite ses rangées à une ligne : un détail tronqué ne dit plus
            // quand l'option est sans effet. Toute la largeur, et non un `Spacer`, pour la même raison.
            .lineLimit(nil)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityHidden(true)
            Toggle(accessibilityTitle ?? title, isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .accessibilityHint(detail ?? "")
        }
    }
}

/// Un petit bouton en pastille, pour une action secondaire logée dans une ligne de réglage.
struct PanelChipButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.medium).monospacedDigit())
            .foregroundStyle(isEnabled ? .primary : .tertiary)
            .padding(.horizontal, 7)
            .frame(height: 18)
            .background(
                configuration.isPressed || (isHovering && isEnabled)
                    ? PanelPalette.press : PanelPalette.quietFill,
                in: Capsule()
            )
            .contentShape(Capsule())
            .onHover { isHovering = $0 }
            .animation(PanelMotion.quick(reduceMotion: reduceMotion), value: isHovering)
    }
}

/// Le titre discret d'une section, à la manière des menus de macOS.
struct PanelSectionTitle: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            .accessibilityAddTraits(.isHeader)
    }
}

/// Le filet d'un groupe à l'autre, en retrait des bords comme ceux des menus.
struct PanelSeparator: View {
    var body: some View {
        Divider()
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
                .font(.body.weight(.medium))
                .foregroundStyle(tint)
                .frame(width: Self.iconColumn)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                if let detail {
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let actionTitle {
                    Button(actionTitle, action: action)
                        .buttonStyle(.link)
                        .font(.subheadline.weight(.medium))
                        .padding(.top, 2)
                }
            }
            // La barre latérale de la fenêtre limite ses rangées à une ligne : un message tronqué ne dit plus
            // quoi faire. Toute la largeur, et non un `Spacer`, pour la même raison.
            .lineLimit(nil)
            .frame(maxWidth: .infinity, alignment: .leading)
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
