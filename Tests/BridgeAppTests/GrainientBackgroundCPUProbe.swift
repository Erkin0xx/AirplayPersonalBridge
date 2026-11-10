import AppKit
import Foundation
import QuartzCore
import SwiftUI
import Testing

@testable import BridgeApp

/// Mesure ce que le fond coûte au process qui l'héberge, dans une vraie fenêtre, et le compare à
/// l'ancien (`Canvas` redessiné vingt fois par seconde).
///
/// Inerte tant que la variable d'environnement n'est pas posée ; à lancer seule, elle dure plusieurs
/// minutes et fait tourner la boucle d'événements principale.
///
/// ```
/// BACKGROUND_CPU_PROBE=30 swift test -c release --filter GrainientBackgroundCPUProbe
/// ```
///
/// La valeur est la durée de chaque relevé, en secondes. Chaque scène est hébergée seule dans une
/// fenêtre de 1200×760 ; le temps CPU du process (`getrusage`, utilisateur + système) est relevé avant
/// et après, et rapporté à la durée : 100 % = un cœur.
///
/// **Limites.** Ce chiffre est celui du process, pas celui du serveur de fenêtres, qui compose le fondu.
/// Écran verrouillé ou fenêtre masquée, rien ne garantit que `TimelineView` batte à son rythme ni que la
/// fenêtre soit composée : le compteur de dessins de l'ancien fond dit ce qu'il en a été.
@Suite("Fond — mesure CPU à la demande")
struct GrainientBackgroundCPUProbe {
    private nonisolated static var duration: TimeInterval? {
        ProcessInfo.processInfo.environment["BACKGROUND_CPU_PROBE"].flatMap(TimeInterval.init)
    }

    private static func cpuSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        func seconds(_ time: timeval) -> Double { Double(time.tv_sec) + Double(time.tv_usec) / 1e6 }
        return seconds(usage.ru_utime) + seconds(usage.ru_stime)
    }

    /// Laisse vivre la fenêtre : la boucle d'événements par courtes tranches, pour AppKit et Core
    /// Animation, et entre deux une suspension, pour les tâches du MainActor. Une boucle imbriquée seule
    /// ne vide pas la file principale : les images-clés, calculées ailleurs, ne revenaient jamais à la
    /// vue, et le calque n'était pas monté. Ces réveils (une dizaine par seconde) comptent dans tous les
    /// relevés, plancher compris.
    private static func spin(for duration: TimeInterval) async {
        let end = Date().addingTimeInterval(duration)
        while Date() < end {
            pump(0.08)
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    private static func pump(_ duration: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(duration))
    }

    private static func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    /// Héberge la vue, laisse la fenêtre se poser, puis relève le CPU sur `duration`.
    private func measure(_ name: String, duration: TimeInterval, _ view: some View) async -> Double {
        let size = CGSize(width: 1200, height: 760)
        let hosting = NSHostingView(rootView: view.environment(\.colorScheme, .dark))
        hosting.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(
            contentRect: CGRect(origin: CGPoint(x: 80, y: 80), size: size),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.orderFrontRegardless()
        window.makeKey()
        // Le temps que la fenêtre se pose et que les images-clés soient calculées : hors mesure.
        await Self.spin(for: 3)

        let draws = LegacyAuroraBackground.draws
        let start = Self.cpuSeconds()
        let began = Date()
        await Self.spin(for: duration)
        let elapsed = Date().timeIntervalSince(began)
        let percent = (Self.cpuSeconds() - start) / elapsed * 100

        let visible = window.occlusionState.contains(.visible)
        // Le calque est-il bien là, avec son animation ? Sans lui, un coût nul ne prouverait rien.
        let layers = Self.descendants(of: hosting).compactMap { $0 as? GrainientMotionView }
        let animated = layers.contains { $0.stage.animation(forKey: GrainientMotionView.animationKey) != nil }
        let paused = layers.contains { $0.stage.speed == 0 }
        let stamp = ISO8601DateFormatter().string(from: began)
        print(
            String(
                format: "SONDE %@ | %@ | %.3f %% d'un cœur sur %.0f s | dessins de l'ancien fond : %d | calque animé : %@ | fenêtre visible : %@ | clé : %@",
                stamp, name, percent, elapsed, LegacyAuroraBackground.draws - draws,
                animated ? (paused ? "oui, en pause" : "oui") : "non",
                visible ? "oui" : "non", window.isKeyWindow ? "oui" : "non"
            )
        )
        // La vue quitte la fenêtre avant sa fermeture : une fenêtre fermée qui garde son contenu laisse
        // battre son `TimelineView`, et l'ancien fond a ainsi faussé tous les relevés suivants d'un
        // premier passage (plus de 100 % d'un cœur partout).
        window.contentView = nil
        window.close()
        await Self.spin(for: 1)
        return percent
    }

    @Test(
        "Relève le CPU du process : fenêtre vide, ancien fond, nouveau fond animé, en pause, au repos",
        .enabled(if: GrainientBackgroundCPUProbe.duration != nil)
    )
    func probe() async throws {
        let duration = try #require(Self.duration)
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)

        // Le seul calcul du nouveau fond : les images-clés d'un cycle, une fois par proportions de fenêtre.
        let before = Self.cpuSeconds()
        let frames = GrainientField.keyframes(aspect: 1.6)
        print(String(format: "SONDE images-clés : %d images calculées en %.1f ms de CPU", frames.count, (Self.cpuSeconds() - before) * 1000))

        // L'ancien fond en dernier : rien de lui ne peut déborder sur les autres relevés.
        _ = await measure("fenêtre vide (plancher)", duration: duration, BridgeTheme.ground)
        _ = await measure("nouveau fond, vivant", duration: duration, GrainientBackground(isLive: true))
        // Le calque seul, sans dépendre de l'état actif de la fenêtre : animé, puis figé.
        let motion = GrainientMotion(aspect: 1.6, frames: GrainientField.keyframes(aspect: 1.6))
        _ = await measure(
            "calque animé seul", duration: duration, GrainientMotionLayer(motion: motion, isPaused: false)
        )
        _ = await measure(
            "calque en pause (fenêtre à l'arrière-plan)", duration: duration,
            GrainientMotionLayer(motion: motion, isPaused: true)
        )
        _ = await measure("nouveau fond, au repos", duration: duration, GrainientBackground(isLive: false))
        _ = await measure("fenêtre vide, de nouveau", duration: duration, BridgeTheme.ground)
        _ = await measure("ancien fond, vivant (Canvas 20 im/s)", duration: duration, LegacyAuroraBackground())
        _ = await measure("fenêtre vide, après l'ancien fond", duration: duration, BridgeTheme.ground)
    }
}

/// L'ancien fond, tel qu'il était avant le 2026-11-10, gardé ici comme point de comparaison de la sonde :
/// quatre nappes radiales redessinées dans un `Canvas` vingt fois par seconde, sous un grain en
/// incrustation. La pause par `appearsActive` est retirée : la sonde veut le coût quand il tourne.
private struct LegacyAuroraBackground: View {
    /// Dessins du `Canvas` depuis le lancement : ce qui dit si `TimelineView` a battu.
    nonisolated(unsafe) static var draws = 0

    private struct Field {
        var color: Color
        var center: UnitPoint
        var radius: Double
        var opacity: Double
        var period: Double
        var phase: Double
    }

    private static let fields: [Field] = [
        Field(color: BridgeTheme.rose, center: UnitPoint(x: 0.16, y: 0.14), radius: 0.46, opacity: 0.50, period: 52, phase: 0),
        Field(color: BridgeTheme.violet, center: UnitPoint(x: 0.82, y: 0.20), radius: 0.44, opacity: 0.46, period: 62, phase: 1.7),
        Field(color: BridgeTheme.blue, center: UnitPoint(x: 0.30, y: 0.90), radius: 0.42, opacity: 0.34, period: 58, phase: 3.1),
        Field(color: BridgeTheme.orange, center: UnitPoint(x: 0.84, y: 0.84), radius: 0.40, opacity: 0.38, period: 46, phase: 4.4),
    ]

    private static let grain: CGImage? = {
        var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
        var pixels = [UInt8](repeating: 0, count: 256 * 256)
        for index in pixels.indices {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            pixels[index] = UInt8(truncatingIfNeeded: seed >> 56)
        }
        return CGDataProvider(data: Data(pixels) as CFData).flatMap {
            CGImage(
                width: 256, height: 256, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: 256,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                provider: $0, decode: nil, shouldInterpolate: false, intent: .defaultIntent
            )
        }
    }()

    var body: some View {
        ZStack {
            BridgeTheme.ground
            TimelineView(.animation(minimumInterval: 1 / 20)) { timeline in
                Canvas { context, size in
                    Self.draws += 1
                    let time = timeline.date.timeIntervalSinceReferenceDate
                    let side = max(size.width, size.height)
                    for field in Self.fields {
                        let angle = 2 * Double.pi * time / field.period + field.phase
                        let center = CGPoint(
                            x: (field.center.x + 0.07 * cos(angle)) * size.width,
                            y: (field.center.y + 0.07 * sin(angle * 0.8)) * size.height
                        )
                        context.fill(
                            Path(CGRect(origin: .zero, size: size)),
                            with: .radialGradient(
                                Gradient(colors: [field.color.opacity(field.opacity), field.color.opacity(0)]),
                                center: center, startRadius: 0, endRadius: field.radius * side
                            )
                        )
                    }
                }
            }
            if let grain = Self.grain {
                Image(decorative: grain, scale: 2)
                    .resizable(resizingMode: .tile)
                    .blendMode(.overlay)
                    .opacity(0.16)
            }
        }
        .ignoresSafeArea()
    }
}
