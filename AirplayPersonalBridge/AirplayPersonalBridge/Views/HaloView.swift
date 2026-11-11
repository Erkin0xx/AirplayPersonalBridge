//
//  HaloView.swift
//  AirplayPersonalBridge
//

import SwiftUI

/// Les mesures de la vue « Halo » : la sphère, et l'anneau du volume autour d'elle.
nonisolated enum HaloMetrics {
    /// De la fenêtre la plus petite à la maquette (280 pt sur 1200 × 760). Le plancher ne descend pas avec
    /// la fenêtre : plus petite, la sphère qui respire toucherait la bande où l'anneau se saisit. C'est ce
    /// qui l'entoure qui cède (`HaloLayout`), et elle tient encore dans la fenêtre de 440 × 400.
    static let sphereRange: ClosedRange<CGFloat> = 150...280
    /// Le rayon de l'anneau, en rayons de sphère : celui de la maquette (172 pour 140).
    static let ringRatio: CGFloat = 172.0 / 140.0
    /// Ce qui dépasse du trait de l'anneau de chaque côté : son bouton, la bande qui répond à la souris
    /// et son anneau de focus.
    static let ringOverhang: CGFloat = 18

    /// Le diamètre de la sphère pour cette place : la plus grande dont l'anneau tient en entier, dans
    /// les bornes de `sphereRange`.
    static func sphereDiameter(fitting zone: CGSize) -> CGFloat {
        let side = min(zone.width, zone.height)
        let fitted = (side - 2 * ringOverhang) / ringRatio
        return min(max(fitted, sphereRange.lowerBound), sphereRange.upperBound)
    }

    static func ringRadius(forSphere diameter: CGFloat) -> CGFloat {
        diameter / 2 * ringRatio
    }

    /// La hauteur qu'il faut au halo le plus petit, anneau compris.
    static var minimumZoneHeight: CGFloat {
        sphereRange.lowerBound * ringRatio + 2 * ringOverhang
    }
}

/// La vue « Halo » selon la taille de la fenêtre : hors de la vue pour être testé.
///
/// La sphère prend la hauteur qui reste (`HaloMetrics.sphereDiameter`). Ce palier décide de ce qui
/// l'entoure : à partir de l'ancienne taille minimale (`WindowSizing.roomy`) rien ne change ; en deçà, les
/// pastilles tiennent sur une rangée qui défile, puis se réduisent, le titre rapetisse, la ligne d'aide
/// s'en va, et les alertes quittent leur coin pour une ligne sous le titre.
nonisolated struct HaloLayout: Equatable {
    enum Chips: Equatable {
        /// Jusqu'à deux rangées centrées, comme toujours.
        case wrapped
        /// Une seule rangée, qui défile ; le silence et la recherche restent épinglés à droite.
        case row
        /// La même rangée, en pastilles réduites : le rond, le nom, et les réglages au clic.
        case compactRow
    }

    var chips: Chips
    var titleSize: CGFloat
    /// La ligne d'aide sous le titre (« Clique sur le halo pour arrêter »).
    var showsSubtitle: Bool
    /// Les alertes flottent dans le coin. Sinon elles tiennent en une ligne sous le titre, à la place de
    /// l'aide : dans le coin, elles recouvriraient l'anneau.
    var floatsNotices: Bool
    var chipsTop: CGFloat
    var sidePadding: CGFloat
    var bottomPadding: CGFloat

    /// En deçà, deux pastilles entières ne tiennent plus à côté des commandes rondes.
    static var compactChipsWidth: CGFloat {
        2 * HaloChipMetrics.width + 2 * HaloChipMetrics.spacing + HaloChipMetrics.controlsWidth + 2 * 24
    }

    static func make(size: CGSize) -> HaloLayout {
        let isRoomy = size.width >= WindowSizing.roomy.width && size.height >= WindowSizing.roomy.height
        let chips: Chips =
            if size.width < compactChipsWidth {
                .compactRow
            } else if size.height < WindowSizing.roomy.height {
                .row
            } else {
                .wrapped
            }
        let byHeight: CGFloat = size.height >= WindowSizing.roomy.height ? 28 : (size.height >= 500 ? 22 : 19)
        let byWidth: CGFloat = size.width >= 560 ? 28 : 22
        let isTight = size.height < 500
        return HaloLayout(
            chips: chips, titleSize: min(byHeight, byWidth), showsSubtitle: size.height >= 520,
            floatsNotices: isRoomy, chipsTop: isTight ? 12 : 18,
            sidePadding: size.width < 560 ? 16 : 24, bottomPadding: isTight ? 14 : 20
        )
    }
}

/// Ce que la vue « Halo » dit sous la sphère : hors de la vue pour être testé.
enum HaloCopy {
    /// La ligne sous le titre : ce qui ne va pas s'il y a quelque chose, puis ce que fait un clic sur le
    /// halo. Le titre (`BridgeStatusSummary.title`) dit déjà où en est la diffusion.
    static func subtitle(
        phase: BridgeState.StreamingPhase, detail: String?, sourceLabel: String, alertTitle: String?,
        isMuted: Bool, hasStartFailure: Bool, canToggle: Bool, hasSpeakers: Bool
    ) -> String {
        switch phase {
        case .starting:
            return "Connexion aux enceintes…"
        case .stopping:
            return "Fermeture des sessions…"
        case .idle:
            // Le halo ne répond pas : dire pourquoi, pas quoi cliquer.
            guard hasSpeakers else { return "Aucune enceinte pour l'instant" }
            guard canToggle else { return "Coche une enceinte pour diffuser" }
            if hasStartFailure { return "Clique sur le halo pour réessayer" }
            return [detail, "clique sur le halo pour diffuser"].compactMap { $0 }.joined(separator: " · ")
        case .running:
            // Une relance : le halo ne répond pas, la source suffit.
            guard canToggle else { return detail ?? sourceLabel }
            // La source est déjà dans la barre d'outils : le détail ne vaut que s'il dit autre chose.
            let note = detail.flatMap { $0 == sourceLabel ? nil : $0 }
            // Une phrase entière se suffit : « La diffusion s'arrête dans un instant. »
            if let note, note.hasSuffix(".") { return note }
            let trouble = note ?? alertTitle ?? (isMuted ? "Son coupé" : nil)
            guard let trouble else { return "Clique sur le halo pour arrêter" }
            return "\(trouble) · clique sur le halo pour arrêter"
        }
    }
}

extension BridgeState {
    /// Un son part vraiment vers au moins une enceinte : c'est ce qui fait vivre la sphère, ses ondes et
    /// les égaliseurs. Plus strict que `isAudiblyStreaming`, qui est vrai dès que la capture tourne :
    /// pendant « Connexion… », aucune enceinte ne joue encore, et des ondes diraient le contraire.
    var isHaloAudible: Bool {
        isAudiblyStreaming
            && outputs.contains { $0.isEnabled && !$0.isMuted && $0.connection == .streaming }
    }
}

/// Où est la sphère dans la vue : les ondes, dessinées derrière tout le reste, partent de là.
private nonisolated struct HaloSphereBoundsKey: PreferenceKey {
    static var defaultValue: Anchor<CGRect>? { nil }

    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = value ?? nextValue()
    }
}

/// La vue « Halo » de la fenêtre : un seul objet au centre, qui respire quand le son passe.
///
/// La sphère est la commande Diffuser / Arrêter, l'anneau qui l'entoure le volume général, et les
/// enceintes tiennent en pastilles au pied de la vue. Le fond, la source et les options sont à
/// `ContentView` : cette vue ne dessine que son contenu.
struct HaloView: View {
    @Bindable var state: BridgeState
    /// La place des commandes flottantes de la fenêtre, en haut. La vue la réserve elle-même, au lieu de
    /// la recevoir en marge de `ContentView` : ses ondes, dessinées derrière elle, vont ainsi jusqu'au bord
    /// haut de la fenêtre. Posée en marge autour de la vue, elle les coupait net sous la source.
    var topInset: CGFloat = 0

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// La taille de la vue, mesurée : c'est elle qui décide du palier (`HaloLayout`).
    @State private var viewSize = CGSize(width: 1200, height: 760)
    @State private var showsNotices = false

    var body: some View {
        let isAudible = state.isHaloAudible
        let layout = HaloLayout.make(size: viewSize)
        VStack(spacing: 0) {
            GeometryReader { zone in
                halo(diameter: HaloMetrics.sphereDiameter(fitting: zone.size), isAudible: isAudible)
                    .position(x: zone.size.width / 2, y: zone.size.height / 2)
            }
            .frame(minHeight: HaloMetrics.minimumZoneHeight)
            headline(layout)
            HaloSpeakerChips(state: state, isAudible: isAudible, mode: layout.chips)
                .padding(.top, layout.chipsTop)
        }
        .padding(.horizontal, layout.sidePadding)
        .padding(.bottom, layout.bottomPadding)
        .padding(.top, topInset)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { viewSize = $0 }
        // Les ondes, derrière tout et sur toute la vue : elles passent sous le titre, les pastilles et les
        // commandes flottantes, sans autre bord que ceux de la fenêtre.
        .backgroundPreferenceValue(HaloSphereBoundsKey.self) { anchor in
            GeometryReader { proxy in
                // Un décor, masquable depuis les Réglages (`WindowBlock.haloWaves`).
                if let anchor, state.isVisible(.haloWaves) {
                    let sphere = proxy[anchor]
                    let insets = proxy.safeAreaInsets
                    HaloWaves(
                        center: CGPoint(x: sphere.midX + insets.leading, y: sphere.midY + insets.top),
                        sphereRadius: sphere.width / 2, isAudible: isAudible
                    )
                    .ignoresSafeArea()
                }
            }
        }
        // Les alertes flottent dans le coin : elles ne poussent ni le halo ni les pastilles.
        .overlay(alignment: .topLeading) {
            if layout.floatsNotices { notices.padding(.top, topInset) }
        }
        .animation(PanelMotion.standard(reduceMotion: reduceMotion), value: state.startFailure)
        .animation(PanelMotion.standard(reduceMotion: reduceMotion), value: state.captureAlert)
    }

    // MARK: - Halo

    private var isStopSide: Bool {
        state.streamingPhase == .running || state.streamingPhase == .stopping
    }

    private func halo(diameter: CGFloat, isAudible: Bool) -> some View {
        let look: HaloSphere.Look = state.streamingPhase == .running ? .live : .resting
        return ZStack {
            Button {
                state.toggleStreaming()
            } label: {
                HaloSphere(
                    look: look, isAudible: isAudible,
                    // Le pont, toujours : c'est le nom de la commande. Les trois points le temps d'une
                    // transition, comme dans la pastille du panneau.
                    glyph: state.status.menuBar == .connecting ? .connecting : .idle,
                    diameter: diameter
                )
                .id(look)
                .transition(.opacity)
            }
            .buttonStyle(HaloSphereButtonStyle())
            // ⌘↩ et non `.defaultAction` : Retour valide un champ, et cette validation ne doit pas faire
            // partir le son vers les enceintes.
            .keyboardShortcut(.return, modifiers: .command)
            // Rien à diffuser tant qu'aucune enceinte n'est cochée, et rien à annuler en pleine transition.
            .disabled(!state.canToggleStreaming)
            .help(isStopSide ? "Arrêter la diffusion (⌘↩)" : "Diffuser vers les enceintes cochées (⌘↩)")
            .accessibilityLabel(isStopSide ? "Arrêter la diffusion" : "Lancer la diffusion")
            .accessibilityValue(state.status.title)
            .anchorPreference(key: HaloSphereBoundsKey.self, value: .bounds) { $0 }
            .animation(reduceMotion ? nil : .smooth(duration: 0.45), value: look)

            // Le volume général masqué (`WindowBlock.masterVolume`) : l'anneau s'en va, la sphère garde sa
            // taille et sa place.
            if state.isVisible(.masterVolume) {
                HaloVolumeRing(
                    decibels: masterBinding, isMuted: $state.isMuted, range: BridgeSettings.Limits.masterDB,
                    radius: HaloMetrics.ringRadius(forSphere: diameter), isLive: isAudible
                )
            }
        }
    }

    /// Saisir l'anneau, c'est vouloir entendre : un son coupé se rétablit, comme dans le panneau.
    private var masterBinding: Binding<Double> {
        Binding(
            get: { state.masterVolumeDB },
            set: { value in
                if state.isMuted { state.isMuted = false }
                state.masterVolumeDB = value
            }
        )
    }

    // MARK: - Titre

    private func headline(_ layout: HaloLayout) -> some View {
        VStack(spacing: 4) {
            Text(state.status.title)
                .font(.system(size: layout.titleSize, weight: .bold))
                .tracking(-0.5)
                .minimumScaleFactor(0.7)
                .accessibilityAddTraits(.isHeader)
            if !layout.floatsNotices, state.startFailure != nil || state.captureAlert != nil {
                inlineNotice
            } else if layout.showsSubtitle {
                subtitle
            }
        }
        .lineLimit(1)
        // Les ondes passent dessous : une ombre garde le texte lisible sur une bande claire.
        .shadow(color: .black.opacity(0.35), radius: 6, y: 1)
        .accessibilityElement(children: .contain)
    }

    private var subtitle: some View {
            Text(
                HaloCopy.subtitle(
                    phase: state.streamingPhase, detail: state.status.detail,
                    sourceLabel: state.selectedSource.label, alertTitle: state.captureAlert?.title,
                    isMuted: state.isMuted, hasStartFailure: state.startFailure != nil,
                    canToggle: state.canToggleStreaming, hasSpeakers: !state.outputs.isEmpty
                )
            )
            .font(.system(size: 15))
            .foregroundStyle(Color.white.opacity(0.86))
            .minimumScaleFactor(0.8)
    }

    // MARK: - Alertes

    /// Dans une petite fenêtre : l'alerte la plus grave en une ligne sous le titre, et les alertes entières
    /// au clic. Elle prend la place de la ligne d'aide, et reste là quand celle-ci n'a plus la sienne.
    private var inlineNotice: some View {
        let isCritical = state.startFailure != nil || state.captureAlert?.severity == .critical
        let name = state.startFailure == nil ? (state.captureAlert?.title ?? "") : "Démarrage impossible"
        // Le titre le dit parfois déjà (« Démarrage impossible ») : la ligne dit alors ce que fait le clic.
        let title = name == state.status.title ? "Voir pourquoi, et quoi faire" : name
        return Button {
            showsNotices.toggle()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: isCritical ? "exclamationmark.triangle.fill" : "exclamationmark.circle.fill")
                    .foregroundStyle(isCritical ? Color.red : Color.orange)
                    .accessibilityHidden(true)
                Text(title)
                    .foregroundStyle(Color.white.opacity(0.92))
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(Color.white.opacity(0.6))
                    .accessibilityHidden(true)
            }
            .font(.system(size: 13, weight: .semibold))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Afficher le détail, et ce qu'il faut faire")
        .accessibilityHint("Affiche l'alerte en entier.")
        .popover(isPresented: $showsNotices, arrowEdge: .top) {
            noticeRows
                .padding(6)
                .frame(width: 300)
        }
    }

    private var noticeRows: some View {
            VStack(alignment: .leading, spacing: 6) {
                if let failure = state.startFailure {
                    PanelNotice(
                        severity: .critical, title: "Démarrage impossible", detail: failure.message,
                        actionTitle: failure.settingsPane == nil ? nil : "Ouvrir les Réglages…",
                        action: { failure.settingsPane?.open() }
                    )
                }
                if let alert = state.captureAlert {
                    PanelNotice(
                        severity: alert.severity, title: alert.title, detail: alert.detail,
                        actionTitle: alert.settingsPane == nil ? nil : "Ouvrir les Réglages…",
                        action: { alert.settingsPane?.open() }
                    )
                }
            }
    }

    @ViewBuilder
    private var notices: some View {
        if state.startFailure != nil || state.captureAlert != nil {
            noticeRows
            .padding(6)
            .frame(width: 300)
            .floatingGlass(in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .padding(.leading, 16)
            .padding(.top, 8)
            .transition(.opacity)
        }
    }
}

#Preview("Diffusion") {
    ContentView(state: .preview(.streaming))
        .frame(width: 1200, height: 760)
}

#Preview("Repos") {
    ContentView(state: .preview(.idle))
        .frame(width: 1200, height: 760)
}
