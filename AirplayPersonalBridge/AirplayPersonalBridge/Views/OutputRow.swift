//
//  OutputRow.swift
//  AirplayPersonalBridge
//

import SwiftUI

/// Une sortie et ses réglages, présentée en carte.
///
/// La carte n'est pas décorative : elle dit où s'arrête une sortie et où commence la
/// suivante. Sur une colonne étroite, quatre curseurs à la file sans regroupement visible
/// deviennent une bouillie où l'on ne sait plus lequel appartient à quoi.
struct OutputRow: View {
    @Bindable var output: OutputState
    let effectiveGainDB: Double
    /// Délai déduit du plan de la pièce, s'il est calculable. Proposé, jamais imposé.
    var suggestedDelayMS: Double?
    var onApplySuggestedDelay: (() -> Void)?

    /// Colonnes fixes : les valeurs s'alignent d'un curseur à l'autre, ce qui permet de
    /// balayer la carte verticalement au lieu de rechercher chaque nombre.
    private let valueWidth: CGFloat = 56
    private let labelWidth: CGFloat = 44

    var body: some View {
        Card(padding: 11) {
            VStack(alignment: .leading, spacing: 10) {
                title
                settings
            }
        }
        .opacity(output.isEnabled ? 1 : 0.55)
    }

    private var title: some View {
        HStack(spacing: 8) {
            Toggle("", isOn: $output.isEnabled)
                .labelsHidden()
                .toggleStyle(.checkbox)
                .accessibilityLabel("Diffuser vers \(output.displayName)")

            StatusDot(state: output.connection)

            VStack(alignment: .leading, spacing: 1) {
                Text(output.displayName)
                    .font(Theme.Font.medium)
                    .foregroundStyle(Theme.foreground)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("\(output.host):\(String(output.port))")
                    .font(Theme.Font.tiny.monospacedDigit())
                    .foregroundStyle(Theme.mutedForeground)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            ShadBadge(text: output.proto.rawValue, variant: .outline)
        }
    }

    private var settings: some View {
        VStack(spacing: 6) {
            settingRow(
                "Trim", value: $output.trimDB, in: -12...12,
                format: { String(format: "%+.1f dB", $0) }
            )
            settingRow(
                "Délai", value: $output.delayMS, in: -200...200,
                format: { String(format: "%.0f ms", $0) }
            )
            if let suggestedDelayMS {
                HStack(spacing: 5) {
                    Spacer().frame(width: labelWidth)
                    Image(systemName: "ruler").font(.system(size: 9))
                    Text(String(format: "Plan : %.0f ms", suggestedDelayMS))
                    // Rien à appliquer si le curseur y est déjà, à un demi-quantum
                    // d'affichage près — le bouton n'aurait alors rien à dire.
                    if abs(suggestedDelayMS - output.delayMS) > 0.5 {
                        Button("Appliquer") { onApplySuggestedDelay?() }
                            .buttonStyle(.plain)
                            .font(Theme.Font.tiny.weight(.medium))
                            .foregroundStyle(Theme.info)
                    }
                    Spacer(minLength: 0)
                }
                .font(Theme.Font.tiny)
                .foregroundStyle(Theme.mutedForeground)
            }
            if output.supportsBassBoost {
                settingRow(
                    "Basses", value: $output.bassBoostDB, in: 0...12,
                    format: { String(format: "%+.1f dB", $0) }
                )
            }

            HStack(spacing: 8) {
                Text("Sortie")
                    .font(Theme.Font.small)
                    .foregroundStyle(Theme.mutedForeground)
                    .frame(width: labelWidth, alignment: .leading)
                LevelBar(gainDB: effectiveGainDB)
                Text(String(format: "%.1f dB", effectiveGainDB))
                    .font(Theme.Font.small.monospacedDigit())
                    .foregroundStyle(Theme.mutedForeground)
                    .frame(width: valueWidth, alignment: .trailing)
            }
        }
        .disabled(!output.isEnabled)
    }

    private func settingRow(
        _ label: String,
        value: Binding<Double>,
        in range: ClosedRange<Double>,
        format: @escaping (Double) -> String
    ) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(Theme.Font.small)
                .foregroundStyle(Theme.mutedForeground)
                .frame(width: labelWidth, alignment: .leading)
            ShadSlider(value: value, range: range)
                .accessibilityLabel("\(label) de \(output.displayName)")
            Text(format(value.wrappedValue))
                .font(Theme.Font.small.monospacedDigit())
                .foregroundStyle(Theme.foreground)
                .frame(width: valueWidth, alignment: .trailing)
        }
    }
}

/// Pastille d'état. La reconnexion a sa propre couleur : c'est un fonctionnement normal
/// prévu par le CDC section 8, pas une panne — la confondre avec un échec ferait paniquer
/// pour rien devant les 90 reconnexions d'une session d'une heure.
private struct StatusDot: View {
    let state: OutputConnectionState

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 7, height: 7)
            .accessibilityLabel(label)
            .help(label)
    }

    private var color: Color {
        switch state {
        case .idle: Theme.mutedForeground
        case .connecting: Theme.warning
        case .streaming: Theme.success
        case .reconnecting: Theme.warning
        case .failed: Theme.destructive
        }
    }

    private var label: String {
        switch state {
        case .idle: "Inactive"
        case .connecting: "Connexion"
        case .streaming: "Diffusion"
        case .reconnecting: "Reconnexion"
        case let .failed(reason): "Échec : \(reason)"
        }
    }
}

/// Indicateur de gain. Ce n'est **pas** un vumètre : il montre la consigne, pas le niveau
/// du signal. Afficher un vrai niveau demanderait de mesurer les échantillons dans le
/// pipeline, ce qui n'existe pas encore et ne doit pas être simulé.
private struct LevelBar: View {
    let gainDB: Double

    var body: some View {
        GeometryReader { geometry in
            let fraction = (gainDB - BridgeState.silenceDB) / (0 - BridgeState.silenceDB)
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.muted)
                Capsule()
                    .fill(Theme.primary.opacity(0.7))
                    .frame(width: max(0, geometry.size.width * fraction))
            }
        }
        .frame(height: 5)
    }
}

#Preview {
    @Previewable @State var state = BridgeState.previewWithRoom()
    ScrollView {
        VStack(spacing: 10) {
            ForEach(state.outputs) { output in
                OutputRow(
                    output: output,
                    effectiveGainDB: state.effectiveGainDB(for: output),
                    suggestedDelayMS: state.suggestedDelayMS(for: output),
                    onApplySuggestedDelay: { state.applySuggestedDelay(to: output) }
                )
            }
        }
        .padding(14)
    }
    .background(Theme.background)
    .frame(width: 340, height: 460)
}
