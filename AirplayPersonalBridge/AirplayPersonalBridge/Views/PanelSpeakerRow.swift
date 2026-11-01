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

/// Une enceinte, comme dans le sélecteur de sortie audio de macOS : on clique n'importe où sur la
/// rangée, et elle joue.
///
/// La rangée garde sa hauteur qu'elle soit retenue ou non : le curseur vient se loger sous le nom, à
/// l'intérieur de la hauteur de la pastille. Cocher ne fait donc jamais sauter le panneau.
struct PanelSpeakerRow: View {
    @Bindable var output: OutputState
    /// Rien ne signale de silence : l'indicateur de la rangée peut bouger.
    let isAudible: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.appearsActive) private var appearsActive
    @State private var isHovering: Bool
    @State private var isAdjusting = false

    /// Plus haute que la pastille : le nom et le curseur y tiennent sans tasser le texte.
    private static let rowHeight: CGFloat = 34

    init(output: OutputState, isAudible: Bool, previewHovering: Bool = false) {
        self.output = output
        self.isAudible = isAudible
        _isHovering = State(initialValue: previewHovering)
    }

    var body: some View {
        HStack(alignment: .top, spacing: PanelMetrics.columnGap) {
            pastille
                .padding(.top, (Self.rowHeight - PanelMetrics.pastille) / 2)
                .allowsHitTesting(false)
            VStack(alignment: .leading, spacing: 1) {
                // Le nom est déjà dans le libellé du bouton : VoiceOver le dirait deux fois.
                nameLine
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
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
        .accessibilityElement(children: .contain)
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
