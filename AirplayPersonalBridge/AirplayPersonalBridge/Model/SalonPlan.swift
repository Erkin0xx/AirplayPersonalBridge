//
//  SalonPlan.swift
//  AirplayPersonalBridge
//

import CoreGraphics
import Foundation

/// Le salon de Baptiste, relevé sur la capture de son plan.
///
/// **D'où viennent les nombres.** Les cotes imprimées sur la capture sont cohérentes à
/// 178 pixels par mètre, avec le coin intérieur haut-gauche de l'alcôve au pixel (166, 150) :
/// `x = (px − 166) / 178`, `y = (py − 150) / 178`. Les murs reprennent les cotes imprimées,
/// exactes au centimètre. Les meubles sont mesurés sur l'image, donc à ±3 cm. Quand un
/// préset porte une mesure réelle (canapé, meuble TV, télé), c'est lui qui l'emporte sur
/// l'image — d'où quelques centimètres d'écart avec le dessin d'origine.
///
/// **Les hauteurs sont des estimations**, aucune ne figure sur la capture. Seules celles des
/// enceintes et des oreilles entrent dans le calcul de distance ; une erreur de 10 cm sur
/// l'une d'elles change le délai suggéré de bien moins d'une milliseconde.
///
/// Les trois enceintes sont les marques ajoutées à la main par Baptiste sur sa capture : gros
/// point vert pour la Geneva, croix jaunes pour les HomePod. Leurs centres sont mesurés au
/// pixel, en écartant ce que le plan d'origine dessinait dessous.
extension RoomLayout {
    /// Identifiants des deux HomePod, tels qu'annoncés au Bonjour.
    ///
    /// Rien ne dit lequel est physiquement à gauche : ils portent le même nom, à un suffixe
    /// près. Gauche = « Salon » est une hypothèse, qu'une écoute tranchera. Se tromper fausse
    /// le délai de chacun de moins d'une milliseconde, les deux étant à des distances voisines.
    static let salonLeftHomePodID = "airplay2/Salon"
    static let salonRightHomePodID = "airplay2/Salon (2)"

    static var salon: RoomLayout {
        var layout = RoomLayout(walls: salonWalls, objects: salonObjects)
        // Le premier lieu d'écoute du plan, à table, est celui qui vaut par défaut.
        layout.activeListenerID = layout.listeners.first?.id
        return layout
    }

    /// Épaisseur des murs sur la capture : 25 pixels.
    private static let salonWallThickness = 0.14

    /// Le contour intérieur, tourné dans le sens horaire pour que l'épaisseur parte vers
    /// l'extérieur. Rien entre (0 ; 5,90) et (0 ; 5,00) : c'est l'ouverture de la porte.
    private static var salonWalls: [WallSegment] {
        func wall(_ a: (Double, Double), _ b: (Double, Double), paint: WallSegment.Paint? = nil)
            -> WallSegment
        {
            WallSegment(
                a: CGPoint(x: a.0, y: a.1), b: CGPoint(x: b.0, y: b.1),
                thickness: salonWallThickness, paint: paint
            )
        }
        return [
            wall((0.65, 0), (4.25, 0)),  // mur fenêtre, 3,60
            wall((4.25, 0), (4.25, 5.90), paint: .sage),  // mur sauge, 5,90
            wall((4.25, 5.90), (0, 5.90)),  // mur du buffet, 4,25
            wall((0, 5.00), (0, 2.85)),  // alcôve, 2,15
            wall((0, 2.85), (0.65, 2.85)),  // retour, 0,65
            wall((0.65, 2.85), (0.65, 0)),  // mur canapé, 2,85
        ]
    }

    /// L'ordre compte à l'intérieur d'un même étage : le feuillage du ficus passe au-dessus
    /// de la console et des chaises, et sous le radiateur, comme sur la capture.
    private static var salonObjects: [RoomObject] {
        func item(
            _ kind: RoomObject.Kind, _ x: Double, _ y: Double, _ width: Double, _ depth: Double,
            height: Double, rotation: Double = 0, shape: RoomObject.Shape = .rectangle,
            name: String = ""
        ) -> RoomObject {
            RoomObject(
                kind: kind, position: CGPoint(x: x, y: y),
                size: CGSize(width: width, height: depth), rotation: rotation, elevation: height,
                name: name, shape: shape
            )
        }

        typealias Library = RoomObject.Library

        var sofa = Library.cornerSofa.makeObject(at: CGPoint(x: 3.0125, y: 4.00), name: "Canapé")
        sofa.isMirrored = true

        var atTable = Library.listener.makeObject(at: CGPoint(x: 2.656, y: 0.85), name: "À table")
        atTable.rotation = 180  // dos à la fenêtre, face à la télé : nez vers le bas du plan
        var onSofa = Library.listener.makeObject(at: CGPoint(x: 2.35, y: 3.70), name: "Au canapé")
        onSofa.rotation = 180

        return [
            item(.rug, 2.70, 3.60, 3.00, 2.00, height: 0.01, name: "Tapis 200 × 300"),

            // Coin repas : la table et ses quatre chaises, dossiers vers l'extérieur.
            item(.table, 2.656, 1.601, 1.10, 1.10, height: 0.75, shape: .ellipse, name: "Table"),
            item(.chair, 2.207, 1.000, 0.46, 0.50, height: 0.45, rotation: 315),
            item(.chair, 3.154, 1.050, 0.46, 0.50, height: 0.45, rotation: 45),
            item(.chair, 2.157, 1.996, 0.46, 0.50, height: 0.45, rotation: 225),
            item(.chair, 3.203, 2.044, 0.46, 0.50, height: 0.45, rotation: 135),
            item(.lamp, 2.423, 1.368, 0.10, 0.10, height: 0.95, shape: .ellipse, name: "Lampe de table"),

            // Sous la fenêtre.
            item(.console, 1.104, 0.300, 0.80, 0.30, height: 0.75, name: "Console"),
            item(.decor, 1.404, 0.350, 0.12, 0.12, height: 0.85, shape: .ellipse),
            // Dossier en bas à droite : il tourne le dos à la pièce et regarde vers l'angle.
            item(.armchair, 1.073, 0.865, 0.66, 0.66, height: 0.45, rotation: 120, name: "Fauteuil"),
            item(.plant, 1.854, 0.350, 1.00, 1.00, height: 1.80, shape: .ellipse, name: "Ficus"),
            item(.radiator, 1.380, 0.045, 0.65, 0.09, height: 0.60, name: "Radiateur"),
            item(.lamp, 3.909, 0.350, 0.42, 0.42, height: 1.60, shape: .ellipse, name: "Lampadaire"),

            // Le buffet longe le mur sauge, façade vers la pièce.
            item(.sideboard, 4.055, 1.848, 1.60, 0.40, height: 0.85, rotation: 270, name: "Buffet"),
            item(.decor, 4.044, 1.400, 0.09, 0.30, height: 0.90),
            item(.decor, 4.072, 1.852, 0.30, 0.30, height: 0.90, shape: .ellipse),
            item(.lamp, 4.078, 2.425, 0.16, 0.16, height: 1.20, shape: .ellipse, name: "Lampe du buffet"),

            // Le coin canapé. Le canapé vient du préset : ses cotes sont des mesures réelles.
            sofa,
            item(.coffeeTable, 2.106, 4.454, 0.61, 0.46, height: 0.40, shape: .ellipse),
            item(.coffeeTable, 2.618, 4.805, 0.81, 0.51, height: 0.40, shape: .ellipse),

            // Le mur télé.
            Library.tvStand.makeObject(at: CGPoint(x: 2.615, y: 5.70), name: "Meuble TV"),
            item(.decor, 1.961, 5.716, 0.26, 0.26, height: 0.60, shape: .ellipse),
            Library.tv55.makeObject(at: CGPoint(x: 2.775, y: 5.805), name: "Télé"),
            item(.sideTable, 3.621, 5.755, 0.25, 0.26, height: 0.50, name: "Petit meuble"),
            item(.decor, 3.621, 5.755, 0.12, 0.12, height: 0.55, shape: .ellipse),
            item(.plant, 4.011, 5.663, 0.84, 0.84, height: 1.40, shape: .ellipse, name: "Plante"),

            // Le bureau, dans l'alcôve : on s'y assoit dos à la pièce, face au mur.
            item(.desk, 0.406, 3.980, 1.60, 0.80, height: 0.75, rotation: 90, name: "Bureau"),
            item(.decor, 0.144, 3.413, 0.365, 0.18, height: 0.80, rotation: 90),
            item(.decor, 0.149, 4.084, 0.95, 0.05, height: 1.10, rotation: 90),
            item(.lamp, 0.205, 4.625, 0.15, 0.15, height: 1.10, shape: .ellipse, name: "Lampe de bureau"),
            item(.chair, 0.854, 3.983, 0.52, 0.52, height: 0.45, rotation: 90, shape: .ellipse),

            // La petite table qui porte le HomePod gauche. Le préset (Ø 50) l'emporte sur la
            // capture, où elle mesure Ø 41 : à Ø 50 elle touchait le mur, d'où 2 cm de décalage.
            Library.sideTable.makeObject(at: CGPoint(x: 0.925, y: 2.799)),

            // Les repères.
            item(.window, 2.85, -0.07, 1.80, 0.14, height: 0, name: "Fenêtre"),
            item(.door, 0.45, 5.45, 0.90, 0.90, height: 0, name: "Porte"),

            // Derrière le mur canapé : dessinés sur la capture, sans rôle dans ce salon.
            item(.shelf, -0.299, 1.901, 0.79, 0.23, height: 0.70, rotation: 180, name: "Étagère (hors pièce)"),
            item(.decor, -0.397, 2.350, 0.46, 0.36, height: 0.40, name: "Pouf (hors pièce)"),

            // Les enceintes. Haut-parleur = dessus du meuble + demi-hauteur de l'enceinte.
            //
            // La Geneva reste sans sortie : éteinte au moment du relevé, son identité
            // `raop/<MAC>@<nom>` est inconnue. `bindingSpeakers(toOutputs:)` la rattachera
            // par son nom dès qu'elle apparaîtra sur le réseau.
            speaker(Library.geneva, 0.893, 0.287, height: 0.75 + 0.22, name: "Geneva", output: nil),
            speaker(Library.homePod, 0.907, 2.770, height: 0.70 + 0.085, name: "HomePod G",
                    output: salonLeftHomePodID),
            speaker(Library.homePod, 4.056, 2.545, height: 0.85 + 0.085, name: "HomePod D",
                    output: salonRightHomePodID),

            // Absents de la capture, mais sans eux aucun délai ne se calcule. Deux lieux au choix
            // (demande de Baptiste), oreilles à 1,10 m : à table côté fenêtre, le lieu par défaut,
            // et la place gauche du canapé, vue sur le plan. Leur place exacte reste à confirmer.
            atTable,
            onSofa,
        ]
    }

    private static func speaker(
        _ preset: RoomObject.Preset, _ x: Double, _ y: Double, height: Double, name: String,
        output: String?
    ) -> RoomObject {
        var object = preset.makeObject(at: CGPoint(x: x, y: y), name: name)
        object.kind = .speaker(outputID: output)
        object.elevation = height
        return object
    }
}
