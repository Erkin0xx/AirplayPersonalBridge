//
//  MenuBarGlyph.swift
//  AirplayPersonalBridge
//

import AppKit
import SwiftUI

/// Le glyphe en image `template` : c'est le seul moyen de lui faire suivre la teinte que macOS donne
/// à la barre de menus, sur un fond clair comme sur un fond foncé.
///
/// Dessiné à la demande plutôt que tiré d'un catalogue d'actifs : il reste vectoriel à toute échelle,
/// et la cible `swift build`, qui ne voit pas `Assets.xcassets`, peut le rendre dans ses tests.
enum MenuBarGlyphImage {
    private static let images = Dictionary(
        uniqueKeysWithValues: BridgeGlyph.Variant.allCases.map { ($0, make($0)) }
    )

    static func image(for variant: BridgeGlyph.Variant) -> NSImage {
        images[variant] ?? make(variant)
    }

    /// Non isolée : AppKit peut rappeler le dessin hors du fil principal, et une fermeture héritant de
    /// l'isolation par défaut planterait alors à la vérification de l'acteur.
    private nonisolated static func make(_ variant: BridgeGlyph.Variant) -> NSImage {
        let image = NSImage(size: BridgeGlyph.canvas, flipped: true) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.addPath(BridgeGlyph.path(variant))
            context.fillPath(using: .evenOdd)
            return true
        }
        image.isTemplate = true
        return image
    }

    /// Les images de la vague, rendues une fois pour toutes : la faire défiler ne coûte qu'un
    /// changement d'image, aucun tracé.
    ///
    /// Une représentation bitmap par grille, chacune dessinée pour la sienne (`BridgeGlyph.waveBars`) :
    /// macOS prend d'office celle de l'écran où se trouve la barre.
    static let waveFrames: [NSImage] = (0..<BridgeGlyph.Wave.frameCount).map(makeWaveFrame)

    /// Une image vide de la taille du glyphe : ce que montre le bouton quand Core Animation joue la
    /// vague par-dessus. L'élément de la barre garde ainsi sa largeur.
    static let spacer: NSImage = {
        let image = NSImage(size: BridgeGlyph.canvas)
        image.isTemplate = true
        return image
    }()

    /// L'une des images de l'icône, comparée par identité : c'est ainsi qu'on retrouve le bouton de
    /// la barre de menus qui la montre.
    static func isGlyph(_ image: NSImage) -> Bool {
        image === spacer || waveFrames.contains { $0 === image }
            || images.values.contains { $0 === image }
    }

    private nonisolated static func makeWaveFrame(_ frame: Int) -> NSImage {
        let image = NSImage(size: BridgeGlyph.canvas)
        for scale in BridgeGlyph.PixelScale.allCases {
            guard let rep = rasterize(BridgeGlyph.wavePath(frame: frame, scale: scale), scale: scale)
            else { continue }
            image.addRepresentation(rep)
        }
        // Un rendu impossible laisse l'icône fixe de la diffusion plutôt qu'un trou dans la barre.
        guard !image.representations.isEmpty else { return make(.streaming) }
        image.isTemplate = true
        return image
    }

    /// Le glyphe en pixels, sur la grille de `scale`. Seul l'alpha compte : l'image est un modèle.
    private nonisolated static func rasterize(
        _ path: CGPath, scale: BridgeGlyph.PixelScale
    ) -> NSBitmapImageRep? {
        let factor = CGFloat(scale.rawValue)
        let pixels = CGSize(
            width: BridgeGlyph.canvas.width * factor, height: BridgeGlyph.canvas.height * factor
        )
        guard
            let space = CGColorSpace(name: CGColorSpace.sRGB),
            let context = CGContext(
                data: nil, width: Int(pixels.width), height: Int(pixels.height), bitsPerComponent: 8,
                bytesPerRow: 0, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else { return nil }
        // Le repère du glyphe a son origine en haut, celui de CoreGraphics en bas.
        context.translateBy(x: 0, y: pixels.height)
        context.scaleBy(x: factor, y: -factor)
        context.addPath(path)
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fillPath(using: .evenOdd)
        guard let image = context.makeImage() else { return nil }
        let rep = NSBitmapImageRep(cgImage: image)
        rep.size = BridgeGlyph.canvas
        return rep
    }
}

/// Ce que montre l'icône de la barre de menus : le glyphe fixe de l'état, ou la vague.
enum MenuBarGlyphMotion: Equatable {
    case still(BridgeGlyph.Variant)
    case wave

    /// La vague ne passe que si un son passe vraiment : diffusion établie, rien de signalé par la
    /// capture, son du master non coupé (`isAudible`, la règle du panneau). Silence, panne,
    /// connexion, ou réduction des animations : l'icône fixe de l'état.
    static func resolve(status: MenuBarStatus, isAudible: Bool, reducesMotion: Bool) -> Self {
        status == .streaming && isAudible && !reducesMotion ? .wave : .still(status.glyph)
    }
}


// MARK: - Faire défiler la vague

/// Un réveil périodique, derrière un protocole : les tests comptent les réveils sans attendre.
protocol GlyphFrameClock {
    /// `tick` dit s'il faut continuer : `false` arrête le réveil pour de bon.
    func repeating(every interval: TimeInterval, _ tick: @escaping @MainActor () -> Bool)
        -> any GlyphFrameTimer
}

protocol GlyphFrameTimer: AnyObject {
    func invalidate()
}

/// Le réveil de secours : un `Timer` de la boucle principale, avec assez de tolérance pour que macOS
/// le regroupe avec ses autres réveils.
struct RunLoopGlyphFrameClock: GlyphFrameClock {
    func repeating(every interval: TimeInterval, _ tick: @escaping @MainActor () -> Bool)
        -> any GlyphFrameTimer
    {
        let timer = Timer(timeInterval: interval, repeats: true) { timer in
            let keepsGoing = MainActor.assumeIsolated { tick() }
            if !keepsGoing { timer.invalidate() }
        }
        timer.tolerance = interval / 5
        // `.common` plutôt que le mode par défaut : la vague ne se fige pas quand un menu est ouvert.
        RunLoop.main.add(timer, forMode: .common)
        return RunLoopGlyphFrameTimer(timer: timer)
    }
}

final class RunLoopGlyphFrameTimer: GlyphFrameTimer {
    private let timer: Timer

    init(timer: Timer) {
        self.timer = timer
    }

    func invalidate() {
        timer.invalidate()
    }
}

/// Là où Core Animation peut jouer la vague à la place de l'app. Derrière un protocole : les tests
/// n'ont pas de barre de menus.
protocol MenuBarWaveStage {
    /// Monte la vague sur le bouton de la barre de menus, ou `nil` s'il ne se trouve pas.
    func mount() -> (any MenuBarWaveMount)?
}

protocol MenuBarWaveMount: AnyObject {
    func unmount()
}

/// Le bouton de la barre de menus que porte le `MenuBarExtra` de l'app.
///
/// SwiftUI ne le donne pas : on le reconnaît parmi les fenêtres de l'app à l'image qu'il montre,
/// l'une de celles de `MenuBarGlyphImage`, comparées par identité. Aucun autre bouton ne peut la
/// porter, et les répliques de la barre (une par bureau) sont des instantanés, pas des boutons.
struct StatusBarWaveStage: MenuBarWaveStage {
    func mount() -> (any MenuBarWaveMount)? {
        guard let button = Self.button(in: NSApp.windows) else { return nil }
        return MenuBarWaveLayer(button: button)
    }

    static func button(in windows: [NSWindow]) -> NSButton? {
        for window in windows where window.screen != nil {
            guard let content = window.contentView else { continue }
            if let button = firstButton(in: content) { return button }
        }
        return nil
    }

    private static func firstButton(in view: NSView) -> NSButton? {
        if let button = view as? NSStatusBarButton, let image = button.image,
            MenuBarGlyphImage.isGlyph(image)
        {
            return button
        }
        for subview in view.subviews {
            if let button = firstButton(in: subview) { return button }
        }
        return nil
    }
}

/// La vague jouée par Core Animation dans le bouton de la barre : **l'app ne se réveille plus du
/// tout**, le serveur de rendu fait défiler les images.
///
/// Changer l'image d'un `NSStatusItem` coûte cher, chaque fois : AppKit redessine l'instantané du
/// bouton pour chaque bureau, et chaque instantané renvoie SwiftUI mettre le libellé à jour. Mesuré
/// sur un vrai `MenuBarExtra` à huit images par seconde, 6,4 % d'un cœur, et 2,4 % encore en
/// changeant l'image sans SwiftUI ; avec ce calque, 0,1 %.
///
/// Les images sont celles que **la cellule du bouton** dessine elle-même, sous son apparence : même
/// teinte que l'icône fixe, sans rien imiter. Le bouton montre pendant ce temps une image vide de
/// même taille (`MenuBarGlyphImage.spacer`), et garde son fond de sélection. Les répliques des autres
/// bureaux reçoivent l'image de repos du calque.
final class MenuBarWaveLayer: MenuBarWaveMount {
    private weak var button: NSButton?
    private let overlay = CALayer()
    private var appearanceObservation: NSKeyValueObservation?
    private var backingObserver: (any NSObjectProtocol)?

    init?(button: NSButton) {
        self.button = button
        button.wantsLayer = true
        guard let host = button.layer else { return nil }
        // Ni fondu ni glissement : les images se succèdent, comme dans une barre de menus.
        overlay.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
        guard capture() else { return nil }
        host.addSublayer(overlay)

        appearanceObservation = button.observe(\.effectiveAppearance) { [weak self] _, _ in
            MainActor.assumeIsolated { _ = self?.capture() }
        }
        backingObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeBackingPropertiesNotification, object: button.window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { _ = self?.capture() }
        }
    }

    /// Redessine les images sous l'apparence et à l'échelle du moment, et relance la boucle.
    private func capture() -> Bool {
        guard let button, let cell = button.cell as? NSButtonCell else { return false }
        let rect = cell.imageRect(forBounds: button.bounds)
        let scale = button.window?.backingScaleFactor ?? 2
        let frames = MenuBarGlyphImage.waveFrames.compactMap { frame -> CGImage? in
            Self.render(frame, in: rect.size, scale: scale, appearance: button.effectiveAppearance) {
                cell.drawImage(frame, withFrame: CGRect(origin: .zero, size: rect.size), in: button)
            }
        }
        guard frames.count == MenuBarGlyphImage.waveFrames.count else { return false }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        overlay.frame = rect
        overlay.contentsScale = scale
        overlay.contents = frames.first
        let animation = CAKeyframeAnimation(keyPath: "contents")
        animation.values = frames
        animation.calculationMode = .discrete
        animation.duration = BridgeGlyph.Wave.period
        animation.repeatCount = .infinity
        overlay.add(animation, forKey: Self.animationKey)
        CATransaction.commit()
        return true
    }

    static let animationKey = "vague"

    /// Ce que dessine `draw`, dans un bitmap de cette taille et de cette échelle.
    private static func render(
        _ image: NSImage, in size: CGSize, scale: CGFloat, appearance: NSAppearance,
        draw: () -> Void
    ) -> CGImage? {
        guard
            size.width > 0, size.height > 0,
            let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: Int((size.width * scale).rounded()),
                pixelsHigh: Int((size.height * scale).rounded()), bitsPerSample: 8,
                samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                bytesPerRow: 0, bitsPerPixel: 0
            )
        else { return nil }
        // Avant le contexte, qui en tire son échelle : posée après, le dessin sort en 1x dans un coin.
        rep.size = size
        guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        appearance.performAsCurrentDrawingAppearance(draw)
        NSGraphicsContext.restoreGraphicsState()
        return rep.cgImage
    }

    /// Le calque que joue Core Animation : ce que vérifient les tests.
    var layer: CALayer { overlay }

    func unmount() {
        appearanceObservation = nil
        if let backingObserver { NotificationCenter.default.removeObserver(backingObserver) }
        backingObserver = nil
        overlay.removeAllAnimations()
        overlay.removeFromSuperlayer()
    }

    /// Une vague oubliée sur le bouton tournerait pour toujours par-dessus l'icône fixe.
    isolated deinit {
        unmount()
    }
}

/// Fait défiler les images de la vague, et rien d'autre.
///
/// **Aucun réveil tant que l'icône est fixe.** Pendant la vague, Core Animation la joue dans le bouton
/// de la barre (`MenuBarWaveStage`), sans réveiller l'app ; à défaut de bouton, un minuteur à huit
/// coups par seconde change l'image du libellé. Seul ce qui change l'image est observé.
@Observable
final class MenuBarGlyphAnimator {
    enum Drive: Equatable {
        case off
        /// La vague est demandée, la scène pas encore cherchée : l'image de repos de la vague.
        case pending
        /// Core Animation la joue : le libellé ne montre qu'une image vide.
        case layer
        /// Le minuteur de secours fait défiler `frame`.
        case timer
    }

    /// L'image de la vague à montrer quand le minuteur la fait défiler.
    private(set) var frame = 0
    private(set) var drive = Drive.off
    /// Réveils servis depuis la création : ce que comptent les tests.
    @ObservationIgnored private(set) var ticks = 0
    @ObservationIgnored private let clock: any GlyphFrameClock
    @ObservationIgnored private let stage: (any MenuBarWaveStage)?
    @ObservationIgnored private var timer: (any GlyphFrameTimer)?
    @ObservationIgnored private var mount: (any MenuBarWaveMount)?

    init(
        clock: any GlyphFrameClock = RunLoopGlyphFrameClock(),
        stage: (any MenuBarWaveStage)? = StatusBarWaveStage()
    ) {
        self.clock = clock
        self.stage = stage
    }

    var isAnimating: Bool { timer != nil || mount != nil }

    /// Pure : ne lit l'état de la vague que pendant la vague, et n'observe donc rien tant que
    /// l'icône est fixe.
    func image(for motion: MenuBarGlyphMotion) -> NSImage {
        switch motion {
        case let .still(variant):
            MenuBarGlyphImage.image(for: variant)
        case .wave where drive == .layer:
            MenuBarGlyphImage.spacer
        case .wave:
            MenuBarGlyphImage.waveFrames[frame % MenuBarGlyphImage.waveFrames.count]
        }
    }

    func follow(_ motion: MenuBarGlyphMotion) {
        if motion == .wave { start() } else { stop() }
    }

    private func start() {
        guard drive == .off else { return }
        drive = .pending
        // Au tour de boucle suivant : l'appel vient de la mise à jour des vues, où l'on ne touche pas
        // au bouton que SwiftUI est en train de remplir. Par la boucle plutôt que par une tâche, qui
        // n'aurait pas sa place tant qu'un travail du MainActor fait tourner une boucle imbriquée.
        RunLoop.main.perform(inModes: [.common]) { [weak self] in
            MainActor.assumeIsolated { self?.settle() }
        }
    }

    private func settle() {
        guard drive == .pending else { return }
        if let mount = stage?.mount() {
            self.mount = mount
            drive = .layer
            return
        }
        drive = .timer
        // Le réveil ne retient pas l'animateur : disparu, il s'arrête au coup suivant.
        timer = clock.repeating(every: 1 / BridgeGlyph.Wave.framesPerSecond) { [weak self] in
            guard let self else { return false }
            ticks += 1
            frame = (frame + 1) % BridgeGlyph.Wave.frameCount
            return true
        }
    }

    private func stop() {
        guard drive != .off else { return }
        timer?.invalidate()
        timer = nil
        mount?.unmount()
        mount = nil
        drive = .off
        // L'icône fixe ne lit plus `frame` : la remettre à zéro ne redessine rien, et la prochaine
        // vague repart de l'image la plus proche du repos.
        frame = 0
    }
}

/// L'icône de la barre de menus : le glyphe de l'état, ou la vague quand un son passe vraiment.
///
/// Des images modèle plutôt qu'une animation SwiftUI, que le libellé d'un `MenuBarExtra` rend mal :
/// une image n'y est qu'une image, et la barre la teinte comme les autres.
struct MenuBarGlyphLabel: View {
    let status: MenuBarStatus
    /// La règle du panneau : la capture ne signale rien, et le son n'est pas coupé.
    let isAudible: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Lu aussi à la source, par précaution : le libellé ne vit dans aucune fenêtre de l'app.
    @State private var systemReducesMotion =
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    @State private var animator = MenuBarGlyphAnimator()

    var body: some View {
        let motion = MenuBarGlyphMotion.resolve(
            status: status, isAudible: isAudible,
            reducesMotion: reduceMotion || systemReducesMotion
        )
        Image(nsImage: animator.image(for: motion))
            .onChange(of: motion, initial: true) { _, motion in animator.follow(motion) }
            .onReceive(
                NSWorkspace.shared.notificationCenter.publisher(
                    for: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification
                )
            ) { _ in
                systemReducesMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            }
    }
}

/// Un chemin du glyphe, ramené au cadre qu'on lui donne.
struct BridgeGlyphShape: Shape {
    private let glyph: Path

    init(path: CGPath) {
        glyph = Path(path)
    }

    func path(in rect: CGRect) -> Path {
        let canvas = BridgeGlyph.canvas
        let scale = min(rect.width / canvas.width, rect.height / canvas.height)
        return glyph.applying(
            CGAffineTransform(
                translationX: rect.midX - canvas.width * scale / 2,
                y: rect.midY - canvas.height * scale / 2
            )
            .scaledBy(x: scale, y: scale)
        )
    }
}

/// La pastille d'état de l'en-tête : le glyphe de la barre de menus, dans la même rondeur que celle
/// des enceintes juste en dessous.
///
/// La diffusion s'y sent sans s'imposer : la pastille prend l'accent et les suspentes respirent. Ce
/// n'est **pas** un vumètre, le pipeline ne mesure aucun niveau. C'est pourquoi l'animation s'arrête
/// dès que la capture signale un silence : elle ne doit pas prétendre qu'un son passe.
struct PanelStatusChip: View {
    let status: MenuBarStatus
    /// Rien ne signale de silence : on peut laisser le glyphe respirer.
    let isAudible: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Le contenu d'un `MenuBarExtra` peut survivre à la fermeture du panneau : sans cette garde,
    /// l'animation continuerait de tourner pour personne.
    @Environment(\.appearsActive) private var appearsActive

    var body: some View {
        ZStack {
            Circle().fill(background)
            // Le point d'exclamation, seule marque du lot, se prend à plus grande échelle pour peser
            // autant que les cinq barres.
            marks
                .frame(width: status == .trouble ? 24 : 18, height: status == .trouble ? 22 : 16)
                .foregroundStyle(foreground)
        }
        .frame(width: PanelMetrics.pastille, height: PanelMetrics.pastille)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var marks: some View {
        switch status {
        case .streaming where isAudible && !reduceMotion:
            TimelineView(.animation(minimumInterval: 1 / 20, paused: !appearsActive)) { timeline in
                glyph(.streaming, levels: Self.levels(at: timeline.date.timeIntervalSinceReferenceDate))
            }
        case .connecting where !reduceMotion:
            TimelineView(.animation(minimumInterval: 1 / 15, paused: !appearsActive)) { timeline in
                glyph(.connecting).opacity(
                    0.55 + 0.45 * abs(sin(timeline.date.timeIntervalSinceReferenceDate * 2.4))
                )
            }
        default:
            glyph(status.glyph)
        }
    }

    private func glyph(
        _ variant: BridgeGlyph.Variant, levels: BridgeGlyph.Levels = .rest
    ) -> some View {
        BridgeGlyphShape(path: BridgeGlyph.marks(variant, levels: levels))
            .fill(style: FillStyle(eoFill: true))
    }

    /// Deux sinusoïdes de périodes sans commune mesure : le mouvement ne se répète pas à l'œil, et
    /// reste assez lent pour passer pour une respiration plutôt que pour un niveau.
    private static func levels(at time: TimeInterval) -> BridgeGlyph.Levels {
        BridgeGlyph.Levels(
            sides: 0.72 + 0.28 * sin(time * 2.1),
            center: 0.5 + 0.5 * sin(time * 3.3 + 1)
        )
    }

    private var background: Color {
        switch status {
        case .idle, .connecting: PanelPalette.quietFill
        case .streaming: .accentColor
        case .trouble: .red
        }
    }

    private var foreground: Color {
        switch status {
        case .idle: .secondary
        case .connecting: .primary
        case .streaming, .trouble: .white
        }
    }
}
