//
//  WindowChrome.swift
//  AirplayPersonalBridge
//

import SwiftUI

/// Ce que les trois vues de la fenêtre partagent autour de leur contenu : le choix de la vue, la source,
/// et le bouton des options.

/// Le choix de la vue de la fenêtre, en tête des options.
struct WindowLayoutPicker: View {
    @Bindable var state: BridgeState

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Vue de la fenêtre")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Picker("Vue de la fenêtre", selection: $state.windowLayout) {
                ForEach(WindowLayout.allCases) { layout in
                    Text(layout.title).tag(layout)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .help("Trois mises en scène du même réglage : rien ne change dans ce qui joue.")
        }
    }
}

/// La source, en menu : pour les vues qui n'ont pas de barre latérale où la loger.
struct SourceMenu: View {
    @Bindable var state: BridgeState

    var body: some View {
        // Un menu au libellé explicite : la source en vigueur se lit dans la barre, là où un sélecteur
        // sans libellé ne montrait qu'un chevron. Des identifiants, pas des valeurs : les PID d'une
        // application varient d'un relevé à l'autre.
        Menu {
            Picker(
                "Source",
                selection: Binding(get: { state.selectedSource.id }, set: { state.selectSource(id: $0) })
            ) {
                ForEach(state.sources) { source in
                    Text(source.label).tag(source.id)
                }
            }
            .pickerStyle(.inline)
            Divider()
            Button("Rafraîchir la liste") { state.refreshSources() }
        } label: {
            Label(state.selectedSource.label, systemImage: "waveform")
        }
        .labelStyle(.titleAndIcon)
        .accessibilityLabel("Source")
        .help("Source du son. Pendant une diffusion, en changer la relance.")
    }
}

/// Le bouton des options des vues sans barre latérale : la vue de la fenêtre, les options du Mac, et le
/// diagnostic.
struct WindowOptionsButton: View {
    @Bindable var state: BridgeState
    var showDiagnostics: () -> Void
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            Label("Options", systemImage: "ellipsis")
        }
        .help("Options : vue de la fenêtre, options du Mac, diagnostic")
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 0) {
                MacOptions(state: state)
                Divider()
                Button {
                    isPresented = false
                    showDiagnostics()
                } label: {
                    Label("Diagnostic…", systemImage: "waveform.path.ecg")
                }
                .buttonStyle(.borderless)
                .padding(16)
            }
        }
    }
}
