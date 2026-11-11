//
//  ConsoleTiles.swift
//  AirplayPersonalBridge
//

import SwiftUI

// MARK: - Enceinte

/// Une enceinte, en tuile : sa pastille qui la coche, son nom et son état, son curseur, puis son silence
/// et ses réglages.
///
/// Décochée, la tuile garde son curseur, éteint : la console ne change pas de forme quand on coche une
/// enceinte. Une enceinte qui exige une intervention n'a pas de curseur du tout : sa tuile dit pourquoi.
struct ConsoleSpeakerTile: View {
    @Bindable var output: OutputState
    let effectiveGainDB: Double
    var listeningCompensationMS: Double?
    var listeningPlaceName: String?
    /// Les autres membres de sa paire stéréo (`BridgeState.stereoPartners(of:)`).
    var stereoPartnerNames: [String] = []
    /// Rien ne signale de silence : le témoin de diffusion peut bouger.
    var isAudible = true
    /// Une fenêtre basse (`ConsoleLayout.compactTiles`) : l'en-tête tient en deux lignes courtes, le niveau
    /// passe entre les deux boutons, et le curseur garde toute la hauteur qui reste.
    var isCompact = false
    /// Le clic sur l'en-tête : `BridgeState.toggleEnabled(_:)`, qui emmène la paire stéréo.
    var toggle: () -> Void
    /// « Masquer » : au clic droit, et par l'œil barré qui apparaît au survol. Emmène la paire stéréo.
    var hide: (() -> Void)?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.revealsHoverControls) private var revealsHoverControls
    @State private var isHovering = false
    @State private var showsSettings = false

    private var caption: (text: String, tone: OutputStatusTone) {
        ConsoleTileCaption.make(
            connection: output.connection, isEnabled: output.isEnabled, isMuted: output.isMuted,
            proto: output.proto.rawValue, statusLine: output.statusLine
        )
    }

    private var trimText: String {
        PanelFormat.decibels(output.trimDB, fractionDigits: 1, signed: true)
    }

    var body: some View {
        VStack(spacing: isCompact ? 8 : 10) {
            header
            if output.consoleIsHeldBack {
                heldBackMessage
            } else {
                fader
                if !isCompact { trimLabel }
                buttons
            }
        }
        .padding(isCompact ? 12 : ConsoleMetrics.tilePadding)
        .frame(width: ConsoleMetrics.speakerWidth)
        .frame(maxHeight: .infinity)
        .modifier(ConsoleTileSurface(isHeldBack: output.consoleIsHeldBack))
        // Dans le coin, par-dessus : la tuile ne change pas de forme au survol, et celle d'une enceinte en
        // retrait, qui n'a pas de boutons, l'a aussi.
        .overlay(alignment: .topTrailing) {
            if let hide, isHovering || revealsHoverControls {
                HideSpeakerButton(
                    name: output.displayName, partners: stereoPartnerNames, isEnabled: output.isEnabled,
                    diameter: 24, isFilled: true, action: hide
                )
                .padding(7)
                .transition(.opacity)
            }
        }
        .onHover { isHovering = $0 }
        .animation(PanelMotion.quick(reduceMotion: reduceMotion), value: isHovering)
        .animation(PanelMotion.standard(reduceMotion: reduceMotion), value: output.isEnabled)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(output.displayName)
        .hideSpeakerMenu(partners: stereoPartnerNames, action: hide)
    }

    private var trimLabel: some View {
        Text(trimText)
            .font(.system(size: isCompact ? 12 : 13, weight: .medium).monospacedDigit())
            .foregroundStyle(output.isEnabled && !output.isMuted ? .primary : .secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .contentTransition(.numericText())
            .accessibilityHidden(true)
    }

    // MARK: En-tête

    private var header: some View {
        Button {
            withAnimation(PanelMotion.standard(reduceMotion: reduceMotion)) { toggle() }
        } label: {
            // Tout part du haut : les noms sont sur la même ligne d'une tuile à l'autre, qu'elle en ait
            // deux ou trois.
            HStack(alignment: .top, spacing: isCompact ? 8 : 10) {
                badge
                VStack(alignment: .leading, spacing: 1) {
                    // Sans paire à nommer, la troisième ligne revient au nom : « Apple TV Salon » y tient.
                    Text(output.displayName)
                        .font(.system(size: isCompact ? 13.5 : 15, weight: .semibold))
                        .foregroundStyle(output.consoleIsHeldBack || !output.isEnabled ? .secondary : .primary)
                        .lineLimit(pair == nil && !isCompact ? 2 : 1)
                        .minimumScaleFactor(0.85)
                        .truncationMode(.tail)
                    HStack(spacing: 4) {
                        indicator
                        Text(caption.text)
                            .foregroundStyle(caption.tone.consoleColor)
                    }
                    .font(.system(size: isCompact ? 11.5 : 12.5))
                    .lineLimit(1)
                    if let pair, !isCompact {
                        Label(pair, systemImage: "link")
                            .labelStyle(ConsolePairLabelStyle())
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
                .multilineTextAlignment(.leading)
                .padding(.top, isCompact ? 0 : 2)
                Spacer(minLength: 0)
            }
            .frame(height: isCompact ? ConsoleMetrics.compactTileHeader : ConsoleMetrics.tileHeader, alignment: .top)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(PanelStereoPair.help(partners: stereoPartnerNames) ?? toggleHelp)
        .accessibilityLabel("Diffuser vers \(output.displayName)")
        .accessibilityValue(accessibilityState)
        .accessibilityHint(PanelStereoPair.accessibilityHint(partners: stereoPartnerNames) ?? "")
        .accessibilityAddTraits(.isToggle)
    }

    /// L'autre enceinte de sa paire stéréo, s'il y en a une.
    private var pair: String? { StereoPairs.names(stereoPartnerNames) }

    private var toggleHelp: String {
        output.isEnabled ? "Retirer cette enceinte de la diffusion" : "Diffuser vers cette enceinte"
    }

    private var accessibilityState: String {
        guard output.isEnabled else { return "décochée" }
        let pair = PanelStereoPair.accessibilityWords(partners: stereoPartnerNames)
        return (["cochée", caption.text] + [pair].compactMap { $0 }).joined(separator: ", ")
    }

    /// Blanche quand elle est cochée, comme les pastilles du halo : la couleur reste au curseur.
    private var badge: some View {
        Image(
            systemName: SpeakerSymbol.name(
                displayName: output.displayName, proto: output.proto, unavailability: output.unavailability
            )
        )
        .font(.system(size: isCompact ? 14 : 17, weight: .medium))
        .foregroundStyle(output.isEnabled ? Color.black.opacity(0.82) : Color.white.opacity(0.7))
        .frame(
            width: isCompact ? ConsoleMetrics.compactBadge : ConsoleMetrics.badge,
            height: isCompact ? ConsoleMetrics.compactBadge : ConsoleMetrics.badge
        )
        .background(output.isEnabled ? Color.white : Color.white.opacity(0.12), in: Circle())
        // Retenue mais absente du réseau, ou en attente d'une intervention : elle ne peut pas jouer, et
        // la pastille ne doit pas affirmer le contraire.
        .opacity(output.consoleIsHeldBack || output.presence == .offline ? 0.55 : 1)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var indicator: some View {
        switch ConsoleTileIndicator.kind(
            connection: output.connection, isEnabled: output.isEnabled, isMuted: output.isMuted,
            isAudible: isAudible
        ) {
        case .live:
            ConsoleLiveBars()
        case .busy:
            ProgressView()
                .controlSize(.mini)
                .accessibilityHidden(true)
        case .failed:
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(PanelPalette.criticalText)
                .accessibilityHidden(true)
        case .none:
            EmptyView()
        }
    }

    // MARK: Curseur et boutons

    /// Coupée, elle reste dans la diffusion et son curseur reste là, grisé ; décochée, il s'éteint.
    private var fader: some View {
        ConsoleFader(
            value: Binding(get: { output.trimDB }, set: { output.trimDB = $0 }),
            range: BridgeSettings.Limits.trimDB, step: PanelToneStep.step, keyStep: PanelToneStep.step,
            isSilenced: output.isMuted || !output.isEnabled, mark: 0,
            label: "Volume de \(output.displayName)", valueText: trimText
        )
        .contextMenu {
            Button("Revenir à \(PanelFormat.decibels(0))") { output.trimDB = 0 }
        }
        .disabled(output.isMuted || !output.isEnabled)
        .opacity(output.isEnabled ? 1 : 0.45)
        .help(
            output.isEnabled
                ? PanelSpeakerMute.sliderHelp(for: output)
                : "Coche cette enceinte pour régler son volume"
        )
    }

    private var buttons: some View {
        HStack(spacing: isCompact ? 2 : 8) {
            ConsoleRoundButton(
                symbol: PanelSpeakerMuteButton.symbol, isOn: output.isEnabled && output.isMuted,
                diameter: isCompact ? ConsoleMetrics.compactRoundButton : ConsoleMetrics.roundButton
            ) {
                PanelSpeakerMute.toggle(output)
            }
            // Décochée, elle ne joue pas : couper son son ne voudrait rien dire.
            .disabled(!output.isEnabled)
            .help(
                output.isMuted
                    ? "Rétablir le son de cette enceinte"
                    : "Couper cette enceinte seule, sans la déconnecter"
            )
            .accessibilityLabel(PanelSpeakerMute.accessibilityLabel(for: output))
            .accessibilityValue(PanelSpeakerMute.accessibilityValue(for: output))
            .accessibilityHint("L'enceinte reste connectée, et les autres continuent de jouer.")
            .accessibilityAddTraits(.isToggle)

            // Le niveau, que la tuile simplifiée n'a plus la place de poser sur sa propre ligne.
            if isCompact { trimLabel.frame(maxWidth: .infinity) }

            ConsoleRoundButton(
                symbol: "slider.horizontal.3", isOn: showsSettings,
                diameter: isCompact ? ConsoleMetrics.compactRoundButton : ConsoleMetrics.roundButton
            ) {
                showsSettings.toggle()
            }
            .help("Réglages de \(output.displayName) : délai, tonalité, adresse")
            .accessibilityLabel("Réglages de \(output.displayName)")
            .popover(isPresented: $showsSettings, arrowEdge: .trailing) {
                SpeakerSettings(
                    output: output, effectiveGainDB: effectiveGainDB,
                    listeningCompensationMS: listeningCompensationMS, listeningPlaceName: listeningPlaceName,
                    stereoPartnerNames: stereoPartnerNames
                )
            }
        }
    }

    // MARK: En retrait

    /// À la place du curseur : pourquoi elle ne jouera pas sans intervention.
    private var heldBackMessage: some View {
        let message = output.statusLine?.text ?? output.unavailability?.rawValue ?? ""
        return VStack(spacing: 8) {
            Image(systemName: ConsoleHeldBack.symbol(for: output.unavailability))
                .font(.system(size: 22, weight: .regular))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(isCompact ? 4 : 6)
                .fixedSize(horizontal: false, vertical: true)
                .help(message)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Ce que montre une tuile en retrait.
enum ConsoleHeldBack {
    /// Un cadenas pour ce qui se débloque (appairage, mot de passe), un panneau pour ce que l'app ne sait
    /// pas faire.
    static func symbol(for unavailability: OutputUnavailability?) -> String {
        switch unavailability {
        case .pairingRequired, .passwordRequired: "lock"
        case .unsupportedEncryption, .unsupportedFormat, .none: "exclamationmark.triangle"
        }
    }
}

/// La paire stéréo sous l'état : un maillon, puis le nom de l'autre enceinte.
private struct ConsolePairLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) {
            configuration.icon.imageScale(.small)
            configuration.title
        }
    }
}

/// Le fond d'une tuile : du verre, ou un cadre en pointillé pour celle qui est en retrait.
struct ConsoleTileSurface: ViewModifier {
    let isHeldBack: Bool

    func body(content: Content) -> some View {
        if isHeldBack {
            content
                .background(Color.white.opacity(0.04), in: ConsoleMetrics.tileShape)
                .overlay {
                    ConsoleMetrics.tileShape
                        .strokeBorder(Color.white.opacity(0.26), style: StrokeStyle(lineWidth: 1, dash: [5, 5]))
                }
                .opacity(0.8)
        } else {
            content.floatingGlass(in: ConsoleMetrics.tileShape)
        }
    }
}
