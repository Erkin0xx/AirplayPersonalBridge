//
//  WidgetView.swift
//  AirplayPersonalBridge
//

import AppKit
import SwiftUI

/// Ce que le widget demande à l'app. Injecté : la vue se rend hors de toute fenêtre.
struct WidgetActions {
    var openMainWindow: () -> Void = {}
}

/// Le widget : l'app en 345 × 165 points, à la taille du widget d'horloge de Baptiste, dans une petite
/// fenêtre sans barre de titre qui reste au-dessus des autres (`WidgetWindow`).
///
/// Pas un widget WidgetKit : il n'accepterait pas de curseur, et la capture doit vivre dans le processus de
/// l'app (ADR 005). Il partage le `BridgeState` de la fenêtre et du panneau : ce qu'on y règle se voit
/// partout.
///
/// Deux styles, au choix (`WidgetStyle`), d'après les maquettes 23 et 24. Le fond est celui de l'app, dans
/// le rectangle arrondi ; aucune commande n'est rose. Tout ce qui se règle est fait des commandes de la
/// fenêtre (`HaloSphere`, `HaloVolumeRing`, `ConsoleFader`, `PanelVolumeSlider`), à d'autres mesures.
struct WidgetView: View {
    @Bindable var state: BridgeState
    var actions = WidgetActions()

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: WidgetMetrics.cornerRadius, style: .continuous)
        ZStack(alignment: .topLeading) {
            GrainientBackground(isLive: state.isAudiblyStreaming)
            WidgetFace(state: state, actions: actions)
        }
        .frame(width: WidgetMetrics.size.width, height: WidgetMetrics.size.height, alignment: .topLeading)
        .clipShape(shape)
        // Le bord du verre : un filet clair, à peine.
        .overlay { shape.strokeBorder(Color.white.opacity(0.1), lineWidth: 1).allowsHitTesting(false) }
        .environment(\.colorScheme, .dark)
        // Ce qui bouge suit la visibilité de la fenêtre du widget, pas le premier plan.
        .tracksWindowVisibility()
    }
}

/// Ce qui se saisit dans le widget, sans son décor : le fond qui déplace la fenêtre et porte le menu, et
/// par-dessus les commandes du style en cours. À part de `WidgetView` pour qu'un test relève ce que touche
/// un clic sans faire calculer le fond animé.
struct WidgetFace: View {
    @Bindable var state: BridgeState
    var actions = WidgetActions()

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Sous les commandes : un clic sur l'une d'elles ne l'atteint pas.
            WidgetBackdrop(
                entries: WidgetMenu.entries(for: state.widget),
                perform: { perform($0) }
            )
            switch state.widget.style {
            case .halo: WidgetHaloFace(state: state)
            case .band: WidgetBandFace(state: state)
            }
        }
        .frame(width: WidgetMetrics.size.width, height: WidgetMetrics.size.height, alignment: .topLeading)
    }

    private func perform(_ action: WidgetMenuAction) {
        if action == .openMainWindow { actions.openMainWindow() }
        WidgetMenu.apply(action, to: &state.widget)
    }
}

// MARK: - Style « Halo »

/// Maquette 23 : à gauche le disque de verre noir entouré de l'anneau blanc du volume général ; à droite
/// « GÉNÉRAL » et sa valeur, puis un curseur fin par enceinte.
private struct WidgetHaloFace: View {
    @Bindable var state: BridgeState

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isStopSide: Bool {
        state.streamingPhase == .running || state.streamingPhase == .stopping
    }

    var body: some View {
        let ringSide = HaloRingMetrics.widget.side(forRadius: WidgetMetrics.haloRingRadius)
        let header = WidgetMetrics.haloHeader
        ZStack(alignment: .topLeading) {
            dial
                .frame(width: ringSide, height: ringSide)
                .offset(
                    x: WidgetMetrics.haloCenter.x - ringSide / 2, y: WidgetMetrics.haloCenter.y - ringSide / 2
                )
            WidgetMasterHeader(state: state)
                .frame(width: header.width, height: header.height)
                .offset(x: header.minX, y: header.minY)
            WidgetSpeakerStrip(state: state, style: .halo)
        }
        .frame(width: WidgetMetrics.size.width, height: WidgetMetrics.size.height, alignment: .topLeading)
    }

    /// Le disque et son anneau : ceux de la vue Halo, en petit.
    private var dial: some View {
        let look: HaloSphere.Look = state.streamingPhase == .running ? .live : .resting
        let isAudible = state.isHaloAudible
        return ZStack {
            Button {
                state.toggleStreaming()
            } label: {
                HaloSphere(
                    look: look, isAudible: isAudible,
                    glyph: state.status.menuBar == .connecting ? .connecting : .idle,
                    diameter: WidgetMetrics.haloDiscDiameter
                )
                .id(look)
                .transition(.opacity)
            }
            .buttonStyle(HaloSphereButtonStyle())
            .disabled(!state.canToggleStreaming)
            .help(isStopSide ? "Arrêter la diffusion" : "Diffuser vers les enceintes cochées")
            .accessibilityLabel(isStopSide ? "Arrêter la diffusion" : "Lancer la diffusion")
            .accessibilityValue(state.status.title)
            .animation(reduceMotion ? nil : .smooth(duration: 0.45), value: look)

            HaloVolumeRing(
                decibels: TransportBar.master(of: state), isMuted: $state.isMuted,
                range: BridgeSettings.Limits.masterDB, radius: WidgetMetrics.haloRingRadius, isLive: isAudible,
                metrics: .widget
            )
        }
    }
}

/// « GÉNÉRAL » et la valeur du volume général.
private struct WidgetMasterHeader: View {
    let state: BridgeState

    var body: some View {
        HStack(spacing: 4) {
            Text("GÉNÉRAL")
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.5)
                .foregroundStyle(Color.white.opacity(0.76))
            Spacer(minLength: 0)
            Text(WidgetCopy.masterValue(isMuted: state.isMuted, decibels: state.masterVolumeDB))
                .font(.system(size: 10, weight: .semibold).monospacedDigit())
                .foregroundStyle(Color.white)
                .contentTransition(.numericText())
        }
        .lineLimit(1)
        // Le fond passe dessous : une ombre garde le texte lisible sur une bande claire.
        .shadow(color: .black.opacity(0.5), radius: 2, y: 1)
        // L'anneau et le curseur disent déjà leur valeur à VoiceOver.
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}

// MARK: - Style « Bandeau »

/// Maquette 24, modifiée par Baptiste : à gauche un bouton rond (blanc à triangle noir au repos ; le pont
/// qui ondule sur du verre noir quand ça joue), et sous lui le volume général en curseur couché, à la
/// place du titre d'état ; à droite une grande pastille-curseur par enceinte.
private struct WidgetBandFace: View {
    @Bindable var state: BridgeState

    var body: some View {
        let column = WidgetMetrics.bandColumn
        ZStack(alignment: .topLeading) {
            VStack(spacing: 0) {
                StreamingRoundButton(
                    state: state, diameter: WidgetMetrics.bandButtonDiameter, showsBridgeWhenLive: true
                )
                .padding(.top, 4)
                Spacer(minLength: 0)
                WidgetMasterHeader(state: state)
                    .padding(.horizontal, 2)
                    .padding(.bottom, 7)
                PanelVolumeSlider(
                    decibels: TransportBar.master(of: state), isMuted: $state.isMuted,
                    range: BridgeSettings.Limits.masterDB, look: .darkshell,
                    height: WidgetMetrics.bandSliderHeight, showsInlineValue: false
                )
                .contextMenu {
                    Button("Revenir à \(PanelFormat.decibels(BridgeState.defaultMasterVolumeDB))") {
                        state.masterVolumeDB = BridgeState.defaultMasterVolumeDB
                    }
                }
                .help("Volume de toutes les enceintes. Clic droit : revenir au niveau de départ.")
            }
            .frame(width: column.width, height: column.height)
            .offset(x: column.minX, y: column.minY)

            WidgetSpeakerStrip(state: state, style: .band)
        }
        .frame(width: WidgetMetrics.size.width, height: WidgetMetrics.size.height, alignment: .topLeading)
    }
}

// MARK: - Enceintes

/// La rangée des enceintes affichées (`BridgeState.visibleOutputs`), sur toute la hauteur du widget : trois
/// tiennent, moins se centrent, plus défilent (`WidgetSpeakerLayout`).
private struct WidgetSpeakerStrip: View {
    let state: BridgeState
    let style: WidgetStyle

    var body: some View {
        let outputs = state.visibleOutputs
        let layout = WidgetSpeakerLayout.make(count: outputs.count, style: style)
        Group {
            if outputs.isEmpty {
                Text(WidgetCopy.emptyMessage(isSearching: state.isBrowsing, allHidden: state.hidesEverySpeaker))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.76))
                    .multilineTextAlignment(.center)
                    .shadow(color: .black.opacity(0.5), radius: 2, y: 1)
                    .padding(.horizontal, WidgetSpeakerLayout.bleed + 8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .allowsHitTesting(false)
            } else if layout.scrolls {
                ScrollView(.horizontal, showsIndicators: false) {
                    row(outputs, layout: layout)
                }
                // Un chevron de chaque côté où il reste des enceintes : une souris à molette ne fait pas
                // défiler de côté.
                .modifier(HorizontalScrollChevrons(fade: WidgetSpeakerLayout.bleed))
            } else {
                // Sans défilement, pas de `ScrollView` : il prendrait pour lui les clics entre les
                // curseurs, et le fond ne se saisirait plus à cet endroit.
                row(outputs, layout: layout)
            }
        }
        .frame(width: layout.viewportWidth, height: WidgetMetrics.size.height)
        .offset(x: layout.viewportX)
    }

    /// Les enceintes côte à côte : centrées dans la fenêtre de défilement quand elles y tiennent.
    private func row(_ outputs: [OutputState], layout: WidgetSpeakerLayout) -> some View {
        HStack(alignment: .top, spacing: layout.spacing) {
            ForEach(outputs) { output in
                speaker(output)
            }
        }
        .padding(.horizontal, WidgetSpeakerLayout.bleed)
        .frame(minWidth: layout.viewportWidth, maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder
    private func speaker(_ output: OutputState) -> some View {
        let partners = state.stereoPartners(of: output).map(\.displayName)
        switch style {
        case .halo:
            WidgetSpeakerColumn(output: output, stereoPartnerNames: partners) { state.toggleEnabled(output) }
                .padding(.top, WidgetMetrics.haloFaderTop)
        case .band:
            WidgetSpeakerPill(output: output, stereoPartnerNames: partners) { state.toggleEnabled(output) }
                .padding(.top, WidgetMetrics.bandPillTop)
        }
    }
}

/// Ce que les deux formes d'une enceinte partagent : son état en mots, et ce qui grise sa commande.
private struct WidgetSpeakerTraits {
    let output: OutputState
    let stereoPartnerNames: [String]

    var isOffline: Bool { output.presence == .offline }
    /// Elle ne joue pas, ou ne jouera pas : sa commande est en retrait.
    var isDimmed: Bool { isOffline || !output.isEnabled || output.consoleIsHeldBack }
    /// Son curseur ne répond pas : décochée ou coupée comme dans la console, ou en attente d'une
    /// intervention. Hors ligne mais cochée, il se règle encore : c'est ce niveau qu'elle retrouvera.
    var isLocked: Bool { output.isMuted || !output.isEnabled || output.consoleIsHeldBack }

    var caption: WidgetCopy.Caption {
        WidgetCopy.caption(
            isOffline: isOffline, isHeldBack: output.consoleIsHeldBack, isEnabled: output.isEnabled,
            isMuted: output.isMuted, trimDB: output.trimDB
        )
    }

    var trimText: String { PanelFormat.decibels(output.trimDB, fractionDigits: 1, signed: true) }

    var symbol: String {
        SpeakerSymbol.name(
            displayName: output.displayName, proto: output.proto, unavailability: output.unavailability
        )
    }

    var toggleHelp: String {
        if let pair = PanelStereoPair.help(partners: stereoPartnerNames) { return pair }
        return output.isEnabled ? "Retirer cette enceinte de la diffusion" : "Diffuser vers cette enceinte"
    }

    var faderHelp: String {
        if output.consoleIsHeldBack {
            return output.statusLine?.text ?? "Cette enceinte ne peut pas jouer pour l'instant"
        }
        guard output.isEnabled else { return "Coche cette enceinte pour régler son volume" }
        return PanelSpeakerMute.sliderHelp(for: output) + ". Clic droit : revenir à 0 dB."
    }

    var accessibilityState: String {
        ([output.isEnabled ? "cochée" : "décochée", caption.tone == .value ? nil : caption.text]
            + [PanelStereoPair.accessibilityWords(partners: stereoPartnerNames)])
            .compactMap { $0 }.joined(separator: ", ")
    }

    func captionColor(_ tone: WidgetCopy.Tone) -> Color {
        switch tone {
        case .value: Color.white.opacity(0.76)
        case .quiet: Color.white.opacity(0.6)
        case .warning: BridgeTheme.orange
        }
    }

    /// Le curseur d'une enceinte : celui de la console, à d'autres mesures.
    func fader(size: CGSize, cornerRadius: CGFloat, floor: CGFloat) -> some View {
        ConsoleFader(
            value: Binding(get: { output.trimDB }, set: { output.trimDB = $0 }),
            range: BridgeSettings.Limits.trimDB, step: PanelToneStep.step, keyStep: PanelToneStep.step,
            isSilenced: output.isMuted || !output.isEnabled, mark: 0, width: size.width,
            cornerRadius: cornerRadius, metrics: .compact(width: size.width, floor: floor),
            label: "Volume de \(output.displayName)", valueText: caption.text
        )
        .frame(height: size.height)
        .contextMenu {
            Button("Revenir à \(PanelFormat.decibels(0))") { output.trimDB = 0 }
        }
        .disabled(isLocked)
        .opacity(isDimmed ? 0.45 : 1)
        .help(faderHelp)
    }
}

/// Une enceinte du style « Halo » : son curseur fin, puis son nom et sa valeur, qui la cochent.
private struct WidgetSpeakerColumn: View {
    @Bindable var output: OutputState
    var stereoPartnerNames: [String] = []
    var toggle: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let traits = WidgetSpeakerTraits(output: output, stereoPartnerNames: stereoPartnerNames)
        let caption = traits.caption
        let width = WidgetSpeakerLayout.make(count: 1, style: .halo).columnWidth
        VStack(spacing: 4) {
            traits.fader(
                size: WidgetMetrics.haloFader, cornerRadius: WidgetMetrics.haloFaderRadius,
                // Un pied de voile sous le trait, au minimum.
                floor: 8
            )
            Button {
                withAnimation(PanelMotion.standard(reduceMotion: reduceMotion)) { toggle() }
            } label: {
                VStack(spacing: 0) {
                    Text(output.displayName)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(traits.isDimmed ? 0.62 : 1))
                        .frame(height: 13)
                    Text(caption.text)
                        .font(.system(size: 9.5, weight: caption.tone == .value ? .regular : .medium).monospacedDigit())
                        .foregroundStyle(traits.captionColor(caption.tone))
                        .frame(height: 12)
                }
                .lineLimit(1)
                .truncationMode(.tail)
                .minimumScaleFactor(0.85)
                .shadow(color: .black.opacity(0.5), radius: 2, y: 1)
                .frame(width: width)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(traits.toggleHelp)
            .accessibilityLabel("Diffuser vers \(output.displayName)")
            .accessibilityValue(traits.accessibilityState)
            .accessibilityAddTraits(.isToggle)
        }
        .frame(width: width)
        .animation(PanelMotion.standard(reduceMotion: reduceMotion), value: output.isEnabled)
    }
}

/// Une enceinte du style « Bandeau » : la pastille entière est son curseur, que le niveau remplit d'un
/// voile gris sous un trait blanc. Son icône, en haut, la coche ; son nom et sa valeur logent au pied.
private struct WidgetSpeakerPill: View {
    @Bindable var output: OutputState
    var stereoPartnerNames: [String] = []
    var toggle: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// La cible de l'icône : plus large que le dessin.
    private static let iconTarget: CGFloat = 26

    var body: some View {
        let traits = WidgetSpeakerTraits(output: output, stereoPartnerNames: stereoPartnerNames)
        let caption = traits.caption
        let size = WidgetMetrics.bandPill
        ZStack {
            traits.fader(
                size: size, cornerRadius: WidgetMetrics.bandPillRadius, floor: WidgetMetrics.bandPillFloor
            )
            VStack(spacing: 0) {
                Button {
                    withAnimation(PanelMotion.standard(reduceMotion: reduceMotion)) { toggle() }
                } label: {
                    Image(systemName: traits.symbol)
                        // D'une seule teinte : le HomePod sortait gris, son seul sommet en blanc.
                        .symbolRenderingMode(.monochrome)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Color.white.opacity(traits.isDimmed ? 0.5 : 0.95))
                        .shadow(color: .black.opacity(0.6), radius: 1.5, y: 1)
                        .frame(width: Self.iconTarget, height: Self.iconTarget)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .padding(.top, 4)
                .help(traits.toggleHelp)
                .accessibilityLabel("Diffuser vers \(output.displayName)")
                .accessibilityValue(traits.accessibilityState)
                .accessibilityAddTraits(.isToggle)
                Spacer(minLength: 0)
                // Le nom et la valeur ne prennent pas la main : dessous, c'est encore le curseur.
                VStack(spacing: 0) {
                    Text(output.displayName)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(traits.isDimmed ? 0.66 : 1))
                        .frame(height: 12)
                    Text(caption.text)
                        .font(.system(size: 9, weight: caption.tone == .value ? .regular : .medium).monospacedDigit())
                        .foregroundStyle(
                            caption.tone == .value ? Color.white.opacity(0.8) : traits.captionColor(caption.tone)
                        )
                        .frame(height: 11)
                }
                .lineLimit(1)
                .truncationMode(.tail)
                .minimumScaleFactor(0.85)
                .shadow(color: .black.opacity(0.8), radius: 1.5, y: 1)
                .padding(.horizontal, 4)
                .padding(.bottom, 7)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        }
        .frame(width: size.width, height: size.height)
        .animation(PanelMotion.standard(reduceMotion: reduceMotion), value: output.isEnabled)
    }
}

// MARK: - Fond saisissable

/// Le fond du widget, côté AppKit : on le saisit pour déplacer la fenêtre, et son clic droit ouvre le menu
/// du widget.
///
/// Une vue AppKit plutôt qu'un geste SwiftUI : `performDrag` remet le déplacement au serveur de fenêtres,
/// qui le suit sans à-coups et sans que l'app passe au premier plan. Les commandes sont posées par-dessus
/// et gardent leurs gestes : `isMovableByWindowBackground` aurait aussi déplacé la fenêtre sous un curseur
/// qu'on glisse.
struct WidgetBackdrop: NSViewRepresentable {
    var entries: [WidgetMenuEntry]
    var perform: (WidgetMenuAction) -> Void

    func makeNSView(context: Context) -> BackdropView {
        let view = BackdropView()
        view.entries = entries
        view.perform = perform
        return view
    }

    func updateNSView(_ view: BackdropView, context: Context) {
        view.entries = entries
        view.perform = perform
    }

    final class BackdropView: NSView {
        var entries: [WidgetMenuEntry] = []
        var perform: (WidgetMenuAction) -> Void = { _ in }

        /// Le widget n'est jamais la fenêtre active : son premier clic doit déjà compter.
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }

        override func menu(for event: NSEvent) -> NSMenu? {
            makeMenu()
        }

        /// Le menu du fond, d'après sa description (`WidgetMenu`).
        func makeMenu() -> NSMenu {
            let menu = NSMenu()
            menu.autoenablesItems = false
            for (index, entry) in entries.enumerated() {
                guard entry.action != nil else {
                    menu.addItem(.separator())
                    continue
                }
                let item = NSMenuItem(title: entry.title, action: #selector(fire(_:)), keyEquivalent: "")
                item.target = self
                // La ligne porte son rang : l'action se relit dans la description du menu.
                item.tag = index
                item.state = entry.isChecked ? .on : .off
                menu.addItem(item)
            }
            return menu
        }

        @objc func fire(_ item: NSMenuItem) {
            // Un séparateur a le rang 0 par défaut : il ne doit pas passer pour la première ligne.
            guard !item.isSeparatorItem, entries.indices.contains(item.tag),
                let action = entries[item.tag].action
            else { return }
            perform(action)
        }

        override func accessibilityRole() -> NSAccessibility.Role? { .group }
        override func accessibilityLabel() -> String? { "Fond du widget" }
    }
}

#Preview("Halo, diffusion") {
    WidgetView(state: .preview(.streaming)).padding(30)
}

#Preview("Bandeau, repos") {
    let state = BridgeState.preview(.offline)
    state.widget.style = .band
    return WidgetView(state: state).padding(30)
}
