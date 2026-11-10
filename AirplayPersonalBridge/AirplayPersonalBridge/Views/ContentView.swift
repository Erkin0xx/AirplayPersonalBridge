//
//  ContentView.swift
//  AirplayPersonalBridge
//

import SwiftUI

/// La fenêtre principale (CDC section 9, jalon 5).
///
/// Le plan d'abord : il occupe toute la fenêtre, et passe sous la barre latérale de verre où flottent
/// les commandes du son (source, master, sorties). Les outils du plan et l'action principale vivent dans
/// la barre d'outils, l'objet sélectionné dans l'inspecteur. Les commandes ont une largeur naturelle — un
/// curseur ne gagne rien à faire 700 points — alors que le plan, lui, profite de chaque point.
struct ContentView: View {
    /// Partagé avec le panneau de la barre de menus : c'est l'application qui le détient, la
    /// fenêtre peut se fermer et se rouvrir sans rien perdre.
    @Bindable var state: BridgeState
    @State private var showsDiagnostics = false
    private let preview: MainWindowPreviewOptions

    init(state: BridgeState, preview: MainWindowPreviewOptions = MainWindowPreviewOptions()) {
        self.state = state
        self.preview = preview
    }

    var body: some View {
        layout
        // Par-dessus chaque vue, sans barre d'outils : la source en pastille au centre, les options à droite.
        .overlay(alignment: .top) {
            SourcePill(state: state)
                .padding(.top, WindowChromeMetrics.topPadding)
        }
        .overlay(alignment: .topTrailing) {
            HStack(spacing: 8) {
                // Le lieu d'écoute de la console, en haut à droite à côté des options ; la vue Plan a le sien
                // dans ses outils.
                if state.windowLayout == .console, state.isVisible(.listeningPlaces) {
                    ConsoleListeningPlaces(state: state)
                }
                WindowOptionsButton(state: state, showDiagnostics: { showsDiagnostics = true })
            }
            .padding(.top, WindowChromeMetrics.topPadding)
            .padding(.trailing, WindowChromeMetrics.sideMargin)
        }
        // Le contenu passe sous la barre de titre, que la scène rend transparente (`hiddenTitleBar`) : seuls
        // les boutons de la fenêtre y restent.
        .ignoresSafeArea()
        .navigationTitle("AirPlay Personal Bridge")
        // Le titre reste celui de la fenêtre (menu Fenêtre, Mission Control), sans s'afficher.
        .toolbar(removing: .title)
        .toolbar(.hidden, for: .windowToolbar)
        .frame(minWidth: 960, minHeight: 620)
        // Le thème de l'app : sombre et rose, dans les trois vues.
        .tint(BridgeTheme.accent)
        .preferredColorScheme(.dark)
        // Les applications qui jouent changent sans prévenir : la liste doit être juste à
        // l'ouverture. La découverte, elle, tourne déjà sans fenêtre (`AppLifecycle`).
        .onAppear { state.refreshSources() }
        .sheet(isPresented: $showsDiagnostics) {
            DiagnosticsView(state: state, onClose: { showsDiagnostics = false })
        }
    }
}

extension ContentView {
    /// Les trois vues de la fenêtre (`WindowLayout`), sur le même état.
    @ViewBuilder
    fileprivate var layout: some View {
        switch state.windowLayout {
        case .plan:
            RoomPlanView(
                state: state, initialSelection: preview.planSelection,
                contentInsets: EdgeInsets(
                    top: WindowChromeMetrics.contentTop, leading: Self.panelInset,
                    bottom: 60, trailing: WindowChromeMetrics.sideMargin
                )
            )
            .overlay(alignment: .topLeading) {
                BridgeSidebar(state: state)
                    .frame(width: BridgeSidebar.panelWidth)
                    .floatingGlass(in: RoundedRectangle(cornerRadius: 26, style: .continuous))
                    .padding(.leading, WindowChromeMetrics.sideMargin)
                    .padding(.top, WindowChromeMetrics.contentTop)
                    .padding(.bottom, WindowChromeMetrics.sideMargin)
            }
        case .halo:
            immersive { HaloView(state: state) }
        case .console:
            immersive { ConsoleView(state: state) }
        }
    }

    /// Le bord gauche de ce que le panneau des enceintes laisse visible du plan.
    private static let panelInset = WindowChromeMetrics.sideMargin + BridgeSidebar.panelWidth + 18

    /// Une vue sans plan : son contenu sur le fond de nappes, sous les commandes flottantes.
    private func immersive(@ViewBuilder _ content: () -> some View) -> some View {
        content()
            .padding(.top, WindowChromeMetrics.contentTop - 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background { GrainientBackground(isLive: state.isAudiblyStreaming) }
    }
}

extension BridgeState {
    /// Un son part vraiment vers les enceintes : la diffusion tourne, rien ne signale de silence, et le
    /// son n'est pas coupé. C'est ce qui anime le fond, le halo et les ondes.
    var isAudiblyStreaming: Bool {
        streamingPhase == .running && captureAlert == nil && !isMuted
    }
}

/// Diffuser ou arrêter : la seule commande proéminente de la fenêtre.
///
/// Teintée de l'accent quand elle invite à démarrer, du rouge système quand elle arrête : c'est l'état
/// qu'elle dit, pas une décoration. Pendant une transition, elle garde son nom et sa largeur, et un témoin
/// remplace son icône ; c'est l'en-tête de la barre latérale qui dit « Démarrage… ».
struct StreamingCommand: View {
    let state: BridgeState

    var body: some View {
        let isStopSide = state.streamingPhase == .running || state.streamingPhase == .stopping
        let isTransition = state.streamingPhase == .starting || state.streamingPhase == .stopping
        Button {
            state.toggleStreaming()
        } label: {
            Label {
                Text(isStopSide ? "Arrêter" : "Diffuser")
            } icon: {
                if isTransition {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: isStopSide ? "stop.fill" : "play.fill")
                }
            }
            .labelStyle(.titleAndIcon)
            .frame(minWidth: 84)
        }
        .glassButtonStyle(prominent: true)
        .tint(isStopSide ? .red : BridgeTheme.accent)
        // ⌘↩ et non `.defaultAction` : Retour valide un champ de l'inspecteur du plan, et cette
        // validation ne doit pas faire partir le son vers les enceintes.
        .keyboardShortcut(.return, modifiers: .command)
        // Rien à diffuser tant qu'aucune sortie n'est cochée. Le cœur le supporterait
        // (une sortie absente n'empêche pas l'autre), mais l'action n'aurait aucun sens.
        .disabled(!state.canToggleStreaming)
        .help(isStopSide ? "Arrêter la diffusion (⌘↩)" : "Diffuser vers les sorties cochées (⌘↩)")
        .accessibilityLabel(isStopSide ? "Arrêter la diffusion" : "Lancer la diffusion")
    }
}

/// Ce que le rendu hors écran force, faute de souris : la fenêtre réelle ne s'en sert jamais.
struct MainWindowPreviewOptions {
    /// Les éléments du plan sélectionnés à l'ouverture, pour montrer l'inspecteur.
    var planSelection: Set<PlanElement> = []
}

#Preview {
    ContentView(state: .previewWithRoom())
        .frame(width: 1200, height: 760)
}
