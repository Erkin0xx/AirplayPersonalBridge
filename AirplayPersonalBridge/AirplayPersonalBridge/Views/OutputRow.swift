//
//  OutputRow.swift
//  AirplayPersonalBridge
//

import SwiftUI

/// Une sortie et ses réglages, en rangée de barre latérale.
///
/// La case et le nom d'abord, l'état en pastille au bout de la ligne ; dessous, une fois cochée, ses
/// réglages fins en colonnes fixes, dont les valeurs s'alignent d'une sortie à l'autre, ce qui permet de
/// balayer la liste verticalement au lieu de rechercher chaque nombre. Décochée, elle se réduit à son
/// nom : ses réglages n'agiraient pas, ils n'ont pas à occuper la place.
struct OutputRow: View {
    @Bindable var output: OutputState
    let effectiveGainDB: Double
    /// Compensation du lieu d'écoute, s'il est calculable. En lecture seule : elle s'applique
    /// d'elle-même, et le curseur « Délai » s'y ajoute.
    var listeningCompensationMS: Double?
    var listeningPlaceName: String?
    /// Les autres membres de sa paire stéréo (`BridgeState.stereoPartners(of:)`).
    var stereoPartnerNames: [String] = []
    /// Rien ne signale de silence : l'indicateur de diffusion peut bouger.
    var isAudible = true
    /// La case : `BridgeState.setEnabled(_:for:)`, qui emmène la paire stéréo.
    var setEnabled: (Bool) -> Void

    /// Les colonnes des réglages : libellé, curseur, valeur.
    private let labelWidth: CGFloat = 44
    private let valueWidth: CGFloat = 58
    private let columnGap: CGFloat = 8
    /// Le silence de l'enceinte, au bout de la rangée du volume.
    private let accessoryWidth: CGFloat = 18
    /// La case, puis l'icône : le message et les réglages commencent sur le bord du nom.
    static let checkboxWidth: CGFloat = 16
    static let iconWidth: CGFloat = 18
    static let columnGap: CGFloat = 8
    static let textInset = checkboxWidth + columnGap + iconWidth + columnGap

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            if let line = message {
                OutputStatusMessage(text: line.text, tone: line.tone, isMuted: !output.isEnabled)
                    .padding(.leading, Self.textInset)
            }
            if output.isEnabled {
                settings
                    .transition(.opacity)
            }
        }
        .padding(.vertical, 6)
    }

    /// Le message sous le nom, s'il dit quelque chose. « Connexion… » n'apporte rien : la pastille de la
    /// rangée le dit déjà, comme le témoin du panneau.
    private var message: (text: String, tone: OutputStatusTone)? {
        if case .connecting = output.connection { return nil }
        return output.statusLine
    }

    // MARK: - En-tête

    private var header: some View {
        HStack(spacing: Self.columnGap) {
            Toggle(
                "Diffuser vers \(output.displayName)",
                isOn: Binding(get: { output.isEnabled }, set: { setEnabled($0) })
            )
            .labelsHidden()
            .toggleStyle(.checkbox)
            .frame(width: Self.checkboxWidth)
            .accessibilityHint(PanelStereoPair.accessibilityHint(partners: stereoPartnerNames) ?? "")

            Image(
                systemName: SpeakerSymbol.name(
                    displayName: output.displayName, proto: output.proto,
                    unavailability: output.unavailability
                )
            )
            .foregroundStyle(output.isEnabled ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            .frame(width: Self.iconWidth)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                Text(output.displayName)
                    .foregroundStyle(output.isEnabled ? .primary : .secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(PanelStereoPair.help(partners: stereoPartnerNames) ?? subtitle)
            }

            Spacer(minLength: 4)

            OutputStatePill(state: output.connection, isAudible: isAudible && !output.isMuted)
        }
    }

    /// La paire stéréo d'abord, qui dit ce que la case emmène ; sinon l'adresse. Le protocole ferme la
    /// ligne : c'est lui que la troncature mange en premier. Une ligne, jamais deux.
    private var subtitle: String {
        if let pair = PanelStereoPair.legend(partners: stereoPartnerNames) {
            return "\(pair) · \(output.proto.rawValue)"
        }
        let address = output.host.isEmpty ? "adresse inconnue" : "\(output.host):\(String(output.port))"
        return "\(address) · \(output.proto.rawValue)"
    }

    // MARK: - Réglages

    /// Des rangées à colonnes fixes plutôt qu'une `Grid` : dans une cellule de liste, la grille gardait
    /// la largeur idéale de ses curseurs, et laissait un vide au bout de chaque rangée.
    private var settings: some View {
        VStack(alignment: .leading, spacing: 4) {
            settingRow(
                "Trim", help: "Volume de cette sortie, en plus du volume master",
                value: Binding(get: { output.trimDB }, set: { output.trimDB = ($0 * 2).rounded() / 2 }),
                in: BridgeSettings.Limits.trimDB,
                text: PanelFormat.decibels(output.trimDB, fractionDigits: 1, signed: true),
                carriesMute: true
            )
            settingRow(
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
                        ) + " ms",
                    systemImage: "ruler"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.leading, labelWidth + columnGap)
                .help("Compensation du lieu d'écoute, appliquée d'elle-même. Le curseur s'y ajoute.")
            }
            if output.supportsToneControl {
                settingRow(
                    "Basses", help: "Renfort des graves sous 80 Hz, pour cette sortie seulement",
                    value: Binding(get: { output.bassBoostDB }, set: { PanelBassControl.set($0, on: output) }),
                    in: BridgeSettings.Limits.bassBoostDB,
                    text: PanelFormat.decibels(output.bassBoostDB, fractionDigits: 1, signed: true)
                )
                settingRow(
                    "Aigus", help: "Atténuation des aigus au-dessus de 3 kHz, pour cette sortie seulement",
                    value: Binding(get: { output.trebleCutDB }, set: { PanelTrebleControl.set($0, on: output) }),
                    in: BridgeSettings.Limits.trebleCutDB,
                    text: PanelFormat.decibels(output.trebleCutDB, fractionDigits: 1, signed: true)
                )
            }
            HStack(spacing: columnGap) {
                Text("Sortie")
                    .foregroundStyle(.secondary)
                    .frame(width: labelWidth, alignment: .leading)
                LevelGauge(gainDB: effectiveGainDB)
                Text(PanelFormat.decibels(effectiveGainDB, fractionDigits: 1))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: valueWidth, alignment: .trailing)
                Color.clear.frame(width: accessoryWidth, height: 1)
            }
            .help("Gain effectif : master et trim confondus, silences compris")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Gain effectif de \(output.displayName)")
            .accessibilityValue(PanelFormat.decibels(effectiveGainDB, fractionDigits: 1))
        }
        .font(.callout)
        // Dans l'axe du nom : la case et l'icône forment la colonne de gauche.
        .padding(.leading, Self.textInset)
    }

    /// `carriesMute` : la rangée du volume porte le silence de l'enceinte au bout, comme dans le panneau ;
    /// coupée, l'enceinte reste dans la diffusion, et son curseur reste là, grisé. Les autres rangées
    /// réservent la colonne, pour que leurs valeurs restent l'une sous l'autre.
    private func settingRow(
        _ label: String, help: String, value: Binding<Double>, in range: ClosedRange<Double>, text: String,
        carriesMute: Bool = false
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
            .disabled(carriesMute && output.isMuted)
            .opacity(carriesMute && output.isMuted ? PanelSpeakerMute.mutedSliderOpacity : 1)
            .accessibilityValue(text)
            .help(carriesMute ? PanelSpeakerMute.sliderHelp(for: output) : help)
            Text(text)
                .monospacedDigit()
                .frame(width: valueWidth, alignment: .trailing)
                .accessibilityHidden(true)
            if carriesMute {
                PanelSpeakerMuteButton(output: output, width: accessoryWidth)
            } else {
                Color.clear
                    .frame(width: accessoryWidth, height: 1)
                    .accessibilityHidden(true)
            }
        }
    }

    private static func milliseconds(_ value: Double) -> String {
        let number = value.formatted(.number.precision(.fractionLength(0)).locale(Locale(identifier: "fr_FR")))
        return "\(number.replacingOccurrences(of: "-", with: "−")) ms"
    }
}

/// L'état d'une sortie en pastille, au bout de sa ligne. Rien au repos : une pastille « inactive » sur
/// chaque rangée ne dirait que du bruit.
///
/// La reconnexion a la teinte de l'attente, pas celle de l'échec : c'est un fonctionnement normal prévu
/// par le CDC section 8, pas une panne — la confondre avec un échec ferait paniquer pour rien devant les
/// 90 reconnexions d'une session d'une heure.
struct OutputStatePill: View {
    let state: OutputConnectionState
    /// Un son passe vraiment : la vague peut bouger.
    var isAudible = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.appearsActive) private var appearsActive

    var body: some View {
        if let text {
            HStack(spacing: 4) {
                symbol
                Text(text)
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(tint.opacity(0.14), in: Capsule())
            .help(label)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
        }
    }

    @ViewBuilder
    private var symbol: some View {
        switch state {
        case .connecting, .waiting, .reconnecting:
            ProgressView().controlSize(.mini)
        case .streaming:
            Image(systemName: "waveform")
                .symbolEffect(.variableColor.iterative, isActive: isAudible && !reduceMotion && appearsActive)
        case .failed:
            Image(systemName: "exclamationmark.circle.fill")
        case .idle:
            EmptyView()
        }
    }

    private var text: String? {
        switch state {
        case .idle: nil
        case .connecting: "Connexion"
        case .waiting: "En attente"
        case .streaming: "Diffusion"
        case .reconnecting: "Reconnexion"
        case .failed: "Échec"
        }
    }

    private var tint: Color {
        switch state {
        case .idle: .secondary
        case .connecting, .waiting, .reconnecting: .orange
        case .streaming: .green
        case .failed: .red
        }
    }

    /// Ce que disent l'aide au survol et VoiceOver, message compris.
    var label: String {
        switch state {
        case .idle: "Inactive"
        case .connecting: "Connexion"
        case let .waiting(_, message, _): "En attente : \(message)"
        case .streaming: "Diffusion"
        case let .reconnecting(message):
            message.map { "Reconnexion : \($0)" } ?? "Reconnexion"
        case let .failed(reason): "Échec : \(reason)"
        }
    }
}

/// Le message d'une sortie, tel que le moteur le rédige. Partagé par la fenêtre et le panneau.
///
/// Ces messages disent quoi faire, et certains font plusieurs phrases (l'appairage d'un Apple TV, par
/// exemple). Repliés, ils gardent la liste lisible d'un coup d'œil ; un lien les déplie, pour qu'une
/// coupure ne passe jamais pour la fin du message.
struct OutputStatusMessage: View {
    let text: String
    let tone: OutputStatusTone
    /// La rangée est en retrait : même un avertissement n'y appelle pas le regard.
    var isMuted = false
    /// Les lignes visibles une fois replié.
    var foldedLines = 3
    /// Au-delà, le message ne tient pas dans ses lignes repliées : le lien apparaît.
    var foldedLength = 125

    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(text)
                .font(.subheadline)
                .foregroundStyle(color)
                .lineLimit(isExpanded ? nil : foldedLines)
                .truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(text)
            if text.count > foldedLength {
                Button(isExpanded ? "Réduire" : "Lire la suite") { isExpanded.toggle() }
                    .buttonStyle(.plain)
                    .font(.subheadline.weight(.medium))
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

/// Indicateur de gain. Ce n'est **pas** un vumètre : il montre la consigne, pas le niveau
/// du signal. Afficher un vrai niveau demanderait de mesurer les échantillons dans le
/// pipeline, ce qui n'existe pas encore et ne doit pas être simulé.
private struct LevelGauge: View {
    let gainDB: Double

    var body: some View {
        Gauge(
            value: min(max(gainDB, BridgeState.silenceDB), 0),
            in: BridgeState.silenceDB...0
        ) {
            EmptyView()
        }
        .gaugeStyle(.accessoryLinearCapacity)
        .tint(.secondary)
        .controlSize(.small)
    }
}

#Preview {
    @Previewable @State var state = BridgeState.previewWithRoom()
    List {
        ForEach(state.outputs) { output in
            OutputRow(
                output: output,
                effectiveGainDB: state.effectiveGainDB(for: output),
                listeningCompensationMS: state.listeningCompensationMS(for: output),
                listeningPlaceName: state.listeningPlaceName,
                stereoPartnerNames: state.stereoPartners(of: output).map(\.displayName),
                setEnabled: { state.setEnabled($0, for: output) }
            )
        }
    }
    .listStyle(.sidebar)
    .frame(width: 330, height: 460)
}
