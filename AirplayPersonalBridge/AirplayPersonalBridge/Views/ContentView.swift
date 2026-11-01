//
//  ContentView.swift
//  AirplayPersonalBridge
//

import SwiftUI

/// La fenêtre principale (CDC section 9, jalon 5).
///
/// Une colonne de commandes étroite à gauche, le plan sur tout le reste. Les commandes ont
/// une largeur naturelle — un curseur ne gagne rien à faire 700 points — alors que le plan,
/// lui, profite de chaque point qu'on lui donne.
struct ContentView: View {
    /// Partagé avec le panneau de la barre de menus : c'est l'application qui le détient, la
    /// fenêtre peut se fermer et se rouvrir sans rien perdre.
    @Bindable var state: BridgeState
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
        // Les applications qui jouent changent sans prévenir : la liste doit être juste à
        // l'ouverture. La découverte, elle, tourne déjà sans fenêtre (`AppLifecycle`).
        .onAppear { state.refreshSources() }
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

    /// Le sélecteur porte des identifiants : les PID d'une application varient d'un relevé à
    /// l'autre, et une valeur complète ne correspondrait plus à aucune entrée de la liste.
    private var sourceSelection: Binding<String> {
        Binding(
            get: { state.selectedSource.id },
            set: { state.selectSource(id: $0) }
        )
    }

    // MARK: - Haut : source et volume master

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Source").shadLabel()
                HStack(spacing: 6) {
                    Picker("", selection: sourceSelection) {
                        ForEach(state.sources) { source in
                            Text(source.label).tag(source.id)
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

                HStack(spacing: 6) {
                    ShadSwitch(isOn: $state.muteLocalOutput)
                    Text("Couper le son du Mac").shadMuted()
                }
                .disabled(state.selectedSource.tapMode == nil)
                .opacity(state.selectedSource.tapMode == nil ? 0.5 : 1)
                .help(
                    "Ne s'applique qu'à la capture du son système ou d'une application. "
                        + "Pendant une diffusion, la change la relance."
                )
            }

            Card(padding: 12) {
                HStack(spacing: 14) {
                    RotaryKnob(
                        value: $state.masterVolumeDB,
                        range: BridgeState.silenceDB...0,
                        diameter: 68,
                        resetValue: BridgeState.defaultMasterVolumeDB
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
                        listeningCompensationMS: state.listeningCompensationMS(for: output),
                        listeningPlaceName: state.listeningPlaceName
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
            Image(systemName: "hifispeaker")
                .font(.system(size: 26))
                .foregroundStyle(Theme.mutedForeground)
            Text("Aucune sortie").font(Theme.Font.title)
            Text(state.discoveryNotice ?? "Lance une recherche sur le réseau local.")
                .shadMuted()
                .multilineTextAlignment(.center)
            if state.discoveryNotice != nil {
                Button("Ouvrir les réglages « Réseau local »") {
                    SystemSettingsPane.localNetwork.open()
                }
                .shadButton(.ghost, size: .small)
            }
            Button("Rechercher") { Task { await state.refreshOutputs() } }
                .shadButton(.outline, size: .small)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
    }

    // MARK: - Bas : actions

    private var footer: some View {
        VStack(spacing: 8) {
            if let failure = state.startFailure {
                NoticeBanner(
                    severity: .critical, title: "Démarrage impossible", detail: failure.message,
                    actionTitle: failure.settingsPane == nil ? nil : "Ouvrir les Réglages",
                    action: { failure.settingsPane?.open() }
                )
            }
            if let alert = state.captureAlert {
                NoticeBanner(
                    severity: alert.severity, title: alert.title, detail: alert.detail,
                    actionTitle: alert.settingsPane == nil ? nil : "Ouvrir les Réglages",
                    action: { alert.settingsPane?.open() }
                )
            }

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
            // ⌘↩ et non `.defaultAction` : Retour valide un champ de l'inspecteur du plan, et cette
            // validation ne doit pas faire partir le son vers les enceintes.
            .keyboardShortcut(.return, modifiers: .command)
            // Rien à diffuser tant qu'aucune sortie n'est cochée. Le cœur le supporterait
            // (une sortie absente n'empêche pas l'autre), mais l'action n'aurait aucun sens.
            .disabled(!state.canToggleStreaming)

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
    ContentView(state: .previewWithRoom())
}
