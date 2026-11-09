//
//  GlassStyles.swift
//  AirplayPersonalBridge
//

import SwiftUI

/// Le verre de la fenêtre principale, et sa doublure pour les rendus hors écran.
///
/// Le verre lit ce que le serveur de fenêtres compose derrière lui : `cacheDisplay` n'y a pas accès,
/// et un rendu d'essai n'en montrerait rien, pas même la forme. Quand `windowSimulatesGlass` est posé
/// (par les exports de `Tests/BridgeAppTests` seulement), chaque élément de verre est remplacé par un
/// aplat discret de même forme : de quoi juger la mise en page, jamais le matériau. L'app ne le pose
/// jamais.
extension EnvironmentValues {
    /// Les rendus hors écran de la fenêtre le posent ; l'app, jamais. Le panneau a le sien,
    /// `panelSimulatesGlass`.
    @Entry var windowSimulatesGlass = false
}

extension View {
    /// Un bouton de verre, `.glass` ; `prominent`, `.glassProminent`, teinté par `.tint`.
    func glassButtonStyle(prominent: Bool = false) -> some View {
        modifier(GlassButtonStyleModifier(prominent: prominent))
    }

    /// Un fond de verre flottant, pour ce qui se pose sur le plan.
    func floatingGlass<S: Shape>(in shape: S, interactive: Bool = false) -> some View {
        modifier(FloatingGlassModifier(shape: shape, interactive: interactive))
    }
}

private struct GlassButtonStyleModifier: ViewModifier {
    let prominent: Bool
    @Environment(\.windowSimulatesGlass) private var simulatesGlass

    func body(content: Content) -> some View {
        if simulatesGlass {
            content.buttonStyle(SimulatedGlassButtonStyle(prominent: prominent))
        } else if prominent {
            content.buttonStyle(.glassProminent)
        } else {
            content.buttonStyle(.glass)
        }
    }
}

/// L'aplat d'un bouton de verre, dans les rendus seulement : neutre, ou teinté s'il est proéminent.
private struct SimulatedGlassButtonStyle: ButtonStyle {
    let prominent: Bool
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.controlSize) private var controlSize
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(prominent ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .padding(.horizontal, controlSize == .small ? 8 : 12)
            .frame(minWidth: controlSize == .small ? 24 : 28, minHeight: controlSize == .small ? 24 : 28)
            .background {
                if prominent {
                    Capsule().fill(.tint)
                } else {
                    Capsule().fill(GlassStandIn.fill(colorScheme))
                }
            }
            .overlay { Capsule().strokeBorder(GlassStandIn.edge(colorScheme), lineWidth: 0.5) }
            .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
            .opacity(isEnabled ? 1 : 0.45)
    }
}

private struct FloatingGlassModifier<S: Shape>: ViewModifier {
    let shape: S
    let interactive: Bool
    @Environment(\.windowSimulatesGlass) private var simulatesGlass
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        if simulatesGlass {
            content
                .background(GlassStandIn.fill(colorScheme), in: shape)
                .overlay { shape.stroke(GlassStandIn.edge(colorScheme), lineWidth: 0.5) }
                .shadow(color: .black.opacity(0.12), radius: 4, y: 1)
        } else {
            content.glassEffect(.regular.interactive(interactive), in: shape)
        }
    }
}

/// Les teintes de la doublure. Fixes, et c'est voulu : elles imitent un matériau que le rendu ne sait
/// pas produire, pas une couleur de l'interface.
enum GlassStandIn {
    static func fill(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(white: 0.24).opacity(0.86) : Color(white: 0.99).opacity(0.86)
    }

    static func edge(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.16) : Color.black.opacity(0.08)
    }
}
