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

@Suite("Icône de la barre de menus — rafraîchissements")
struct MenuBarGlyphAnimatorTests {
    @Test("Fixe : aucun minuteur, aucune image nouvelle, l'icône d'aujourd'hui")
    func stillCostsNothing() {
        let clock = ManualGlyphClock()
        let animator = MenuBarGlyphAnimator(clock: clock)
        for variant in BridgeGlyph.Variant.allCases {
            let motion = MenuBarGlyphMotion.still(variant)
            animator.follow(motion)
            #expect(animator.image(for: motion) === MenuBarGlyphImage.image(for: variant))
            let changed = invalidates({ _ = animator.image(for: motion) }) { clock.fire(20) }
            #expect(!changed, "\(variant)")
        }
        #expect(clock.timers.isEmpty)
        #expect(!animator.isAnimating)
        #expect(animator.ticks == 0)
    }

    @Test("La vague : un seul minuteur à huit coups par seconde, une image neuve à chaque coup")
    func waveScrollsTheFrames() {
        let clock = ManualGlyphClock()
        let animator = MenuBarGlyphAnimator(clock: clock)
        animator.follow(.wave)
        animator.follow(.wave)
        #expect(clock.timers.count == 1)
        #expect(clock.timers.first?.interval == 1 / BridgeGlyph.Wave.framesPerSecond)
        #expect(animator.image(for: .wave) === MenuBarGlyphImage.waveFrames[0])

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
    func stoppingCancelsTheTimer() {
        let clock = ManualGlyphClock()
        let animator = MenuBarGlyphAnimator(clock: clock)
        animator.follow(.wave)
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
        #expect(clock.active.count == 1)
        #expect(animator.image(for: .wave) === MenuBarGlyphImage.waveFrames[0])
    }

    @Test("Un animateur disparu arrête son minuteur au coup suivant")
    func releasedAnimatorStopsItsTimer() {
        let clock = ManualGlyphClock()
        var animator: MenuBarGlyphAnimator? = MenuBarGlyphAnimator(clock: clock)
        animator?.follow(.wave)
        #expect(clock.active.count == 1)
        animator = nil
        clock.fire(1)
        #expect(clock.active.isEmpty)
    }

    /// Le vrai minuteur de l'app, sur la boucle principale : compté sur une seconde de vague, et
    /// aucun coup quand l'icône est fixe.
    ///
    /// La durée réelle est mesurée plutôt que supposée : un autre test du MainActor peut tourner
    /// dans cette boucle et la prolonger.
    @Test("Avec le vrai minuteur : zéro réveil à l'arrêt, huit par seconde en vague")
    func realTimerWakesOnlyWhileWaving() {
        let animator = MenuBarGlyphAnimator(clock: RunLoopGlyphFrameClock())
        animator.follow(.still(.streaming))
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        #expect(animator.ticks == 0)

        animator.follow(.wave)
        let start = Date()
        RunLoop.main.run(until: start.addingTimeInterval(1.0))
        let elapsed = Date().timeIntervalSince(start)
        let waved = animator.ticks
        let expected = elapsed * BridgeGlyph.Wave.framesPerSecond
        #expect(
            Double(waved) >= expected - 2 && Double(waved) <= expected + 1,
            "\(waved) réveils en \(elapsed) s"
        )

        animator.follow(.still(.streaming))
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        #expect(animator.ticks == waved)
    }

    /// Le libellé tel que la barre l'héberge : rendu à intervalles réguliers, il ne change jamais
    /// quand l'icône est fixe, et change sans cesse pendant la vague.
    @Test("Hébergé, le libellé ne change pas quand il est fixe, et défile pendant la vague")
    func hostedLabelRefreshesOnlyWhileWaving() throws {
        let still = try snapshots(of: MenuBarGlyphLabel(status: .streaming, isAudible: false))
        #expect(Set(still).count == 1)

        let waving = try snapshots(of: MenuBarGlyphLabel(status: .streaming, isAudible: true))
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            #expect(Set(waving).count == 1, "réduction des animations demandée sur ce Mac")
        } else {
            #expect(Set(waving).count >= 4, "\(Set(waving).count) images distinctes")
        }
    }

    private func snapshots(of label: MenuBarGlyphLabel) throws -> [Data] {
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
        for _ in 0..<10 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.11))
            hosting.layoutSubtreeIfNeeded()
            let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            images.append(Data(try GlyphBitmap(bitmap).alphas))
        }
        return images
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
