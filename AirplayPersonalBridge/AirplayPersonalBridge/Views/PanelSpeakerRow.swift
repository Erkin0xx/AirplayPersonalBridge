//
//  PanelSpeakerRow.swift
//  AirplayPersonalBridge
//

import AudioCore
import SwiftUI

/// Le symbole d'une enceinte, d'après ce que la découverte en rapporte : son nom et son protocole.
enum SpeakerSymbol {
    /// Le nom d'abord : c'est lui qui distingue le mieux. Faute d'indice, le protocole tranche :
    /// sur cette installation, AirPlay 2 sans appairage veut dire HomePod, et le reste retombe sur
    /// l'enceinte générique. Un appairage exigé trahit un Apple TV (`OutputCatalog.requiresPairing`).
    static func name(
        displayName: String, proto: OutputProtocol, unavailability: OutputUnavailability?
    ) -> String {
        let name = displayName.lowercased()
        if name.contains("homepod") { return "homepod.fill" }
        if name.contains("apple tv") || name.contains("appletv") { return "appletv.fill" }
        if name.contains("geneva") || name.contains("aerosphere") { return "hifispeaker.fill" }
        if unavailability == .pairingRequired { return "appletv.fill" }
        switch proto {
        case .airplay2: return "homepod.fill"
        case .raop: return "hifispeaker.fill"
        }
    }

    /// Tous ceux que `name(displayName:proto:unavailability:)` peut rendre.
    static let all = ["homepod.fill", "appletv.fill", "hifispeaker.fill"]
}

/// L'ordre du panneau : ce qui demande une intervention passe en dernier, le reste garde son ordre.
/// Une enceinte hors ligne ne descend pas : Bonjour clignote, et la liste ne doit pas bouger avec lui.
/// La liste de l'état reste intacte : c'est une présentation.
enum PanelSpeakerOrder {
    static func sorted(_ outputs: [OutputState]) -> [OutputState] {
        outputs.enumerated()
            .sorted { ($0.element.isInRetreat ? 1 : 0, $0.offset) < ($1.element.isInRetreat ? 1 : 0, $1.offset) }
            .map(\.element)
    }
}

extension OutputState {
    /// Exige une intervention : la rangée s'efface et passe en fin de liste. Une enceinte qui diffuse
    /// malgré son signalement n'en fait pas partie (`statusLine` raisonne de même).
    fileprivate var isInRetreat: Bool {
        unavailability != nil && connection != .streaming
    }

    /// Le message à afficher sous le nom, s'il dit quelque chose. « Connexion… » n'apporte rien : le
    /// témoin tournant de la rangée le dit déjà, et trois fois le même mot ne dirait que du bruit.
    fileprivate var panelMessage: (text: String, tone: OutputStatusTone)? {
        if case .connecting = connection { return nil }
        return statusLine
    }
}

/// Ce que le tiroir des basses fait d'un geste du curseur.
///
/// Hors de la vue pour être testé : c'est par ici que passe tout réglage fait dans le panneau. Il
/// n'écrit que dans `OutputState.bassBoostDB`, et c'est la boucle de `BridgeState` qui le fait suivre
/// au moteur, au plus une fois par tour et seulement sur changement : un glissement ne pousse pas un
/// réglage par pixel.
enum PanelBassControl {
    /// Le pas du curseur. Plus fin ne s'entendrait pas, et chaque pas de moins est une poussée de moins.
    static let step = 0.5
    static var range: ClosedRange<Double> { BridgeSettings.Limits.bassBoostDB }

    /// Sans effet sur une sortie qui n'a pas de renfort (`supportsBassBoost`) : les HomePod gardent
    /// une stéréo pleine bande intacte (ADR-002).
    static func set(_ value: Double, on output: OutputState) {
        guard output.supportsBassBoost else { return }
        let rounded = (value / step).rounded() * step
        output.bassBoostDB = min(max(rounded, range.lowerBound), range.upperBound)
    }

    static func reset(_ output: OutputState) {
        set(0, on: output)
    }
}

/// Une enceinte, comme dans le sélecteur de sortie audio de macOS : on clique n'importe où sur la
/// rangée, et elle joue.
///
/// La rangée garde sa hauteur qu'elle soit retenue ou non : le curseur vient se loger sous le nom, à
/// l'intérieur de la hauteur de la pastille. Cocher ne fait donc jamais sauter le panneau.
///
/// Une sortie qui a des réglages propres (aujourd'hui les basses de la Geneva) porte un chevron au
/// bout de la ligne du nom, qui déplie un tiroir sous la rangée. Le tiroir s'ouvre vers le bas, et rien
/// d'autre ne bouge : ni les colonnes, ni la ligne du nom, ni les rangées du dessus.
struct PanelSpeakerRow: View {
    @Bindable var output: OutputState
    /// Rien ne signale de silence : l'indicateur de la rangée peut bouger.
    let isAudible: Bool
    /// Une rangée au moins a un tiroir : toutes réservent la colonne du chevron, pour que leurs
    /// témoins restent l'un sous l'autre.
    let reservesDrawerColumn: Bool
    @Binding var isDrawerOpen: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.appearsActive) private var appearsActive
    @State private var isHovering: Bool
    @State private var isHoveringChevron = false
    @State private var isAdjusting = false

    /// Plus haute que la pastille : le nom et le curseur y tiennent sans tasser le texte.
    private static let rowHeight: CGFloat = 34
    /// La hauteur de la ligne du nom, à laquelle le chevron s'aligne.
    private static let nameLineHeight: CGFloat = 18
    static let drawerColumn: CGFloat = 20

    init(
        output: OutputState, isAudible: Bool, reservesDrawerColumn: Bool = false,
        isDrawerOpen: Binding<Bool> = .constant(false), previewHovering: Bool = false
    ) {
        self.output = output
        self.isAudible = isAudible
        self.reservesDrawerColumn = reservesDrawerColumn
        _isDrawerOpen = isDrawerOpen
        _isHovering = State(initialValue: previewHovering)
    }

    /// Le tiroir n'existe que pour ce qu'il sait régler, et pas sur une rangée en retrait : l'Apple TV
    /// passe en RAOP et accepterait des basses, mais elle ne jouera pas sans appairage, et son chevron
    /// ne serait que du bruit. La colonne restant réservée, il peut apparaître sans rien décaler.
    private var hasDrawer: Bool { output.supportsBassBoost && !output.isInRetreat }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            row
            // Hors de la surface de la rangée : un clic à côté du curseur ne doit pas la décocher.
            if hasDrawer, isDrawerOpen {
                PanelBassDrawer(output: output)
                    .padding(.top, 2)
                    .padding(.bottom, 4)
                    .transition(.opacity)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var row: some View {
        HStack(alignment: .top, spacing: PanelMetrics.columnGap) {
            pastille
                .padding(.top, (Self.rowHeight - PanelMetrics.pastille) / 2)
                .allowsHitTesting(false)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    // Le nom est déjà dans le libellé du bouton : VoiceOver le dirait deux fois.
                    nameLine
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                    if reservesDrawerColumn { drawerToggle }
                }
                .frame(height: Self.nameLineHeight)
                if output.isEnabled {
                    volume.transition(.opacity)
                }
                if let message = output.panelMessage {
                    PanelStatusMessage(text: message.text, tone: message.tone, isMuted: output.isInRetreat)
                }
            }
            .frame(minHeight: Self.rowHeight)
            // Un message allonge la rangée vers le bas : sans cette marge, il toucherait la suivante.
            .padding(.bottom, output.panelMessage != nil && output.isEnabled ? 5 : 0)
        }
        .padding(.horizontal, PanelMetrics.margin - PanelMetrics.rowInset)
        .padding(.vertical, 1)
        .background { toggleSurface }
        .onHover { isHovering = $0 }
        .animation(PanelMotion.quick(reduceMotion: reduceMotion), value: isHovering)
    }

    // MARK: Tiroir

    /// Le chevron du tiroir, ou sa place vide : la colonne existe sur toutes les rangées dès qu'une
    /// seule en a besoin. Il tourne sur place, comme celui des options.
    @ViewBuilder
    private var drawerToggle: some View {
        if hasDrawer {
            Button {
                withAnimation(PanelMotion.standard(reduceMotion: reduceMotion)) {
                    isDrawerOpen.toggle()
                }
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isDrawerOpen ? 90 : 0))
                    .frame(width: Self.drawerColumn, height: Self.nameLineHeight)
                    .background(
                        isHoveringChevron ? PanelPalette.press : .clear,
                        in: RoundedRectangle(cornerRadius: 5, style: .continuous)
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { isHoveringChevron = $0 }
            .help(isDrawerOpen ? "Masquer le réglage des basses" : "Régler les basses de cette enceinte")
            .accessibilityLabel("Réglage des basses de \(output.displayName)")
            .accessibilityValue(isDrawerOpen ? "déplié" : "replié")
        } else {
            Color.clear
                .frame(width: Self.drawerColumn, height: Self.nameLineHeight)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    /// Toute la rangée répond, comme dans le menu de macOS, où l'on vise un nom et pas un carré de
    /// seize points. Le bouton passe **sous** le contenu pour ne pas avaler le curseur.
    private var toggleSurface: some View {
        Button {
            withAnimation(PanelMotion.standard(reduceMotion: reduceMotion)) {
                output.isEnabled.toggle()
            }
        } label: {
            RoundedRectangle(cornerRadius: PanelMetrics.rowRadius, style: .continuous)
                .fill(isHovering ? PanelPalette.hover : .clear)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Diffuser vers \(output.displayName)")
        .accessibilityValue(accessibilityStateValue)
    }

    private var accessibilityStateValue: String {
        var parts = [output.isEnabled ? "cochée" : "décochée"]
        switch output.connection {
        case .streaming: parts.append("en diffusion")
        case .connecting: parts.append("connexion en cours")
        case .waiting: parts.append("en attente")
        case .reconnecting: parts.append("reconnexion en cours")
        case .failed: parts.append("en panne")
        case .idle: break
        }
        return parts.joined(separator: ", ")
    }

    // MARK: Pastille

    private var pastille: some View {
        Image(
            systemName: SpeakerSymbol.name(
                displayName: output.displayName, proto: output.proto,
                unavailability: output.unavailability
            )
        )
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(output.isEnabled ? Color.white : Color.primary.opacity(0.75))
        .frame(width: PanelMetrics.pastille, height: PanelMetrics.pastille)
        .background(
            output.isEnabled ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(PanelPalette.quietFill),
            in: Circle()
        )
        // Retenue mais absente du réseau, ou en attente d'une intervention : elle ne peut pas jouer,
        // et la pastille ne doit pas affirmer le contraire.
        .opacity(output.isInRetreat || output.presence == .offline ? 0.55 : 1)
        .accessibilityHidden(true)
    }

    // MARK: Nom et état

    private var nameLine: some View {
        HStack(spacing: 6) {
            Text(output.displayName)
                .font(.system(size: 13))
                .foregroundStyle(output.isInRetreat ? .secondary : .primary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            if output.isEnabled, isHovering || isAdjusting {
                Text(PanelFormat.decibels(output.trimDB, fractionDigits: 1, signed: true))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .transition(.opacity)
                    .accessibilityHidden(true)
            }
            stateIndicator
                .frame(width: 16, height: 16)
        }
        .frame(height: 18)
    }

    @ViewBuilder
    private var stateIndicator: some View {
        switch output.connection {
        case .connecting, .waiting, .reconnecting:
            ProgressView()
                .controlSize(.mini)
                .accessibilityHidden(true)
        case .failed:
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 13))
                .foregroundStyle(.red)
                .accessibilityHidden(true)
        case .streaming where output.isEnabled && isAudible:
            // Elle reçoit, et un son passe : le seul cas où l'indicateur a le droit de bouger.
            Image(systemName: "waveform")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .symbolEffect(.variableColor.iterative, isActive: !reduceMotion && appearsActive)
                .accessibilityHidden(true)
        case .idle, .streaming:
            if output.isEnabled {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .accessibilityHidden(true)
            }
        }
    }

    // MARK: Volume

    /// Un curseur système, en petit : il reste secondaire, et le clavier comme VoiceOver y sont gratuits.
    ///
    /// La valeur est arrondie à la main plutôt que par `step:`, qui ferait dessiner des graduations à
    /// macOS sur ce rail de quelques points.
    private var volume: some View {
        Slider(
            value: Binding(
                get: { output.trimDB },
                set: { output.trimDB = ($0 * 2).rounded() / 2 }
            ),
            in: BridgeSettings.Limits.trimDB,
            onEditingChanged: { isAdjusting = $0 }
        ) {
            Text("Volume de \(output.displayName)")
        }
        .labelsHidden()
        .controlSize(.mini)
        .tint(.secondary)
        .help("Volume de cette enceinte, en plus du volume master")
        .accessibilityValue(PanelFormat.decibels(output.trimDB, fractionDigits: 1, signed: true))
    }
}

/// Le tiroir d'une enceinte : ses basses, de 0 à +12 dB (plateau grave à 80 Hz, limiteur compris,
/// ADR-002).
///
/// Une rangée en miniature, sur la même grille : le symbole sur l'axe des pastilles, le libellé et la
/// valeur sur la ligne du nom, le curseur dessous, à la largeur de celui du volume. Il agit que la
/// sortie soit cochée ou non : décochée, elle partira avec ce réglage.
struct PanelBassDrawer: View {
    @Bindable var output: OutputState

    static let symbol = "slider.vertical.3"
    static let resetSymbol = "arrow.counterclockwise"

    private var valueText: String {
        PanelFormat.decibels(output.bassBoostDB, fractionDigits: 1, signed: true)
    }

    var body: some View {
        HStack(alignment: .top, spacing: PanelMetrics.columnGap) {
            Image(systemName: Self.symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: PanelMetrics.pastille, height: 18)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text("Basses")
                        .font(.system(size: 12))
                        .accessibilityHidden(true)
                    Spacer(minLength: 4)
                    Text(valueText)
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    // La flèche dit « revenir à » : sans elle, « 0 dB » à côté de la valeur se lirait
                    // comme une seconde valeur.
                    Button {
                        PanelBassControl.reset(output)
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: Self.resetSymbol).font(.system(size: 9, weight: .semibold))
                            Text("0 dB")
                        }
                    }
                    .buttonStyle(PanelChipButtonStyle())
                    .disabled(output.bassBoostDB == 0)
                    .help("Remettre les basses à 0 dB")
                    .accessibilityLabel("Remettre les basses de \(output.displayName) à 0 dB")
                }
                .frame(height: 18)
                slider
            }
        }
        .padding(.horizontal, PanelMetrics.margin - PanelMetrics.rowInset)
        .padding(.vertical, 6)
        .background(
            PanelPalette.tray,
            in: RoundedRectangle(cornerRadius: PanelMetrics.rowRadius, style: .continuous)
        )
        .accessibilityElement(children: .contain)
    }

    /// Le même curseur que celui du volume, au même pas arrondi à la main (voir `PanelSpeakerRow`).
    private var slider: some View {
        Slider(
            value: Binding(
                get: { output.bassBoostDB },
                set: { PanelBassControl.set($0, on: output) }
            ),
            in: PanelBassControl.range
        ) {
            Text("Basses de \(output.displayName)")
        }
        .labelsHidden()
        .controlSize(.mini)
        .tint(.secondary)
        .help("Renfort des graves sous 80 Hz, pour cette enceinte seulement")
        .accessibilityValue(valueText)
    }
}

/// Le message d'une enceinte, tel que le moteur le rédige.
///
/// Ces messages disent quoi faire, et certains font plusieurs phrases. Repliés, ils gardent la liste
/// lisible ; un lien les déplie, pour qu'une coupure ne passe jamais pour la fin du message.
private struct PanelStatusMessage: View {
    let text: String
    let tone: OutputStatusTone
    /// La rangée est en retrait : même un avertissement n'y appelle pas le regard.
    let isMuted: Bool
    @State private var isExpanded = false

    /// Ce qui tient en deux lignes dans la colonne de texte.
    private let foldedLength = 86

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(color)
                .lineLimit(isExpanded ? nil : 2)
                .truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(text)
            if text.count > foldedLength {
                Button(isExpanded ? "Réduire" : "Lire la suite") { isExpanded.toggle() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var color: Color {
        if isMuted { return .secondary }
        switch tone {
        case .muted: return .secondary
        case .warning: return PanelPalette.warningText
        case .critical: return PanelPalette.criticalText
        }
    }
}
