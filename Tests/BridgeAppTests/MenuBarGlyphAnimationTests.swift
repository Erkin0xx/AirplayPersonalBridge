import AppKit
import Foundation
import Observation
import SwiftUI
import Testing

@testable import BridgeApp

// MARK: - Les images

/// La vague telle que la barre de menus la reçoit : des images modèle, une représentation par grille.
@Suite("Icône de la barre de menus — les images de la vague")
struct MenuBarGlyphWaveTests {
    private typealias Wave = BridgeGlyph.Wave

    @Test("Une image par phase, à une cadence basse, sur un cycle lent")
    func framesExistForEveryPhase() throws {
        #expect((8...12).contains(Wave.frameCount))
        #expect((8...12).contains(Wave.framesPerSecond))
        #expect((1.2...2.0).contains(Wave.period))
        #expect(MenuBarGlyphImage.waveFrames.count == Wave.frameCount)

        for (index, image) in MenuBarGlyphImage.waveFrames.enumerated() {
            #expect(image.isTemplate, "image \(index)")
            #expect(image.size == BridgeGlyph.canvas, "image \(index)")
            let widths = image.representations.compactMap { ($0 as? NSBitmapImageRep)?.pixelsWide }
            #expect(widths.sorted() == [20, 40], "image \(index) : une représentation 1x, une 2x")
            for scale in BridgeGlyph.PixelScale.allCases {
                let rep = try Self.representation(of: image, scale: scale)
                #expect(rep.pixelsHigh == 18 * scale.rawValue)
                #expect(rep.size == BridgeGlyph.canvas)
            }
        }
    }

    /// Un bord de barre à cheval sur deux pixels se lit comme un trait gris : chaque bord droit doit
    /// tomber sur un pixel entier, à chaque grille. Les bouts des barres sont arrondis, ce qui ne se
    /// cale pas : seule leur boîte compte.
    @Test("Chaque barre tombe sur la grille de pixels, en 1x comme en 2x")
    func barsSitOnThePixelGrid() {
        for frame in 0..<Wave.frameCount {
            for scale in BridgeGlyph.PixelScale.allCases {
                let bars = BridgeGlyph.waveBars(frame: frame, scale: scale)
                #expect(bars.count == 5)
                for bar in bars {
                    for edge in [bar.minX, bar.maxX, bar.minY, bar.maxY] {
                        let pixels = edge * CGFloat(scale.rawValue)
                        #expect(
                            pixels == pixels.rounded(),
                            "image \(frame), \(scale.rawValue)x : bord à \(edge) pt"
                        )
                    }
                    #expect(bar.width == 2)
                }
            }
        }
    }

    /// Ce que la grille promet, vérifié sur les pixels livrés : à la hauteur de la ligne médiane, la
    /// pastille est pleine et chaque barre découpée nette, sans aucun pixel intermédiaire. Seuls les
    /// points (barres de 2 pt) sont ronds jusque-là, et écartés.
    @Test("Les pixels livrés sont nets : pleins ou vides de part et d'autre de chaque barre")
    func pixelsAreCrisp() throws {
        for (frame, image) in MenuBarGlyphImage.waveFrames.enumerated() {
            for scale in BridgeGlyph.PixelScale.allCases {
                let factor = scale.rawValue
                let bitmap = try GlyphBitmap(try Self.representation(of: image, scale: scale))
                let bars = BridgeGlyph.waveBars(frame: frame, scale: scale)
                for row in [9 * factor - 1, 9 * factor] {
                    for column in 0..<bitmap.width {
                        let left = CGFloat(column) / CGFloat(factor)
                        let right = CGFloat(column + 1) / CGFloat(factor)
                        let bar = bars.first { $0.minX < right && left < $0.maxX }
                        if let bar, bar.height <= 2 { continue }
                        let expected: UInt8 = bar == nil ? 255 : 0
                        let alpha = bitmap.alpha(x: column, y: row)
                        #expect(
                            abs(Int(alpha) - Int(expected)) <= 1,
                            "image \(frame), \(factor)x, pixel (\(column), \(row)) : alpha \(alpha)"
                        )
                    }
                }
            }
        }
    }

    @Test("Les pylônes ne bougent pas et dépassent toujours les suspentes : la silhouette du pont tient")
    func bridgeSilhouetteHolds() {
        for scale in BridgeGlyph.PixelScale.allCases {
            let first = BridgeGlyph.waveBars(frame: 0, scale: scale)
            for frame in 0..<Wave.frameCount {
                let bars = BridgeGlyph.waveBars(frame: frame, scale: scale)
                #expect(bars[0] == first[0] && bars[4] == first[4], "pylônes immobiles")
                #expect(bars[0].height == 10 && bars[4].height == 10)
                for hanger in bars[1...3] {
                    #expect((Wave.lowest...Wave.highest).contains(hanger.height))
                    #expect(hanger.height < bars[0].height)
                    #expect(hanger.minX >= bars[0].maxX && hanger.maxX <= bars[4].minX)
                }
            }
        }
        // En 2x, l'espacement de l'icône fixe : passer de l'une à l'autre ne décale rien.
        let still = BridgeGlyph.waveBars(frame: 0, scale: .double).map(\.midX)
        #expect(still == [3, 6.5, 10, 13.5, 17])
    }

    /// Un quart de cycle de retard entre deux suspentes voisines : l'onde court de gauche à droite.
    @Test("L'onde court de gauche à droite, chaque suspente un quart de cycle derrière sa voisine")
    func waveTravelsRightwards() {
        let lag = Wave.frameCount / 4
        for frame in 0..<Wave.frameCount {
            let now = Wave.heights(frame: frame)
            let earlier = Wave.heights(frame: (frame - lag + Wave.frameCount) % Wave.frameCount)
            #expect(abs(now[1] - earlier[0]) < 1e-9)
            #expect(abs(now[2] - earlier[1]) < 1e-9)
        }
    }

    /// Chaque réveil doit montrer quelque chose de neuf, sans quoi il coûte pour rien.
    @Test("Toutes les images diffèrent, et chacune de la suivante, à chaque grille")
    func everyFrameIsNew() throws {
        for scale in BridgeGlyph.PixelScale.allCases {
            let bitmaps = try MenuBarGlyphImage.waveFrames.map {
                try GlyphBitmap(try Self.representation(of: $0, scale: scale)).alphas
            }
            #expect(Set(bitmaps).count == bitmaps.count, "\(scale.rawValue)x")
            let fixed = try GlyphBitmap(
                drawing: MenuBarGlyphImage.image(for: .streaming), scale: scale
            ).alphas
            #expect(!bitmaps.contains(fixed), "la vague se distingue de l'icône fixe")
        }
    }

    /// Dessinée dans un contexte 1x ou 2x, l'image prend la représentation de cette grille, et non
    /// une autre mise à l'échelle : c'est ce qui garde l'image nette dans la barre.
    @Test("Dessinée à une échelle, l'image prend la représentation de cette grille")
    func drawingPicksTheMatchingRepresentation() throws {
        for image in MenuBarGlyphImage.waveFrames {
            for scale in BridgeGlyph.PixelScale.allCases {
                let drawn = try GlyphBitmap(drawing: image, scale: scale)
                let own = try GlyphBitmap(try Self.representation(of: image, scale: scale))
                #expect(drawn.alphas == own.alphas, "\(scale.rawValue)x")
            }
        }
    }

    static func representation(
        of image: NSImage, scale: BridgeGlyph.PixelScale
    ) throws -> NSBitmapImageRep {
        try #require(
            image.representations
                .compactMap { $0 as? NSBitmapImageRep }
                .first { $0.pixelsWide == 20 * scale.rawValue }
        )
    }
}

/// L'alpha d'une image, ligne par ligne depuis le haut.
private struct GlyphBitmap {
    let width: Int
    let height: Int
    let alphas: [UInt8]

    init(_ rep: NSBitmapImageRep) throws {
        let image = try #require(rep.cgImage)
        try self.init(image)
    }

    /// Ce que donne l'image dessinée dans un contexte à cette échelle, comme la barre de menus.
    init(drawing image: NSImage, scale: BridgeGlyph.PixelScale) throws {
        let size = BridgeGlyph.canvas
        let rep = try #require(
            NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: Int(size.width) * scale.rawValue,
                pixelsHigh: Int(size.height) * scale.rawValue, bitsPerSample: 8, samplesPerPixel: 4,
                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0,
                bitsPerPixel: 0
            )
        )
        rep.size = size
        let context = try #require(NSGraphicsContext(bitmapImageRep: rep))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        image.draw(in: CGRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        try self.init(rep)
    }

    init(_ image: CGImage) throws {
        let width = image.width
        let height = image.height
        self.width = width
        self.height = height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard
                let context = CGContext(
                    data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                    bytesPerRow: width * 4, space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                )
            else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        try #require(drawn)
        alphas = stride(from: 3, to: bytes.count, by: 4).map { bytes[$0] }
    }

    func alpha(x: Int, y: Int) -> UInt8 {
        alphas[y * width + x]
    }
}

// MARK: - Animée ou fixe

@Suite("Icône de la barre de menus — animée ou fixe")
struct MenuBarGlyphMotionTests {
    @Test("La vague seulement en diffusion, avec un son, sans réduction des animations")
    func resolveTable() {
        for status in MenuBarStatus.allCases {
            for isAudible in [true, false] {
                for reducesMotion in [true, false] {
                    let motion = MenuBarGlyphMotion.resolve(
                        status: status, isAudible: isAudible, reducesMotion: reducesMotion
                    )
                    let waves = status == .streaming && isAudible && !reducesMotion
                    #expect(
                        motion == (waves ? .wave : .still(status.glyph)),
                        "\(status), son \(isAudible), réduction \(reducesMotion)"
                    )
                }
            }
        }
    }

    private func motion(_ state: BridgeState, reducesMotion: Bool = false) -> MenuBarGlyphMotion {
        MenuBarGlyphMotion.resolve(
            status: state.status.menuBar, isAudible: MenuBarLabel.isAudible(state),
            reducesMotion: reducesMotion
        )
    }

    @Test("Suit l'état du pont : diffusion audible, silence, son coupé, panne, connexion, repos")
    func followsTheBridge() {
        #expect(motion(.preview(.streaming)) == .wave)

        // La capture signale « rien ne joue » : la diffusion tient, l'icône s'immobilise.
        let silent = BridgeState.preview(.nothingPlaying)
        #expect(silent.captureAlert != nil)
        #expect(motion(silent) == .still(silent.status.menuBar.glyph))
        #expect(motion(silent) != .wave)

        let muted = BridgeState.preview(.streaming)
        muted.isMuted = true
        #expect(motion(muted) == .still(.streaming))

        #expect(motion(.preview(.streaming), reducesMotion: true) == .still(.streaming))
        #expect(motion(.preview(.trouble)) == .still(.trouble))
        #expect(motion(.preview(.starting)) == .still(.connecting))
        #expect(motion(.preview(.idle)) == .still(.idle))
        #expect(motion(.preview(.startFailed)) == .still(.trouble))
    }
}

// MARK: - Les rafraîchissements

/// Un réveil qu'on actionne à la main : on compte ce qui démarre, et on fait passer le temps.
private final class ManualGlyphClock: GlyphFrameClock {
    final class Timer: GlyphFrameTimer {
        let interval: TimeInterval
        private let tick: @MainActor () -> Bool
        private(set) var isValid = true

        init(interval: TimeInterval, tick: @escaping @MainActor () -> Bool) {
            self.interval = interval
            self.tick = tick
        }

        func invalidate() { isValid = false }

        func fire() {
            guard isValid else { return }
            if !tick() { isValid = false }
        }
    }

    private(set) var timers: [Timer] = []
    var active: [Timer] { timers.filter(\.isValid) }

    func repeating(every interval: TimeInterval, _ tick: @escaping @MainActor () -> Bool)
        -> any GlyphFrameTimer
    {
        let timer = Timer(interval: interval, tick: tick)
        timers.append(timer)
        return timer
    }

    func fire(_ count: Int) {
        for _ in 0..<count {
            for timer in timers { timer.fire() }
        }
    }
}

/// Vrai si `action` change ce que lit `read` aux yeux d'`Observation`, c'est-à-dire si SwiftUI
/// redessinerait une vue qui le lit.
private func invalidates(_ read: () -> Void, during action: () -> Void) -> Bool {
    nonisolated final class Flag: @unchecked Sendable { var raised = false }
    let flag = Flag()
    withObservationTracking(read) { flag.raised = true }
    action()
    return flag.raised
}

/// Une scène qu'on règle : elle trouve un bouton ou non, et compte ce qu'on lui demande.
private final class FakeWaveStage: MenuBarWaveStage {
    final class Mount: MenuBarWaveMount {
        private(set) var isMounted = true
        func unmount() { isMounted = false }
    }

    let findsButton: Bool
    private(set) var mounts: [Mount] = []

    init(findsButton: Bool) {
        self.findsButton = findsButton
    }

    func mount() -> (any MenuBarWaveMount)? {
        guard findsButton else { return nil }
        let mount = Mount()
        mounts.append(mount)
        return mount
    }
}

@Suite("Icône de la barre de menus — rafraîchissements")
struct MenuBarGlyphAnimatorTests {
    @Test("Fixe : ni minuteur ni calque, aucune image nouvelle, l'icône d'aujourd'hui")
    func stillCostsNothing() async {
        let clock = ManualGlyphClock()
        let stage = FakeWaveStage(findsButton: true)
        let animator = MenuBarGlyphAnimator(clock: clock, stage: stage)
        for variant in BridgeGlyph.Variant.allCases {
            let motion = MenuBarGlyphMotion.still(variant)
            animator.follow(motion)
            await Task.yield()
            #expect(animator.image(for: motion) === MenuBarGlyphImage.image(for: variant))
            let changed = invalidates({ _ = animator.image(for: motion) }) { clock.fire(20) }
            #expect(!changed, "\(variant)")
        }
        #expect(clock.timers.isEmpty)
        #expect(stage.mounts.isEmpty)
        #expect(!animator.isAnimating)
        #expect(animator.drive == .off)
        #expect(animator.ticks == 0)
    }

    /// Le chemin de l'app : Core Animation joue la vague, l'app ne se réveille jamais.
    @Test("La vague dans la barre : un calque, aucun minuteur, et le libellé ne change plus")
    func layerPathWakesNothing() async {
        let clock = ManualGlyphClock()
        let stage = FakeWaveStage(findsButton: true)
        let animator = MenuBarGlyphAnimator(clock: clock, stage: stage)
        animator.follow(.wave)
        animator.follow(.wave)
        #expect(await eventually { animator.drive == .layer })
        #expect(stage.mounts.count == 1)
        #expect(clock.timers.isEmpty)
        #expect(animator.image(for: .wave) === MenuBarGlyphImage.spacer)

        let changed = invalidates({ _ = animator.image(for: .wave) }) { clock.fire(20) }
        #expect(!changed)
        #expect(animator.ticks == 0)

        animator.follow(.still(.streaming))
        #expect(stage.mounts.first?.isMounted == false)
        #expect(animator.drive == .off)
        #expect(!animator.isAnimating)
        #expect(animator.image(for: .still(.streaming)) === MenuBarGlyphImage.image(for: .streaming))
    }

    @Test("Une vague annulée avant d'avoir trouvé sa scène ne monte rien")
    func cancelledBeforeSettling() async {
        let clock = ManualGlyphClock()
        let stage = FakeWaveStage(findsButton: true)
        let animator = MenuBarGlyphAnimator(clock: clock, stage: stage)
        animator.follow(.wave)
        animator.follow(.still(.streaming))
        #expect(await staysFalse(during: .milliseconds(50)) { !stage.mounts.isEmpty })
        #expect(clock.timers.isEmpty)
        #expect(animator.drive == .off)
    }

    /// Sans bouton de barre (les tests, ou un macOS qui l'aurait caché autrement) : le minuteur.
    @Test("Sans bouton : un seul minuteur à huit coups par seconde, une image neuve à chaque coup")
    func timerFallbackScrollsTheFrames() async {
        let clock = ManualGlyphClock()
        let animator = MenuBarGlyphAnimator(clock: clock, stage: FakeWaveStage(findsButton: false))
        animator.follow(.wave)
        animator.follow(.wave)
        #expect(animator.image(for: .wave) === MenuBarGlyphImage.waveFrames[0])
        #expect(await eventually { animator.drive == .timer })
        #expect(clock.timers.count == 1)
        #expect(clock.timers.first?.interval == 1 / BridgeGlyph.Wave.framesPerSecond)

        var shown: [Int] = []
        for _ in 0..<BridgeGlyph.Wave.frameCount {
            let changed = invalidates({ _ = animator.image(for: .wave) }) { clock.fire(1) }
            #expect(changed)
            shown.append(animator.frame)
            #expect(animator.image(for: .wave) === MenuBarGlyphImage.waveFrames[animator.frame])
        }
        #expect(shown == Array(1..<BridgeGlyph.Wave.frameCount) + [0])
        #expect(animator.ticks == BridgeGlyph.Wave.frameCount)
    }

    @Test("Revenue fixe, l'icône arrête son minuteur et ne se redessine plus")
    func stoppingCancelsTheTimer() async {
        let clock = ManualGlyphClock()
        let animator = MenuBarGlyphAnimator(clock: clock, stage: nil)
        animator.follow(.wave)
        #expect(await eventually { animator.drive == .timer })
        clock.fire(5)
        let still = MenuBarGlyphMotion.still(.streaming)
        animator.follow(still)
        #expect(clock.active.isEmpty)
        #expect(!animator.isAnimating)
        #expect(animator.frame == 0)

        let changed = invalidates({ _ = animator.image(for: still) }) { clock.fire(10) }
        #expect(!changed)
        #expect(animator.ticks == 5)

        // Et repart de la première image, la plus proche du repos.
        animator.follow(.wave)
        #expect(await eventually { clock.active.count == 1 })
        #expect(animator.image(for: .wave) === MenuBarGlyphImage.waveFrames[0])
    }

    @Test("Un animateur disparu arrête son minuteur au coup suivant")
    func releasedAnimatorStopsItsTimer() async {
        let clock = ManualGlyphClock()
        var animator: MenuBarGlyphAnimator? = MenuBarGlyphAnimator(clock: clock, stage: nil)
        animator?.follow(.wave)
        #expect(await eventually { clock.active.count == 1 })
        animator = nil
        clock.fire(1)
        #expect(clock.active.isEmpty)
    }

    /// Le vrai minuteur de secours, sur la boucle principale : compté sur une seconde de vague, et
    /// aucun coup quand l'icône est fixe.
    ///
    /// **Aucune boucle imbriquée** : on attend en rendant la main au MainActor. Une boucle relancée
    /// depuis un test du MainActor ne vide plus la file principale, et bloque pendant toute sa durée
    /// les tâches des autres suites (`CLAUDE.md`, le défaut du SIGTERM). La borne basse reste large :
    /// la file principale est partagée avec les autres suites, qui peuvent retarder un coup.
    @Test("Avec le vrai minuteur : zéro réveil à l'arrêt, huit par seconde en vague")
    func realTimerWakesOnlyWhileWaving() async throws {
        let animator = MenuBarGlyphAnimator(clock: RunLoopGlyphFrameClock(), stage: nil)
        animator.follow(.still(.streaming))
        try await Task.sleep(for: .milliseconds(500))
        #expect(animator.ticks == 0)

        animator.follow(.wave)
        #expect(await eventually { animator.drive == .timer })
        let start = Date()
        try await Task.sleep(for: .seconds(1))
        let elapsed = Date().timeIntervalSince(start)
        let waved = animator.ticks
        let expected = elapsed * BridgeGlyph.Wave.framesPerSecond
        #expect(waved >= 3 && Double(waved) <= expected + 1, "\(waved) réveils en \(elapsed) s")

        animator.follow(.still(.streaming))
        try await Task.sleep(for: .milliseconds(500))
        #expect(animator.ticks == waved)
    }

    /// Le libellé hébergé hors de toute barre de menus : pas de bouton, donc le minuteur de
    /// secours. Rendu à intervalles réguliers, il ne change jamais quand l'icône est fixe, et change
    /// pendant la vague. Les attentes rendent la main au MainActor, sans boucle imbriquée.
    @Test("Hébergé, le libellé ne change pas quand il est fixe, et défile pendant la vague")
    func hostedLabelRefreshesOnlyWhileWaving() async throws {
        let still = try await snapshots(of: MenuBarGlyphLabel(status: .streaming, isAudible: false))
        #expect(Set(still).count == 1)

        let waving = try await snapshots(of: MenuBarGlyphLabel(status: .streaming, isAudible: true))
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            #expect(Set(waving).count == 1, "réduction des animations demandée sur ce Mac")
        } else {
            #expect(Set(waving).count >= 3, "\(Set(waving).count) images distinctes")
        }
    }

    private func snapshots(of label: MenuBarGlyphLabel) async throws -> [Data] {
        let hosting = NSHostingView(rootView: label)
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 24, height: 22), styleMask: [.borderless],
            backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        hosting.frame = CGRect(x: 0, y: 0, width: 24, height: 22)
        defer { window.contentView = nil }
        var images: [Data] = []
        for _ in 0..<12 {
            try await Task.sleep(for: .milliseconds(110))
            hosting.layoutSubtreeIfNeeded()
            let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            images.append(Data(try GlyphBitmap(bitmap).alphas))
        }
        return images
    }
}

// MARK: - Le calque de la barre de menus

/// Le calque monté sur un vrai bouton AppKit, dans une fenêtre hors écran : pas de barre de menus en
/// test, mais la même cellule, la même capture et la même animation.
@Suite("Icône de la barre de menus — la vague jouée par Core Animation")
struct MenuBarWaveLayerTests {
    private func button(showing image: NSImage, statusBar: Bool = false) -> (NSWindow, NSButton) {
        let frame = CGRect(x: 0, y: 0, width: 36, height: 22)
        let button = statusBar ? NSStatusBarButton(frame: frame) : NSButton(frame: frame)
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.image = image
        let window = NSWindow(
            contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(button)
        return (window, button)
    }

    @Test("Douze images de la cellule du bouton, en boucle discrète d'une seconde et demie")
    func mountsTheLoop() throws {
        let (window, button) = button(showing: MenuBarGlyphImage.image(for: .streaming))
        defer { window.contentView = nil }
        let wave = try #require(MenuBarWaveLayer(button: button))
        defer { wave.unmount() }

        #expect(wave.layer.superlayer === button.layer)
        let animation = try #require(
            wave.layer.animation(forKey: MenuBarWaveLayer.animationKey) as? CAKeyframeAnimation
        )
        #expect(animation.calculationMode == .discrete)
        #expect(animation.duration == BridgeGlyph.Wave.period)
        #expect(animation.repeatCount == .infinity)

        let images = try #require(animation.values as? [CGImage])
        let frames = try images.map { image -> [UInt8] in
            let scale = window.backingScaleFactor
            #expect(CGFloat(image.width) == wave.layer.bounds.width * scale)
            #expect(CGFloat(image.height) == wave.layer.bounds.height * scale)
            return try GlyphBitmap(image).alphas
        }
        #expect(frames.count == BridgeGlyph.Wave.frameCount)
        #expect(Set(frames).count == frames.count, "chaque image diffère")
        #expect(frames.allSatisfy { $0.contains { $0 > 0 } }, "aucune image vide")
        // Le glyphe tient dans le cadre que la cellule réserve à l'image.
        #expect(wave.layer.bounds.size == BridgeGlyph.canvas)
    }

    @Test("Démonté, le calque quitte le bouton et ne joue plus rien")
    func unmountRemovesTheLayer() throws {
        let (window, button) = button(showing: MenuBarGlyphImage.image(for: .streaming))
        defer { window.contentView = nil }
        let wave = try #require(MenuBarWaveLayer(button: button))
        wave.unmount()
        #expect(wave.layer.superlayer == nil)
        #expect(wave.layer.animationKeys()?.isEmpty ?? true)
        #expect(!(button.layer?.sublayers ?? []).contains { $0 === wave.layer })
    }

    @Test("Libéré sans être démonté, le calque quitte quand même le bouton")
    func releaseRemovesTheLayer() throws {
        let (window, button) = button(showing: MenuBarGlyphImage.image(for: .streaming))
        defer { window.contentView = nil }
        weak var layer: CALayer?
        do {
            let wave = try #require(MenuBarWaveLayer(button: button))
            layer = wave.layer
            #expect(layer?.superlayer != nil)
        }
        #expect(!(button.layer?.sublayers ?? []).contains { $0 === layer })
    }

    /// Le bouton se reconnaît à l'image qu'il porte : seulement un bouton de barre de menus, et
    /// seulement s'il montre l'une des images de l'icône.
    @Test("La scène trouve le bouton de barre qui montre l'icône, et lui seul")
    func stageFindsOnlyTheGlyphButton() {
        let (barWindow, barButton) = button(
            showing: MenuBarGlyphImage.image(for: .streaming), statusBar: true
        )
        let (plainWindow, _) = button(showing: MenuBarGlyphImage.image(for: .streaming))
        let (otherWindow, _) = button(
            showing: NSImage(size: BridgeGlyph.canvas), statusBar: true
        )
        defer {
            for window in [barWindow, plainWindow, otherWindow] { window.contentView = nil }
        }
        #expect(StatusBarWaveStage.button(in: [plainWindow, otherWindow, barWindow]) === barButton)
        #expect(StatusBarWaveStage.button(in: [plainWindow, otherWindow]) == nil)

        for image in MenuBarGlyphImage.waveFrames + [MenuBarGlyphImage.spacer] {
            #expect(MenuBarGlyphImage.isGlyph(image))
        }
        for variant in BridgeGlyph.Variant.allCases {
            #expect(MenuBarGlyphImage.isGlyph(MenuBarGlyphImage.image(for: variant)))
        }
        #expect(!MenuBarGlyphImage.isGlyph(NSImage(size: BridgeGlyph.canvas)))
    }
}

// MARK: - L'icône d'app

/// `scripts/make-app-icon.swift` compile `BridgeGlyph.swift` : toucher à la géométrie du glyphe peut
/// changer l'icône d'app sans que rien ne le signale. On la régénère depuis la géométrie actuelle et
/// on la compare, pixel pour pixel, à celle du dépôt.
@Suite("BridgeGlyph — l'icône d'app")
struct BridgeGlyphAppIconTests {
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    @Test("Régénérée depuis la géométrie actuelle, l'AppIcon est identique pixel pour pixel")
    func appIconIsUnchanged() async throws {
        let work = FileManager.default.temporaryDirectory
            .appending(path: "apb-appicon-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        let generator = work.appending(path: "make-app-icon")
        let compiled = try await Self.run(
            URL(fileURLWithPath: "/usr/bin/xcrun"),
            [
                "swiftc", "-parse-as-library",
                Self.root.appending(path: "scripts/make-app-icon.swift").path,
                Self.root.appending(path: "AirplayPersonalBridge/AirplayPersonalBridge/Views/BridgeGlyph.swift")
                    .path,
                "-o", generator.path,
            ]
        )
        try #require(compiled.status == 0, "compilation : \(compiled.output)")

        let generated = work.appending(path: "AppIcon.appiconset")
        let ran = try await Self.run(generator, [generated.path])
        try #require(ran.status == 0, "génération : \(ran.output)")

        let committed = Self.root.appending(
            path: "AirplayPersonalBridge/AirplayPersonalBridge/Assets.xcassets/AppIcon.appiconset"
        )
        let names = try FileManager.default.contentsOfDirectory(atPath: committed.path)
            .filter { $0.hasSuffix(".png") }.sorted()
        #expect(names.count == 10)
        for name in names {
            let before = try Self.pixels(committed.appending(path: name))
            let after = try Self.pixels(generated.appending(path: name))
            #expect(before.size == after.size, "\(name) : taille")
            #expect(before.bytes == after.bytes, "\(name) : pixels changés")
        }
        #expect(
            try Data(contentsOf: committed.appending(path: "Contents.json"))
                == Data(contentsOf: generated.appending(path: "Contents.json"))
        )
    }

    /// Les octets RGBA d'un PNG, décodé : deux encodages d'une même image se valent.
    private static func pixels(_ url: URL) throws -> (size: CGSize, bytes: [UInt8]) {
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard
                let context = CGContext(
                    data: buffer.baseAddress, width: image.width, height: image.height,
                    bitsPerComponent: 8, bytesPerRow: image.width * 4, space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                )
            else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        try #require(drawn)
        return (CGSize(width: image.width, height: image.height), bytes)
    }

    /// La fin de fichier dit que le process a terminé. Jamais `waitUntilExit()` (CLAUDE.md, Tests).
    private static func run(_ executable: URL, _ arguments: [String]) async throws
        -> (status: Int32, output: String)
    {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let pid = process.processIdentifier
        let guardian = DispatchWorkItem { kill(pid, SIGKILL) }
        DispatchQueue.global().asyncAfter(deadline: .now() + 300, execute: guardian)
        defer { guardian.cancel() }

        let output = await withCheckedContinuation { (continuation: CheckedContinuation<String, Never>) in
            DispatchQueue.global().async {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                continuation.resume(returning: String(decoding: data, as: UTF8.self))
            }
        }
        #expect(await eventually { !process.isRunning }, "le process ne sort pas : \(output)")
        return (process.terminationStatus, output)
    }
}
