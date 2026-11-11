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
    /// La largeur d'une tuile d'enceinte : pleine quand la rangée tient, resserrée dans une fenêtre étroite
    /// pour que toutes les enceintes restent visibles avant de devoir défiler.
    var tileWidth: CGFloat = ConsoleMetrics.speakerWidth
    /// La rangée dépasse : elle défile, d'un bord de la fenêtre à l'autre.
    var scrolls: Bool
    /// Le plafond de la hauteur des tuiles : un curseur n'a pas à faire toute la hauteur d'un grand écran.
    var maxTileHeight: CGFloat
    /// Du bord de la fenêtre au contenu.
    var margin: CGFloat
    /// La hauteur manque (fenêtre plus basse que l'ancienne taille minimale) : la recherche rejoint la
    /// ligne des avertissements, qui n'en garde qu'un, et la barre de lecture s'amincit. Tout ce que les
    /// curseurs y gagnent, ils le prennent.
    var isCompact: Bool
    /// Même ainsi, le curseur passerait sous sa hauteur utile : la tuile se simplifie (un en-tête d'une
    /// ligne de nom et une d'état, le niveau entre ses deux boutons).
    var compactTiles: Bool

    /// En deçà, la barre de lecture n'a plus la place de son titre, de son curseur et de sa commande.
    static let minimumColumnWidth: CGFloat = 720
    static let minimumTileHeight: CGFloat = 250
    static let tileHeightCeiling: CGFloat = 480
    /// La hauteur de la vue dans une fenêtre à l'ancienne taille minimale : à partir d'elle, rien ne change.
    static let roomyHeight: CGFloat = WindowSizing.roomy.height - 48
    /// En deçà, les marges se resserrent : chaque point compte pour les tuiles.
    static let narrowWidth: CGFloat = 760
    static let narrowMargin: CGFloat = 16
    /// En deçà, la barre de lecture s'amincit même dans une fenêtre haute : son titre y tient en entier.
    static let slimTransportWidth: CGFloat = 520
    /// Ce qui entoure les tuiles dans une fenêtre basse : marges, barre de lecture amincie, et la ligne des
    /// avertissements.
    static let compactChromeHeight: CGFloat = 118
    /// La tuile entière demande cette hauteur pour que son curseur garde une course utile.
    static let fullTileHeight: CGFloat = 300
    /// La tuile simplifiée la plus basse : son curseur y garde 96 points.
    static let smallestTileHeight: CGFloat = 200

    /// - Parameter speakerCount: les tuiles d'enceintes ; à zéro, une tuile d'attente les remplace.
    static func make(size: CGSize, speakerCount: Int) -> ConsoleLayout {
        let margin = size.width < narrowWidth ? narrowMargin : ConsoleMetrics.margin
        let available = max(size.width - 2 * margin, 0)
        let tileWidth = tileWidth(speakerCount: speakerCount, available: available)
        let rowWidth = rowWidth(speakerCount: speakerCount, tileWidth: tileWidth)
        let isCompact = size.height < roomyHeight
        let tileRoom = size.height - compactChromeHeight
        return ConsoleLayout(
            rowWidth: rowWidth,
            columnWidth: min(available, max(rowWidth, minimumColumnWidth)),
            tileWidth: tileWidth,
            // Un demi-point de marge : la largeur resserrée est une division.
            scrolls: rowWidth > available + 0.5,
            maxTileHeight: isCompact
                ? min(max(tileRoom, smallestTileHeight), tileHeightCeiling)
                : min(max(size.height * 0.66, minimumTileHeight), tileHeightCeiling),
            margin: margin, isCompact: isCompact, compactTiles: isCompact && tileRoom < fullTileHeight
        )
    }

    static func rowWidth(speakerCount: Int, tileWidth: CGFloat = ConsoleMetrics.speakerWidth) -> CGFloat {
        let count = max(speakerCount, 0)
        guard count > 0 else { return ConsoleMetrics.placeholderWidth }
        return CGFloat(count) * tileWidth + CGFloat(count - 1) * ConsoleMetrics.tileSpacing
    }

    /// La tuile la plus étroite : son curseur de 72 points et ses deux boutons y tiennent encore.
    static let narrowestTile: CGFloat = 122

    /// La largeur d'une tuile pour que la rangée tienne dans la place : pleine si possible, resserrée
    /// jusqu'à `narrowestTile` si cela suffit à tout montrer. Sinon la rangée défile, et autant garder des
    /// tuiles pleines : les resserrer sans éviter le défilement ne ferait que tronquer leurs textes.
    static func tileWidth(speakerCount: Int, available: CGFloat) -> CGFloat {
        let count = CGFloat(max(speakerCount, 1))
        let fitting = (available - (count - 1) * ConsoleMetrics.tileSpacing) / count
        guard fitting >= narrowestTile else { return ConsoleMetrics.speakerWidth }
        return min(fitting, ConsoleMetrics.speakerWidth)
    }
}

/// La vue « Console » de la fenêtre : une tuile et un curseur vertical par enceinte, puis, en grand dessous,
/// la barre de lecture (ce qui joue, le volume général, Diffuser/Arrêter).
///
/// La mise en page de la maquette 2, aux couleurs du thème : du verre sur le fond granuleux, le rose de
/// l'app réservé à l'état, les commandes dans la coque noire à liseré de la maquette 15 (`Darkshell`). Ce
/// qui est masqué ne s'y annonce pas : Baptiste n'en veut pas ici, les Réglages le disent. La source, le lieu d'écoute et les options flottent en haut
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
                    .frame(
                        minHeight: layout.isCompact
                            ? ConsoleLayout.smallestTileHeight : ConsoleLayout.minimumTileHeight,
                        maxHeight: layout.maxTileHeight
                    )
                if !layout.isCompact {
                    footer
                        .frame(width: layout.columnWidth)
                        .padding(.top, 12)
                }
                // Le volume général et la commande, en grand sous les curseurs des enceintes.
                TransportBar(
                    state: state, width: layout.columnWidth,
                    isCompact: layout.isCompact || layout.columnWidth < ConsoleLayout.slimTransportWidth
                )
                    .frame(width: layout.columnWidth)
                    .padding(.top, layout.isCompact ? 10 : 14)
                // Les avertissements en petit sous la barre, à une place réservée : leur arrivée ne déplace
                // rien.
                // Toutes les enceintes, masquées comprises : masquer une tuile ne fait pas taire son
                // avertissement.
                let warnings = ConsoleWarning.list(for: state, speakers: PanelSpeakerOrder.sorted(state.outputs))
                if layout.isCompact {
                    // Une seule ligne dans une fenêtre basse : le premier avertissement, les autres au clic,
                    // et la recherche au bout.
                    HStack(spacing: 8) {
                        ConsoleCompactWarnings(warnings: warnings)
                        Spacer(minLength: 0)
                        if !state.outputs.isEmpty { search(showsTitle: false) }
                    }
                    .padding(.horizontal, 14)
                    .frame(width: layout.columnWidth, height: ConsoleCompactWarnings.height)
                    .padding(.top, 6)
                } else {
                    ConsoleWarnings(warnings: warnings)
                        .frame(width: layout.columnWidth)
                        .padding(.top, 8)
                }
            }
            .padding(.top, layout.isCompact ? 8 : 12)
            .padding(.bottom, layout.isCompact ? 12 : 16)
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
                                isCompact: layout.compactTiles, width: layout.tileWidth,
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
                .padding(.horizontal, layout.margin)
                .frame(minWidth: proxy.size.width)
                .frame(height: proxy.size.height)
            }
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            .scrollDisabled(!layout.scrolls)
            // L'ombre des tuiles déborde du défilement, et ne doit pas s'y couper.
            .scrollClipDisabled()
            // Une souris à molette ne fait pas défiler de côté : un chevron mène aux tuiles hors de vue.
            .modifier(HorizontalScrollChevrons(inset: 6))
        }
    }

    // MARK: - Pied

    /// Sous la console : la recherche sur le réseau. Les messages des enceintes sont sous la barre de lecture
    /// (`ConsoleWarnings`). Toujours là, même pendant la recherche : la console ne change pas de hauteur.
    private var footer: some View {
        HStack {
            Spacer(minLength: 0)
            if !state.outputs.isEmpty {
                search(showsTitle: true)
            }
        }
        .frame(minHeight: 22, alignment: .top)
    }

    /// - Parameter showsTitle: dans une fenêtre basse, l'icône seule, au bout de la ligne des avertissements.
    private func search(showsTitle: Bool) -> some View {
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
                if showsTitle {
                    Text(state.isBrowsing ? "Recherche…" : "Rechercher des enceintes")
                }
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
        .background { GrainientBackground(isLive: true) }
        .preferredColorScheme(.dark)
}
