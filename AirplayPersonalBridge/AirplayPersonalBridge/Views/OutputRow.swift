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
    /// Compensation du lieu d'écoute, s'il est calculable. En lecture seule : elle s'applique
    /// d'elle-même, et le curseur « Délai » s'y ajoute.
    var listeningCompensationMS: Double?
    var listeningPlaceName: String?

    /// Colonnes fixes : les valeurs s'alignent d'un curseur à l'autre, ce qui permet de
    /// balayer la carte verticalement au lieu de rechercher chaque nombre.
    private let valueWidth: CGFloat = 56
    private let labelWidth: CGFloat = 44

    var body: some View {
        Card(padding: 11) {
            VStack(alignment: .leading, spacing: 10) {
                title
                if let line = output.statusLine {
                    OutputStatusMessage(text: line.text, tone: line.tone)
                }
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

            OutputStatusDot(state: output.connection)

            VStack(alignment: .leading, spacing: 1) {
                Text(output.displayName)
                    .font(Theme.Font.medium)
                    .foregroundStyle(Theme.foreground)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(output.host.isEmpty ? "adresse inconnue" : "\(output.host):\(String(output.port))")
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
                "Trim", value: $output.trimDB, in: BridgeSettings.Limits.trimDB,
                format: { String(format: "%+.1f dB", $0) }
            )
            settingRow(
                "Délai", value: $output.delayMS, in: BridgeSettings.Limits.delayMS,
                format: { String(format: "%.0f ms", $0) }
            )
            if let listeningCompensationMS {
                HStack(spacing: 5) {
                    Spacer().frame(width: labelWidth)
                    Image(systemName: "ruler").font(.system(size: 9))
                    Text(
                        "\(listeningPlaceName ?? "Lieu d'écoute") : "
                            + String(format: "+ %.1f ms", listeningCompensationMS)
                    )
                    Spacer(minLength: 0)
                }
                .font(Theme.Font.tiny)
                .foregroundStyle(Theme.mutedForeground)
                .help("Compensation du lieu d'écoute, appliquée d'elle-même. Le curseur s'y ajoute.")
            }
            if output.supportsBassBoost {
                settingRow(
                    "Basses", value: $output.bassBoostDB, in: BridgeSettings.Limits.bassBoostDB,
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
struct OutputStatusDot: View {
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
        case .waiting: Theme.warning
        case .streaming: Theme.success
        case .reconnecting: Theme.warning
        case .failed: Theme.destructive
        }
    }

    private var label: String {
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

/// La ligne de message d'une sortie, telle que le moteur la rédige.
///
/// Ces messages disent quoi faire, et certains font plusieurs phrases (l'appairage d'un Apple TV,
/// par exemple). Repliés, ils gardent la liste lisible d'un coup d'œil ; un lien les déplie, pour
/// qu'une coupure ne passe jamais pour la fin du message.
struct OutputStatusMessage: View {
    let text: String
    let tone: OutputStatusTone
    @State private var isExpanded = false

    /// Ce qui tient en trois lignes dans la colonne la plus étroite.
    private let foldedLength = 125

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(text)
                .font(Theme.Font.tiny)
                .foregroundStyle(color)
                .lineLimit(isExpanded ? nil : 3)
                .truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(text)
            if text.count > foldedLength {
                Button(isExpanded ? "Réduire" : "Lire la suite") { isExpanded.toggle() }
                    .buttonStyle(.plain)
                    .font(Theme.Font.tiny.weight(.medium))
                    .foregroundStyle(Theme.mutedForeground)
            }
        }
    }

    private var color: Color {
        switch tone {
        case .muted: Theme.mutedForeground
        case .warning: Theme.warning
        case .critical: Theme.destructive
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
                    listeningCompensationMS: state.listeningCompensationMS(for: output),
                    listeningPlaceName: state.listeningPlaceName
                )
            }
        }
        .padding(14)
    }
    .background(Theme.background)
    .frame(width: 340, height: 460)
}
