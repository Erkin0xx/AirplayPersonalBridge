import AppKit
import Foundation
import SwiftUI
import Testing

@testable import BridgeApp

/// La capture d'une fenêtre jamais affichée, verre compris autant qu'on le peut.
///
/// `cacheDisplay` ne dessine ni le verre ni ce qu'il contient : la barre latérale et l'inspecteur d'un
/// `NavigationSplitView` vivent dans un `NSGlassEffectView`, et sortaient vides (sondé : ni `cacheDisplay`
/// ni `CALayer.render(in:)` n'en tirent un pixel, alors que la même liste rendue seule se dessine). Après
/// la capture du cadre, chaque verre visible est donc repeint : un aplat discret à sa place
/// (`GlassStandIn`), puis son contenu. Celui des colonnes est rendu à part, à leur taille, depuis la vue
/// que l'appelant fournit ; celui des boutons de la barre d'outils, capturé tel quel. Le matériau
/// lui-même ne se juge que dans l'app.
enum WindowSnapshot {
    /// Ce qui remplit les colonnes de verre : la barre latérale à gauche, l'inspecteur à droite.
    struct Columns {
        var leading: AnyView?
        var trailing: AnyView?
    }

    static func capture(_ root: NSView, scheme: ColorScheme, columns: Columns) throws -> NSBitmapImageRep {
        root.layoutSubtreeIfNeeded()
        let bitmap = try #require(root.bitmapImageRepForCachingDisplay(in: root.bounds))
        root.cacheDisplay(in: root.bounds, to: bitmap)
        // La hauteur de la barre d'outils : les colonnes commencent dessous.
        let toolbarHeight = root.window.map { $0.frame.height - $0.contentLayoutRect.height } ?? 0

        let context = try #require(NSGraphicsContext(bitmapImageRep: bitmap))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        defer { NSGraphicsContext.restoreGraphicsState() }

        func isColumn(_ glass: NSGlassEffectView) -> Bool {
            glass.cornerRadius == 0 && glass.bounds.height >= root.bounds.height - 1
        }
        // Les colonnes d'abord : les boutons de verre de la barre d'outils passent par-dessus.
        let glasses = descendants(of: root).compactMap { $0 as? NSGlassEffectView }
            .filter { !$0.isHiddenOrHasHiddenAncestor && $0.bounds.width > 1 && $0.bounds.height > 1 }
            .sorted { isColumn($0) && !isColumn($1) }

        for glass in glasses {
            var frame = rect(of: glass, in: root)
            let isColumn = isColumn(glass)
            // Une colonne s'arrête sous la barre d'outils : ses boutons de fenêtre restent lisibles.
            if isColumn { frame.size.height -= toolbarHeight }
            let shape = NSBezierPath(roundedRect: frame, xRadius: glass.cornerRadius, yRadius: glass.cornerRadius)
            NSColor(GlassStandIn.fill(scheme)).setFill()
            shape.fill()
            NSColor(GlassStandIn.edge(scheme)).setStroke()
            shape.lineWidth = 1
            shape.stroke()

            let column: AnyView? =
                if !isColumn { nil }
                else if frame.minX < 1 { columns.leading }
                else if frame.maxX > root.bounds.width - 1 { columns.trailing }
                else { nil }

            let content: NSBitmapImageRep
            if let column {
                // Rendue seule, à la taille de ce qui est sous la barre d'outils.
                content = try render(column, size: frame.size, scheme: scheme)
            } else if let view = glass.contentView, view.bounds.width > 1 {
                content = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                view.cacheDisplay(in: view.bounds, to: content)
            } else {
                continue
            }
            NSGraphicsContext.saveGraphicsState()
            shape.addClip()
            content.draw(
                in: frame, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: false, hints: nil
            )
            NSGraphicsContext.restoreGraphicsState()
        }
        return bitmap
    }

    /// Une colonne rendue seule, sur fond transparent, pour se poser sur l'aplat du verre.
    private static func render(_ view: some View, size: CGSize, scheme: ColorScheme) throws -> NSBitmapImageRep {
        let hosting = NSHostingView(
            rootView: view
                .environment(\.colorScheme, scheme)
                .environment(\.windowSimulatesGlass, true)
                .frame(width: size.width, height: size.height)
        )
        hosting.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(
            contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.contentView = hosting
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        hosting.layoutSubtreeIfNeeded()
        let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        window.close()
        return bitmap
    }

    /// Le cadre d'une vue dans le repère du bitmap : origine en bas à gauche, comme le contexte.
    private static func rect(of view: NSView, in root: NSView) -> CGRect {
        var rect = view.convert(view.bounds, to: root)
        if root.isFlipped { rect.origin.y = root.bounds.height - rect.maxY }
        return rect
    }

    private static func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }
}
