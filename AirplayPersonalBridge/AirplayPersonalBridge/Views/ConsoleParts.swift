//
//  ConsoleParts.swift
//  AirplayPersonalBridge
//

import SwiftUI

/// Les mesures de la console : des tuiles de largeur fixe, sur une seule ligne.
enum ConsoleMetrics {
    static let generalWidth: CGFloat = 172
    static let speakerWidth: CGFloat = 160
    /// La tuile qui tient lieu d'enceintes quand il n'y en a aucune.
    static let placeholderWidth: CGFloat = 380
    static let tileSpacing: CGFloat = 14
    static let tileRadius: CGFloat = 28
    static let tilePadding: CGFloat = 14
    /// La hauteur de l'en-tête d'une tuile, la même partout : les curseurs partent de la même ligne.
    static let tileHeader: CGFloat = 54
    static let badge: CGFloat = 38
    static let roundButton: CGFloat = 34
    /// Du bord de la fenêtre au contenu.
    static let margin: CGFloat = 32

    static var tileShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: tileRadius, style: .continuous)
    }
}

// MARK: - Ce que dit une tuile

/// Le témoin d'une tuile, à côté de son état en mots.
enum ConsoleTileIndicator: Equatable {
    /// Elle reçoit, et un son passe : le seul cas où le témoin a le droit de bouger.
    case live
    /// Une session se négocie ou se reprend.
    case busy
    case failed
    case none

    static func kind(
        connection: OutputConnectionState, isEnabled: Bool, isMuted: Bool, isAudible: Bool
    ) -> ConsoleTileIndicator {
        guard isEnabled else { return .none }
        switch connection {
        case .connecting, .waiting, .reconnecting: return .busy
        case .failed: return .failed
        case .streaming: return isAudible && !isMuted ? .live : .none
        case .idle: return .none
        }
    }
}

/// L'état d'une enceinte en mots, à la largeur d'une tuile : hors de la vue pour être testé.
enum ConsoleTileCaption {
    /// Les mots de la carte de la vue « Plan » (`SpeakerCardCaption`), sans la paire stéréo, qui a sa
    /// propre ligne. Cochée et au repos, une enceinte que le réseau ne voit pas le dit : « Prête » serait
    /// faux.
    static func make(
        connection: OutputConnectionState, isEnabled: Bool, isMuted: Bool, proto: String,
        statusLine: (text: String, tone: OutputStatusTone)?
    ) -> (text: String, tone: OutputStatusTone) {
        if isEnabled, connection == .idle, let statusLine { return statusLine }
        let text = SpeakerCardCaption.text(
            connection: connection, isEnabled: isEnabled, isMuted: isMuted, proto: proto, partners: []
        )
        guard isEnabled else { return (text, .muted) }
        switch connection {
        case .failed: return (text, .critical)
        case .waiting, .reconnecting: return (text, .warning)
        case .idle, .connecting, .streaming: return (text, .muted)
        }
    }

    /// Le message du moteur, quand il en dit plus que la légende : il ne tient pas dans une tuile, et se
    /// lit sous la console. Une enceinte qui exige une intervention le porte déjà dans sa tuile.
    static func detail(
        connection: OutputConnectionState, isEnabled: Bool, isHeldBack: Bool
    ) -> (text: String, tone: OutputStatusTone)? {
        guard isEnabled, !isHeldBack else { return nil }
        switch connection {
        case let .failed(message): return (message, .critical)
        case let .waiting(_, message, _): return (message, .warning)
        case let .reconnecting(message): return message.map { ($0, .warning) }
        case .idle, .connecting, .streaming: return nil
        }
    }
}

extension OutputState {
    /// Exige une intervention : sa tuile s'efface, sans curseur.
    var consoleIsHeldBack: Bool {
        unavailability != nil && connection != .streaming
    }
}

extension OutputStatusTone {
    /// La couleur d'un texte de ce ton, sur le verre sombre de la console.
    var consoleColor: Color {
        switch self {
        case .muted: .secondary
        case .warning: PanelPalette.warningText
        case .critical: PanelPalette.criticalText
        }
    }
}

// MARK: - Témoin de diffusion

/// Trois barres qui montent et descendent : l'enceinte joue. Elles ne mesurent rien, et restent assez
/// lentes pour ne pas passer pour un niveau.
struct ConsoleLiveBars: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Fenêtre à l'arrière-plan : les barres s'arrêtent, personne ne les regarde.
    @Environment(\.appearsActive) private var appearsActive

    static let barCount = 3
    static let minimumLevel = 0.35
    /// Sans mouvement, les barres restent dites : posées, inégales.
    static let restLevels = [0.6, 1.0, 0.75]
    private static let height: CGFloat = 11

    /// La hauteur de chaque barre à cet instant, de `minimumLevel` à 1. Des périodes sans commune mesure :
    /// le mouvement ne se répète pas à l'œil.
    static func levels(at time: TimeInterval) -> [Double] {
        let speeds = [4.4, 5.6, 3.7]
        let phases = [0.0, 1.9, 3.8]
        return (0..<barCount).map { index in
            let wave = 0.5 + 0.5 * sin(time * speeds[index] + phases[index])
            return minimumLevel + (1 - minimumLevel) * wave
        }
    }

    var body: some View {
        Group {
            if reduceMotion {
                bars(Self.restLevels)
            } else {
                TimelineView(.animation(minimumInterval: 1 / 20, paused: !appearsActive)) { timeline in
                    bars(Self.levels(at: timeline.date.timeIntervalSinceReferenceDate))
                }
            }
        }
        .accessibilityHidden(true)
    }

    private func bars(_ levels: [Double]) -> some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(Array(levels.enumerated()), id: \.offset) { _, level in
                Capsule()
                    .fill(BridgeTheme.rose)
                    .frame(width: 2.5, height: Self.height * level)
            }
        }
        .frame(height: Self.height, alignment: .bottom)
    }
}

// MARK: - Bouton rond

/// Un bouton rond de la console. L'icône ne change pas d'un état à l'autre : elle dit ce que fait le
/// bouton, et c'est le fond qui dit s'il est enclenché, comme dans le panneau.
struct ConsoleRoundButton: View {
    let symbol: String
    var isOn = false
    var diameter: CGFloat = ConsoleMetrics.roundButton
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: diameter * 0.4, weight: .semibold))
                .foregroundStyle(isOn ? Color.white : Color.white.opacity(0.82))
                .frame(width: diameter, height: diameter)
                .background(background, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.4)
        .onHover { isHovering = $0 }
        .animation(PanelMotion.quick(reduceMotion: reduceMotion), value: isHovering)
        .animation(PanelMotion.standard(reduceMotion: reduceMotion), value: isOn)
    }

    private var background: AnyShapeStyle {
        if isOn { return AnyShapeStyle(BridgeTheme.accent) }
        return AnyShapeStyle(Color.white.opacity(isHovering && isEnabled ? 0.2 : 0.12))
    }
}
