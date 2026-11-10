//
//  ConsoleView.swift
//  AirplayPersonalBridge
//

import SwiftUI

/// La mise en page de la console, en fonction pure : ce qui tient, et sur quelle largeur.
struct ConsoleLayout: Equatable {
    /// La largeur des tuiles et de leurs intervalles, sans les marges.
    var rowWidth: CGFloat
    /// La largeur de l'en-tête, des alertes et du pied : celle de la rangée quand elle tient, pour que
    /// le titre parte du bord de la première tuile et la commande s'arrête à celui de la dernière.
    var columnWidth: CGFloat
    /// La rangée dépasse : elle défile, d'un bord de la fenêtre à l'autre.
    var scrolls: Bool
    /// Le plafond de la hauteur des tuiles : un curseur n'a pas à faire toute la hauteur d'un grand écran.
    var maxTileHeight: CGFloat

    /// En deçà, l'en-tête n'a plus la place de son titre et de sa commande.
    static let minimumColumnWidth: CGFloat = 720
    static let minimumTileHeight: CGFloat = 250
    static let tileHeightCeiling: CGFloat = 480

    /// - Parameter speakerCount: les tuiles d'enceintes ; à zéro, une tuile d'attente les remplace.
    static func make(size: CGSize, speakerCount: Int) -> ConsoleLayout {
        let rowWidth = rowWidth(speakerCount: speakerCount)
        let available = max(size.width - 2 * ConsoleMetrics.margin, 0)
        return ConsoleLayout(
            rowWidth: rowWidth,
            columnWidth: min(available, max(rowWidth, minimumColumnWidth)),
            scrolls: rowWidth > available,
            maxTileHeight: min(max(size.height * 0.66, minimumTileHeight), tileHeightCeiling)
        )
    }

    static func rowWidth(speakerCount: Int) -> CGFloat {
        let count = max(speakerCount, 0)
        let rest =
            count == 0
            ? ConsoleMetrics.placeholderWidth + ConsoleMetrics.tileSpacing
            : CGFloat(count) * (ConsoleMetrics.speakerWidth + ConsoleMetrics.tileSpacing)
        return ConsoleMetrics.generalWidth + rest
    }
}

/// La vue « Console » de la fenêtre : ce qui joue en tête, puis une tuile et un curseur vertical par
/// enceinte, le volume général en premier.
///
/// La mise en page de la maquette 2, aux couleurs du thème : du verre sur le fond de nappes, le rose de
/// l'app aux curseurs. Elle ne montre que ce qu'on règle en écoutant ; la source et les options sont dans
/// la barre d'outils (`WindowChrome`), le plan est une autre vue.
struct ConsoleView: View {
    @Bindable var state: BridgeState

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// L'ordre du panneau : celles qui exigent une intervention passent en fin de rangée.
    private var speakers: [OutputState] { PanelSpeakerOrder.sorted(state.outputs) }

    var body: some View {
        GeometryReader { proxy in
            let layout = ConsoleLayout.make(size: proxy.size, speakerCount: state.outputs.count)
            VStack(spacing: 0) {
                header
                    .frame(width: layout.columnWidth)
                if state.startFailure != nil || state.captureAlert != nil {
                    notices
                        .frame(width: layout.columnWidth)
                        .padding(.top, 16)
                }
                console(layout)
                    .frame(minHeight: ConsoleLayout.minimumTileHeight, maxHeight: layout.maxTileHeight)
                    .padding(.top, 22)
                footer
                    .frame(width: layout.columnWidth)
                    .padding(.top, 12)
            }
            .padding(.top, 12)
            .padding(.bottom, 16)
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .animation(PanelMotion.standard(reduceMotion: reduceMotion), value: state.captureAlert != nil)
        .animation(PanelMotion.standard(reduceMotion: reduceMotion), value: state.startFailure != nil)
    }

    // MARK: - En-tête

    /// Ce qui joue, puis le lieu d'écoute et la commande.
    private var header: some View {
        let status = state.status
        return HStack(spacing: 16) {
            HStack(spacing: 16) {
                PanelStatusChip(
                    status: status.menuBar, isAudible: state.captureAlert == nil && !state.isMuted, diameter: 58
                )
                .shadow(color: .black.opacity(0.3), radius: 10, y: 5)
                VStack(alignment: .leading, spacing: 2) {
                    Text(status.title)
                        .font(.system(size: 30, weight: .bold))
                        .tracking(-0.5)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    if let detail = status.detail {
                        Text(detail)
                            .font(.system(size: 15))
                            // Sur les nappes et non sur du verre : le secondaire du système s'y perdrait.
                            .foregroundStyle(Color.white.opacity(0.78))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)

            Spacer(minLength: 8)

            ConsoleListeningPlaces(state: state)
                .layoutPriority(1)
            StreamingCommand(state: state)
                .controlSize(.large)
                .layoutPriority(1)
        }
    }

    // MARK: - Alertes

    /// Les alertes de la diffusion, au-dessus de la console. Côte à côte s'il y en a deux : la console
    /// garde sa hauteur. Un voile sombre dessous : sur les nappes, le fond teinté d'une alerte ne suffit
    /// pas à porter son texte.
    private var notices: some View {
        HStack(alignment: .top, spacing: 10) {
            if let failure = state.startFailure {
                notice(
                    PanelNotice(
                        severity: .critical, title: "Démarrage impossible", detail: failure.message,
                        actionTitle: failure.settingsPane == nil ? nil : "Ouvrir les Réglages…",
                        action: { failure.settingsPane?.open() }
                    )
                )
            }
            if let alert = state.captureAlert {
                notice(
                    PanelNotice(
                        severity: alert.severity, title: alert.title, detail: alert.detail,
                        actionTitle: alert.settingsPane == nil ? nil : "Ouvrir les Réglages…",
                        action: { alert.settingsPane?.open() }
                    )
                )
            }
        }
    }

    private func notice(_ content: PanelNotice) -> some View {
        content
            .background(Color.black.opacity(0.34), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Console

    /// La rangée de tuiles, centrée quand elle tient, défilante sinon. Un seul chemin pour les deux : une
    /// fenêtre qu'on élargit ne referme pas les réglages ouverts d'une tuile.
    private func console(_ layout: ConsoleLayout) -> some View {
        GeometryReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: ConsoleMetrics.tileSpacing) {
                    ConsoleGeneralTile(state: state)
                    if speakers.isEmpty {
                        ConsoleEmptyTile(state: state)
                    } else {
                        ForEach(speakers) { output in
                            ConsoleSpeakerTile(
                                output: output,
                                effectiveGainDB: state.effectiveGainDB(for: output),
                                listeningCompensationMS: state.listeningCompensationMS(for: output),
                                listeningPlaceName: state.listeningPlaceName,
                                stereoPartnerNames: state.stereoPartners(of: output).map(\.displayName),
                                isAudible: state.captureAlert == nil && !state.isMuted,
                                toggle: { state.toggleEnabled(output) }
                            )
                        }
                    }
                }
                .padding(.horizontal, ConsoleMetrics.margin)
                .frame(minWidth: proxy.size.width)
                .frame(height: proxy.size.height)
            }
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            .scrollDisabled(!layout.scrolls)
            // L'ombre des tuiles déborde du défilement, et ne doit pas s'y couper.
            .scrollClipDisabled()
        }
    }

    // MARK: - Pied

    /// Sous la console : ce que le moteur dit d'une enceinte en peine, et la recherche sur le réseau.
    /// Toujours là, même vide : la console ne change pas de hauteur quand la recherche tourne.
    private var footer: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(speakers) { output in
                    if let detail = ConsoleTileCaption.detail(
                        connection: output.connection, isEnabled: output.isEnabled,
                        isHeldBack: output.consoleIsHeldBack
                    ) {
                        ConsoleSpeakerMessage(name: output.displayName, text: detail.text, tone: detail.tone)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if !state.outputs.isEmpty {
                search
            }
        }
        .frame(minHeight: 22, alignment: .top)
    }

    private var search: some View {
        Button {
            Task { await state.refreshOutputs() }
        } label: {
            HStack(spacing: 6) {
                // Le même cadre avec ou sans le témoin : la recherche revient régulièrement, et la ligne
                // ne doit pas tressauter à chaque fois.
                Group {
                    if state.isBrowsing {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .frame(width: 14, height: 14)
                Text(state.isBrowsing ? "Recherche…" : "Rechercher des enceintes")
            }
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(Color.white.opacity(0.72))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(state.isBrowsing)
        .help("Rechercher les enceintes sur le réseau local")
        .accessibilityLabel(state.isBrowsing ? "Recherche en cours" : "Rechercher des enceintes")
    }
}

#Preview("Diffusion") {
    ConsoleView(state: .preview(.streaming))
        .frame(width: 1200, height: 700)
        .background { AuroraBackground(isLive: true) }
        .preferredColorScheme(.dark)
}
