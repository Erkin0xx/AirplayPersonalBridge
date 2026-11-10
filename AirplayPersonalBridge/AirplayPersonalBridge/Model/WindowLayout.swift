//
//  WindowLayout.swift
//  AirplayPersonalBridge
//

import Foundation

/// Les trois vues de la fenêtre, qui vivent côte à côte : on passe de l'une à l'autre dans les options,
/// sans rien perdre. Elles montrent le même état et règlent les mêmes choses ; seule la mise en scène
/// change.
enum WindowLayout: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Un seul objet au centre, qui respire quand le son passe ; les enceintes en pastilles dessous.
    case halo
    /// Une tuile et un curseur vertical par enceinte.
    case console
    /// Le plan de la pièce, avec les enceintes en cartes dans la barre latérale.
    case plan

    /// Celle qu'ouvre une installation neuve, ou un fichier de réglages d'avant ce choix.
    static let `default` = WindowLayout.halo

    var id: String { rawValue }

    var title: String {
        switch self {
        case .halo: "Halo"
        case .console: "Console"
        case .plan: "Plan"
        }
    }

    var symbol: String {
        switch self {
        case .halo: "circle.circle"
        case .console: "slider.vertical.3"
        case .plan: "square.split.bottomrightquarter"
        }
    }
}
