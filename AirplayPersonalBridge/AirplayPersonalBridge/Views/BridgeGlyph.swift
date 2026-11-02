//
//  BridgeGlyph.swift
//  AirplayPersonalBridge
//

import CoreGraphics

/// L'identité de l'app : cinq barres dont le profil dessine un pont suspendu.
///
/// Deux pylônes hauts, et entre eux trois suspentes dont les sommets suivent la courbe du câble :
/// un pont pour qui regarde la silhouette, un égaliseur pour qui regarde le rythme. C'est l'idée de
/// l'app, un seul son tendu vers plusieurs enceintes. Le profil en V la sépare du `waveform` système,
/// dont la barre haute est au centre ; l'absence d'arc et de triangle la sépare d'AirPlay et du
/// Wi-Fi, ses voisins dans la barre de menus.
///
/// **L'état se lit à la forme, jamais à la couleur**, la barre de menus étant monochrome. La pastille
/// se remplit à mesure que la session s'établit : rien au repos, un contour pendant la connexion,
/// pleine en diffusion, pleine aussi en panne mais avec une seule marque au lieu de cinq. Quand un son
/// passe vraiment, les suspentes de la pastille pleine ondulent (`Wave`) ; tout le reste est immobile.
///
/// Géométrie pure, CoreGraphics et rien d'autre : `scripts/make-app-icon.swift` compile ce même
/// fichier pour que l'icône d'app et le glyphe ne puissent pas diverger.
nonisolated enum BridgeGlyph {
    enum Variant: CaseIterable, Sendable {
        case idle
        case connecting
        case streaming
        case trouble
    }

    /// Hauteur des suspentes, pour les faire vivre dans le panneau pendant une diffusion : les
    /// latérales de 0 (un point) à 1 (leur repos), la centrale de 0 (son repos, un point) à 1.
    struct Levels: Equatable, Sendable {
        var sides: CGFloat = 1
        var center: CGFloat = 0

        static let rest = Levels()
    }

    /// Le cadre commun à toutes les variantes : l'icône ne bouge pas dans la barre quand l'état change.
    static let canvas = CGSize(width: 20, height: 18)

    /// Barres de 2 pt, intervalles de 2 pt, hauteurs paires : tout tombe juste sur la grille de pixels
    /// en 1x comme en 2x, ce qui garde le glyphe net là où un trait de 1,5 pt baverait. C'est ce qui
    /// décide à cette taille : la moindre barre à cheval sur un pixel se lit comme un trait gris.
    private static let barWidth: CGFloat = 2
    private static let barCenters: [CGFloat] = [2, 6, 10, 14, 18]
    private static let midline: CGFloat = 9
    private static let pylonHeight: CGFloat = 14
    private static let sideHeight: CGFloat = 6

    private static let pill = CGRect(x: 0, y: 2, width: 20, height: 14)
    private static let pillRadius: CGFloat = 4.5
    private static let ringWidth: CGFloat = 1.5

    /// Les barres découpées dans la pastille pleine de la diffusion. Resserrées : elles doivent laisser
    /// 2 pt de pastille tout autour, sans quoi les pylônes rongent le bord et la forme se défait.
    private static let streamingCenters: [CGFloat] = [3, 6.5, 10, 13.5, 17]
    private static let streamingPylonHeight: CGFloat = 10

    /// Le glyphe complet de la barre de menus, à remplir en règle **pair-impair** : les marques se
    /// découpent ainsi dans la pastille pleine, et l'anneau de la connexion s'évide tout seul.
    static func path(_ variant: Variant) -> CGPath {
        let path = CGMutablePath()
        switch variant {
        case .idle:
            path.addPath(marks(.idle))
        case .connecting:
            path.addRoundedRect(
                in: pill, cornerWidth: pillRadius, cornerHeight: pillRadius
            )
            let inner = pill.insetBy(dx: ringWidth, dy: ringWidth)
            let innerRadius = pillRadius - ringWidth
            path.addRoundedRect(in: inner, cornerWidth: innerRadius, cornerHeight: innerRadius)
            path.addPath(marks(.connecting))
        case .streaming:
            path.addRoundedRect(in: pill, cornerWidth: pillRadius, cornerHeight: pillRadius)
            let heights: [CGFloat] = [
                streamingPylonHeight, sideHeight, barWidth, sideHeight, streamingPylonHeight,
            ]
            for (center, height) in zip(streamingCenters, heights) {
                addBar(to: path, x: center, height: height, width: barWidth)
            }
        case .trouble:
            path.addRoundedRect(in: pill, cornerWidth: pillRadius, cornerHeight: pillRadius)
            path.addPath(marks(.trouble))
        }
        return path
    }

    /// Les marques seules, sans pastille : c'est ce que portent la pastille d'état du panneau et
    /// l'icône d'app, qui fournissent elles-mêmes le fond.
    static func marks(_ variant: Variant, levels: Levels = .rest) -> CGPath {
        let path = CGMutablePath()
        switch variant {
        case .idle, .streaming:
            path.addPath(pylons())
            path.addPath(hangers(levels: levels))
        case .connecting:
            for center in barCenters[1...3] {
                addBar(to: path, x: center, height: barWidth, width: barWidth)
            }
        case .trouble:
            addBar(to: path, x: 10, top: 4, bottom: 10, width: barWidth)
            addBar(to: path, x: 10, top: 12, bottom: 14, width: barWidth)
        }
        return path
    }

    /// Séparés des suspentes : l'icône d'app les colore différemment.
    static func pylons() -> CGPath {
        let path = CGMutablePath()
        addBar(to: path, x: barCenters[0], height: pylonHeight, width: barWidth)
        addBar(to: path, x: barCenters[4], height: pylonHeight, width: barWidth)
        return path
    }

    static func hangers(levels: Levels = .rest) -> CGPath {
        let path = CGMutablePath()
        let side = barWidth + (sideHeight - barWidth) * levels.sides
        addBar(to: path, x: barCenters[1], height: side, width: barWidth)
        // Le point central ne dépasse jamais les suspentes latérales : au-delà, le creux du câble
        // disparaît et on retombe sur le profil du `waveform` système.
        let center = barWidth + (sideHeight * 0.6 - barWidth) * levels.center
        addBar(to: path, x: barCenters[2], height: center, width: barWidth)
        addBar(to: path, x: barCenters[3], height: side, width: barWidth)
        return path
    }

    // MARK: - La vague de la diffusion

    /// La grille de pixels d'un écran : un pixel par point, ou deux.
    enum PixelScale: Int, CaseIterable, Sendable {
        case single = 1
        case double = 2
    }

    /// Les suspentes qui ondulent dans la barre de menus, tant qu'un son passe vraiment.
    ///
    /// Une onde qui court de gauche à droite, chaque suspente un quart de cycle derrière sa voisine :
    /// on lit une vague qui avance, là où un tiers de cycle se lirait comme un égaliseur au hasard.
    /// Les pylônes ne bougent pas et dépassent toujours les suspentes : la vague vit entre eux, la
    /// silhouette du pont demeure.
    ///
    /// Douze images à huit par seconde, soit un cycle d'une seconde et demie : assez lent pour passer
    /// pour un mouvement de fond, assez rare pour ne coûter presque rien.
    enum Wave {
        static let frameCount = 12
        static let framesPerSecond: Double = 8
        static var period: Double { Double(frameCount) / framesPerSecond }

        /// D'un point à 8 pt : 2 pt de moins que les pylônes, qui restent ce qui dépasse.
        static let lowest: CGFloat = 2
        static let highest: CGFloat = 8
        static let phaseLag = Double.pi / 2

        /// Les hauteurs des trois suspentes, de gauche à droite, avant leur calage sur une grille.
        ///
        /// Échantillonnées au milieu de chaque image : aucune ne tombe alors à égale distance de
        /// deux crans, où l'arrondi trancherait au hasard des flottants.
        static func heights(frame: Int) -> [CGFloat] {
            let middle = Double(lowest + highest) / 2
            let amplitude = Double(highest - lowest) / 2
            let phase = 2 * Double.pi * (Double(frame) + 0.5) / Double(frameCount)
            return (0..<3).map { index in
                CGFloat(middle + amplitude * sin(phase - phaseLag * Double(index)))
            }
        }
    }

    /// Une image de la vague : la pastille pleine de la diffusion, ses barres découpées à la hauteur
    /// de cette image et calées sur la grille demandée. À remplir en règle pair-impair.
    static func wavePath(frame: Int, scale: PixelScale) -> CGPath {
        let path = CGMutablePath()
        path.addRoundedRect(in: pill, cornerWidth: pillRadius, cornerHeight: pillRadius)
        for bar in waveBars(frame: frame, scale: scale) {
            addBar(to: path, x: bar.midX, top: bar.minY, bottom: bar.maxY, width: bar.width)
        }
        return path
    }

    /// Les cinq barres d'une image de la vague, de gauche à droite, avant l'arrondi de leurs bouts.
    ///
    /// **Chaque grille a son dessin**, comme les icônes de Apple ont le leur en 1x. En 2x, l'espacement
    /// de l'icône fixe (des intervalles de 1,5 pt), et des hauteurs au point près. En 1x, ces
    /// intervalles mettraient les suspentes à cheval sur deux pixels : elles se resserrent d'un
    /// demi-point vers le centre, et leurs hauteurs vont de deux en deux, pour que haut et bas restent
    /// symétriques autour de la ligne médiane sur des pixels entiers.
    static func waveBars(frame: Int, scale: PixelScale) -> [CGRect] {
        let centers: [CGFloat] = scale == .single ? [3, 7, 10, 13, 17] : streamingCenters
        let step = 2 / CGFloat(scale.rawValue)
        let hangers = Wave.heights(frame: frame).map { height in
            let snapped = Wave.lowest + step * ((height - Wave.lowest) / step).rounded()
            return min(max(snapped, Wave.lowest), Wave.highest)
        }
        let heights = [streamingPylonHeight] + hangers + [streamingPylonHeight]
        return zip(centers, heights).map { center, height in
            CGRect(
                x: center - barWidth / 2, y: midline - height / 2, width: barWidth, height: height
            )
        }
    }

    private static func addBar(
        to path: CGMutablePath, x: CGFloat, height: CGFloat, width: CGFloat
    ) {
        addBar(
            to: path, x: x, top: midline - height / 2, bottom: midline + height / 2, width: width
        )
    }

    private static func addBar(
        to path: CGMutablePath, x: CGFloat, top: CGFloat, bottom: CGFloat, width: CGFloat
    ) {
        let rect = CGRect(x: x - width / 2, y: top, width: width, height: max(bottom - top, width))
        // `addRoundedRect` refuse un rayon qui dépasse la moitié du côté, à l'arrondi flottant près.
        let radius = min(width, rect.height) / 2 * 0.999
        path.addRoundedRect(in: rect, cornerWidth: radius, cornerHeight: radius)
    }
}
