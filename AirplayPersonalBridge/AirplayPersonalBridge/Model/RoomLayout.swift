//
//  RoomLayout.swift
//  AirplayPersonalBridge
//

import AudioCore
import CoreGraphics
import CryptoKit
import Foundation
import OSLog

/// Un plan se relit à chaque lancement et s'écrit à chaque geste : une erreur de disque
/// doit laisser une trace, sinon le plan se perd sans que rien ne le dise.
private let planLog = Logger(subsystem: AudioLog.subsystem, category: "plan")

/// Un élément sélectionnable du plan. Murs et meubles partagent la même sélection : on
/// s'attend à pouvoir attraper les deux ensemble et tout effacer d'un coup.
enum PlanElement: Hashable {
    case object(UUID)
    case wall(UUID)
}

/// Un objet posé dans la pièce.
///
/// Le plan est vu du dessus, mais chaque objet porte une **hauteur** : c'est elle qui rend
/// la distance vraiment tridimensionnelle. Entre une enceinte sur une étagère à 1,80 m et
/// des oreilles à 1,10 m assises dans le canapé, l'écart vertical vaut 0,70 m — soit 2 ms
/// de propagation, du même ordre que ce qu'on cherche à corriger. L'ignorer aurait vidé le
/// calcul de son intérêt.
struct RoomObject: Codable, Equatable, Identifiable {
    var id = UUID()
    var kind: Kind
    /// Centre de l'objet au sol, en mètres.
    var position: CGPoint
    /// Emprise au sol, en mètres (largeur × profondeur avant rotation).
    var size: CGSize
    /// Rotation autour de son centre, en degrés, sens horaire.
    var rotation: Double = 0
    /// Hauteur du point qui compte acoustiquement : le haut-parleur pour une enceinte,
    /// les oreilles pour l'auditeur, le centre de l'écran pour la télé. Pas la hauteur
    /// hors-tout du meuble, qui ne sert à rien ici.
    var elevation: Double
    /// Nom affiché. Vide pour les objets dont le type suffit à les désigner.
    var name: String = ""

    /// Empreinte au sol. Une table basse ronde dessinée en carré se place mal contre un
    /// canapé, et le plan sert précisément à juger ces distances-là.
    var shape: Shape = .rectangle

    /// Épaisseur des deux branches d'un canapé d'angle, en mètres. Sans objet ailleurs.
    var armThickness: Double = 0.91
    /// Renvoie le L de l'autre côté. Un canapé d'angle existe en version gauche et droite,
    /// et se tromper de main rend le plan faux là où il sert — la distance aux oreilles.
    var isMirrored: Bool = false

    enum Shape: String, Codable, Equatable {
        case rectangle
        case ellipse
        /// Canapé d'angle : deux branches perpendiculaires dans l'emprise.
        case lShape
    }

    /// Contour de l'objet dans son propre repère, centré sur (0, 0), rotation non comprise.
    ///
    /// Une seule définition sert au dessin **et** au test de clic. Les avoir écrites deux
    /// fois aurait garanti qu'elles divergent : on aurait cliqué à côté d'une forme visible.
    var localPolygon: [CGPoint] {
        let halfWidth = size.width / 2
        let halfHeight = size.height / 2
        switch shape {
        case .rectangle, .ellipse:
            return [
                CGPoint(x: -halfWidth, y: -halfHeight), CGPoint(x: halfWidth, y: -halfHeight),
                CGPoint(x: halfWidth, y: halfHeight), CGPoint(x: -halfWidth, y: halfHeight),
            ]
        case .lShape:
            // Branche longue en haut sur toute la largeur, retour vertical à une extrémité.
            let thickness = min(max(armThickness, 0.05), min(size.width, size.height))
            let returnX = isMirrored ? halfWidth - thickness : -halfWidth + thickness
            return isMirrored
                ? [
                    CGPoint(x: -halfWidth, y: -halfHeight), CGPoint(x: halfWidth, y: -halfHeight),
                    CGPoint(x: halfWidth, y: halfHeight), CGPoint(x: returnX, y: halfHeight),
                    CGPoint(x: returnX, y: -halfHeight + thickness),
                    CGPoint(x: -halfWidth, y: -halfHeight + thickness),
                ]
                : [
                    CGPoint(x: -halfWidth, y: -halfHeight), CGPoint(x: halfWidth, y: -halfHeight),
                    CGPoint(x: halfWidth, y: -halfHeight + thickness),
                    CGPoint(x: returnX, y: -halfHeight + thickness),
                    CGPoint(x: returnX, y: halfHeight),
                    CGPoint(x: -halfWidth, y: halfHeight),
                ]
        }
    }

    enum Kind: Codable, Equatable, Hashable {
        case sofa
        case tv
        case tvStand
        case table
        case coffeeTable
        case sideTable
        case shelf
        /// Matériel qui ne produit pas de son (Apple TV) : repère visuel, hors calcul.
        case device
        /// Rattachée à une sortie découverte, par son identité Bonjour — ou à aucune.
        ///
        /// `nil` est le cas normal au moment où l'on meuble : on dessine sa pièce avant
        /// d'allumer quoi que ce soit, et rien ne doit dépendre de ce qui est visible sur
        /// le réseau à cet instant. Le rattachement se fait ensuite, dans l'inspecteur.
        case speaker(outputID: String?)
        /// La position d'écoute — le « bonhomme ». Une seule dans un plan.
        case listener
        case armchair
        case chair
        /// Son emprise est celle du feuillage, qui passe au-dessus des meubles voisins.
        case plant
        case lamp
        case sideboard
        case console
        case desk
        case rug
        /// Repère : position et sens d'ouverture d'une porte. Hors de tout calcul.
        case door
        /// Repère : une fenêtre posée sur un mur. Hors de tout calcul.
        case window
        case radiator
        /// Ce qui est posé sur un meuble sans jouer de rôle : vase, plateau, écran.
        case decor

        var label: String {
            switch self {
            case .sofa: "Canapé"
            case .tv: "Télé"
            case .tvStand: "Meuble TV"
            case .table: "Table"
            case .coffeeTable: "Table basse"
            case .sideTable: "Table d'appoint"
            case .shelf: "Étagère"
            case .device: "Appareil"
            case .speaker: "Enceinte"
            case .listener: "Position d'écoute"
            case .armchair: "Fauteuil"
            case .chair: "Chaise"
            case .plant: "Plante"
            case .lamp: "Lampe"
            case .sideboard: "Buffet"
            case .console: "Console"
            case .desk: "Bureau"
            case .rug: "Tapis"
            case .door: "Porte"
            case .window: "Fenêtre"
            case .radiator: "Radiateur"
            case .decor: "Objet décoratif"
            }
        }

        var symbol: String {
            switch self {
            case .sofa: "sofa.fill"
            case .tv: "tv.fill"
            case .tvStand, .sideboard: "cabinet.fill"
            case .table, .coffeeTable, .sideTable, .console: "table.furniture.fill"
            case .shelf: "books.vertical.fill"
            case .device: "appletv.fill"
            case .speaker: "hifispeaker.fill"
            case .listener: "figure.seated.side"
            case .armchair: "chair.lounge.fill"
            case .chair: "chair.fill"
            case .plant: "leaf.fill"
            case .lamp: "lamp.floor.fill"
            case .desk: "studentdesk"
            case .rug: "rectangle.dashed"
            case .door: "door.left.hand.open"
            case .window: "window.casement"
            case .radiator: "heater.vertical.fill"
            case .decor: "cube.fill"
            }
        }

        var outputID: String? {
            if case let .speaker(outputID) = self { return outputID }
            return nil
        }

        /// À quel étage de la superposition appartient l'objet (voir `PlanLayer`).
        var layer: PlanLayer {
            switch self {
            case .rug: .floor
            case .door, .window: .wallFixture
            case .speaker, .listener: .top
            default: .furniture
            }
        }

        /// Ce qui couvre une grande surface sans qu'on la vise : le tapis, le débattement
        /// d'une porte. Ils ne se prennent qu'en dernier recours, et ne suivent la souris
        /// qu'une fois sélectionnés — sinon déplacer la vue au-dessus d'un tapis le ferait
        /// glisser sous les meubles.
        var yieldsToEverything: Bool {
            switch self {
            case .rug, .door: true
            default: false
            }
        }

        /// Ni hauteur, ni trajet du son : ces objets ne servent qu'à se repérer dans le plan.
        var hasNoAcousticHeight: Bool {
            switch self {
            case .rug, .door, .window: true
            default: false
            }
        }
    }

    /// Part du feuillage occupée par le pot. Le clic s'y limite (voir `contains`) : le
    /// feuillage déborde sur tout ce qui l'entoure, et il rendrait ces meubles inattrapables.
    static let plantPotRatio = 0.40

    /// Un modèle prêt à poser.
    ///
    /// Les cotes sont des valeurs de meubles courants, à corriger dans l'inspecteur : elles
    /// évitent d'avoir à tout saisir à la main, elles ne prétendent pas décrire *ton*
    /// mobilier. Seules celles que tu as données sont des mesures réelles.
    struct Preset: Identifiable, Hashable {
        var id: String { label }
        let label: String
        let kind: Kind
        let size: CGSize
        var shape: Shape = .rectangle
        let elevation: Double
        /// Ce que mesure `elevation` pour ce meuble, affiché en aide dans l'inspecteur.
        var note: String = ""
        var armThickness: Double = 0.91
        /// Nom donné à l'objet posé. Une Geneva tirée de la bibliothèque doit s'appeler
        /// « Geneva » : c'est ce nom qui permet ensuite de la rattacher à sa sortie, alors que
        /// son identité Bonjour n'est connue qu'une fois l'enceinte allumée.
        var defaultName: String = ""

        func makeObject(at position: CGPoint, name: String = "") -> RoomObject {
            RoomObject(
                kind: kind, position: position, size: size, elevation: elevation,
                name: name.isEmpty ? defaultName : name, shape: shape, armThickness: armThickness
            )
        }
    }

    /// La bibliothèque, groupée comme elle s'affiche dans le menu.
    enum Library {
        // Cotes relevées : 243 de long, 156 au bout du L, 91 de profondeur ailleurs.
        // L'emprise vaut donc 243 × 156, et 91 est l'épaisseur des deux branches.
        static let cornerSofa = Preset(
            label: "Canapé d'angle (243 × 156, prof. 91)", kind: .sofa,
            size: CGSize(width: 2.43, height: 1.56), shape: .lShape, elevation: 0.45,
            note: "hauteur d'assise", armThickness: 0.91
        )

        static let seating: [Preset] = [
            cornerSofa,
            Preset(label: "Canapé droit", kind: .sofa, size: CGSize(width: 2.00, height: 0.90),
                   elevation: 0.45, note: "hauteur d'assise"),
            Preset(label: "Fauteuil (66 × 66)", kind: .armchair,
                   size: CGSize(width: 0.66, height: 0.66), elevation: 0.45,
                   note: "hauteur d'assise"),
            Preset(label: "Chaise (46 × 50)", kind: .chair,
                   size: CGSize(width: 0.46, height: 0.50), elevation: 0.45,
                   note: "hauteur d'assise"),
            Preset(label: "Chaise de bureau (Ø 52)", kind: .chair,
                   size: CGSize(width: 0.52, height: 0.52), shape: .ellipse, elevation: 0.45,
                   note: "hauteur d'assise"),
        ]

        static let sideTable = Preset(
            label: "Petite table ronde (Ø 50, h 70)", kind: .sideTable,
            size: CGSize(width: 0.50, height: 0.50), shape: .ellipse, elevation: 0.70,
            note: "hauteur du plateau"
        )

        static let tables: [Preset] = [
            Preset(label: "Table basse ronde — grande (Ø 90)", kind: .coffeeTable,
                   size: CGSize(width: 0.90, height: 0.90), shape: .ellipse, elevation: 0.40,
                   note: "hauteur du plateau"),
            Preset(label: "Table basse ronde — moyenne (Ø 70)", kind: .coffeeTable,
                   size: CGSize(width: 0.70, height: 0.70), shape: .ellipse, elevation: 0.40,
                   note: "hauteur du plateau"),
            Preset(label: "Table basse ronde — petite (Ø 50)", kind: .coffeeTable,
                   size: CGSize(width: 0.50, height: 0.50), shape: .ellipse, elevation: 0.40,
                   note: "hauteur du plateau"),
            sideTable,
            Preset(label: "Table", kind: .table, size: CGSize(width: 1.20, height: 0.70),
                   elevation: 0.75, note: "hauteur du plateau"),
            Preset(label: "Table ronde (Ø 110)", kind: .table,
                   size: CGSize(width: 1.10, height: 1.10), shape: .ellipse, elevation: 0.75,
                   note: "hauteur du plateau"),
            Preset(label: "Bureau (160 × 80)", kind: .desk,
                   size: CGSize(width: 1.60, height: 0.80), elevation: 0.75,
                   note: "hauteur du plateau"),
        ]

        static let tvStand = Preset(
            label: "Meuble TV (175 × 40)", kind: .tvStand,
            size: CGSize(width: 1.75, height: 0.40), elevation: 0.50,
            note: "hauteur du dessus"
        )

        static let storage: [Preset] = [
            tvStand,
            Preset(label: "Étagère (90 × 25, h 70)", kind: .shelf,
                   size: CGSize(width: 0.90, height: 0.25), elevation: 0.70,
                   note: "hauteur du dessus"),
            Preset(label: "Buffet (160 × 40, h 85)", kind: .sideboard,
                   size: CGSize(width: 1.60, height: 0.40), elevation: 0.85,
                   note: "hauteur du dessus"),
            Preset(label: "Console (80 × 30, h 75)", kind: .console,
                   size: CGSize(width: 0.80, height: 0.30), elevation: 0.75,
                   note: "hauteur du dessus"),
        ]

        /// Les enceintes sont rondes : vues du dessus, c'est leur encombrement réel qui
        /// compte pour juger d'un dégagement, et un rectangle en donnerait une idée fausse.
        static let geneva = Preset(
            label: "Geneva (Ø 45)", kind: .speaker(outputID: nil),
            size: CGSize(width: 0.45, height: 0.45), shape: .ellipse, elevation: 0.90,
            note: "hauteur du haut-parleur", defaultName: "Geneva"
        )
        static let homePod = Preset(
            label: "HomePod (Ø 15)", kind: .speaker(outputID: nil),
            size: CGSize(width: 0.15, height: 0.15), shape: .ellipse, elevation: 0.90,
            note: "hauteur du haut-parleur", defaultName: "HomePod"
        )
        /// Le modèle d'enceinte générique, pour poser une sortie découverte d'un seul geste.
        static let genericSpeaker = Preset(
            label: "Enceinte générique (Ø 30)", kind: .speaker(outputID: nil),
            size: CGSize(width: 0.30, height: 0.30), shape: .ellipse, elevation: 0.90,
            note: "hauteur du haut-parleur"
        )
        static let speakers: [Preset] = [geneva, homePod, genericSpeaker]

        // 55 pouces = 139,7 cm de diagonale ; en 16/9 la largeur vaut la diagonale
        // fois 16/√(16²+9²), soit 121,8 cm. C'est la dalle seule, cadre non compris.
        static let tv55 = Preset(
            label: "Télé 55″ (122 cm)", kind: .tv,
            size: CGSize(width: 1.22, height: 0.07), elevation: 1.05,
            note: "centre de l'écran"
        )
        static let listener = Preset(
            label: "Position d'écoute", kind: .listener,
            size: CGSize(width: 0.45, height: 0.40), elevation: 1.10,
            note: "hauteur d'oreilles, assis"
        )

        static let audio: [Preset] = [
            tv55,
            // L'Apple TV ne produit aucun son : c'est le point de destination AirPlay 2,
            // restitué par les HomePod. On la place pour le repère, pas pour le calcul —
            // d'où un simple boîtier et non une enceinte.
            Preset(label: "Apple TV (boîtier)", kind: .device,
                   size: CGSize(width: 0.10, height: 0.10), elevation: 0.55,
                   note: "hauteur de pose"),
            listener,
        ]

        static let decoration: [Preset] = [
            Preset(label: "Plante (feuillage Ø 100)", kind: .plant,
                   size: CGSize(width: 1.00, height: 1.00), shape: .ellipse, elevation: 1.80,
                   note: "hauteur du sommet"),
            Preset(label: "Lampadaire (Ø 42)", kind: .lamp,
                   size: CGSize(width: 0.42, height: 0.42), shape: .ellipse, elevation: 1.60,
                   note: "hauteur du sommet"),
            Preset(label: "Lampe à poser (Ø 15)", kind: .lamp,
                   size: CGSize(width: 0.15, height: 0.15), shape: .ellipse, elevation: 1.00,
                   note: "hauteur du sommet"),
            Preset(label: "Tapis (300 × 200)", kind: .rug,
                   size: CGSize(width: 3.00, height: 2.00), elevation: 0.01),
            Preset(label: "Objet décoratif (Ø 30)", kind: .decor,
                   size: CGSize(width: 0.30, height: 0.30), shape: .ellipse, elevation: 0.90,
                   note: "hauteur de pose"),
        ]

        /// De purs repères : ils aident à reconnaître la pièce, et aucun calcul ne les lit.
        static let landmarks: [Preset] = [
            Preset(label: "Porte (90)", kind: .door,
                   size: CGSize(width: 0.90, height: 0.90), elevation: 0),
            Preset(label: "Fenêtre (180)", kind: .window,
                   size: CGSize(width: 1.80, height: 0.14), elevation: 0),
            Preset(label: "Radiateur (65 × 9)", kind: .radiator,
                   size: CGSize(width: 0.65, height: 0.09), elevation: 0.60,
                   note: "hauteur du dessus"),
        ]

        static let groups: [(String, [Preset])] = [
            ("Assises", seating), ("Tables", tables), ("Rangements", storage),
            ("Enceintes", speakers), ("Audio", audio), ("Décoration", decoration),
            ("Repères", landmarks),
        ]
    }

    /// Test d'appartenance, rotation et forme comprises : on ramène le point dans le repère
    /// propre de l'objet plutôt que de faire tourner la figure.
    func contains(_ point: CGPoint) -> Bool {
        let dx = point.x - position.x
        let dy = point.y - position.y
        let angle = -rotation * .pi / 180
        let localX = dx * cos(angle) - dy * sin(angle)
        let localY = dx * sin(angle) + dy * cos(angle)
        let halfWidth = max(size.width / 2, 1e-6)
        let halfHeight = max(size.height / 2, 1e-6)
        if kind == .plant {
            let x = localX / (halfWidth * Self.plantPotRatio)
            let y = localY / (halfHeight * Self.plantPotRatio)
            return x * x + y * y <= 1
        }
        switch shape {
        case .rectangle:
            return abs(localX) <= halfWidth && abs(localY) <= halfHeight
        case .ellipse:
            let x = localX / halfWidth
            let y = localY / halfHeight
            return x * x + y * y <= 1
        case .lShape:
            return RoomLayout.polygon(localPolygon, contains: CGPoint(x: localX, y: localY))
        }
    }

    var isRound: Bool { shape == .ellipse && abs(size.width - size.height) < 0.001 }

    /// Où poser l'icône, dans le repère propre de l'objet, en mètres.
    ///
    /// Au centre pour presque tout — mais le centre géométrique d'un canapé d'angle tombe
    /// dans le vide de l'angle, là où il n'y a pas de canapé. L'icône va donc au milieu de
    /// la méridienne, la seule partie assez large pour la porter.
    var iconOffset: CGPoint {
        guard shape == .lShape else { return .zero }
        let thickness = min(max(armThickness, 0.05), min(size.width, size.height))
        let x = size.width / 2 - thickness / 2
        return CGPoint(x: isMirrored ? x : -x, y: thickness / 2)
    }
}

/// Les étages du dessin, du sol vers le haut.
///
/// Un plan n'est pas qu'une liste dans l'ordre de pose : un tapis posé après le canapé le
/// recouvrirait, et une table ajoutée tard masquerait l'enceinte qu'elle porte. Les murs
/// se dessinent entre `furniture` et `wallFixture`, ce qui leur fait cacher ce qui déborde
/// (le feuillage d'une plante en angle) sans cacher la fenêtre qu'ils portent.
enum PlanLayer: Int, Comparable {
    case floor
    case furniture
    case wallFixture
    case top

    static func < (lhs: PlanLayer, rhs: PlanLayer) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Le plan de la pièce (CDC section 9).
///
/// **Toutes les coordonnées sont en mètres**, jamais en points d'écran : c'est ce qui
/// permet d'en tirer une distance, donc un temps de propagation. La conversion vers
/// l'écran vit dans `PlanTransform`, du côté de la vue, et nulle part ailleurs.
///
/// Le type ne s'appelle pas `RoomPlan` pour ne pas entrer en collision avec le framework
/// Apple du même nom — celui du scan LiDAR, écarté comme sous-projet distinct.
struct RoomLayout: Codable, Equatable {
    /// Murs, **segment par segment**.
    ///
    /// La première version les stockait en polylignes. Une pièce fermée n'y était donc
    /// qu'un seul objet : sélectionner un pan pour l'effacer effaçait toute la pièce, sans
    /// recours. Une liste plate coûte quelques points dupliqués aux angles — négligeable —
    /// et rend la sélection fine naturelle plutôt qu'à reconstruire.
    var walls: [WallSegment] = []

    /// Meubles, enceintes et position d'écoute. À étage égal, l'ordre du tableau est l'ordre
    /// de dessin (voir `objectsInDrawingOrder`).
    var objects: [RoomObject] = []

    /// Image de fond à décalquer : photo ou capture d'un plan existant.
    var background: Background?

    /// Un plan existant posé sous la grille, mis à l'échelle par calibrage.
    ///
    /// L'échelle ne se devine pas : une image ne porte aucune notion de mètre. On la
    /// déduit d'une mesure connue tracée dessus (« ce mur fait 4,20 m »), ce qui est
    /// exactement la manière dont on relève un plan papier.
    struct Background: Codable, Equatable {
        /// Nom du fichier recopié dans le dossier de l'app — pas un chemin vers l'original,
        /// qui peut être déplacé ou effacé sans prévenir.
        var fileName: String
        /// Coin haut-gauche de l'image, en mètres.
        var origin: CGPoint = .zero
        /// Taille d'un pixel de l'image, en mètres. C'est la seule inconnue du calibrage.
        var metersPerPixel: Double = 0.01
        var opacity: Double = 0.45
        /// Orientation de l'image, en degrés — elle suit les rotations du plan.
        var rotation: Double = 0
        /// Définition de l'image en pixels, retenue à l'import pour pouvoir la faire
        /// pivoter sans avoir à la recharger depuis le disque.
        var pixelWidth: Double = 0
        var pixelHeight: Double = 0
        /// Verrouillée, l'image ne se déplace plus : une fois calée, on ne veut plus la
        /// bouger par accident en déplaçant la vue.
        var isLocked = true
    }

    /// Dossier où sont recopiées les images de fond.
    static var backgroundsDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "AirplayPersonalBridge/plans")
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    struct WallSegment: Codable, Equatable, Identifiable {
        var id = UUID()
        var a: CGPoint
        var b: CGPoint
        /// Épaisseur du mur, en mètres, **à gauche du sens de tracé** : pour un contour tourné
        /// dans le sens horaire, c'est l'extérieur, et le segment reste la face intérieure.
        ///
        /// C'est la face intérieure qui compte pour poser un meuble contre un mur et pour
        /// comparer aux cotes d'un plan. Un mur tracé à la main reste à 0 : un simple trait,
        /// dont on ne sait pas de quel côté il aurait de l'épaisseur.
        var thickness: Double = 0
        /// Peinture de la face intérieure, purement visuelle.
        var paint: Paint?

        enum Paint: String, Codable, Equatable {
            case sage
        }

        var length: Double { hypot(b.x - a.x, b.y - a.y) }

        /// Vecteur unitaire de `a` vers `b`, nul pour un mur de longueur nulle.
        var direction: CGPoint {
            guard length > 1e-9 else { return .zero }
            return CGPoint(x: (b.x - a.x) / length, y: (b.y - a.y) / length)
        }

        /// Vecteur unitaire vers le côté où le mur a de l'épaisseur.
        var outerNormal: CGPoint { CGPoint(x: direction.y, y: -direction.x) }

        /// Distance d'un point au segment, bornée à ses extrémités — un mur n'est pas une
        /// droite infinie, et viser au-delà de son bout ne doit pas le sélectionner.
        func distance(to point: CGPoint) -> Double {
            let dx = b.x - a.x
            let dy = b.y - a.y
            let lengthSquared = dx * dx + dy * dy
            guard lengthSquared > 1e-9 else { return hypot(point.x - a.x, point.y - a.y) }
            let t = min(max(((point.x - a.x) * dx + (point.y - a.y) * dy) / lengthSquared, 0), 1)
            return hypot(point.x - (a.x + t * dx), point.y - (a.y + t * dy))
        }
    }

    /// Tous les points de mur, pour le magnétisme aux angles existants.
    var wallVertices: [CGPoint] { walls.flatMap { [$0.a, $0.b] } }

    /// Contour du corps d'un mur épais, vide pour un mur sans épaisseur.
    ///
    /// Les extrémités sont coupées en onglet sur le mur voisin : un rectangle par segment
    /// laisserait un trou à chaque angle sortant et mordrait dans la pièce à chaque angle
    /// rentrant. Un bout libre, comme celui d'une ouverture de porte, reste coupé d'équerre.
    func wallBody(_ wall: WallSegment) -> [CGPoint] {
        guard wall.thickness > 0, wall.length > 1e-9 else { return [] }
        return [
            wall.a, wall.b,
            outerCorner(of: wall, at: wall.b),
            outerCorner(of: wall, at: wall.a),
        ]
    }

    private func outerCorner(of wall: WallSegment, at vertex: CGPoint) -> CGPoint {
        let normal = wall.outerNormal
        let foot = CGPoint(
            x: vertex.x + normal.x * wall.thickness, y: vertex.y + normal.y * wall.thickness
        )
        let direction = wall.direction
        for neighbor in walls where neighbor.id != wall.id && neighbor.thickness > 0 {
            let touches = [neighbor.a, neighbor.b].contains {
                hypot($0.x - vertex.x, $0.y - vertex.y) < 0.002
            }
            guard touches else { continue }
            let other = neighbor.direction
            let determinant = direction.x * other.y - direction.y * other.x
            guard abs(determinant) > 1e-6 else { continue }
            // Le coin extérieur est l'intersection des deux faces extérieures.
            let origin = CGPoint(
                x: neighbor.a.x + neighbor.outerNormal.x * neighbor.thickness,
                y: neighbor.a.y + neighbor.outerNormal.y * neighbor.thickness
            )
            let travel = ((origin.x - foot.x) * other.y - (origin.y - foot.y) * other.x) / determinant
            let corner = CGPoint(x: foot.x + direction.x * travel, y: foot.y + direction.y * travel)
            // Un angle très aigu enverrait la pointe de l'onglet à l'autre bout du plan.
            guard hypot(corner.x - vertex.x, corner.y - vertex.y) < wall.thickness * 4 else {
                continue
            }
            return corner
        }
        return foot
    }

    // MARK: - Accès

    var listener: RoomObject? { objects.first { $0.kind == .listener } }

    /// Les objets du dessous vers le dessus. Le tri est stable : à étage égal, le dernier
    /// posé reste au-dessus, comme avant l'introduction des étages.
    var objectsInDrawingOrder: [RoomObject] {
        objects.enumerated()
            .sorted { lhs, rhs in
                lhs.element.kind.layer == rhs.element.kind.layer
                    ? lhs.offset < rhs.offset
                    : lhs.element.kind.layer < rhs.element.kind.layer
            }
            .map(\.element)
    }

    /// Objet sous le point : le plus haut dessiné, puisque c'est celui qu'on voit. Le tapis
    /// et le débattement des portes ne répondent que si rien d'autre n'est dessous.
    func object(at point: CGPoint) -> RoomObject? {
        let touched = objectsInDrawingOrder.filter { $0.contains(point) }
        return touched.last { !$0.kind.yieldsToEverything } ?? touched.last
    }

    /// Élément sous le point, dans l'ordre inverse du dessin : enceintes et fenêtres, puis le
    /// corps des murs, puis les meubles, puis la tolérance autour d'un mur, puis le tapis.
    ///
    /// La tolérance vient **après** les meubles parce que ce sont eux qu'on croit viser quand
    /// on clique à côté d'un mur. Le corps du mur vient avant, lui : il recouvre à l'écran ce
    /// qui déborde derrière, et on ne s'attend pas à attraper ce qu'on ne voit plus.
    func element(at point: CGPoint, wallTolerance: Double) -> PlanElement? {
        let hit = object(at: point)
        if let hit, hit.kind.layer > .furniture, !hit.kind.yieldsToEverything {
            return .object(hit.id)
        }
        if let wall = walls.last(where: {
            let body = wallBody($0)
            return !body.isEmpty && Self.polygon(body, contains: point)
        }) {
            return .wall(wall.id)
        }
        if let hit, !hit.kind.yieldsToEverything { return .object(hit.id) }
        let near = walls
            .map { ($0, $0.distance(to: point)) }
            .filter { $0.1 < wallTolerance }
            .min { $0.1 < $1.1 }?.0
        if let near { return .wall(near.id) }
        return hit.map { .object($0.id) }
    }

    /// Lancer de rayon horizontal : un point est dedans s'il traverse un nombre impair
    /// d'arêtes. Suffisant ici, où les contours sont simples et sans trou.
    static func polygon(_ points: [CGPoint], contains point: CGPoint) -> Bool {
        var isInside = false
        var j = points.count - 1
        for i in points.indices {
            let a = points[i]
            let b = points[j]
            if (a.y > point.y) != (b.y > point.y),
                point.x < (b.x - a.x) * (point.y - a.y) / (b.y - a.y) + a.x
            {
                isInside.toggle()
            }
            j = i
        }
        return isInside
    }

    // MARK: - Rattachement

    /// Noms sous lesquels une même enceinte peut s'annoncer. La Geneva s'appelle « Geneva »
    /// sur le plan et peut se présenter sur le réseau sous sa gamme, « AeroSphere ».
    private static let speakerAliases: [[String]] = [["geneva", "aerosphere"]]

    /// Rattache à sa sortie toute enceinte qui n'en a pas et dont le nom correspond.
    ///
    /// L'identité Bonjour d'un récepteur RAOP (`raop/<MAC>@<nom>`) n'est connue qu'une fois
    /// l'appareil allumé : un plan préparé à l'avance ne peut pas la contenir. Le nom est le
    /// seul lien disponible d'ici là.
    ///
    /// **Dans le doute, on ne rattache pas.** Deux sorties qui répondent au même nom laissent
    /// l'enceinte libre : une enceinte sans sortie se voit et se corrige dans l'inspecteur,
    /// alors qu'un rattachement faux fausse le délai suggéré sans rien dire. Une enceinte déjà
    /// rattachée n'est jamais touchée, même si sa sortie a disparu du réseau pour l'instant.
    func bindingSpeakers(toOutputs outputs: [(id: String, name: String)]) -> RoomLayout {
        var result = self
        for index in result.objects.indices {
            guard case let .speaker(outputID) = result.objects[index].kind, outputID == nil,
                let match = Self.output(matching: result.objects[index].name, among: outputs)
            else { continue }
            result.objects[index].kind = .speaker(outputID: match)
        }
        return result
    }

    private static func output(
        matching speakerName: String, among outputs: [(id: String, name: String)]
    ) -> String? {
        let name = normalized(speakerName)
        guard !name.isEmpty else { return nil }
        let exact = outputs.filter { normalized($0.name) == name }
        if !exact.isEmpty { return exact.count == 1 ? exact[0].id : nil }
        guard let aliases = speakerAliases.first(where: { group in
            group.contains { name.contains($0) }
        }) else { return nil }
        let candidates = outputs.filter { output in
            aliases.contains { normalized(output.name).contains($0) }
        }
        return candidates.count == 1 ? candidates[0].id : nil
    }

    private static func normalized(_ name: String) -> String {
        name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// **Plusieurs** enceintes peuvent porter la même sortie.
    ///
    /// C'est le cas de l'installation cible : l'Apple TV et ses deux HomePod en stéréo ne
    /// forment qu'une seule destination AirPlay 2 (CDC section 2), mais ce sont bien deux
    /// boîtes distantes dans la pièce. Les traiter comme un point unique aurait faussé la
    /// distance de la moitié de leur écartement.
    func speakers(forOutput outputID: String) -> [RoomObject] {
        objects.filter { $0.kind.outputID == outputID }
    }

    // MARK: - Géométrie

    /// Vitesse du son dans l'air à ~20 °C. Elle varie de ~0,6 m/s par degré, soit moins
    /// de 1 % sur toute la plage d'une pièce habitée : la raffiner n'aurait aucun sens
    /// face à l'imprécision des positions relevées à la main.
    static let speedOfSound: Double = 343

    /// Distance en trois dimensions entre une enceinte et les oreilles de l'auditeur.
    func distance(from speaker: RoomObject, to listener: RoomObject) -> Double {
        let dx = speaker.position.x - listener.position.x
        let dy = speaker.position.y - listener.position.y
        let dz = speaker.elevation - listener.elevation
        return sqrt(dx * dx + dy * dy + dz * dz)
    }

    /// Distance retenue pour une **sortie**, moyenne de ses enceintes.
    ///
    /// Une paire stéréo reçoit le même flux et joue au même instant : ce qu'on peut
    /// corriger, c'est un décalage commun, pas l'écart entre les deux boîtes — qui relève
    /// du placement, pas du réglage. La moyenne est donc la seule valeur qu'un délai unique
    /// puisse honorer.
    func distanceToListener(outputID: String) -> Double? {
        guard let listener else { return nil }
        let distances = speakers(forOutput: outputID).map { distance(from: $0, to: listener) }
        guard !distances.isEmpty else { return nil }
        return distances.reduce(0, +) / Double(distances.count)
    }

    /// Délai à appliquer à chaque sortie pour que les sons arrivent ensemble à l'oreille.
    ///
    /// L'enceinte la plus lointaine arrive la dernière : c'est elle la référence, et les
    /// autres se retardent de leur avance. Elle garde donc 0 ms, ce qui évite d'ajouter
    /// une latence globale inutile.
    ///
    /// À distinguer de l'ancrage du jalon 4, qui aligne la **restitution chez les
    /// récepteurs** ; ceci aligne l'**arrivée à l'oreille**. Les deux s'additionnent.
    func suggestedDelaysMS(for outputIDs: [String]) -> [String: Double] {
        let distances = outputIDs.compactMap { id in
            distanceToListener(outputID: id).map { (id, $0) }
        }
        guard let farthest = distances.map(\.1).max() else { return [:] }
        return Dictionary(
            uniqueKeysWithValues: distances.map { id, distance in
                (id, (farthest - distance) / Self.speedOfSound * 1000)
            }
        )
    }

    /// Emprise du plan, murs et objets confondus. `nil` tant que rien n'a été posé.
    var bounds: CGRect? {
        // Le corps des murs compte : c'est lui qu'on voit à l'écran, pas leur face intérieure.
        let wallPoints = wallVertices + walls.flatMap { wallBody($0) }
        var rects: [CGRect] = wallPoints.map { CGRect(origin: $0, size: .zero) }
        // L'emprise exacte de chaque objet tourné. Le cercle circonscrit, plus simple, gonflait
        // le cadrage de tout objet long et fin : celui d'une fenêtre de 1,80 m débordait de
        // 90 cm de part et d'autre du mur, et la pièce n'occupait plus que 40 % de la vue.
        rects += objects.map { object in
            let angle = object.rotation * .pi / 180
            let (c, s) = (abs(cos(angle)), abs(sin(angle)))
            let (a, b) = (object.size.width / 2, object.size.height / 2)
            let halfWidth = object.shape == .ellipse ? hypot(a * c, b * s) : a * c + b * s
            let halfHeight = object.shape == .ellipse ? hypot(a * s, b * c) : a * s + b * c
            return CGRect(
                x: object.position.x - halfWidth, y: object.position.y - halfHeight,
                width: halfWidth * 2, height: halfHeight * 2
            )
        }
        guard let first = rects.first else { return nil }
        return rects.dropFirst().reduce(first) { $0.union($1) }
    }

    /// Dimensions de la pièce, telles qu'affichées sous le plan : celles des murs dès qu'il y
    /// en a. Ce qui déborde (feuillage, meuble hors pièce) sert au cadrage, mais annoncer
    /// « 5,3 × 6,6 m » pour une pièce de 4,25 × 5,90 m rendrait le chiffre inutilisable.
    var dimensions: CGSize? {
        guard let first = wallVertices.first else {
            return bounds.map { CGSize(width: $0.width, height: $0.height) }
        }
        let walled = wallVertices.dropFirst().reduce(CGRect(origin: first, size: .zero)) {
            $0.union(CGRect(origin: $1, size: .zero))
        }
        return CGSize(width: walled.width, height: walled.height)
    }

    /// Fait pivoter tout le plan d'un quart de tour autour de son centre.
    ///
    /// La rotation porte sur **les données**, pas sur l'affichage. Faire tourner la vue
    /// aurait contaminé tout le reste — test de clic, magnétisme, tracé des murs devraient
    /// chacun défaire la rotation, et la moindre omission passerait inaperçue. Une
    /// transformation ponctuelle du modèle laisse tout le code en aval inchangé, et quatre
    /// rotations ramènent exactement au point de départ.
    func rotatedQuarterTurn(clockwise: Bool) -> RoomLayout {
        guard let bounds else { return self }
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        // Repère écran, ordonnées vers le bas : un quart de tour horaire envoie (dx, dy)
        // sur (−dy, dx).
        func rotate(_ point: CGPoint) -> CGPoint {
            let dx = point.x - center.x
            let dy = point.y - center.y
            return clockwise
                ? CGPoint(x: center.x - dy, y: center.y + dx)
                : CGPoint(x: center.x + dy, y: center.y - dx)
        }

        var result = self
        result.walls = walls.map { wall in
            var rotated = wall
            rotated.a = rotate(wall.a)
            rotated.b = rotate(wall.b)
            return rotated
        }
        result.objects = objects.map { object in
            var rotated = object
            rotated.position = rotate(object.position)
            rotated.rotation = (object.rotation + (clockwise ? 90 : -90))
                .truncatingRemainder(dividingBy: 360)
            if rotated.rotation < 0 { rotated.rotation += 360 }
            return rotated
        }
        if var background {
            // L'image de fond suit, sinon le décalque cesserait de correspondre au relevé.
            // On fait tourner son centre, puis son orientation propre.
            let pixelCenter = CGPoint(
                x: background.origin.x + background.pixelWidth * background.metersPerPixel / 2,
                y: background.origin.y + background.pixelHeight * background.metersPerPixel / 2
            )
            let newCenter = rotate(pixelCenter)
            background.origin = CGPoint(
                x: newCenter.x - background.pixelWidth * background.metersPerPixel / 2,
                y: newCenter.y - background.pixelHeight * background.metersPerPixel / 2
            )
            background.rotation = (background.rotation + (clockwise ? 90 : -90))
                .truncatingRemainder(dividingBy: 360)
            result.background = background
        }
        return result
    }
}

// MARK: - Persistance

extension RoomLayout {
    /// Emplacement unique et **définitif** du plan.
    ///
    /// Les versions précédentes stockaient dans les préférences sous une clé versionnée,
    /// que j'ai changée trois fois en faisant évoluer le format — et chaque changement a
    /// effacé le plan en cours sans rien dire. C'était le défaut le plus coûteux de cet
    /// éditeur : un travail de mise en plan perdu à chaque itération.
    ///
    /// La règle est donc désormais : **un seul emplacement, qui ne change plus jamais**, et
    /// un décodage tolérant (voir `init(from:)`) qui accepte les champs absents plutôt que
    /// de rejeter tout le fichier. Un format qui gagne un champ doit se relire, pas se
    /// perdre.
    static var storageURL: URL {
        let directory = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "AirplayPersonalBridge")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appending(path: "room-layout.json")
    }

    /// Anciennes clés de préférences, relues une fois pour récupérer un plan d'avant le
    /// passage au fichier. Elles ne sont jamais réécrites.
    private static let legacyKeys = ["roomLayout.v4", "roomLayout.v3", "roomLayout.v2", "roomLayout"]

    static func load() -> RoomLayout {
        load(from: storageURL, legacyDefaults: .standard)
    }

    /// Relit un plan, **sans jamais laisser la sauvegarde suivante détruire ce qu'on n'a pas
    /// su lire**.
    ///
    /// Un fichier illisible donnait un plan vide, que le premier geste réécrivait par-dessus
    /// l'original : un octet corrompu coûtait tout le relevé, et sans laisser de trace. On
    /// recopie donc d'abord l'original à côté, y compris quand le décodage tolérant n'a
    /// sauvé qu'une partie du fichier — c'est le cas le plus traître, le plan s'ouvre et
    /// rien n'indique qu'il lui manque des meubles.
    static func load(from url: URL, legacyDefaults: UserDefaults?) -> RoomLayout {
        if FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
            do {
                let data = try Data(contentsOf: url)
                if let decoded = decodeReportingLoss(data) {
                    if !decoded.isComplete {
                        planLog.error("Plan relu en partie seulement : \(url.path, privacy: .public)")
                        preserveCopy(of: data, nextTo: url)
                    }
                    return decoded.layout
                }
                planLog.error("Plan illisible : \(url.path, privacy: .public)")
                preserveCopy(of: data, nextTo: url)
            } catch {
                // Illisible au sens du système de fichiers : on ne peut pas le recopier, mais
                // on peut encore l'écarter du chemin de la prochaine sauvegarde.
                planLog.error(
                    "Lecture du plan impossible : \(error.localizedDescription, privacy: .public)"
                )
                moveAside(url)
            }
        }
        for key in legacyKeys {
            if let data = legacyDefaults?.data(forKey: key),
                let layout = try? JSONDecoder().decode(RoomLayout.self, from: data)
            {
                layout.save(to: url)
                return layout
            }
        }
        return RoomLayout()
    }

    /// Décode le plan et dit si tout y est passé : le décodage tolérant écarte ce qu'il ne
    /// comprend pas sans échouer, et seule une comparaison au JSON brut peut le révéler.
    static func decodeReportingLoss(_ data: Data) -> (layout: RoomLayout, isComplete: Bool)? {
        guard let layout = try? JSONDecoder().decode(RoomLayout.self, from: data) else {
            return nil
        }
        let raw = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        func lostNothing(_ key: CodingKeys, decoded: Int) -> Bool {
            guard let value = raw[key.stringValue], !(value is NSNull) else { return true }
            return (value as? [Any])?.count == decoded
        }
        let backgroundLost = raw[CodingKeys.background.stringValue].map { !($0 is NSNull) } == true
            && layout.background == nil
        let isComplete = lostNothing(.walls, decoded: layout.walls.count)
            && lostNothing(.objects, decoded: layout.objects.count)
            && !backgroundLost
        return (layout, isComplete)
    }

    /// Le nom dérive du contenu : relancer l'app sur le même fichier abîmé ne multiplie pas
    /// les copies, et deux fichiers abîmés différents ne s'écrasent pas.
    @discardableResult
    static func preserveCopy(of data: Data, nextTo url: URL) -> URL? {
        let digest = SHA256.hash(data: data).prefix(6).map { String(format: "%02x", $0) }.joined()
        let copy = url.deletingPathExtension()
            .appendingPathExtension("illisible-\(digest)")
            .appendingPathExtension(url.pathExtension)
        if FileManager.default.fileExists(atPath: copy.path(percentEncoded: false)) { return copy }
        do {
            try data.write(to: copy, options: .atomic)
            planLog.notice("Original du plan préservé : \(copy.path, privacy: .public)")
            return copy
        } catch {
            planLog.error(
                "Impossible de préserver l'original : \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }
    }

    private static func moveAside(_ url: URL) {
        let stamp = Int(Date().timeIntervalSince1970)
        let destination = url.deletingPathExtension()
            .appendingPathExtension("illisible-\(stamp)")
            .appendingPathExtension(url.pathExtension)
        do {
            try FileManager.default.moveItem(at: url, to: destination)
        } catch {
            planLog.error(
                "Impossible d'écarter le plan : \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    /// Écriture atomique : une sauvegarde interrompue ne doit pas laisser un fichier
    /// tronqué, qui serait pire qu'une absence de fichier — il ne se décoderait plus.
    func save() { save(to: Self.storageURL) }

    /// Rend `false` si l'écriture a échoué, ce qui est aussi journalisé : le plan qu'on voit
    /// à l'écran n'existe alors plus que dans cette session.
    @discardableResult
    func save(to url: URL) -> Bool {
        do {
            let data = try JSONEncoder().encode(self)
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            planLog.error(
                "Plan non sauvegardé (\(url.path, privacy: .public)) : \(error.localizedDescription, privacy: .public)"
            )
            return false
        }
    }
}

// MARK: - Annulation

/// La pile d'annulation du plan : des instantanés complets, rien de plus.
///
/// Un plan fait quelques kilo-octets et ne change qu'au rythme des gestes : recopier tout le
/// modèle coûte moins cher qu'une pile de commandes inverses, où chaque nouvelle façon de
/// modifier le plan devrait penser à écrire son inverse — et où l'oubli ne se voit qu'au
/// moment où on en a besoin.
struct PlanHistory: Equatable {
    private(set) var undoStack: [RoomLayout] = []
    private(set) var redoStack: [RoomLayout] = []
    private var groupKey: String?

    /// Au-delà, les gestes les plus anciens sont oubliés.
    static let limit = 100

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    /// Retient l'état d'avant un geste. À appeler **avant** de modifier le plan.
    ///
    /// `group` regroupe une suite de retouches en un seul pas d'annulation : sans cela,
    /// annuler un réglage au curseur reviendrait dessus un cran à la fois.
    mutating func record(_ layout: RoomLayout, group: String? = nil) {
        if let group, group == groupKey { return }
        groupKey = group
        redoStack = []
        guard undoStack.last != layout else { return }
        undoStack.append(layout)
        if undoStack.count > Self.limit { undoStack.removeFirst(undoStack.count - Self.limit) }
    }

    /// Clôt le groupe en cours : la retouche suivante sera un nouveau pas d'annulation.
    mutating func endGroup() { groupKey = nil }

    /// Rend l'état à restaurer, ou `nil` s'il n'y a rien à annuler. Un instantané identique
    /// à l'état courant est sauté : annuler doit toujours produire un effet visible.
    mutating func undo(from current: RoomLayout) -> RoomLayout? {
        groupKey = nil
        while let previous = undoStack.popLast() {
            guard previous != current else { continue }
            redoStack.append(current)
            return previous
        }
        return nil
    }

    mutating func redo(from current: RoomLayout) -> RoomLayout? {
        groupKey = nil
        while let next = redoStack.popLast() {
            guard next != current else { continue }
            undoStack.append(current)
            return next
        }
        return nil
    }
}

// MARK: - Décodage tolérant

extension RoomLayout {
    enum CodingKeys: String, CodingKey {
        case walls, objects, background
    }

    /// Un élément de liste qui n'empêche pas de lire ses voisins s'il est illisible.
    private struct Lossy<Element: Decodable>: Decodable {
        let value: Element?

        init(from decoder: Decoder) throws {
            value = try? Element(from: decoder)
        }
    }

    /// Chaque champ est facultatif et retombe sur sa valeur par défaut.
    ///
    /// Les listes sont lues **élément par élément** : un meuble abîmé ne doit coûter que ce
    /// meuble-là, et ni ses voisins ni les murs, qui représentent le gros du travail de
    /// relevé. Tout rejeter en bloc serait le pire des comportements.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        walls = ((try? container.decode([Lossy<WallSegment>].self, forKey: .walls)) ?? [])
            .compactMap(\.value)
        objects = ((try? container.decode([Lossy<RoomObject>].self, forKey: .objects)) ?? [])
            .compactMap(\.value)
        background = try? container.decode(Background.self, forKey: .background)
    }
}

extension RoomLayout.WallSegment {
    enum CodingKeys: String, CodingKey {
        case id, a, b, thickness, paint
    }

    /// L'épaisseur et la peinture sont venues après coup : un plan qui les ignore doit se
    /// relire tel quel. La forme engendrée par le compilateur exigerait ces clés, et la
    /// moindre d'entre elles absente aurait fait disparaître tous les murs.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? container.decode(UUID.self, forKey: .id)) ?? UUID()
        a = try container.decode(CGPoint.self, forKey: .a)
        b = try container.decode(CGPoint.self, forKey: .b)
        thickness = (try? container.decode(Double.self, forKey: .thickness)) ?? 0
        paint = try? container.decode(Paint.self, forKey: .paint)
    }
}

extension RoomObject {
    enum CodingKeys: String, CodingKey {
        case id, kind, position, size, rotation, elevation, name, shape, armThickness, isMirrored
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Ces quatre-là définissent l'objet : sans eux il n'y a rien à placer.
        id = (try? container.decode(UUID.self, forKey: .id)) ?? UUID()
        kind = try container.decode(Kind.self, forKey: .kind)
        position = try container.decode(CGPoint.self, forKey: .position)
        size = try container.decode(CGSize.self, forKey: .size)
        elevation = try container.decode(Double.self, forKey: .elevation)
        // Le reste est de l'habillage, ajouté au fil des versions.
        rotation = (try? container.decode(Double.self, forKey: .rotation)) ?? 0
        name = (try? container.decode(String.self, forKey: .name)) ?? ""
        shape = (try? container.decode(Shape.self, forKey: .shape)) ?? .rectangle
        // Les enceintes posées avant qu'elles ne deviennent rondes le redeviennent ici :
        // rectifier à la lecture évite d'avoir à les reposer une à une.
        if case .speaker = kind { shape = .ellipse }
        armThickness = (try? container.decode(Double.self, forKey: .armThickness)) ?? 0.91
        isMirrored = (try? container.decode(Bool.self, forKey: .isMirrored)) ?? false
    }
}

extension RoomObject.Kind {
    private enum CodingKeys: String, CodingKey { case type, outputID }

    /// Encodage explicite par nom de type plutôt que la forme engendrée par le compilateur.
    ///
    /// C'est le changement d'un type associé (`String` devenu `String?`) qui avait rendu
    /// illisibles les plans précédents. Avec un discriminant textuel, ajouter un cas ou
    /// rendre un champ facultatif n'invalide plus rien, et un type inconnu retombe sur un
    /// meuble générique au lieu de faire échouer tout le plan.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "sofa": self = .sofa
        case "tv": self = .tv
        case "tvStand": self = .tvStand
        case "table": self = .table
        case "coffeeTable": self = .coffeeTable
        case "sideTable": self = .sideTable
        case "shelf": self = .shelf
        case "device": self = .device
        case "listener": self = .listener
        case "armchair": self = .armchair
        case "chair": self = .chair
        case "plant": self = .plant
        case "lamp": self = .lamp
        case "sideboard": self = .sideboard
        case "console": self = .console
        case "desk": self = .desk
        case "rug": self = .rug
        case "door": self = .door
        case "window": self = .window
        case "radiator": self = .radiator
        case "decor": self = .decor
        case "speaker":
            self = .speaker(outputID: try? container.decode(String.self, forKey: .outputID))
        default: self = .table
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .sofa: try container.encode("sofa", forKey: .type)
        case .tv: try container.encode("tv", forKey: .type)
        case .tvStand: try container.encode("tvStand", forKey: .type)
        case .table: try container.encode("table", forKey: .type)
        case .coffeeTable: try container.encode("coffeeTable", forKey: .type)
        case .sideTable: try container.encode("sideTable", forKey: .type)
        case .shelf: try container.encode("shelf", forKey: .type)
        case .device: try container.encode("device", forKey: .type)
        case .listener: try container.encode("listener", forKey: .type)
        case .armchair: try container.encode("armchair", forKey: .type)
        case .chair: try container.encode("chair", forKey: .type)
        case .plant: try container.encode("plant", forKey: .type)
        case .lamp: try container.encode("lamp", forKey: .type)
        case .sideboard: try container.encode("sideboard", forKey: .type)
        case .console: try container.encode("console", forKey: .type)
        case .desk: try container.encode("desk", forKey: .type)
        case .rug: try container.encode("rug", forKey: .type)
        case .door: try container.encode("door", forKey: .type)
        case .window: try container.encode("window", forKey: .type)
        case .radiator: try container.encode("radiator", forKey: .type)
        case .decor: try container.encode("decor", forKey: .type)
        case let .speaker(outputID):
            try container.encode("speaker", forKey: .type)
            try container.encodeIfPresent(outputID, forKey: .outputID)
        }
    }
}

// MARK: - Conversion écran ↔ pièce

/// Passage entre les mètres du modèle et les points de l'écran.
///
/// Regroupé dans un seul type pour que la vue n'ait jamais à mélanger les deux unités —
/// c'est l'erreur qui rend ce genre d'éditeur impossible à déboguer.
struct PlanTransform {
    /// Points d'écran par mètre.
    let scale: Double
    /// Origine du modèle, exprimée en points d'écran.
    let origin: CGPoint

    func toView(_ point: CGPoint) -> CGPoint {
        CGPoint(x: origin.x + point.x * scale, y: origin.y + point.y * scale)
    }

    func toModel(_ point: CGPoint) -> CGPoint {
        CGPoint(x: (point.x - origin.x) / scale, y: (point.y - origin.y) / scale)
    }

    /// Cadre le plan dans la vue, avec une marge. En l'absence de plan, on part sur une
    /// pièce de 6 m centrée — assez pour que les premiers clics tombent à une échelle
    /// plausible plutôt que dans un espace sans repère.
    static func fitting(
        _ layout: RoomLayout, in size: CGSize, padding: Double = 44
    ) -> PlanTransform {
        let usable = CGSize(
            width: max(size.width - padding * 2, 1), height: max(size.height - padding * 2, 1)
        )
        guard let bounds = layout.bounds, bounds.width > 0.1 || bounds.height > 0.1 else {
            let scale = min(usable.width, usable.height) / 6
            return PlanTransform(
                scale: scale,
                origin: CGPoint(x: size.width / 2 - 3 * scale, y: size.height / 2 - 3 * scale)
            )
        }
        let scale = min(
            usable.width / max(bounds.width, 0.1), usable.height / max(bounds.height, 0.1)
        )
        return PlanTransform(
            scale: scale,
            origin: CGPoint(
                x: (size.width - bounds.width * scale) / 2 - bounds.minX * scale,
                y: (size.height - bounds.height * scale) / 2 - bounds.minY * scale
            )
        )
    }
}
