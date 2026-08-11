//
//  DiagnosticsView.swift
//  AirplayPersonalBridge
//

import SwiftUI

/// Le panneau de diagnostic.
///
/// Il n'est pas décoratif : le jour où la vraie Geneva remplacera le mock, tout ce qui a
/// été validé au jalon 4 redevient une hypothèse, et ce sont exactement ces compteurs qui
/// diront si elle tient. Ils existent déjà dans les `Statistics` des deux senders — les
/// afficher ne coûte rien de plus qu'une mise en page.
struct DiagnosticsView: View {
    let state: BridgeState
    /// Fermeture de la feuille. Une feuille modale sans échappatoire visible piège
    /// l'utilisateur : le bouton est ici la seule sortie.
    var onClose: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Diagnostic").font(.title3.bold())
                Spacer()
                Button("Fermer", action: onClose)
                    .keyboardShortcut(.cancelAction)
            }
            .padding()

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    ForEach(state.outputs) { output in
                        outputSection(output)
                    }
                    if state.outputs.isEmpty {
                        Text("Aucune sortie.")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, 40)
                    }
                }
                .padding()
            }
        }
        .frame(minWidth: 460, minHeight: 420)
    }

    private func outputSection(_ output: OutputState) -> some View {
        let diagnostics = output.diagnostics
        return VStack(alignment: .leading, spacing: 6) {
            Text("\(output.displayName) — \(output.proto.rawValue)")
                .font(.headline)

            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 3) {
                metric("Paquets audio émis", diagnostics.packetsSent)
                metric("Trames lues du ring buffer", diagnostics.framesRead)
                metric("Erreurs d'émission", diagnostics.errors, alarming: diagnostics.errors > 0)
                metric("Recalages de cadence", diagnostics.resyncs)
                // Le rapport importe plus que les deux nombres : une annonce de synchro non
                // ancrée est une trame restituée sans référence commune, donc un décalage.
                metricText(
                    "Annonces de synchro ancrées",
                    "\(diagnostics.anchoredSyncPackets) / \(diagnostics.syncPacketsSent)",
                    alarming: diagnostics.anchoredSyncPackets != diagnostics.syncPacketsSent
                )
                metric("Trames insérées (dérive)", diagnostics.framesInserted)
                metric("Trames retirées (dérive)", diagnostics.framesRemoved)
                metricText(
                    "Reconnexions",
                    "\(diagnostics.reconnections) sur \(diagnostics.reconnectionAttempts) tentatives"
                )
                metric("Trames écartées avant diffusion", diagnostics.droppedBeforeStreaming)
                // Zéro veut dire « non annoncée », pas « aucune latence » : le mock AirPlay 2
                // ne l'annonce pas, et publier « 0 ms » serait un chiffre inventé.
                metricText(
                    "Latence annoncée",
                    diagnostics.reportedLatencyFrames == 0
                        ? "non annoncée"
                        : String(
                            format: "%.0f ms (%d trames)",
                            Double(diagnostics.reportedLatencyFrames) / 44.1,
                            diagnostics.reportedLatencyFrames
                        )
                )
                if output.proto == .airplay2 {
                    metricText(
                        "Canal d'événements",
                        diagnostics.eventChannelConnected ? "connecté" : "fermé",
                        alarming: !diagnostics.eventChannelConnected
                    )
                }
            }
            .font(.callout)
        }
    }

    private func metric(_ label: String, _ value: Int, alarming: Bool = false) -> some View {
        metricText(label, value.formatted(.number.grouping(.automatic)), alarming: alarming)
    }

    private func metricText(
        _ label: String, _ value: String, alarming: Bool = false
    ) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value)
                .monospacedDigit()
                .foregroundStyle(alarming ? AnyShapeStyle(.red) : AnyShapeStyle(.primary))
                .gridColumnAlignment(.trailing)
        }
    }
}

#Preview {
    DiagnosticsView(state: .preview())
}
