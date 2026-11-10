import AppKit
import QuartzCore
import SwiftUI

// Sonde manuelle : le fond **bouge-t-il vraiment** dans une vraie fenêtre ? La vraie vue
// `GrainientBackground`, hébergée dans une `NSWindow` d'un vrai process AppKit (`NSApplication.run`),
// suivie dans le temps à travers ce qui pourrait lui faire perdre son animation : fenêtre masquée puis
// remontrée, app désactivée puis réactivée, diffusion coupée puis reprise, fenêtre redimensionnée.
//
//     swift run BackgroundMotionProbe            # tout le parcours, ~30 s
//     swift run BackgroundMotionProbe court      # premier plan, puis le CPU du process en mouvement et au repos, ~17 s
//
// **Elle affiche une petite fenêtre** (320×200, coin bas droit de l'écran) et prend le premier plan,
// qu'elle rend en partant à l'application qui l'avait. Le process de `swift test` ne peut pas prendre
// le premier plan : le fond s'y fige (`appearsActive` faux), d'où cet exécutable à part.
//
// À chaque relevé, une ligne `MOUVEMENT` : le calque est-il là, avec son animation, à quelle vitesse, où
// en est son horloge, et **les pixels composés de la fenêtre ont-ils changé** depuis le relevé précédent
// (capture par le serveur de fenêtres, réduite à 160×100, écart moyen et maximal par composante sur
// 255). C'est ce dernier chiffre qui tranche : une animation attachée mais jamais jouée le laisse à zéro.
//
// **Limites.** Écran verrouillé, la capture échoue ou reste figée : seuls les relevés du calque valent.
// Ce n'est pas la fenêtre de l'app : ni sa barre d'outils, ni ses vues par-dessus le fond, ni sa
// condition de diffusion (`isAudiblyStreaming`).
//
// Compilée seulement en debug : elle lit des types internes de l'app (`@testable`), ce qu'une
// compilation release du paquet (`make-cli-bundle.sh`) ne permet pas.

#if DEBUG
@testable import BridgeApp

@Observable
final class ProbeModel {
    var isLive = true
}

struct ProbeHost: View {
    let model: ProbeModel
    var body: some View { GrainientBackground(isLive: model.isLive) }
}

func descendants(of view: NSView) -> [NSView] {
    view.subviews.flatMap { [$0] + descendants(of: $0) }
}

typealias CaptureFunction = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?

/// Les pixels de la fenêtre tels que le serveur de fenêtres les compose. La fonction est retirée des
/// en-têtes Swift, pas de la bibliothèque : un process capture ses propres fenêtres sans autorisation.
func capture(_ window: NSWindow) -> [UInt8]? {
    guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else {
        return nil
    }
    let function = unsafeBitCast(symbol, to: CaptureFunction.self)
    // « Cette fenêtre seule », sans son ombre, à la résolution nominale.
    guard let image = function(.null, 1 << 3, UInt32(window.windowNumber), 1 | 1 << 4)?.takeRetainedValue()
    else { return nil }
    let width = 160
    let height = 100
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    guard
        let space = CGColorSpace(name: CGColorSpace.sRGB),
        let context = CGContext(
            data: &bytes, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )
    else { return nil }
    context.interpolationQuality = .high
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    return bytes
}

func difference(_ a: [UInt8]?, _ b: [UInt8]?) -> String {
    guard let a, let b, a.count == b.count, !a.isEmpty else { return "—" }
    var sum = 0
    var peak = 0
    var index = 0
    while index < a.count {
        let gap = abs(Int(a[index]) - Int(b[index]))
        sum += gap
        peak = max(peak, gap)
        index += 1
    }
    return String(format: "moy %.3f max %d", Double(sum) / Double(a.count), peak)
}

func cpuSeconds() -> Double {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    func seconds(_ time: timeval) -> Double { Double(time.tv_sec) + Double(time.tv_usec) / 1e6 }
    return seconds(usage.ru_utime) + seconds(usage.ru_stime)
}

func report(_ line: String) {
    FileHandle.standardOutput.write(Data("\(line)\n".utf8))
}

final class ProbeDelegate: NSObject, NSApplicationDelegate {
    let isShort: Bool
    private var window: NSWindow?
    private var hosting: NSView?
    private var last: [UInt8]?
    private let began = Date()

    init(isShort: Bool) {
        self.isShort = isShort
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { await run() }
    }

    private func note(_ label: String) {
        guard let window, let hosting else { return }
        let views = descendants(of: hosting).compactMap { $0 as? GrainientMotionView }
        let shot = capture(window)
        let pixels = difference(last, shot)
        last = shot
        var layer = "aucun calque"
        if let view = views.first {
            let stage = view.stage
            let clock = stage.convertTime(CACurrentMediaTime(), from: nil)
            var turn = "sans animation"
            if let animation = stage.animation(forKey: GrainientMotionView.animationKey) {
                let elapsed = (clock - animation.beginTime).truncatingRemainder(dividingBy: animation.duration)
                turn = String(format: "%.2f s dans le cycle de %.0f s", elapsed, animation.duration)
            }
            layer = String(
                format: "calques %d | clés %@ | vitesse %.0f | %@ | dans une fenêtre %@",
                views.count, (stage.animationKeys() ?? []).description, stage.speed, turn,
                view.window != nil ? "oui" : "non"
            )
        }
        report(
            String(
                format: "MOUVEMENT %5.1f s | %@ | active %@ clé %@ visible %@ | %@ | pixels depuis le relevé précédent : %@",
                Date().timeIntervalSince(began), label, NSApp.isActive ? "oui" : "non",
                window.isKeyWindow ? "oui" : "non", window.occlusionState.contains(.visible) ? "oui" : "non",
                layer, shot == nil ? "capture impossible" : pixels
            )
        )
    }

    private func watch(_ label: String, seconds: Int) async {
        var second = 0
        while second < seconds {
            try? await Task.sleep(for: .seconds(1))
            second += 1
            note("\(label) +\(second) s")
        }
    }

    private func cpuPercent(seconds: Double) async -> Double {
        let before = cpuSeconds()
        let since = Date()
        try? await Task.sleep(for: .seconds(seconds))
        return (cpuSeconds() - before) / Date().timeIntervalSince(since) * 100
    }

    private func run() async {
        let previous = NSWorkspace.shared.frontmostApplication
        let locked = (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool ?? false
        report("MOUVEMENT écran verrouillé : \(locked ? "oui" : "non") | au premier plan avant : \(previous?.localizedName ?? "?")")

        let size = CGSize(width: 320, height: 200)
        let model = ProbeModel()
        let hosting = NSHostingView(rootView: ProbeHost(model: model).environment(\.colorScheme, .dark))
        hosting.frame = CGRect(origin: .zero, size: size)
        let screen = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let window = NSWindow(
            contentRect: CGRect(origin: CGPoint(x: screen.maxX - size.width - 12, y: screen.minY + 12), size: size),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.title = "Sonde du fond"
        window.contentView = hosting
        self.window = window
        self.hosting = hosting

        if !isShort {
            // 1. Affichée sans prendre le premier plan : `appearsActive` est faux, le fond doit être en pause.
            window.orderFrontRegardless()
            await watch("affichée, app inactive", seconds: 3)
        }

        // 2. Au premier plan : la situation de Baptiste.
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        await watch("au premier plan", seconds: isShort ? 4 : 5)

        if isShort {
            // Le CPU du process, sans aucun relevé : pendant le mouvement, puis au repos. Les images-clés
            // sont calculées depuis longtemps, il ne reste que ce que le mouvement coûte à l'app.
            let moving = await cpuPercent(seconds: 5)
            model.isLive = false
            try? await Task.sleep(for: .seconds(2))
            let resting = await cpuPercent(seconds: 5)
            report(String(format: "MOUVEMENT CPU du process, en %% d'un cœur : %.2f pendant le mouvement, %.2f au repos", moving, resting))
        }

        if !isShort {
            // 3. Masquée, puis remontrée.
            window.orderOut(nil)
            await watch("masquée", seconds: 1)
            window.makeKeyAndOrderFront(nil)
            await watch("remontrée", seconds: 3)

            // 4. App désactivée (le premier plan rendu à qui l'avait), puis réactivée.
            previous?.activate()
            await watch("app désactivée", seconds: 2)
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            await watch("app réactivée", seconds: 3)

            // 5. La diffusion s'arrête, reprend, s'arrête, reprend.
            model.isLive = false
            await watch("diffusion coupée", seconds: 2)
            model.isLive = true
            await watch("diffusion reprise", seconds: 2)
            model.isLive = false
            await watch("diffusion recoupée", seconds: 1)
            model.isLive = true
            await watch("diffusion reprise (2)", seconds: 3)

            // 6. D'autres proportions : les images-clés sont recalculées.
            var frame = window.frame
            frame.origin.x -= 80
            frame.size.width += 80
            window.setFrame(frame, display: true)
            await watch("élargie", seconds: 3)
        }

        window.orderOut(nil)
        previous?.activate()
        try? await Task.sleep(for: .milliseconds(300))
        exit(0)
    }
}

let delegate = ProbeDelegate(isShort: CommandLine.arguments.dropFirst().first == "court")
let application = NSApplication.shared
application.delegate = delegate
// Une app ordinaire, le temps de la sonde : une app accessoire ne prend pas le premier plan.
application.setActivationPolicy(.regular)
// Garde-fou : la sonde ne reste jamais affichée.
DispatchQueue.global().asyncAfter(deadline: .now() + 60) { exit(3) }
application.run()
#else
print("BackgroundMotionProbe ne se compile qu'en debug : swift run BackgroundMotionProbe")
#endif
