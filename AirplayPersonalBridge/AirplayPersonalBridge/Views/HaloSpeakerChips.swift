//
//  HaloSpeakerChips.swift
//  AirplayPersonalBridge
//

import SwiftUI

/// Les mesures des pastilles d'enceintes de la vue « Halo ».
nonisolated enum HaloChipMetrics {
    /// Quatre pastilles et les deux commandes rondes tiennent sur une rangée dans la fenêtre de 1200 pt,
    /// trois et les commandes dans celle de 960 pt.
    static let width: CGFloat = 252
    static let height: CGFloat = 64
    static let spacing: CGFloat = 12
    static let rowSpacing: CGFloat = 10
    /// Le rond blanc qui porte l'icône de chaque enceinte, et les commandes rondes au bout de la rangée.
    static let badge: CGFloat = 40
    /// Entre le silence général et la recherche, au bout de la rangée.
    static let controlSpacing: CGFloat = 8
    /// Les deux commandes rondes ensemble : elles passent à la ligne d'un bloc.
    static var controlsWidth: CGFloat { 2 * badge + controlSpacing }
    /// Au-delà de deux rangées, les pastilles défilent : le halo garde sa place.
    static let maxRows = 2
    static var maxHeight: CGFloat { CGFloat(maxRows) * height + CGFloat(maxRows - 1) * rowSpacing }
    /// La pastille réduite d'une petite fenêtre : le rond, le nom et le niveau. Deux tiennent à côté des
    /// commandes rondes dans la fenêtre la plus étroite.
    static let compactWidth: CGFloat = 128
    static let compactHeight: CGFloat = 48
    static let compactBadge: CGFloat = 36
    /// Le fondu des bords d'une rangée qui défile : il dit qu'il y a une suite.
    static let scrollFade: CGFloat = 18
}

/// Où vont les commandes rondes (silence général, recherche) : hors de la vue pour être testé.
nonisolated enum HaloChipsArrangement {
    /// Les commandes sortent-elles du défilement, épinglées à droite des pastilles ? Tant que tout tient
    /// sur `maxRows` rangées, elles suivent la dernière pastille. Au-delà, les pastilles défilent : laissées
    /// au bout, les commandes partiraient hors de vue, et le silence général doit rester sous la main.
    static func pinsControls(chipCount: Int, available: CGFloat) -> Bool {
        guard chipCount > 0, available.isFinite, available > 0 else { return false }
        let widths = Array(repeating: HaloChipMetrics.width, count: chipCount) + [HaloChipMetrics.controlsWidth]
        let rows = HaloFlowLayout.rows(widths: widths, available: available, spacing: HaloChipMetrics.spacing)
        return rows.count > HaloChipMetrics.maxRows
    }

    /// La largeur d'une rangée unique de pastilles, sans les commandes rondes.
    static func rowWidth(chipCount: Int, chipWidth: CGFloat) -> CGFloat {
        let count = max(chipCount, 0)
        return CGFloat(count) * chipWidth + CGFloat(max(count - 1, 0)) * HaloChipMetrics.spacing
    }
}

/// Ce que dit et quand se montre le silence général de la vue « Halo » : hors de la vue pour être testé.
nonisolated enum HaloMuteControl {
    /// Le bouton suit la dernière enceinte. Sans aucune enceinte il n'a rien à couper, mais un son déjà
    /// coupé doit toujours pouvoir se rétablir d'un clic.
    static func isShown(hasSpeakers: Bool, isMuted: Bool) -> Bool {
        hasSpeakers || isMuted
    }

    /// L'aide : ce que fait un clic, puis le niveau, que la vue n'écrit plus nulle part ailleurs.
    static func help(isMuted: Bool, level: String) -> String {
        let action = isMuted ? "Rétablir le son des enceintes" : "Couper le son des enceintes, sans les déconnecter"
        return "\(action) · volume général \(level)"
    }

    static func accessibilityValue(isMuted: Bool, level: String) -> String {
        "\(isMuted ? "activé" : "désactivé"), volume général \(level)"
    }
}

extension OutputState {
    /// Exige une intervention : la pastille s'efface, comme la carte de la barre latérale.
    fileprivate var isHeldBack: Bool {
        unavailability != nil && connection != .streaming
    }

    /// Ce que la pastille dit à la place du curseur : ce qui empêche l'enceinte de jouer. « Connexion… »
    /// n'en fait pas partie, le témoin tournant le dit déjà.
    fileprivate var chipMessage: (text: String, tone: OutputStatusTone)? {
        guard let line = statusLine else { return nil }
        if isHeldBack { return line }
        return line.tone == .muted ? nil : line
    }
}

/// Les enceintes, en pastilles de verre au pied de la vue « Halo ».
struct HaloSpeakerChips: View {
    @Bindable var state: BridgeState
    /// Un son part vraiment : les égaliseurs des enceintes qui diffusent peuvent bouger.
    let isAudible: Bool
    /// Deux rangées centrées, ou une seule qui défile, selon la taille de la fenêtre (`HaloLayout`).
    var mode: HaloLayout.Chips = .wrapped
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var contentHeight: CGFloat = HaloChipMetrics.height
    /// La largeur offerte à la rangée. Inconnue à la première passe : rien n'est épinglé.
    @State private var availableWidth: CGFloat = .infinity

    var body: some View {
        Group {
            if state.outputs.isEmpty {
                HStack(spacing: HaloChipMetrics.spacing) {
                    emptyOutputs
                    if HaloMuteControl.isShown(hasSpeakers: false, isMuted: state.isMuted) {
                        HaloMuteButton(state: state)
                    }
                }
            } else if mode != .wrapped {
                row(isCompact: mode == .compactRow)
            } else {
                let pinsControls = HaloChipsArrangement.pinsControls(
                    chipCount: state.visibleOutputs.count, available: availableWidth
                )
                HStack(spacing: HaloChipMetrics.spacing) {
                    chips(withControls: !pinsControls)
                    if pinsControls { controls }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { availableWidth = $0 }
    }

    /// Le silence général puis la recherche : au bout de la dernière rangée, ou épinglés à sa droite quand
    /// les pastilles défilent (`HaloChipsArrangement`).
    private var controls: some View {
        HStack(spacing: HaloChipMetrics.controlSpacing) {
            HaloMuteButton(state: state)
            searchButton
        }
        .frame(height: HaloChipMetrics.height)
    }

    /// Une seule rangée, pour une petite fenêtre : les pastilles défilent, le silence général et la
    /// recherche restent épinglés à leur droite. Tant que tout tient, la rangée est centrée.
    private func row(isCompact: Bool) -> some View {
        let outputs = PanelSpeakerOrder.sorted(state.visibleOutputs)
        let chipWidth = isCompact ? HaloChipMetrics.compactWidth : HaloChipMetrics.width
        let height = isCompact ? HaloChipMetrics.compactHeight : HaloChipMetrics.height
        return HStack(spacing: HaloChipMetrics.spacing) {
            if state.hidesEverySpeaker {
                AllSpeakersHiddenNotice()
                    .glassButtonStyle()
                    .padding(.horizontal, 20)
                    .frame(minHeight: HaloChipMetrics.height)
                    .floatingGlass(in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            } else {
                ScrollView(.horizontal) {
                    HStack(spacing: HaloChipMetrics.spacing) {
                        ForEach(outputs) { output in chip(output, isCompact: isCompact) }
                    }
                }
                .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
                .scrollIndicators(.never)
                .frame(
                    maxWidth: HaloChipsArrangement.rowWidth(chipCount: outputs.count, chipWidth: chipWidth)
                )
                .frame(height: height)
                // Ce qui dépasse s'efface au bord, sous un chevron qui y mène.
                .modifier(HorizontalScrollChevrons(fade: HaloChipMetrics.scrollFade))
            }
            controls
        }
    }

    private func chip(_ output: OutputState, isCompact: Bool = false) -> some View {
        HaloSpeakerChip(
            output: output,
            effectiveGainDB: state.effectiveGainDB(for: output),
            listeningCompensationMS: state.listeningCompensationMS(for: output),
            listeningPlaceName: state.listeningPlaceName,
            stereoPartnerNames: state.stereoPartners(of: output).map(\.displayName),
            isAudible: isAudible,
            isCompact: isCompact,
            toggle: { state.toggleEnabled(output) },
            hide: { hide(output) }
        )
    }

    private func chips(withControls: Bool) -> some View {
        ScrollView(.vertical) {
            HaloFlowLayout(spacing: HaloChipMetrics.spacing, rowSpacing: HaloChipMetrics.rowSpacing) {
                // L'ordre du panneau : celles qui exigent une intervention passent en dernier.
                // Les masquées n'y sont pas : elles jouent toujours si elles sont cochées.
                ForEach(PanelSpeakerOrder.sorted(state.visibleOutputs)) { output in
                    chip(output)
                }
                if state.hidesEverySpeaker {
                    AllSpeakersHiddenNotice()
                        .glassButtonStyle()
                        .padding(.horizontal, 20)
                        .frame(height: HaloChipMetrics.height)
                        .floatingGlass(in: Capsule(style: .circular))
                }
                if withControls { controls }
            }
            .frame(maxWidth: .infinity)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
        }
        .scrollBounceBehavior(.basedOnSize)
        .scrollIndicators(.never)
        // La hauteur de ce qu'il contient, jusqu'à deux rangées : la vue ne réserve pas de vide.
        .frame(height: min(max(contentHeight, HaloChipMetrics.height), HaloChipMetrics.maxHeight))
    }

    private func hide(_ output: OutputState) {
        withAnimation(PanelMotion.standard(reduceMotion: reduceMotion)) {
            state.setHidden(true, for: output)
        }
    }

    /// La recherche, au bout des pastilles, à côté du silence général et à sa taille : le même cadre avec
    /// ou sans le témoin, elle revient régulièrement et la rangée ne doit pas tressauter.
    private var searchButton: some View {
        Group {
            if state.isBrowsing {
                ProgressView().controlSize(.small)
                    .accessibilityLabel("Recherche en cours")
            } else {
                Button {
                    Task { await state.refreshOutputs() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Color.primary.opacity(0.7))
                        .frame(width: HaloChipMetrics.badge, height: HaloChipMetrics.badge)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Rechercher les enceintes sur le réseau local")
                .accessibilityLabel("Rechercher les enceintes")
            }
        }
        .frame(width: HaloChipMetrics.badge, height: HaloChipMetrics.badge)
        .floatingGlass(in: Circle(), interactive: true)
    }

    // MARK: - Aucune enceinte

    /// Les mêmes mots que la barre latérale (`BridgeSidebar.emptyOutputs`), couchés : au pied de la vue,
    /// la hauteur compte.
    private var emptyOutputs: some View {
        HStack(spacing: 14) {
            if state.isBrowsing || !state.hasCompletedDiscovery {
                ProgressView().controlSize(.small)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Recherche des enceintes…").font(.headline)
                    Text("Elles apparaîtront ici dès qu'elles répondront.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } else {
                Image(systemName: "hifispeaker")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Aucune sortie").font(.headline)
                    Text(state.discoveryNotice ?? "Lance une recherche sur le réseau local.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: 380, alignment: .leading)
                VStack(spacing: 6) {
                    Button("Rechercher") { Task { await state.refreshOutputs() } }
                    if state.discoveryNotice != nil {
                        Button("Réseau local…") { SystemSettingsPane.localNetwork.open() }
                            .help("Ouvrir les réglages « Réseau local »")
                    }
                }
                .controlSize(.small)
                .glassButtonStyle()
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .floatingGlass(in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .accessibilityElement(children: .contain)
    }
}

/// Le silence général de la vue « Halo » : un rond de verre au bout de la rangée, de la taille du badge
/// des enceintes.
///
/// Il coupe et rétablit le son de toutes les enceintes sans rien déconnecter (`BridgeState.isMuted`,
/// comme `PanelMuteButton`). Enclenché, le rond devient blanc et son icône sombre, comme le badge d'une
/// enceinte cochée : jamais de rose sur une commande. Le bloc « Volume général » masqué
/// (`WindowBlock.masterVolume`) retire l'anneau, jamais ce bouton : un son coupé doit toujours se voir, et
/// se rétablir d'un clic. Le niveau, que l'anneau montre, se lit en chiffres dans son aide.
struct HaloMuteButton: View {
    @Bindable var state: BridgeState

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let isMuted = state.isMuted
        let level = PanelFormat.decibels(state.masterVolumeDB)
        Button {
            state.isMuted.toggle()
        } label: {
            Image(systemName: PanelMuteButton.symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(isMuted ? BridgeTheme.color(0x1D1D1F) : Color.primary.opacity(0.7))
                .frame(width: HaloChipMetrics.badge, height: HaloChipMetrics.badge)
                .background(isMuted ? Color.white : Color.clear, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .floatingGlass(in: Circle(), interactive: true)
        .animation(PanelMotion.standard(reduceMotion: reduceMotion), value: isMuted)
        .help(HaloMuteControl.help(isMuted: isMuted, level: level))
        .accessibilityLabel(PanelMuteButton.title)
        .accessibilityValue(HaloMuteControl.accessibilityValue(isMuted: isMuted, level: level))
        .accessibilityHint("Les enceintes restent connectées.")
        .accessibilityAddTraits(.isToggle)
    }
}

/// Une enceinte, en pastille : son badge qui la coche, son nom, puis son volume.
///
/// La pastille ne montre que ce qu'on règle en écoutant ; le délai, la tonalité et l'adresse sont un clic
/// plus loin, dans la même fenêtre surgissante que la carte de la barre latérale (`SpeakerSettings`).
/// Quand quelque chose empêche l'enceinte de jouer, le message prend la place du curseur : c'est lui
/// qu'on cherche alors, pas le volume — qui reste dans les réglages.
struct HaloSpeakerChip: View {
    @Bindable var output: OutputState
    let effectiveGainDB: Double
    var listeningCompensationMS: Double?
    var listeningPlaceName: String?
    /// Les autres membres de sa paire stéréo (`BridgeState.stereoPartners(of:)`).
    var stereoPartnerNames: [String] = []
    /// Un son part vraiment : l'égaliseur peut bouger.
    var isAudible = true
    /// Dans une petite fenêtre : le rond, le nom et le niveau ; le curseur et le silence de l'enceinte sont
    /// dans la fenêtre surgissante, au clic sur le nom.
    var isCompact = false
    /// Le clic sur le badge : `BridgeState.toggleEnabled(_:)`, qui emmène la paire stéréo.
    var toggle: () -> Void
    /// « Masquer » : au clic droit, et par l'œil barré qui apparaît au survol. Emmène la paire stéréo.
    var hide: (() -> Void)?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.revealsHoverControls) private var revealsHoverControls
    @State private var isHovering = false
    @State private var isAdjusting = false
    @State private var showsSettings = false
    @State private var showsMessage = false

    var body: some View {
        content
        .frame(
            width: isCompact ? HaloChipMetrics.compactWidth : HaloChipMetrics.width,
            height: isCompact ? HaloChipMetrics.compactHeight : HaloChipMetrics.height
        )
        .floatingGlass(in: Capsule(style: .circular))
        .opacity(output.isHeldBack ? 0.62 : 1)
        .onHover { isHovering = $0 }
        .animation(PanelMotion.quick(reduceMotion: reduceMotion), value: isHovering)
        .accessibilityElement(children: .contain)
        .hideSpeakerMenu(partners: stereoPartnerNames, action: hide)
    }

    @ViewBuilder
    private var content: some View {
        if isCompact { compact } else { regular }
    }

    // MARK: - Réduite

    /// Ce que la pastille réduite dit sous le nom : ce qui empêche l'enceinte de jouer, son niveau quand
    /// elle joue, sinon son état.
    private var compactCaption: (text: String, color: Color) {
        if let message = output.chipMessage { return (message.text, messageColor(message.tone)) }
        if output.isEnabled, !output.isMuted, output.connection == .streaming {
            return (PanelFormat.decibels(output.trimDB, fractionDigits: 1, signed: true), .secondary)
        }
        return (caption, .secondary)
    }

    private var compact: some View {
        let line = compactCaption
        return HStack(spacing: 7) {
            badge
            Button {
                if output.isHeldBack {
                    showsMessage.toggle()
                } else {
                    showsSettings.toggle()
                }
            } label: {
                VStack(alignment: .leading, spacing: 1) {
                    Text(output.displayName)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(output.isHeldBack || !output.isEnabled ? .secondary : .primary)
                        .truncationMode(.middle)
                    Text(line.text)
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(line.color)
                }
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(
                output.isHeldBack
                    ? line.text : "Réglages de \(output.displayName) : volume, silence, délai, tonalité"
            )
            .accessibilityLabel(output.isHeldBack ? line.text : "Réglages de \(output.displayName)")
            .accessibilityValue(line.text)
            .popover(isPresented: $showsSettings, arrowEdge: .top) {
                VStack(alignment: .leading, spacing: 0) {
                    // Ce qui l'empêche de jouer, en entier : la pastille n'en montre que le début.
                    if let message = output.chipMessage {
                        Text(message.text)
                            .font(.callout)
                            .foregroundStyle(messageColor(message.tone))
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                            .frame(maxWidth: 300, alignment: .leading)
                            .padding(.horizontal, 16)
                            .padding(.top, 14)
                    }
                    // Le silence de l'enceinte, que la pastille réduite n'a plus la place de porter.
                    Toggle(
                        "Couper cette enceinte",
                        isOn: Binding(get: { output.isMuted }, set: { _ in PanelSpeakerMute.toggle(output) })
                    )
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .disabled(!output.isEnabled)
                    .help("Couper cette enceinte seule, sans la déconnecter")
                    .padding(.horizontal, 16)
                    .padding(.top, 14)
                    SpeakerSettings(
                        output: output, effectiveGainDB: effectiveGainDB,
                        listeningCompensationMS: listeningCompensationMS, listeningPlaceName: listeningPlaceName,
                        stereoPartnerNames: stereoPartnerNames
                    )
                }
            }
            .background {
                // Sur une vue à part : deux fenêtres surgissantes sur le même bouton se disputent.
                Color.clear.popover(isPresented: $showsMessage, arrowEdge: .top) {
                    messagePopover(line.text)
                }
            }
        }
        .padding(.leading, 6)
        .padding(.trailing, 10)
    }

    // MARK: - Entière

    private var regular: some View {
        HStack(spacing: 10) {
            badge
            VStack(alignment: .leading, spacing: output.chipMessage == nil ? 5 : 1) {
                HStack(spacing: 6) {
                    Text(output.displayName)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(output.isHeldBack || !output.isEnabled ? .secondary : .primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 2)
                    indicator
                        .frame(width: 16, height: 16)
                    if let hide, isHovering || revealsHoverControls {
                        HideSpeakerButton(
                            name: output.displayName, partners: stereoPartnerNames,
                            isEnabled: output.isEnabled, action: hide
                        )
                        .transition(.opacity)
                    }
                    if !output.isHeldBack {
                        settingsButton
                    }
                }
                .frame(height: 22)
                detail
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 14)
    }

    // MARK: - Badge

    private var badge: some View {
        Button {
            withAnimation(PanelMotion.standard(reduceMotion: reduceMotion)) { toggle() }
        } label: {
            Image(
                systemName: SpeakerSymbol.name(
                    displayName: output.displayName, proto: output.proto, unavailability: output.unavailability
                )
            )
            .font(.system(size: isCompact ? 15 : 17, weight: .medium))
            .foregroundStyle(output.isEnabled ? BridgeTheme.color(0x1D1D1F) : Color.white.opacity(0.75))
            .frame(
                width: isCompact ? HaloChipMetrics.compactBadge : HaloChipMetrics.badge,
                height: isCompact ? HaloChipMetrics.compactBadge : HaloChipMetrics.badge
            )
            .background(output.isEnabled ? Color.white : Color.white.opacity(0.12), in: Circle())
            // Retenue mais absente du réseau : elle ne peut pas jouer, le badge ne doit pas l'affirmer.
            .opacity(output.presence == .offline ? 0.55 : 1)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(PanelStereoPair.help(partners: stereoPartnerNames) ?? toggleHelp)
        .accessibilityLabel("Diffuser vers \(output.displayName)")
        .accessibilityValue(output.isEnabled ? "cochée, \(caption)" : "décochée")
        .accessibilityHint(PanelStereoPair.accessibilityHint(partners: stereoPartnerNames) ?? "")
        .accessibilityAddTraits(.isToggle)
    }

    private var toggleHelp: String {
        output.isEnabled ? "Retirer cette enceinte de la diffusion" : "Diffuser vers cette enceinte"
    }

    private var caption: String {
        SpeakerCardCaption.text(
            connection: output.connection, isEnabled: output.isEnabled, isMuted: output.isMuted,
            proto: output.proto.rawValue, partners: stereoPartnerNames
        )
    }

    // MARK: - Témoin

    @ViewBuilder
    private var indicator: some View {
        if output.isEnabled {
            switch output.connection {
            case .connecting, .waiting, .reconnecting:
                ProgressView()
                    .controlSize(.mini)
                    .accessibilityHidden(true)
            case .failed:
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .accessibilityHidden(true)
            case .streaming:
                // Elle reçoit, et un son part : le seul cas où l'égaliseur a le droit de bouger.
                HaloEqualiser(isMoving: isAudible && !output.isMuted)
            case .idle:
                HaloEqualiser(isMoving: false)
            }
        }
    }

    private var settingsButton: some View {
        Button {
            showsSettings.toggle()
        } label: {
            Image(systemName: "slider.horizontal.3")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Color.primary.opacity(isHovering || showsSettings ? 0.8 : 0.45))
                .frame(width: 22, height: 22)
                .background(showsSettings ? PanelPalette.press : Color.clear, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help("Réglages de \(output.displayName) : délai, tonalité, adresse")
        .accessibilityLabel("Réglages de \(output.displayName)")
        .popover(isPresented: $showsSettings, arrowEdge: .top) {
            SpeakerSettings(
                output: output, effectiveGainDB: effectiveGainDB,
                listeningCompensationMS: listeningCompensationMS, listeningPlaceName: listeningPlaceName,
                stereoPartnerNames: stereoPartnerNames
            )
        }
    }

    // MARK: - Seconde ligne

    @ViewBuilder
    private var detail: some View {
        if let message = output.chipMessage {
            messageLine(message.text, tone: message.tone)
        } else if output.isEnabled {
            volume
        } else {
            Text(caption)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, minHeight: 18, alignment: .leading)
        }
    }

    /// Deux lignes au plus dans la pastille ; un clic donne le message entier, qui dit quoi faire.
    private func messageLine(_ text: String, tone: OutputStatusTone) -> some View {
        Button {
            showsMessage.toggle()
        } label: {
            Text(text)
                .font(.subheadline)
                .foregroundStyle(messageColor(tone))
                .lineLimit(2)
                .truncationMode(.tail)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, minHeight: 18, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(text)
        .accessibilityLabel(text)
        .accessibilityHint("Affiche le message en entier.")
        .popover(isPresented: $showsMessage, arrowEdge: .top) {
            messagePopover(text)
        }
    }

    private func messagePopover(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(output.displayName).font(.headline)
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .padding(16)
        .frame(width: 320, alignment: .leading)
    }

    private func messageColor(_ tone: OutputStatusTone) -> Color {
        if output.isHeldBack { return .secondary }
        switch tone {
        case .muted: return .secondary
        case .warning: return PanelPalette.warningText
        case .critical: return PanelPalette.criticalText
        }
    }

    /// Le volume de l'enceinte, avec son silence au bout : coupée, elle reste dans la diffusion, et son
    /// curseur reste là, grisé.
    private var volume: some View {
        HStack(spacing: 4) {
            Slider(
                value: Binding(get: { output.trimDB }, set: { output.trimDB = ($0 * 2).rounded() / 2 }),
                in: BridgeSettings.Limits.trimDB,
                onEditingChanged: { isAdjusting = $0 }
            ) {
                Text("Volume de \(output.displayName)")
            }
            .labelsHidden()
            .controlSize(.mini)
            .tint(.white)
            .disabled(output.isMuted)
            .opacity(output.isMuted ? PanelSpeakerMute.mutedSliderOpacity : 1)
            .help(PanelSpeakerMute.sliderHelp(for: output))
            .accessibilityValue(PanelFormat.decibels(output.trimDB, fractionDigits: 1, signed: true))

            Text(PanelFormat.decibels(output.trimDB, fractionDigits: 1, signed: true))
                .font(.caption.monospacedDigit())
                .foregroundStyle(isAdjusting ? .primary : .secondary)
                .lineLimit(1)
                .frame(width: 50, alignment: .trailing)
                .accessibilityHidden(true)

            PanelSpeakerMuteButton(output: output, width: 22)
        }
        .frame(height: 18)
    }
}

/// Le petit égaliseur d'une pastille : trois barres, qui ne bougent que si l'enceinte joue vraiment.
///
/// Comme le glyphe de l'en-tête, ce n'est pas un vumètre : le pipeline ne mesure aucun niveau. Il dit
/// « un son part vers celle-ci », et se couche dès que ce n'est plus vrai.
struct HaloEqualiser: View {
    let isMoving: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.windowIsOnScreen) private var isOnScreen

    var body: some View {
        Group {
            if isMoving && !reduceMotion {
                TimelineView(.animation(minimumInterval: 1 / 20, paused: !isOnScreen)) { timeline in
                    canvas(at: timeline.date.timeIntervalSinceReferenceDate)
                }
            } else {
                // Elle joue mais le mouvement est réduit : les barres restent dressées, sans bouger.
                canvas(at: nil).opacity(isMoving ? 1 : 0.45)
            }
        }
        .frame(width: 16, height: 16)
        .accessibilityHidden(true)
    }

    private func canvas(at time: TimeInterval?) -> some View {
        Canvas { context, size in
            let bars = HaloEqualiserMotion.bars
            var index = 0
            while index < bars.count {
                let share =
                    time.map { HaloEqualiserMotion.share(bar: index, at: $0) }
                    ?? (isMoving ? HaloEqualiserMotion.stillShare : HaloEqualiserMotion.restShare)
                let height = bars[index].height * share
                let x = Double(index) * (HaloEqualiserMotion.barWidth + HaloEqualiserMotion.gap)
                let rect = CGRect(
                    x: x, y: size.height - height, width: HaloEqualiserMotion.barWidth, height: height
                )
                context.fill(
                    Path(roundedRect: rect, cornerRadius: HaloEqualiserMotion.barWidth / 2),
                    with: .color(.white)
                )
                index += 1
            }
        }
    }
}

/// Le mouvement de l'égaliseur, hors de la vue pour être testé.
nonisolated enum HaloEqualiserMotion {
    struct Bar: Equatable, Sendable {
        /// Sa hauteur à son plus haut, en points.
        var height: Double
        /// La durée d'un aller-retour, et son décalage : les trois barres ne montent jamais ensemble.
        var period: Double
        var offset: Double
    }

    static let bars: [Bar] = [
        Bar(height: 10, period: 1.4, offset: 0),
        Bar(height: 16, period: 1.6, offset: 0.35),
        Bar(height: 12, period: 1.8, offset: 0.7),
    ]
    static let barWidth = 3.0
    static let gap = 2.5
    /// Au plus bas de sa course, une barre garde cette part de sa hauteur.
    static let lowShare = 0.35
    /// Couchée : l'enceinte ne joue pas. Assez haute pour rester une barre : plus bas, trois points se
    /// liraient comme un bouton « plus ».
    static let restShare = 0.45
    /// Dressée sans bouger : elle joue, mais le mouvement est réduit.
    static let stillShare = 0.8

    /// La part de sa hauteur que prend la barre à cet instant : de `lowShare` à 1.
    static func share(bar: Int, at time: TimeInterval) -> Double {
        let bar = bars[bar % bars.count]
        let wave = 0.5 - 0.5 * cos(2 * Double.pi * (time + bar.offset) / bar.period)
        return lowShare + (1 - lowShare) * wave
    }
}

/// Des rangées centrées, qui passent à la ligne quand la largeur manque.
struct HaloFlowLayout: Layout {
    var spacing: CGFloat
    var rowSpacing: CGFloat

    /// Les rangées, par indices : une vue passe à la ligne dès qu'elle ne tient plus. Une vue plus large
    /// que la place occupe sa rangée seule.
    nonisolated static func rows(widths: [CGFloat], available: CGFloat, spacing: CGFloat) -> [[Int]] {
        var rows: [[Int]] = []
        var current: [Int] = []
        var used: CGFloat = 0
        for (index, width) in widths.enumerated() {
            let needed = current.isEmpty ? width : used + spacing + width
            if !current.isEmpty && needed > available {
                rows.append(current)
                current = [index]
                used = width
            } else {
                current.append(index)
                used = needed
            }
        }
        if !current.isEmpty { rows.append(current) }
        return rows
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let available = proposal.width ?? .infinity
        let rows = Self.rows(widths: sizes.map(\.width), available: available, spacing: spacing)
        let widest = rows.map { rowWidth($0, sizes: sizes) }.max() ?? 0
        let height = rows.reduce(CGFloat(0)) { $0 + rowHeight($1, sizes: sizes) }
            + CGFloat(max(rows.count - 1, 0)) * rowSpacing
        return CGSize(width: widest, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let rows = Self.rows(widths: sizes.map(\.width), available: bounds.width, spacing: spacing)
        var y = bounds.minY
        for row in rows {
            let height = rowHeight(row, sizes: sizes)
            var x = bounds.midX - rowWidth(row, sizes: sizes) / 2
            for index in row {
                subviews[index].place(
                    at: CGPoint(x: x, y: y + height / 2), anchor: .leading, proposal: .unspecified
                )
                x += sizes[index].width + spacing
            }
            y += height + rowSpacing
        }
    }

    private func rowWidth(_ row: [Int], sizes: [CGSize]) -> CGFloat {
        row.reduce(CGFloat(0)) { $0 + sizes[$1].width } + CGFloat(max(row.count - 1, 0)) * spacing
    }

    private func rowHeight(_ row: [Int], sizes: [CGSize]) -> CGFloat {
        row.map { sizes[$0].height }.max() ?? 0
    }
}
