//
//  BridgeTheme.swift
//  AirplayPersonalBridge
//

import AppKit
import SwiftUI

/// Le thème de l'app, commun à ses trois vues et au panneau : sombre, rose, sur un fond de bandes de
/// couleur granuleuses (`GrainientBackground`). Il vient de la maquette « Halo » retenue par Baptiste le 2026-11-10, et de l'icône rose.
///
/// L'accent est une couleur de l'app, pas celle du système : `Color.accentColor` suivrait le choix fait
/// dans Réglages Système, et l'app perdrait sa teinte chez qui a choisi le graphite.
enum BridgeTheme {
    /// Le rose de l'icône, un ton plus profond : du texte blanc doit rester lisible dessus.
    static let accent = color(0xDF3880)
    /// Les quatre teintes des ondes du halo et de la sphère.
    static let rose = color(0xFF4F93)
    static let violet = color(0x7C5CFF)
    static let blue = color(0x3D8BFF)
    static let orange = color(0xFF9A3C)
    /// Le noir du fond, à peine violet.
    static let ground = color(0x09080D)

    static func color(_ hex: UInt32) -> Color {
        Color(
            .sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}
