//
//  HaloSpeakerChips.swift
//  AirplayPersonalBridge
//

import SwiftUI

/// Les mesures des pastilles d'enceintes de la vue « Halo ».
nonisolated enum HaloChipMetrics {
    static let width: CGFloat = 260
    static let height: CGFloat = 64
    static let spacing: CGFloat = 12
    static let rowSpacing: CGFloat = 10
    static let badge: CGFloat = 40
    /// Au-delà de deux rangées, les pastilles défilent : le halo garde sa place.
    static let maxRows = 2
    static var maxHeight: CGFloat { CGFloat(maxRows) * height + CGFloat(maxRows - 1) * rowSpacing }
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
    @State private var contentHeight: CGFloat = HaloChipMetrics.height

    var body: some View {
        if state.outputs.isEmpty {
            emptyOutputs
        } else {
            ScrollView(.vertical) {
                HaloFlowLayout(spacing: HaloChipMetrics.spacing, rowSpacing: HaloChipMetrics.rowSpacing) {
                    // L'ordre du panneau : celles qui exigent une intervention passent en dernier.
                    ForEach(PanelSpeakerOrder.sorted(state.outputs)) { output in
                        HaloSpeakerChip(
                            output: output,
                            effectiveGainDB: state.effectiveGainDB(for: output),
                            listeningCompensationMS: state.listeningCompensationMS(for: output),
                            listeningPlaceName: state.listeningPlaceName,
                            stereoPartnerNames: state.stereoPartners(of: output).map(\.displayName),
                            isAudible: isAudible,
                            toggle: { state.toggleEnabled(output) }
                        )
                    }
                    searchButton
                }
                .frame(maxWidth: .infinity)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollIndicators(.never)
            // La hauteur de ce qu'il contient, jusqu'à deux rangées : la vue ne réserve pas de vide.
            .frame(height: min(max(contentHeight, HaloChipMetrics.height), HaloChipMetrics.maxHeight))
        }
    }

    /// La recherche, au bout des pastilles : le même cadre avec ou sans le témoin, elle revient
    /// régulièrement et la rangée ne doit pas tressauter.
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
                        .font(.callout.weight(.medium))
                        .foregroundStyle(Color.primary.opacity(0.7))
                        .frame(width: 32, height: 32)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Rechercher les enceintes sur le réseau local")
                .accessibilityLabel("Rechercher les enceintes")
            }
        }
        .frame(width: 32, height: 32)
        .floatingGlass(in: Circle(), interactive: true)
        .frame(height: HaloChipMetrics.height)
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
    /// Le clic sur le badge : `BridgeState.toggleEnabled(_:)`, qui emmène la paire stéréo.
    var toggle: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false
    @State private var isAdjusting = false
    @State private var showsSettings = false
    @State private var showsMessage = false

    var body: some View {
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
        .frame(width: HaloChipMetrics.width, height: HaloChipMetrics.height)
        .floatingGlass(in: Capsule(style: .circular))
        .opacity(output.isHeldBack ? 0.62 : 1)
        .onHover { isHovering = $0 }
        .animation(PanelMotion.quick(reduceMotion: reduceMotion), value: isHovering)
        .accessibilityElement(children: .contain)
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
            .font(.system(size: 17, weight: .medium))
            .foregroundStyle(output.isEnabled ? BridgeTheme.color(0x1D1D1F) : Color.white.opacity(0.75))
            .frame(width: HaloChipMetrics.badge, height: HaloChipMetrics.badge)
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
    @Environment(\.appearsActive) private var appearsActive

    var body: some View {
        Group {
            if isMoving && !reduceMotion {
                TimelineView(.animation(minimumInterval: 1 / 20, paused: !appearsActive)) { timeline in
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
