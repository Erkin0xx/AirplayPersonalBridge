//
//  WindowChrome.swift
//  AirplayPersonalBridge
//

import SwiftUI

/// Ce que les trois vues de la fenêtre partagent par-dessus leur contenu : les commandes de fenêtre en haut
/// à gauche (`WindowControls`), la source en pastille en haut au centre, le bouton des options en haut à
/// droite, et le choix de la vue. Pas de barre d'outils : tout flotte
/// au-dessus du fond (demande de Baptiste du 2026-11-10).
enum WindowChromeMetrics {
    /// Du haut de la fenêtre aux commandes flottantes.
    static let topPadding: CGFloat = 8
    static let controlHeight: CGFloat = 36
    /// Du haut de la fenêtre au contenu, sous les commandes flottantes.
    static let contentTop: CGFloat = 56
    /// Des bords de la fenêtre aux éléments flottants.
    static let sideMargin: CGFloat = 14
    /// La place des commandes de fenêtre (`WindowControls`, qui remplacent les boutons rouge, orange et
    /// vert), marge et écart compris : c'est là que commencent les outils du plan.
    static let trafficLightsWidth: CGFloat =
        sideMargin + WindowControlsMetrics.width + WindowControlsMetrics.trailingGap
}

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

/// La source, en pastille de verre : son nom et un chevron, qui ouvrent la liste des sources.
///
/// Quand la fenêtre se resserre, le nom se tronque à la place qui reste entre ses voisins, puis laisse la
/// place à une icône (`WindowChromeLayout`) : le menu, lui, dit toujours la source en entier.
struct SourcePill: View {
    @Bindable var state: BridgeState
    /// La largeur que la pastille ne dépasse pas : ce qui reste entre ses voisins.
    var maxWidth: CGFloat = .infinity
    /// Plus la place d'un nom : une icône et le chevron.
    var isIconOnly = false

    var body: some View {
        // Des identifiants, pas des valeurs : les PID d'une application varient d'un relevé à l'autre.
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
            HStack(spacing: 7) {
                if isIconOnly {
                    Image(systemName: "waveform")
                        .font(.body.weight(.semibold))
                        .accessibilityHidden(true)
                } else {
                    Text(state.selectedSource.label)
                        .font(.body.weight(.semibold))
                        .lineLimit(1)
                }
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.bold))
                    .accessibilityHidden(true)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, isIconOnly ? 12 : 18)
            .frame(maxWidth: isIconOnly ? nil : maxWidth)
            .frame(height: WindowChromeMetrics.controlHeight)
            .floatingGlass(in: Capsule(), interactive: true)
            .contentShape(Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Source du son : \(state.selectedSource.label). Pendant une diffusion, en changer la relance.")
        .accessibilityLabel("Source")
        .accessibilityValue(state.selectedSource.label)
    }
}

/// Le bouton des options, rond, en verre : la vue de la fenêtre, les options du Mac, et le diagnostic.
struct WindowOptionsButton: View {
    @Bindable var state: BridgeState
    var showDiagnostics: () -> Void
    @Environment(\.openSettings) private var openSettings
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            Image(systemName: "ellipsis")
                .font(.body.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: WindowChromeMetrics.controlHeight, height: WindowChromeMetrics.controlHeight)
                .floatingGlass(in: Circle(), interactive: true)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help("Options : vue de la fenêtre, options du Mac, réglages, diagnostic")
        .accessibilityLabel("Options")
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 0) {
                MacOptions(state: state)
                Divider()
                VStack(alignment: .leading, spacing: 10) {
                    // Ce qui est masqué se réaffiche là : la fenêtre des réglages de l'app (⌘,).
                    Button {
                        isPresented = false
                        AppSettingsWindow.open(openSettings)
                    } label: {
                        Label("Réglages…", systemImage: "gearshape")
                    }
                    .help("Vue de la fenêtre, enceintes et éléments masqués (⌘,)")
                    Button {
                        isPresented = false
                        state.widget.isShown.toggle()
                    } label: {
                        Label(WidgetCopy.toggleTitle(isShown: state.widget.isShown), systemImage: WidgetSymbol.name)
                    }
                    .help("Un widget posé sur le bureau : diffuser et régler les volumes")
                    Button {
                        isPresented = false
                        showDiagnostics()
                    } label: {
                        Label("Diagnostic…", systemImage: "waveform.path.ecg")
                    }
                }
                .buttonStyle(.borderless)
                .padding(16)
            }
        }
    }
}
