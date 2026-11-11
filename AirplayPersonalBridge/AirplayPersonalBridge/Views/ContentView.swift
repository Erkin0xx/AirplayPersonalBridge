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
    /// La taille de la fenêtre, mesurée : c'est elle qui décide des paliers (`WindowSizing`).
    @State private var windowSize = CGSize(width: 1200, height: 760)
    /// Ce que les commandes de droite occupent en haut de la fenêtre, mesuré : la pastille s'en écarte.
    @State private var trailingControlsWidth = WindowChromeMetrics.controlHeight
    /// Ce que les outils du plan occupent de chaque côté, mesuré par la vue Plan.
    @State private var planToolWidths = PlanToolWidths()
    /// Le panneau des enceintes de la vue Plan, ouvert en surimpression quand il ne tient plus à côté.
    @State private var showsSpeakerPanel: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let preview: MainWindowPreviewOptions

    init(state: BridgeState, preview: MainWindowPreviewOptions = MainWindowPreviewOptions()) {
        self.state = state
        self.preview = preview
        _showsSpeakerPanel = State(initialValue: preview.showsSpeakerPanel)
    }

    /// Ce que les commandes occupent depuis le bord gauche de la fenêtre, marge comprise.
    private var chromeLeading: CGFloat {
        let controls = WindowChromeMetrics.sideMargin + WindowControlsMetrics.width
        guard state.windowLayout == .plan, planToolWidths.leading > 0 else { return controls }
        return controls + WindowControlsMetrics.trailingGap + planToolWidths.leading
    }

    /// Ce que les commandes occupent depuis le bord droit de la fenêtre, marge comprise.
    private var chromeTrailing: CGFloat {
        let controls = WindowChromeMetrics.sideMargin + trailingControlsWidth
        guard state.windowLayout == .plan, planToolWidths.trailing > 0 else { return controls }
        return controls + WindowChromeLayout.gap + planToolWidths.trailing
    }

    var body: some View {
        layout
        // Par-dessus chaque vue, sans barre d'outils : la source en pastille au centre, les options à droite.
        // Centrée tant qu'elle ne touche pas ses voisins, puis poussée, tronquée, et réduite à une icône.
        .overlay(alignment: .top) {
            let slot = WindowChromeLayout.pillSlot(
                windowWidth: windowSize.width, leading: chromeLeading, trailing: chromeTrailing
            )
            SourcePillLayout(leading: chromeLeading, trailing: chromeTrailing) {
                SourcePill(
                    state: state, maxWidth: slot, isIconOnly: WindowChromeLayout.pillIsIconOnly(slot: slot)
                )
            }
            .padding(.top, WindowChromeMetrics.topPadding)
        }
        // Fermer, réduire, agrandir : à la place des boutons système, masqués (`AppLifecycle`).
        .overlay(alignment: .topLeading) {
            WindowControls()
                .padding(.top, WindowControlsMetrics.top)
                .padding(.leading, WindowChromeMetrics.sideMargin)
        }
        .overlay(alignment: .topTrailing) {
            HStack(spacing: 8) {
                // Le lieu d'écoute de la console, en haut à droite à côté des options ; la vue Plan a le sien
                // dans ses outils.
                if state.windowLayout == .console, state.isVisible(.listeningPlaces) {
                    // En segments, en menu ou en icône, selon ce qui tient dans la place qui lui reste.
                    CappedWidthLayout(
                        maxWidth: WindowChromeLayout.listeningPlacesBudget(windowWidth: windowSize.width)
                    ) {
                        ConsoleListeningPlaces(state: state)
                    }
                }
                WindowOptionsButton(state: state, showDiagnostics: { showsDiagnostics = true })
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { trailingControlsWidth = $0 }
            .padding(.top, WindowChromeMetrics.topPadding)
            .padding(.trailing, WindowChromeMetrics.sideMargin)
        }
        // Le contenu passe sous la barre de titre, que la scène rend transparente (`hiddenTitleBar`) : elle
        // ne montre plus rien, mais c'est toujours par elle que la fenêtre se déplace.
        .ignoresSafeArea()
        .navigationTitle("AirPlay Personal Bridge")
        // Le titre reste celui de la fenêtre (menu Fenêtre, Mission Control), sans s'afficher.
        .toolbar(removing: .title)
        .toolbar(.hidden, for: .windowToolbar)
        .frame(minWidth: WindowSizing.minimum.width, minHeight: WindowSizing.minimum.height)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { windowSize = $0 }
        .onPreferenceChange(PlanToolWidths.Key.self) { planToolWidths = $0 }
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
            let plan = PlanWindowLayout.make(windowWidth: windowSize.width)
            RoomPlanView(
                state: state, initialSelection: preview.planSelection,
                contentInsets: EdgeInsets(
                    top: plan.overlayTop,
                    leading: plan.docksSidebar ? Self.panelInset : WindowChromeMetrics.sideMargin,
                    bottom: 60, trailing: WindowChromeMetrics.sideMargin
                ),
                window: plan, showsSpeakerPanel: $showsSpeakerPanel
            )
            .overlay(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: PlanWindowLayout.compactBarGap) {
                    // Le panneau replié : l'état, le silence et Diffuser/Arrêter restent sous la main.
                    if !plan.docksSidebar {
                        PlanCompactBar(state: state, showsPanel: $showsSpeakerPanel)
                            .frame(height: PlanWindowLayout.compactBarHeight)
                    }
                    if plan.docksSidebar || showsSpeakerPanel {
                        BridgeSidebar(state: state, showsStatus: plan.docksSidebar)
                            .frame(width: plan.sidebarWidth)
                            .floatingGlass(in: RoundedRectangle(cornerRadius: 26, style: .continuous))
                            .transition(.opacity)
                    }
                }
                .padding(.leading, WindowChromeMetrics.sideMargin)
                .padding(.top, WindowChromeMetrics.contentTop)
                .padding(.bottom, plan.sidebarBottom)
                .animation(PanelMotion.standard(reduceMotion: reduceMotion), value: showsSpeakerPanel)
            }
        case .halo:
            // La vue Halo réserve elle-même la place des commandes flottantes : une marge posée ici
            // rognerait ses ondes, qui doivent passer dessous jusqu'au bord haut de la fenêtre.
            immersive(topPadding: 0) { HaloView(state: state, topInset: Self.immersiveTop) }
        case .console:
            immersive { ConsoleView(state: state) }
        }
    }

    /// Le bord gauche de ce que le panneau des enceintes laisse visible du plan.
    private static let panelInset = WindowChromeMetrics.sideMargin + BridgeSidebar.panelWidth + 18

    /// Du haut de la fenêtre au contenu d'une vue sans plan.
    private static let immersiveTop = WindowChromeMetrics.contentTop - 8

    /// Une vue sans plan : son contenu sur le fond granuleux, sous les commandes flottantes.
    private func immersive(
        topPadding: CGFloat = ContentView.immersiveTop, @ViewBuilder _ content: () -> some View
    ) -> some View {
        content()
            .padding(.top, topPadding)
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
    /// Le panneau des enceintes ouvert en surimpression, quand la fenêtre est trop étroite pour le loger.
    var showsSpeakerPanel = false
}

#Preview {
    ContentView(state: .previewWithRoom())
        .frame(width: 1200, height: 760)
}
