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

    /// En deçà, la barre de lecture n'a plus la place de son titre, de son curseur et de sa commande.
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
        guard count > 0 else { return ConsoleMetrics.placeholderWidth }
        return CGFloat(count) * ConsoleMetrics.speakerWidth + CGFloat(count - 1) * ConsoleMetrics.tileSpacing
    }
}

/// La vue « Console » de la fenêtre : une tuile et un curseur vertical par enceinte, puis, en grand dessous,
/// la barre de lecture (ce qui joue, le volume général, Diffuser/Arrêter).
///
/// La mise en page de la maquette 2, aux couleurs du thème : du verre sur le fond de nappes, le rose de
/// l'app réservé à l'état, les curseurs en blanc. La source, le lieu d'écoute et les options flottent en haut
/// de la fenêtre (`WindowChrome`) ; le plan est une autre vue.
struct ConsoleView: View {
    @Bindable var state: BridgeState

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// L'ordre du panneau : celles qui exigent une intervention passent en fin de rangée. Les masquées n'ont
    /// pas de tuile.
    private var speakers: [OutputState] { PanelSpeakerOrder.sorted(state.visibleOutputs) }

    var body: some View {
        GeometryReader { proxy in
            let layout = ConsoleLayout.make(size: proxy.size, speakerCount: speakers.count)
            VStack(spacing: 0) {
                console(layout)
                    .frame(minHeight: ConsoleLayout.minimumTileHeight, maxHeight: layout.maxTileHeight)
                footer
                    .frame(width: layout.columnWidth)
                    .padding(.top, 12)
                // Le volume général et la commande, en grand sous les curseurs des enceintes.
                TransportBar(state: state)
                    .frame(width: layout.columnWidth)
                    .padding(.top, 14)
                // Les avertissements en petit sous la barre, à une place réservée : leur arrivée ne déplace
                // rien.
                // Toutes les enceintes, masquées comprises : masquer une tuile ne fait pas taire son
                // avertissement.
                ConsoleWarnings(
                    warnings: ConsoleWarning.list(for: state, speakers: PanelSpeakerOrder.sorted(state.outputs))
                )
                    .frame(width: layout.columnWidth)
                    .padding(.top, 8)
            }
            .padding(.top, 12)
            .padding(.bottom, 16)
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }

    // MARK: - Console

    /// La rangée de tuiles, centrée quand elle tient, défilante sinon. Un seul chemin pour les deux : une
    /// fenêtre qu'on élargit ne referme pas les réglages ouverts d'une tuile.
    private func console(_ layout: ConsoleLayout) -> some View {
        GeometryReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: ConsoleMetrics.tileSpacing) {
                    if state.hidesEverySpeaker {
                        AllSpeakersHiddenNotice()
                            .glassButtonStyle()
                            .padding(.horizontal, 24)
                            .frame(width: ConsoleMetrics.placeholderWidth)
                            .frame(maxHeight: .infinity)
                            .modifier(ConsoleTileSurface(isHeldBack: true))
                    } else if speakers.isEmpty {
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
                                toggle: { state.toggleEnabled(output) },
                                hide: {
                                    withAnimation(PanelMotion.standard(reduceMotion: reduceMotion)) {
                                        state.setHidden(true, for: output)
                                    }
                                }
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

    /// Sous la console : la recherche sur le réseau. Les messages des enceintes sont sous la barre de lecture
    /// (`ConsoleWarnings`). Toujours là, même pendant la recherche : la console ne change pas de hauteur.
    private var footer: some View {
        HStack {
            // Ce qui est masqué, en face de la recherche : la ligne existait, rien ne se déplace.
            HiddenElementsNote(state: state)
            Spacer(minLength: 0)
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
