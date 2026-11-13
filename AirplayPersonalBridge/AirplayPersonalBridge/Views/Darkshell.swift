//
//  Darkshell.swift
//  AirplayPersonalBridge
//

import SwiftUI

/// La matière des commandes de la vue Console, d'après la maquette 15 « Darkshells » retenue par Baptiste
/// (2026-11-10) : une coque presque noire, dont seule la lèvre est dessinée par un liseré blanc qui
/// s'éteint, et un niveau qui n'est plus un bloc blanc mais un voile gris.
///
/// Aucune couleur : le rose de l'app reste à l'état, jamais à une commande. Tout se dessine en dégradés
/// et en traits, sans flou ni shader : le rendu hors écran montre la même chose que l'app.
enum Darkshell {
    /// Un arrêt de dégradé : sa place de 0 à 1, et l'opacité de sa teinte.
    struct Stop: Equatable {
        var location: Double
        var opacity: Double
    }

    // MARK: Liseré

    /// La lèvre d'une coque. Le dégradé court de haut en bas : net au sommet, presque éteint au pied.
    enum Lip: CaseIterable {
        /// Le rail vertical d'une tuile : la lumière descend le long des bords avant de mourir.
        case fader
        /// Le rail couché du volume général : trop bas pour qu'elle descende, elle tombe d'un coup.
        case bar
        /// Un bouton rond.
        case disc

        var stops: [Stop] {
            switch self {
            case .fader:
                [Stop(location: 0, opacity: 0.95), Stop(location: 0.16, opacity: 0.4),
                 Stop(location: 0.42, opacity: 0.08), Stop(location: 1, opacity: 0.03)]
            case .bar:
                [Stop(location: 0, opacity: 0.95), Stop(location: 0.6, opacity: 0.12),
                 Stop(location: 1, opacity: 0.03)]
            case .disc:
                [Stop(location: 0, opacity: 0.9), Stop(location: 0.62, opacity: 0.06),
                 Stop(location: 1, opacity: 0.03)]
            }
        }
    }

    /// L'épaisseur du liseré : ce qui se dessine dans la coque commence après lui.
    static let lipWidth: CGFloat = 1

    static func lipGradient(_ lip: Lip) -> LinearGradient {
        LinearGradient(
            stops: lip.stops.map { Gradient.Stop(color: .white.opacity($0.opacity), location: $0.location) },
            startPoint: .top, endPoint: .bottom
        )
    }

    // MARK: Fond

    /// Le fond d'un rail : presque noir, à peine plus clair au pied.
    static let ground = LinearGradient(
        colors: [BridgeTheme.color(0x060607), BridgeTheme.color(0x0B0B0D)], startPoint: .top, endPoint: .bottom
    )
    /// Le fond d'un bouton rond.
    static let discGround = BridgeTheme.color(0x08080A)
    /// Sous la main, le fond s'éclaire à peine : la commande répond sans changer de matière.
    static let hoverLift = Color.white.opacity(0.07)

    // MARK: Voile

    /// Les teintes du voile, du niveau vers le fond : un gris froid qui s'assombrit.
    private static let veilTints: [UInt32] = [0xECEFF3, 0xCDD1D7, 0xA5A9AF]
    private static let veilLocations: [Double] = [0, 0.38, 1]
    private static let veilOpacities: [Double] = [0.46, 0.2, 0.06]
    /// Son coupé ou enceinte décochée : le voile reste à sa place, pour dire le niveau qui reviendra, mais
    /// éteint.
    static let silencedVeilFactor = 0.3

    /// Les arrêts du voile, du niveau (0) au bout du rail (1) : le plus clair juste sous le niveau, puis il
    /// meurt dans le noir.
    static func veilStops(isSilenced: Bool) -> [Stop] {
        let factor = isSilenced ? silencedVeilFactor : 1
        return zip(veilLocations, veilOpacities).map { Stop(location: $0, opacity: $1 * factor) }
    }

    /// Le voile en dégradé. `from` est le côté du niveau : le haut pour un rail vertical, la droite pour le
    /// rail couché.
    static func veilGradient(isSilenced: Bool, from start: UnitPoint, to end: UnitPoint) -> LinearGradient {
        let stops = veilStops(isSilenced: isSilenced)
        return LinearGradient(
            stops: zip(stops, veilTints).map { stop, tint in
                Gradient.Stop(color: BridgeTheme.color(tint).opacity(stop.opacity), location: stop.location)
            },
            startPoint: start, endPoint: end
        )
    }

    // MARK: Niveau

    /// Le trait du niveau et sa prise : blancs, ou gris quand le son ne passe pas. La prise est opaque :
    /// le trait ne doit pas se lire à travers.
    static func levelColor(isSilenced: Bool) -> Color {
        isSilenced ? Color(white: 0.46) : .white
    }

    /// Les deux tirets du repère : blancs, discrets.
    static let markColor = Color.white.opacity(0.75)
}

/// La géométrie du curseur vertical dans sa coque : hors de la vue pour être testée. Les ordonnées partent
/// du haut du rail, comme la position d'un geste.
enum DarkshellFaderGeometry {
    static let lineThickness: CGFloat = 2
    static let grip = CGSize(width: 26, height: 6)
    static let mark = CGSize(width: 8, height: 1)
    /// Du liseré à un tiret du repère.
    static let markInset: CGFloat = 6

    /// Le haut du voile, où passe le trait du niveau. Un remplissage qui déborde ne sort pas du rail.
    static func levelY(fill: CGFloat, trackHeight: CGFloat) -> CGFloat {
        let height = max(trackHeight, 0)
        guard fill.isFinite else { return height }
        return height - min(max(fill, 0), height)
    }

    /// La hauteur du voile sous le trait.
    static func veilHeight(fill: CGFloat, trackHeight: CGFloat) -> CGFloat {
        max(trackHeight, 0) - levelY(fill: fill, trackHeight: trackHeight)
    }

    /// Le centre de la prise : à cheval sur le trait, mais retenue à l'intérieur du liseré. Au maximum le
    /// trait touche la lèvre, et une prise centrée dessus serait rognée de moitié.
    static func gripCenterY(
        levelY: CGFloat, trackHeight: CGFloat, gripHeight: CGFloat = grip.height,
        lineThickness: CGFloat = lineThickness
    ) -> CGFloat {
        let half = gripHeight / 2
        let lowest = Darkshell.lipWidth + half
        let highest = trackHeight - Darkshell.lipWidth - half
        // Un rail plus bas que la prise : elle reste au milieu.
        guard highest >= lowest else { return max(trackHeight, 0) / 2 }
        return min(max(levelY + lineThickness / 2, lowest), highest)
    }

    /// Le haut d'un tiret du repère, pour la hauteur de remplissage de la valeur repérée : son pied est
    /// sur la ligne où passerait le haut du voile, si bien que le trait du niveau le recouvre exactement
    /// quand la valeur y est.
    static func markY(fill: CGFloat, trackHeight: CGFloat) -> CGFloat {
        levelY(fill: fill, trackHeight: trackHeight)
    }
}

/// Les mesures d'un curseur vertical : celles de la console par défaut, plus fines pour le widget, où le
/// même curseur tient dans 22 pt de large. La matière et le comportement ne changent pas.
struct DarkshellFaderMetrics: Equatable {
    var lineThickness = DarkshellFaderGeometry.lineThickness
    var grip = DarkshellFaderGeometry.grip
    var mark = DarkshellFaderGeometry.mark
    /// Du liseré à un tiret du repère.
    var markInset = DarkshellFaderGeometry.markInset
    /// Ce qui reste rempli au minimum. `nil` : le socle de l'allure du curseur (`ConsoleFader.Look`).
    var floor: CGFloat?
    /// L'ombre portée de la coque.
    var shadowRadius: CGFloat = 11
    var shadowY: CGFloat = 10
    /// L'ombre de la prise.
    var gripShadowRadius: CGFloat = 4
    var gripShadowY: CGFloat = 2

    /// La vue Console.
    static let console = DarkshellFaderMetrics()

    /// Un curseur étroit ou court (le widget) : trait d'un point, prise et tirets à la mesure de la largeur,
    /// ombre courte. D'après les maquettes 23 et 24.
    static func compact(width: CGFloat, floor: CGFloat) -> DarkshellFaderMetrics {
        DarkshellFaderMetrics(
            lineThickness: 1,
            grip: CGSize(width: max(9, (width * 0.36).rounded()), height: 3),
            mark: CGSize(width: max(3, (width * 0.11).rounded()), height: 1),
            markInset: 2, floor: floor, shadowRadius: 4.5, shadowY: 4, gripShadowRadius: 1.5, gripShadowY: 1
        )
    }
}

/// La géométrie du voile dans le rail couché du volume général, dont la prise reste ronde.
enum DarkshellBarGeometry {
    /// Le voile s'arrête au centre de la prise, qui en couvre le bout : il ne dépasse jamais derrière elle,
    /// et ne sort pas du rail.
    static func veilWidth(knobOffset: CGFloat, knob: CGFloat, width: CGFloat) -> CGFloat {
        guard knobOffset.isFinite else { return 0 }
        return min(max(knobOffset + knob / 2, 0), max(width, 0))
    }
}

/// Où une commande partagée est posée : sa matière en dépend, pas son comportement.
enum ControlLook {
    /// Le panneau de la barre de menus, la barre latérale du Plan, le halo : couleurs du système.
    case panel
    /// La vue Console : la coque noire à liseré.
    case darkshell
}

// MARK: - Bouton rond

/// Le fond d'un bouton rond de la console : la coque noire et son liseré ; enclenché, un disque blanc.
struct DarkshellDisc: View {
    var isOn = false
    var isHovering = false

    var body: some View {
        ZStack {
            if isOn {
                Circle().fill(Color.white)
            } else {
                Circle().fill(Darkshell.discGround)
                if isHovering { Circle().fill(Darkshell.hoverLift) }
                Circle().strokeBorder(Darkshell.lipGradient(.disc), lineWidth: Darkshell.lipWidth)
            }
        }
    }
}

// MARK: - Rail couché

/// Le rail du volume général dans la matière de la console : la coque noire, le voile jusqu'à la prise, et
/// la prise ronde blanche qu'a gardée Baptiste. L'icône du son est blanche sur la coque, et sombre là où
/// la prise passe dessous.
struct DarkshellBar: View {
    /// Le bord gauche de la prise.
    let knobOffset: CGFloat
    /// Le diamètre de la prise : la hauteur du rail.
    let knob: CGFloat
    let width: CGFloat
    var isSilenced = false
    var isLit = false
    /// L'icône du son, dans la case de gauche.
    let symbol: Image

    var body: some View {
        let level = Darkshell.levelColor(isSilenced: isSilenced)
        ZStack(alignment: .leading) {
            Capsule().fill(Darkshell.ground)
            ZStack(alignment: .leading) {
                if isLit { Darkshell.hoverLift }
                Rectangle()
                    .fill(Darkshell.veilGradient(isSilenced: isSilenced, from: .trailing, to: .leading))
                    .frame(width: DarkshellBarGeometry.veilWidth(knobOffset: knobOffset, knob: knob, width: width))
            }
            .frame(width: width, height: knob, alignment: .leading)
            .clipShape(Capsule().inset(by: Darkshell.lipWidth))
            Capsule().strokeBorder(Darkshell.lipGradient(.bar), lineWidth: Darkshell.lipWidth)
            glyph.foregroundStyle(Color.white.opacity(isSilenced ? 0.5 : 0.9))
            Circle()
                .fill(level)
                .shadow(color: .black.opacity(0.5), radius: 3, y: 0.5)
                .frame(width: knob, height: knob)
                .offset(x: knobOffset)
            // La même icône, sombre, là où la prise la recouvre : elle reste lisible au bas de la course.
            glyph
                .foregroundStyle(Color.black.opacity(0.7))
                .mask(alignment: .leading) {
                    Circle().frame(width: knob, height: knob).offset(x: knobOffset)
                }
        }
        .frame(width: width, height: knob, alignment: .leading)
        .accessibilityHidden(true)
    }

    private var glyph: some View {
        symbol
            .font(.callout.weight(.medium))
            .frame(width: knob, height: knob)
    }
}
