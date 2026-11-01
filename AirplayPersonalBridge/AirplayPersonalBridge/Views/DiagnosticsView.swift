//
//  DiagnosticsView.swift
//  AirplayPersonalBridge
//

import AudioCore
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
                    captureSection
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

    // MARK: - Capture

    private var captureSection: some View {
        let health = state.captureHealth
        return VStack(alignment: .leading, spacing: 6) {
            Text("Capture — \(state.selectedSource.label)")
                .font(.headline)

            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 3) {
                metricText(
                    "État", Self.label(for: health.diagnosis),
                    alarming: health.diagnosis == .silentWhilePlaying
                        || health.diagnosis == .stalled
                )
                metric("Trames captées", health.framesCaptured)
                metricText(
                    "Autorisation", Self.label(for: health.permission),
                    alarming: health.permission == .denied || health.permission == .restricted
                )
                if let silentSince = health.silentSince {
                    metricText("Silence strict depuis", Self.seconds(since: silentSince))
                }
                if let stalledSince = health.stalledSince {
                    metricText("Plus de blocs depuis", Self.seconds(since: stalledSince), alarming: true)
                }
                metric("Reconstructions après changement de périphérique", health.rebuilds)
                metricText(
                    "Interruptions cumulées", String(format: "%.2f s", health.interruptedSeconds)
                )
                if let error = health.lastRebuildError {
                    metricText("Dernier échec de reconstruction", error, alarming: true)
                }
            }
            .font(.callout)
        }
    }

    private static func label(for diagnosis: BridgeEngine.CaptureHealth.Diagnosis) -> String {
        switch diagnosis {
        case .notRunning: "à l'arrêt"
        case .waitingForFirstBlock: "en attente du premier bloc"
        case .healthy: "son reçu"
        case .stalled: "plus de blocs"
        case .silentWhilePlaying: "silence alors qu'une application joue"
        case .silentNothingPlaying: "silence, rien ne joue"
        case .silentUnknown: "silence, cause inconnue"
        }
    }

    private static func label(for permission: CapturePermission.Status?) -> String {
        switch permission {
        case nil: "—"
        case .authorized?: "accordée"
        case .denied?: "refusée"
        case .restricted?: "restreinte"
        case .notDetermined?: "pas encore demandée"
        case .unknown?: "inconnue"
        }
    }

    private static func seconds(since date: Date) -> String {
        String(format: "%.0f s", Date().timeIntervalSince(date))
    }

    // MARK: - Sorties

    private func outputSection(_ output: OutputState) -> some View {
        let statistics = output.statistics
        return VStack(alignment: .leading, spacing: 6) {
            Text("\(output.displayName) — \(output.proto.rawValue)")
                .font(.headline)

            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 3) {
                if let line = output.statusLine {
                    metricText("État", line.text, alarming: line.tone == .critical)
                }
                metric("Paquets audio émis", statistics.packetsSent)
                metric("Trames lues du ring buffer", statistics.framesRead)
                metric("Erreurs d'émission", statistics.errors, alarming: statistics.errors > 0)
                metric("Recalages de cadence", statistics.resyncs)
                // Le rapport importe plus que les deux nombres : une annonce de synchro non
                // ancrée est une trame restituée sans référence commune, donc un décalage.
                metricText(
                    "Annonces de synchro ancrées",
                    "\(statistics.anchoredSyncPackets) / \(statistics.syncPacketsSent)",
                    alarming: statistics.anchoredSyncPackets != statistics.syncPacketsSent
                )
                metric("Trames insérées (dérive)", statistics.framesInserted)
                metric("Trames retirées (dérive)", statistics.framesRemoved)
                metricText(
                    "Reconnexions",
                    "\(statistics.reconnections) sur \(statistics.reconnectionAttempts) tentatives"
                )
                metric("Trames écartées avant diffusion", statistics.droppedBeforeStreaming)
                metric(
                    "Trames refusées en diffusion", output.droppedWhileStreaming,
                    alarming: output.droppedWhileStreaming > 0
                )
                // Absente veut dire « non annoncée », pas « aucune latence » : le mock AirPlay 2
                // ne l'annonce pas, et publier « 0 ms » serait un chiffre inventé.
                metricText(
                    "Latence annoncée",
                    statistics.reportedLatencyFrames.map {
                        String(format: "%.0f ms (%d trames)", Double($0) / 44.1, $0)
                    } ?? "non annoncée"
                )
                if let responses = statistics.timingResponsesSent {
                    metric("Réponses aux requêtes d'horloge", responses)
                }
                if let requests = statistics.retransmitRequests {
                    metric("Demandes de retransmission", requests)
                }
                if let connected = statistics.eventChannelConnected {
                    metricText(
                        "Canal d'événements",
                        connected ? "connecté" : "fermé",
                        alarming: !connected
                    )
                }
                if let sync = output.sync {
                    metricText(
                        "Décalage manuel", String(format: "%.0f ms", sync.manualOffsetSeconds * 1000)
                    )
                    metricText("Délai de pipeline", Self.milliseconds(sync.pipelineDelaySeconds))
                    // C'est la grandeur à comparer au seuil de perception de 20 à 30 ms du CDC
                    // section 8. Absente tant que la mesure se cale, jamais remplacée par zéro.
                    metricText(
                        "Écart résiduel à la consigne",
                        Self.milliseconds(sync.residualErrorSeconds),
                        alarming: abs(sync.residualErrorSeconds ?? 0) > 0.020
                    )
                }
            }
            .font(.callout)
        }
    }

    private static func milliseconds(_ seconds: TimeInterval?) -> String {
        seconds.map { String(format: "%.1f ms", $0 * 1000) } ?? "en cours de calage"
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
