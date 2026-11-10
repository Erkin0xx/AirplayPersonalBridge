//
//  SpeakerCard.swift
//  AirplayPersonalBridge
//

import SwiftUI

/// Les mesures de la fenêtre : une seule grille pour l'en-tête et les cartes d'enceintes.
///
/// Les pastilles partagent un axe, les textes un bord, et le rayon des cartes est concentrique à celui de
/// leurs pastilles : c'est ce qui fait d'une pile de cartes un seul objet, comme dans le panneau.
enum WindowMetrics {
    /// Du bord de la barre latérale aux cartes.
    static let margin: CGFloat = 12
    /// Du bord d'une carte à son contenu.
    static let cardPadding: CGFloat = 12
    static let cardRadius: CGFloat = 16
    static let cardSpacing: CGFloat = 8
    /// La pastille d'une enceinte, et celle de l'état en plus grand.
    static let pastille: CGFloat = 36
    static let heroPastille: CGFloat = 44
    static let columnGap: CGFloat = 12
    /// Le bord gauche des textes d'une carte, depuis son contenu.
    static let textColumn = pastille + columnGap
}

extension View {
    /// Le fond d'une carte de la barre latérale : un voile sur le verre, jamais un second verre. Empiler
    /// du verre sur du verre brouille les deux ; un voile laisse la barre latérale rester le matériau.
    func windowCard(isRaised: Bool = true) -> some View {
        background(
            Color.primary.opacity(isRaised ? 0.06 : 0.03),
            in: RoundedRectangle(cornerRadius: WindowMetrics.cardRadius, style: .continuous)
        )
    }
}

extension OutputState {
    /// Exige une intervention : la carte s'efface, comme la rangée du panneau.
    fileprivate var isHeldBack: Bool {
        unavailability != nil && connection != .streaming
    }

    /// Le message sous le nom, s'il dit quelque chose. « Connexion… » n'apporte rien : le témoin de la
    /// carte le dit déjà.
    fileprivate var cardMessage: (text: String, tone: OutputStatusTone)? {
        if case .connecting = connection { return nil }
        return statusLine
    }
}

/// Ce que la carte dit de l'état d'une enceinte, en mots : hors de la vue pour être testé.
enum SpeakerCardCaption {
    /// L'état d'abord, puis la paire stéréo ; décochée, elle dit seulement ce qu'elle est.
    static func text(
        connection: OutputConnectionState, isEnabled: Bool, isMuted: Bool, proto: String,
        partners: [String]
    ) -> String {
        var parts: [String] = []
        if isEnabled {
            switch connection {
            case .streaming: parts.append(isMuted ? "Coupée" : "Diffusion")
            case .connecting: parts.append("Connexion…")
            case .waiting: parts.append("En attente")
            case .reconnecting: parts.append("Reconnexion…")
            case .failed: parts.append("Échec")
            case .idle: parts.append("Prête")
            }
        } else {
            parts.append(proto)
        }
        if let pair = PanelStereoPair.legend(partners: partners) { parts.append(pair) }
        return parts.joined(separator: " · ")
    }
}

/// Une enceinte, en carte : sa pastille qui la coche, son nom et son état, puis son volume.
///
/// La carte ne montre que ce qu'on règle en écoutant. Le délai, la tonalité et l'adresse sont un clic plus
/// loin, dans une fenêtre surgissante : ils se règlent une fois, et n'ont pas à tenir tête au volume à
/// chaque regard. Décochée, la carte se réduit à son nom.
struct SpeakerCard: View {
    @Bindable var output: OutputState
    let effectiveGainDB: Double
    var listeningCompensationMS: Double?
    var listeningPlaceName: String?
    /// Les autres membres de sa paire stéréo (`BridgeState.stereoPartners(of:)`).
    var stereoPartnerNames: [String] = []
    /// Rien ne signale de silence : le témoin de diffusion peut bouger.
    var isAudible = true
    /// Le clic sur l'en-tête : `BridgeState.toggleEnabled(_:)`, qui emmène la paire stéréo.
    var toggle: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.appearsActive) private var appearsActive
    @State private var isHovering = false
    @State private var isAdjusting = false
    @State private var showsSettings: Bool

    init(
        output: OutputState, effectiveGainDB: Double, listeningCompensationMS: Double? = nil,
        listeningPlaceName: String? = nil, stereoPartnerNames: [String] = [], isAudible: Bool = true,
        previewShowsSettings: Bool = false, toggle: @escaping () -> Void
    ) {
        self.output = output
        self.effectiveGainDB = effectiveGainDB
        self.listeningCompensationMS = listeningCompensationMS
        self.listeningPlaceName = listeningPlaceName
        self.stereoPartnerNames = stereoPartnerNames
        self.isAudible = isAudible
        self.toggle = toggle
        _showsSettings = State(initialValue: previewShowsSettings)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if output.isEnabled {
                volume
                    .padding(.leading, WindowMetrics.textColumn)
                    .transition(.opacity)
            }
            if let message = output.cardMessage {
                OutputStatusMessage(text: message.text, tone: message.tone, isMuted: output.isHeldBack)
                    .padding(.leading, WindowMetrics.textColumn)
            }
        }
        .padding(WindowMetrics.cardPadding)
        .windowCard(isRaised: output.isEnabled)
        .overlay {
            RoundedRectangle(cornerRadius: WindowMetrics.cardRadius, style: .continuous)
                .strokeBorder(Color.primary.opacity(isHovering ? 0.10 : 0), lineWidth: 1)
        }
        .onHover { isHovering = $0 }
        .animation(PanelMotion.quick(reduceMotion: reduceMotion), value: isHovering)
        .accessibilityElement(children: .contain)
    }

    // MARK: - En-tête

    private var header: some View {
        HStack(spacing: 6) {
            Button {
                withAnimation(PanelMotion.standard(reduceMotion: reduceMotion)) { toggle() }
            } label: {
                HStack(spacing: WindowMetrics.columnGap) {
                    pastille
                    VStack(alignment: .leading, spacing: 1) {
                        Text(output.displayName)
                            .font(.body.weight(.medium))
                            .foregroundStyle(output.isHeldBack || !output.isEnabled ? .secondary : .primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(caption)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    Spacer(minLength: 4)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(PanelStereoPair.help(partners: stereoPartnerNames) ?? toggleHelp)
            .accessibilityLabel("Diffuser vers \(output.displayName)")
            .accessibilityValue(output.isEnabled ? "cochée, \(caption)" : "décochée")
            .accessibilityHint(PanelStereoPair.accessibilityHint(partners: stereoPartnerNames) ?? "")
            .accessibilityAddTraits(.isToggle)

            stateIndicator
                .frame(width: 18, height: 18)
            if !output.isHeldBack {
                settingsButton
            }
        }
    }

    private var toggleHelp: String {
        output.isEnabled ? "Retirer cette enceinte de la diffusion" : "Diffuser vers cette enceinte"
    }

    private var caption: String {
        SpeakerCardCaption.text(
            connection: output.connection, isEnabled: output.isEnabled, isMuted: output.isMuted,
            proto: output.proto.rawValue, partners: stereoPartnerNames
        )
    }

    private var pastille: some View {
        Image(
            systemName: SpeakerSymbol.name(
                displayName: output.displayName, proto: output.proto,
                unavailability: output.unavailability
            )
        )
        .font(.title3.weight(.medium))
        .foregroundStyle(output.isEnabled ? Color.white : Color.primary.opacity(0.7))
        .frame(width: WindowMetrics.pastille, height: WindowMetrics.pastille)
        .background(
            output.isEnabled
                ? AnyShapeStyle(BridgeTheme.accent.gradient) : AnyShapeStyle(PanelPalette.quietFill),
            in: Circle()
        )
        // Retenue mais absente du réseau, ou en attente d'une intervention : elle ne peut pas jouer, et
        // la pastille ne doit pas affirmer le contraire.
        .opacity(output.isHeldBack || output.presence == .offline ? 0.55 : 1)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var stateIndicator: some View {
        switch output.connection {
        case .connecting, .waiting, .reconnecting:
            ProgressView()
                .controlSize(.small)
                .accessibilityHidden(true)
        case .failed:
            Image(systemName: "exclamationmark.circle.fill")
                .font(.body)
                .foregroundStyle(.red)
                .accessibilityHidden(true)
        case .streaming where output.isEnabled && isAudible && !output.isMuted:
            // Elle reçoit, et un son passe : le seul cas où le témoin a le droit de bouger.
            Image(systemName: "waveform")
                .font(.body.weight(.semibold))
                .foregroundStyle(BridgeTheme.accent)
                .symbolEffect(.variableColor.iterative, isActive: !reduceMotion && appearsActive)
                .accessibilityHidden(true)
        case .idle, .streaming:
            EmptyView()
        }
    }

    private var settingsButton: some View {
        Button {
            showsSettings.toggle()
        } label: {
            Image(systemName: "slider.horizontal.3")
                .font(.callout.weight(.medium))
                .foregroundStyle(Color.primary.opacity(isHovering || showsSettings ? 0.75 : 0.4))
                .frame(width: 26, height: 26)
                .background(showsSettings ? PanelPalette.press : Color.clear, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
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

    // MARK: - Volume

    /// Le volume de l'enceinte, avec son silence au bout : coupée, elle reste dans la diffusion, et son
    /// curseur reste là, grisé.
    private var volume: some View {
        HStack(spacing: 8) {
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
            .controlSize(.small)
            .disabled(output.isMuted)
            .opacity(output.isMuted ? PanelSpeakerMute.mutedSliderOpacity : 1)
            .help(PanelSpeakerMute.sliderHelp(for: output))
            .accessibilityValue(PanelFormat.decibels(output.trimDB, fractionDigits: 1, signed: true))

            Text(PanelFormat.decibels(output.trimDB, fractionDigits: 1, signed: true))
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(isAdjusting ? .primary : .secondary)
                .frame(width: 58, alignment: .trailing)
                .accessibilityHidden(true)

            PanelSpeakerMuteButton(output: output, width: 26)
        }
    }
}

/// Les réglages fins d'une enceinte, dans la fenêtre surgissante de sa carte.
///
/// Des rangées à colonnes fixes : les valeurs s'alignent, et l'œil descend la colonne au lieu de chercher
/// chaque nombre.
struct SpeakerSettings: View {
    @Bindable var output: OutputState
    let effectiveGainDB: Double
    var listeningCompensationMS: Double?
    var listeningPlaceName: String?
    var stereoPartnerNames: [String] = []

    private let labelWidth: CGFloat = 52
    private let valueWidth: CGFloat = 62
    private let columnGap: CGFloat = 10

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            title
            VStack(alignment: .leading, spacing: 8) {
                row(
                    "Volume", help: "Volume de cette enceinte, en plus du volume général",
                    value: Binding(get: { output.trimDB }, set: { output.trimDB = ($0 * 2).rounded() / 2 }),
                    in: BridgeSettings.Limits.trimDB,
                    text: PanelFormat.decibels(output.trimDB, fractionDigits: 1, signed: true)
                )
                row(
                    "Délai", help: "Décalage manuel, ajouté à la compensation du lieu d'écoute",
                    value: Binding(get: { output.delayMS }, set: { output.delayMS = $0.rounded() }),
                    in: BridgeSettings.Limits.delayMS,
                    text: Self.milliseconds(output.delayMS)
                )
                if let listeningCompensationMS {
                    Label(
                        "\(listeningPlaceName ?? "Lieu d'écoute") : + "
                            + listeningCompensationMS.formatted(
                                .number.precision(.fractionLength(1)).locale(Locale(identifier: "fr_FR"))
                            ) + " ms, appliqués d'office",
                        systemImage: "ruler"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, labelWidth + columnGap)
                    .help("Compensation du lieu d'écoute, appliquée d'elle-même. Le curseur s'y ajoute.")
                }
            }
            if output.supportsToneControl {
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    row(
                        "Basses", help: "Renfort des graves sous 80 Hz, pour cette enceinte seulement",
                        value: Binding(
                            get: { output.bassBoostDB }, set: { PanelBassControl.set($0, on: output) }
                        ),
                        in: BridgeSettings.Limits.bassBoostDB,
                        text: PanelFormat.decibels(output.bassBoostDB, fractionDigits: 1, signed: true)
                    )
                    row(
                        "Aigus", help: "Atténuation des aigus au-dessus de 3 kHz, pour cette enceinte seulement",
                        value: Binding(
                            get: { output.trebleCutDB }, set: { PanelTrebleControl.set($0, on: output) }
                        ),
                        in: BridgeSettings.Limits.trebleCutDB,
                        text: PanelFormat.decibels(output.trebleCutDB, fractionDigits: 1, signed: true)
                    )
                }
            }
            Divider()
            level
        }
        .padding(16)
        .frame(width: 330)
    }

    private var title: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(output.displayName)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(details)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .textSelection(.enabled)
        }
    }

    /// Ce que la carte ne dit plus : le protocole et l'adresse, utiles le jour où une enceinte ne répond pas.
    private var details: String {
        let address = output.host.isEmpty ? "adresse inconnue" : "\(output.host):\(String(output.port))"
        var parts = [output.proto.rawValue, address]
        if let pair = PanelStereoPair.legend(partners: stereoPartnerNames) { parts.insert(pair, at: 1) }
        return parts.joined(separator: " · ")
    }

    /// Ce n'est **pas** un vumètre : il montre la consigne, pas le niveau du signal. Afficher un vrai
    /// niveau demanderait de mesurer les échantillons dans le pipeline, ce qui n'existe pas et ne doit pas
    /// être simulé.
    private var level: some View {
        HStack(spacing: columnGap) {
            Text("Niveau")
                .foregroundStyle(.secondary)
                .frame(width: labelWidth, alignment: .leading)
            Gauge(value: min(max(effectiveGainDB, BridgeState.silenceDB), 0), in: BridgeState.silenceDB...0) {
                EmptyView()
            }
            .gaugeStyle(.accessoryLinearCapacity)
            .tint(.secondary)
            .controlSize(.small)
            Text(PanelFormat.decibels(effectiveGainDB, fractionDigits: 1))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: valueWidth, alignment: .trailing)
        }
        .font(.callout)
        .help("Gain effectif : volume général et volume de l'enceinte confondus, silences compris")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Gain effectif de \(output.displayName)")
        .accessibilityValue(PanelFormat.decibels(effectiveGainDB, fractionDigits: 1))
    }

    private func row(
        _ label: String, help: String, value: Binding<Double>, in range: ClosedRange<Double>, text: String
    ) -> some View {
        HStack(spacing: columnGap) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: labelWidth, alignment: .leading)
                .accessibilityHidden(true)
            Slider(value: value, in: range) {
                Text("\(label) de \(output.displayName)")
            }
            .labelsHidden()
            .controlSize(.small)
            .accessibilityValue(text)
            .help(help)
            Text(text)
                .monospacedDigit()
                .frame(width: valueWidth, alignment: .trailing)
                .accessibilityHidden(true)
        }
        .font(.callout)
    }

    private static func milliseconds(_ value: Double) -> String {
        let number = value.formatted(.number.precision(.fractionLength(0)).locale(Locale(identifier: "fr_FR")))
        return "\(number.replacingOccurrences(of: "-", with: "−")) ms"
    }
}
