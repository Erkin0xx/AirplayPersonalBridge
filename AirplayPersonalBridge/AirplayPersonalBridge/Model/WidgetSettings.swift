//
//  WidgetSettings.swift
//  AirplayPersonalBridge
//

import Foundation

/// Les deux styles du widget, retenus par Baptiste parmi quatre maquettes (2026-11-13). Ils montrent le
/// même état et règlent les mêmes choses ; seule la mise en scène change.
enum WidgetStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Maquette 23 : le disque du Halo entouré de l'anneau du volume général, et trois curseurs fins.
    case halo
    /// Maquette 24 : un bouton rond, le volume général en curseur couché, et trois pastilles-curseurs.
    case band = "bandeau"

    /// Celui d'une installation neuve, ou d'un fichier de réglages d'avant ce choix.
    static let `default` = WidgetStyle.halo

    var id: String { rawValue }

    var title: String {
        switch self {
        case .halo: "Halo"
        case .band: "Bandeau"
        }
    }

    /// L'autre style : le clic droit sur le fond du widget y mène.
    var other: WidgetStyle {
        switch self {
        case .halo: .band
        case .band: .halo
        }
    }
}

/// Ce que le widget garde d'un lancement à l'autre (`settings.json`, clé `widget`).
///
/// Purement visuel, comme la vue de la fenêtre : rien ici ne change ce qui joue.
struct WidgetSettings: Codable, Equatable, Sendable {
    /// Le coin bas gauche de la fenêtre du widget, dans le repère de l'écran d'AppKit.
    struct Position: Codable, Equatable, Sendable {
        var x: Double
        var y: Double

        /// Au-delà, ce n'est pas une place d'écran : un fichier retouché à la main, ou abîmé.
        static let reach = 100_000.0

        var isPlausible: Bool {
            x.isFinite && y.isFinite && abs(x) <= Self.reach && abs(y) <= Self.reach
        }
    }

    /// Le widget est affiché : il se rouvre au lancement suivant.
    var isShown = false
    var style = WidgetStyle.default
    /// Au-dessus des autres fenêtres. Sans cela, il vit à leur niveau et passe dessous.
    var floatsOnTop = true
    /// Là où on l'a laissé. `nil` : jamais déplacé, il s'ouvre dans le coin de l'écran.
    var position: Position?

    private enum CodingKeys: String, CodingKey {
        case isShown, style, floatsOnTop, position
    }

    init() {}

    init(isShown: Bool, style: WidgetStyle = .default, floatsOnTop: Bool = true, position: Position? = nil) {
        self.isShown = isShown
        self.style = style
        self.floatsOnTop = floatsOnTop
        self.position = position
    }

    /// Décodage tolérant, champ par champ : un style inconnu ou une position illisible ne doivent pas
    /// coûter le reste (ni faire écarter tout `settings.json`).
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isShown = (try? container.decode(Bool.self, forKey: .isShown)) ?? false
        style = (try? container.decode(WidgetStyle.self, forKey: .style)) ?? .default
        floatsOnTop = (try? container.decode(Bool.self, forKey: .floatsOnTop)) ?? true
        let decoded = try? container.decode(Position.self, forKey: .position)
        position = decoded.flatMap { $0.isPlausible ? $0 : nil }
    }
}
