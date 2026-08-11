//
//  ContentView.swift
//  AirplayPersonalBridge
//

import AppKit
import SwiftUI

/// La fenêtre principale (CDC section 9, jalon 5).
///
/// Une colonne de commandes étroite à gauche, le plan sur tout le reste. Les commandes ont
/// une largeur naturelle — un curseur ne gagne rien à faire 700 points — alors que le plan,
/// lui, profite de chaque point qu'on lui donne.
struct ContentView: View {
    @State private var state = BridgeState()
    @State private var showsDiagnostics = false

    var body: some View {
        HSplitView {
            controlColumn
                .frame(minWidth: 310, idealWidth: 340, maxWidth: 400)
            RoomPlanView(state: state)
                .frame(minWidth: 520)
                .layoutPriority(1)
        }
        .frame(minWidth: 900, minHeight: 620)
        .background(Theme.background)
        .task {
            state.refreshSources()
            await state.refreshOutputs()
        }
        // Filet de sécurité : le plan est déjà écrit à chaque modification, mais une
        // sauvegarde à la fermeture évite de dépendre d'un appel qu'on aurait oublié
        // d'ajouter en introduisant une nouvelle façon de le modifier.
        .onReceive(
            NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)
        ) { _ in
            state.persistRoomLayout()
        }
        .sheet(isPresented: $showsDiagnostics) {
            DiagnosticsView(state: state, onClose: { showsDiagnostics = false })
        }
    }

    private var controlColumn: some View {
        VStack(spacing: 0) {
            header
            ShadSeparator()
            outputList
            ShadSeparator()
            footer
        }
        .background(Theme.background)
    }

    // MARK: - Haut : source et volume master

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Source").shadLabel()
                HStack(spacing: 6) {
                    Picker("", selection: $state.selectedSource) {
                        ForEach(state.sources) { source in
                            Text(source.label).tag(source)
                        }
                    }
                    .labelsHidden()
                    .font(Theme.Font.body)

                    Button {
                        state.refreshSources()
                    } label: {
                        Image(systemName: "arrow.clockwise").font(.system(size: 11))
                    }
                    .shadButton(.outline, size: .small)
                    .help("Rafraîchir la liste des applications qui jouent du son")
                }
            }

            Card(padding: 12) {
                HStack(spacing: 14) {
                    RotaryKnob(
                        value: $state.masterVolumeDB,
                        range: BridgeState.silenceDB...0,
                        diameter: 68,
                        resetValue: -12
                    )
                    .opacity(state.isMuted ? 0.35 : 1)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Volume master").shadMuted()
                        Text(
                            state.isMuted
                                ? "silence" : String(format: "%.0f dB", state.masterVolumeDB)
                        )
                        .font(.system(size: 22, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(state.isMuted ? Theme.mutedForeground : Theme.foreground)

                        HStack(spacing: 6) {
                            ShadSwitch(isOn: $state.isMuted)
                            Text("Silence").shadMuted()
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(14)
    }

    // MARK: - Milieu : les sorties

    private var outputList: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                ForEach(state.outputs) { output in
                    OutputRow(
                        output: output,
                        effectiveGainDB: state.effectiveGainDB(for: output),
                        suggestedDelayMS: state.suggestedDelayMS(for: output),
                        onApplySuggestedDelay: { state.applySuggestedDelay(to: output) }
                    )
                }

                if state.outputs.isEmpty { emptyState }
            }
            .padding(14)
        }
        .background(Theme.background)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "hifispeaker.slash")
                .font(.system(size: 26))
                .foregroundStyle(Theme.mutedForeground)
            Text("Aucune sortie").font(Theme.Font.title)
            Text(state.discoveryNotice ?? "Lance une recherche sur le réseau local.")
                .shadMuted()
                .multilineTextAlignment(.center)
            Button("Rechercher") { Task { await state.refreshOutputs() } }
                .shadButton(.outline, size: .small)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
    }

    // MARK: - Bas : actions

    private var footer: some View {
        VStack(spacing: 8) {
            Button {
                state.toggleStreaming()
            } label: {
                Label(
                    state.isStreaming ? "Arrêter la diffusion" : "Diffuser",
                    systemImage: state.isStreaming ? "stop.fill" : "play.fill"
                )
                .frame(maxWidth: .infinity)
            }
            .shadButton(state.isStreaming ? .destructive : .primary, size: .large)
            .keyboardShortcut(.defaultAction)
            // Rien à diffuser tant qu'aucune sortie n'est cochée. Le cœur le supporterait
            // (une sortie absente n'empêche pas l'autre), mais l'action n'aurait aucun sens.
            .disabled(!state.outputs.contains(where: \.isEnabled))

            HStack(spacing: 8) {
                Button {
                    Task { await state.refreshOutputs() }
                } label: {
                    if state.isBrowsing {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small).scaleEffect(0.7)
                            Text("Recherche…")
                        }
                    } else {
                        Label("Rechercher", systemImage: "antenna.radiowaves.left.and.right")
                    }
                }
                .shadButton(.outline, size: .small)
                .disabled(state.isBrowsing)

                Spacer()

                Button {
                    showsDiagnostics = true
                } label: {
                    Label("Diagnostic", systemImage: "waveform.path.ecg")
                }
                .shadButton(.ghost, size: .small)
            }
        }
        .padding(14)
    }
}

#Preview {
    ContentView()
}
