//
//  RoomLayout.swift
//  AirplayPersonalBridge
//

import CoreGraphics
import Foundation

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
            }
        }

        var symbol: String {
            switch self {
            case .sofa: "sofa.fill"
            case .tv: "tv.fill"
            case .tvStand: "cabinet.fill"
            case .table, .coffeeTable, .sideTable: "table.furniture.fill"
            case .shelf: "books.vertical.fill"
            case .device: "appletv.fill"
            case .speaker: "hifispeaker.fill"
            case .listener: "figure.seated.side"
            }
        }

        var outputID: String? {
            if case let .speaker(outputID) = self { return outputID }
            return nil
        }
    }

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

        func makeObject(at position: CGPoint, name: String = "") -> RoomObject {
            RoomObject(
                kind: kind, position: position, size: size, elevation: elevation, name: name,
                shape: shape, armThickness: armThickness
            )
        }
    }

    /// La bibliothèque, groupée comme elle s'affiche dans le menu.
    enum Library {
        static let seating: [Preset] = [
            // Cotes relevées : 243 de long, 156 au bout du L, 91 de profondeur ailleurs.
            // L'emprise vaut donc 243 × 156, et 91 est l'épaisseur des deux branches.
            Preset(label: "Canapé d'angle (243 × 156, prof. 91)", kind: .sofa,
                   size: CGSize(width: 2.43, height: 1.56), shape: .lShape, elevation: 0.45,
                   note: "hauteur d'assise", armThickness: 0.91),
            Preset(label: "Canapé droit", kind: .sofa, size: CGSize(width: 2.00, height: 0.90),
                   elevation: 0.45, note: "hauteur d'assise"),
        ]

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
            Preset(label: "Petite table ronde (Ø 50, h 70)", kind: .sideTable,
                   size: CGSize(width: 0.50, height: 0.50), shape: .ellipse, elevation: 0.70,
                   note: "hauteur du plateau"),
            Preset(label: "Table", kind: .table, size: CGSize(width: 1.20, height: 0.70),
                   elevation: 0.75, note: "hauteur du plateau"),
        ]

        static let storage: [Preset] = [
            Preset(label: "Meuble TV (175 × 40)", kind: .tvStand,
                   size: CGSize(width: 1.75, height: 0.40), elevation: 0.50,
                   note: "hauteur du dessus"),
            Preset(label: "Étagère (90 × 25, h 70)", kind: .shelf,
                   size: CGSize(width: 0.90, height: 0.25), elevation: 0.70,
                   note: "hauteur du dessus"),
        ]

        /// Les enceintes sont rondes : vues du dessus, c'est leur encombrement réel qui
        /// compte pour juger d'un dégagement, et un rectangle en donnerait une idée fausse.
        static let speakers: [Preset] = [
            Preset(label: "Geneva (Ø 45)", kind: .speaker(outputID: nil),
                   size: CGSize(width: 0.45, height: 0.45), shape: .ellipse, elevation: 0.90,
                   note: "hauteur du haut-parleur"),
            Preset(label: "HomePod (Ø 15)", kind: .speaker(outputID: nil),
                   size: CGSize(width: 0.15, height: 0.15), shape: .ellipse, elevation: 0.90,
                   note: "hauteur du haut-parleur"),
            Preset(label: "Enceinte générique (Ø 30)", kind: .speaker(outputID: nil),
                   size: CGSize(width: 0.30, height: 0.30), shape: .ellipse, elevation: 0.90,
                   note: "hauteur du haut-parleur"),
        ]

        static let audio: [Preset] = [
            // 55 pouces = 139,7 cm de diagonale ; en 16/9 la largeur vaut la diagonale
            // fois 16/√(16²+9²), soit 121,8 cm. C'est la dalle seule, cadre non compris.
            Preset(label: "Télé 55″ (122 cm)", kind: .tv,
                   size: CGSize(width: 1.22, height: 0.07), elevation: 1.05,
                   note: "centre de l'écran"),
            // L'Apple TV ne produit aucun son : c'est le point de destination AirPlay 2,
            // restitué par les HomePod. On la place pour le repère, pas pour le calcul —
            // d'où un simple boîtier et non une enceinte.
            Preset(label: "Apple TV (boîtier)", kind: .device,
                   size: CGSize(width: 0.10, height: 0.10), elevation: 0.55,
                   note: "hauteur de pose"),
            Preset(label: "Position d'écoute", kind: .listener,
                   size: CGSize(width: 0.45, height: 0.40), elevation: 1.10,
                   note: "hauteur d'oreilles, assis"),
        ]

        static let groups: [(String, [Preset])] = [
            ("Assises", seating), ("Tables", tables), ("Rangements", storage),
            ("Enceintes", speakers), ("Audio", audio),
        ]

        /// Le modèle d'enceinte générique, pour poser une sortie découverte d'un seul geste.
        static var genericSpeaker: Preset { speakers[2] }
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
        switch shape {
        case .rectangle:
            return abs(localX) <= halfWidth && abs(localY) <= halfHeight
        case .ellipse:
            let x = localX / halfWidth
            let y = localY / halfHeight
            return x * x + y * y <= 1
        case .lShape:
            return Self.polygon(localPolygon, contains: CGPoint(x: localX, y: localY))
        }
    }

    /// Lancer de rayon horizontal : un point est dedans s'il traverse un nombre impair
    /// d'arêtes. Suffisant ici, où les contours sont simples et sans trou.
    private static func polygon(_ points: [CGPoint], contains point: CGPoint) -> Bool {
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

    /// Meubles, enceintes et position d'écoute, dans l'ordre de dessin.
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

        var length: Double { hypot(b.x - a.x, b.y - a.y) }

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

    // MARK: - Accès

    var listener: RoomObject? { objects.first { $0.kind == .listener } }

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
        var rects: [CGRect] = wallVertices.map { CGRect(origin: $0, size: .zero) }
        // L'emprise d'un objet tourné est celle de son cercle circonscrit : suffisant pour
        // cadrer, et insensible à l'angle, ce qui évite que le plan tressaute en tournant
        // un meuble.
        rects += objects.map { object in
            let radius = hypot(object.size.width, object.size.height) / 2
            return CGRect(
                x: object.position.x - radius, y: object.position.y - radius,
                width: radius * 2, height: radius * 2
            )
        }
        guard let first = rects.first else { return nil }
        return rects.dropFirst().reduce(first) { $0.union($1) }
    }

    /// Dimensions hors-tout, telles qu'affichées sous le plan.
    var dimensions: CGSize? { bounds.map { CGSize(width: $0.width, height: $0.height) } }

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
        result.walls = walls.map { WallSegment(id: $0.id, a: rotate($0.a), b: rotate($0.b)) }
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
        if let data = try? Data(contentsOf: storageURL),
            let layout = try? JSONDecoder().decode(RoomLayout.self, from: data)
        {
            return layout
        }
        for key in legacyKeys {
            if let data = UserDefaults.standard.data(forKey: key),
                let layout = try? JSONDecoder().decode(RoomLayout.self, from: data)
            {
                layout.save()
                return layout
            }
        }
        return RoomLayout()
    }

    /// Écriture atomique : une sauvegarde interrompue ne doit pas laisser un fichier
    /// tronqué, qui serait pire qu'une absence de fichier — il ne se décoderait plus.
    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        try? data.write(to: Self.storageURL, options: .atomic)
    }
}

// MARK: - Décodage tolérant

extension RoomLayout {
    enum CodingKeys: String, CodingKey {
        case walls, objects, background
    }

    /// Chaque champ est facultatif et retombe sur sa valeur par défaut.
    ///
    /// Les objets sont décodés **à part** : si un jour un type d'objet devient illisible,
    /// on perd les meubles mais on garde les murs, qui représentent le gros du travail de
    /// relevé. Tout rejeter en bloc serait le pire des comportements.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        walls = (try? container.decode([WallSegment].self, forKey: .walls)) ?? []
        objects = (try? container.decode([RoomObject].self, forKey: .objects)) ?? []
        background = try? container.decode(Background.self, forKey: .background)
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
