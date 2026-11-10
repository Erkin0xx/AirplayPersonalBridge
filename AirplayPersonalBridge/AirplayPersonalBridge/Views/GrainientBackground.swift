//
//  GrainientBackground.swift
//  AirplayPersonalBridge
//

import AppKit
import QuartzCore
import SwiftUI

/// La recette du fond, sans rien d'affiché : une rampe de couleurs à une dimension posée sur des bandes
/// obliques, un grand noir en haut à droite, et une nappe claire à bord courbe dans le coin bas droit,
/// frangée de bleu. Le style vient de la référence choisie par Baptiste le 2026-11-10 (Grainient,
/// *shadeshifter-05*), **reproduit par le calcul** dans la palette de l'app : aucune image de Grainient
/// n'entre dans le dépôt, sa licence en interdit la redistribution.
///
/// Repère : `x` de 0 (gauche) à 1, `y` de 0 (haut) à 1 (bas), `aspect` = largeur / hauteur, `phase` en
/// radians. Tout est périodique en `phase` (elle n'entre que par `sin`/`cos` de `phase` et de `2·phase`) :
/// le mouvement se referme sans couture. Les couleurs se calculent en lumière linéaire, pas en sRGB : un
/// mélange en sRGB assombrit et salit le milieu des transitions.
nonisolated enum GrainientField {
    /// Une couleur en lumière linéaire, composantes de 0 à 1.
    struct RGB: Equatable, Sendable {
        var red: Double
        var green: Double
        var blue: Double

        /// Depuis un code sRGB `0xRRGGBB`.
        init(hex: UInt32) {
            red = GrainientField.linear(fromSRGB: Double((hex >> 16) & 0xFF) / 255)
            green = GrainientField.linear(fromSRGB: Double((hex >> 8) & 0xFF) / 255)
            blue = GrainientField.linear(fromSRGB: Double(hex & 0xFF) / 255)
        }

        init(red: Double, green: Double, blue: Double) {
            self.red = red
            self.green = green
            self.blue = blue
        }

        func mixed(with other: RGB, weight: Double) -> RGB {
            RGB(
                red: red + (other.red - red) * weight, green: green + (other.green - green) * weight,
                blue: blue + (other.blue - blue) * weight
            )
        }

        func scaled(by gain: Double) -> RGB {
            RGB(red: red * gain, green: green * gain, blue: blue * gain)
        }

        /// La luminance relative (WCAG), de 0 à 1.
        var luminance: Double { 0.2126 * red + 0.7152 * green + 0.0722 * blue }

        /// Le contraste d'un texte blanc posé sur cette couleur (WCAG) : 4,5 au moins pour du texte courant.
        var contrastWithWhite: Double { 1.05 / (min(max(luminance, 0), 1) + 0.05) }
    }

    struct Stop: Sendable {
        var position: Double
        var color: RGB
    }

    // MARK: - Réglages

    /// La durée d'un cycle complet du mouvement, en secondes. À 54 s et avec des ampleurs trois fois
    /// moindres, le fond tournait bien (sonde `BackgroundMotionProbe`) mais Baptiste le voyait fixe : une
    /// bande n'avançait pas de plus de 10 points par seconde (fenêtre de 1200). Elle en fait jusqu'à 48.
    static let period: TimeInterval = 36
    /// Les images-clés d'un cycle : une toutes les 0,3 s. Entre deux, aucune bande ne bouge de plus de
    /// 1,2 % de la largeur (14,3 points dans une fenêtre de 1200, test `keyframeStepStaysSmall`), comme
    /// avant, et un fondu de l'une à l'autre ne se distingue pas d'une déformation. Plus espacées, le
    /// filet violet, large d'une centaine de points, se dédoublerait à chaque fondu.
    static let keyframeCount = 120
    /// La taille des images calculées, étirées ensuite à la taille de la vue : le dégradé est flou par
    /// nature, et son détail le plus fin (le filet violet) y fait encore une dizaine de pixels.
    static let pixelWidth = 160
    static let pixelHeight = 100

    /// L'assombrissement, en lumière linéaire : du texte et des commandes blanches passent devant. À
    /// 0,39, un texte blanc garde un contraste de 4,5 au moins **partout** sur le fond, coin pêche compris.
    static let liveGain = 0.39
    /// Au repos, il ne reste qu'une trace des couleurs.
    static let restGain = 0.085
    /// La nappe claire du coin est retenue plus que le reste : c'est elle qui éblouirait, et son cœur
    /// tient ainsi le même contraste de 4,5.
    static let poolGain = 0.56

    /// Le fond bouge-t-il : seulement quand un son part, et jamais sous « Réduire les animations ».
    static func isAnimated(isLive: Bool, reduceMotion: Bool) -> Bool { isLive && !reduceMotion }

    /// La rampe des bandes, de la gauche (pêche, orange, rose) au noir de droite. Le creux à 0,50 puis la
    /// remontée à 0,56 font le filet clair de la référence.
    static let ramp: [Stop] = [
        Stop(position: 0, color: RGB(hex: 0xF5A26F)), Stop(position: 0.16, color: RGB(hex: 0xF26A3D)),
        Stop(position: 0.32, color: RGB(hex: 0xDF3880)), Stop(position: 0.42, color: RGB(hex: 0xB3246F)),
        Stop(position: 0.50, color: RGB(hex: 0x4A1260)), Stop(position: 0.56, color: RGB(hex: 0x7B2CA0)),
        Stop(position: 0.62, color: RGB(hex: 0x34124F)), Stop(position: 0.74, color: RGB(hex: 0x110A1B)),
        Stop(position: 0.84, color: RGB(hex: 0x09090D)), Stop(position: 1, color: RGB(hex: 0x08090C)),
    ]

    /// La nappe du coin bas droit, de son bord (noir, puis bleu vif) à son cœur clair.
    static let pool: [Stop] = [
        Stop(position: 0, color: RGB(hex: 0x08090C)), Stop(position: 0.22, color: RGB(hex: 0x161F4A)),
        Stop(position: 0.42, color: RGB(hex: 0x2F56C8)), Stop(position: 0.62, color: RGB(hex: 0x6F8FE8)),
        Stop(position: 0.82, color: RGB(hex: 0xB9C8F7)), Stop(position: 1, color: RGB(hex: 0xE6EAFB)),
    ]

    // MARK: - Mouvement

    /// La phase du mouvement à cet instant, de 0 à 2π : elle revient à chaque `period`.
    static func phase(at time: TimeInterval) -> Double {
        let turn = (time / period).truncatingRemainder(dividingBy: 1)
        return 2 * Double.pi * (turn < 0 ? turn + 1 : turn)
    }

    /// La phase de l'image-clé de ce rang. Le rang `keyframeCount` retombe sur le rang 0.
    static func keyframePhase(_ index: Int) -> Double {
        2 * Double.pi * Double(index % keyframeCount) / Double(keyframeCount)
    }

    // MARK: - Bandes

    /// L'ampleur des deux ondulations des bandes, en fraction de la largeur.
    static let slowWarp = 0.09
    static let fineWarp = 0.045
    /// La pente des bandes, en largeurs par hauteur, et ce dont elle balance de part et d'autre.
    static let slope = 0.30
    static let slopeSway = 0.06

    /// La pente des bandes à cette phase : elles se redressent et se couchent une fois par cycle.
    static func slope(phase: Double) -> Double { slope + slopeSway * sin(phase + 2.1) }

    /// La coordonnée en travers des bandes : elles penchent, balancent et ondulent lentement.
    static func band(x: Double, y: Double, aspect: Double, phase: Double) -> Double {
        x + slope(phase: phase) * y + slowWarp * sin(2.4 * Double.pi * y + phase)
            + fineWarp * sin(5 * y - 3 * x * aspect + 2 * phase + 1)
    }

    /// Où cette bande tombe sur la rampe.
    static func rampPosition(band: Double) -> Double { (band - 0.02) / 0.78 }

    /// La couleur d'une rampe à cette position, bornée à ses extrémités, interpolée en lumière linéaire.
    static func color(in stops: [Stop], at position: Double) -> RGB {
        guard let first = stops.first, let last = stops.last else { return RGB(red: 0, green: 0, blue: 0) }
        if position <= first.position { return first.color }
        if position >= last.position { return last.color }
        var index = 1
        while index < stops.count - 1, stops[index].position < position { index += 1 }
        let low = stops[index - 1]
        let high = stops[index]
        let span = high.position - low.position
        guard span > 0 else { return high.color }
        return low.color.mixed(with: high.color, weight: (position - low.position) / span)
    }

    // MARK: - Nappe claire

    /// Jusqu'où le centre de la nappe dérive, en hauteurs de vue.
    static let poolDrift = 0.10
    /// Le rayon où la nappe s'éteint, ce dont il respire, et la largeur de sa montée, en hauteurs de vue.
    static let poolRadius = 1.18
    static let poolBreath = 0.05
    static let poolFalloff = 0.62

    /// Le rayon de la nappe à cette phase : elle enfle et se retire une fois par cycle, à contretemps
    /// de sa dérive.
    static func poolRadius(phase: Double) -> Double { poolRadius + poolBreath * sin(phase + 0.9) }

    /// Le centre de la nappe, en hauteurs de vue : sous le coin bas droit, sur un petit cercle.
    static func poolCenter(aspect: Double, phase: Double) -> (x: Double, y: Double) {
        (1.02 * aspect + poolDrift * cos(phase), 1.55 + poolDrift * sin(phase))
    }

    /// La profondeur dans la nappe, de 0 (dehors) à 1 (au cœur).
    static func poolDepth(x: Double, y: Double, aspect: Double, phase: Double) -> Double {
        let center = poolCenter(aspect: aspect, phase: phase)
        let distance = hypot(x * aspect - center.x, y - center.y)
        return min(max((poolRadius(phase: phase) - distance) / poolFalloff, 0), 1)
    }

    /// La part de la nappe sur les bandes à cette profondeur : elle les recouvre tout à fait dès 0,45.
    static func poolCover(depth: Double) -> Double { smoothstep(0, 0.45, depth) }

    static func smoothstep(_ low: Double, _ high: Double, _ value: Double) -> Double {
        let t = min(max((value - low) / (high - low), 0), 1)
        return t * t * (3 - 2 * t)
    }

    // MARK: - Couleur d'un point

    /// La couleur du fond en ce point, en lumière linéaire, assombrie de `gain`.
    static func color(x: Double, y: Double, aspect: Double, phase: Double, gain: Double) -> RGB {
        let bands = color(in: ramp, at: rampPosition(band: band(x: x, y: y, aspect: aspect, phase: phase)))
        let depth = poolDepth(x: x, y: y, aspect: aspect, phase: phase)
        guard depth > 0 else { return bands.scaled(by: gain) }
        let light = color(in: pool, at: depth).scaled(by: poolGain)
        return bands.mixed(with: light, weight: poolCover(depth: depth)).scaled(by: gain)
    }

    /// Le rapport largeur / hauteur d'une vue, arrondi au vingtième et borné : la fenêtre qu'on étire ne
    /// fait pas recalculer le fond à chaque pixel, et une vue sans taille ne divise pas par zéro.
    static func quantizedAspect(width: Double, height: Double) -> Double {
        guard width > 0, height > 0 else { return 1.6 }
        return min(max((width / height * 20).rounded() / 20, 0.5), 4)
    }

    // MARK: - Images

    static func linear(fromSRGB value: Double) -> Double {
        value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }

    static func srgb(fromLinear value: Double) -> Double {
        let clamped = min(max(value, 0), 1)
        return clamped <= 0.003_130_8 ? clamped * 12.92 : 1.055 * pow(clamped, 1 / 2.4) - 0.055
    }

    /// Les octets RGBX (sRGB, 4 par pixel, ligne du haut d'abord) du fond à cette phase.
    static func pixels(width: Int, height: Int, aspect: Double, phase: Double, gain: Double) -> [UInt8] {
        var bytes = [UInt8](repeating: 255, count: max(width, 0) * max(height, 0) * 4)
        var row = 0
        while row < height {
            // Le centre de chaque pixel : l'image étirée garde ses bords à leur place.
            let y = (Double(row) + 0.5) / Double(height)
            var column = 0
            while column < width {
                let x = (Double(column) + 0.5) / Double(width)
                let color = color(x: x, y: y, aspect: aspect, phase: phase, gain: gain)
                let offset = (row * width + column) * 4
                bytes[offset] = UInt8((srgb(fromLinear: color.red) * 255).rounded())
                bytes[offset + 1] = UInt8((srgb(fromLinear: color.green) * 255).rounded())
                bytes[offset + 2] = UInt8((srgb(fromLinear: color.blue) * 255).rounded())
                column += 1
            }
            row += 1
        }
        return bytes
    }

    /// Le fond à cette phase, en petite image à étirer.
    static func image(
        aspect: Double, phase: Double, gain: Double, width: Int = pixelWidth, height: Int = pixelHeight
    ) -> CGImage? {
        let bytes = pixels(width: width, height: height, aspect: aspect, phase: phase, gain: gain)
        guard
            let provider = CGDataProvider(data: Data(bytes) as CFData),
            let space = CGColorSpace(name: CGColorSpace.sRGB)
        else { return nil }
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
        )
    }

    /// Toutes les images-clés d'un cycle, dans l'ordre. Plus d'un dixième de seconde de calcul : à
    /// appeler hors du MainActor.
    static func keyframes(aspect: Double, width: Int = pixelWidth, height: Int = pixelHeight) -> [CGImage] {
        var frames: [CGImage] = []
        frames.reserveCapacity(keyframeCount)
        var index = 0
        while index < keyframeCount {
            let phase = keyframePhase(index)
            if let frame = image(aspect: aspect, phase: phase, gain: liveGain, width: width, height: height) {
                frames.append(frame)
            }
            index += 1
        }
        return frames
    }

    // MARK: - Grain

    /// L'écart le plus fort du grain, en fraction de l'échelle sRGB.
    static let grainAmplitude = 0.075
    static let grainSide = 256

    /// Le désordre du grain, de −1 à 1 par pixel, tiré une fois d'une graine fixe : le grain ne scintille
    /// pas, et un rendu d'essai se répète au pixel près. La somme de deux tirages uniformes donne une
    /// répartition en triangle : beaucoup de petits écarts, peu de grands, comme un grain de film.
    static func grainNoise(side: Int = grainSide) -> [Double] {
        var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
        func next() -> Double {
            // Un générateur congruentiel suffit : il faut du désordre, pas du hasard.
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(seed >> 40) / Double(1 << 24)
        }
        var noise = [Double](repeating: 0, count: side * side)
        var index = 0
        while index < noise.count {
            noise[index] = next() - next()
            index += 1
        }
        return noise
    }

    /// Les octets RGBA prémultipliés du carreau de grain : du blanc ou du noir pur, plus ou moins
    /// transparent. Posé tel quel sur le fond, il l'éclaircit ou l'assombrit d'autant, sans le teinter, et
    /// marque aussi les noirs — ce qu'une fusion en incrustation ne fait pas — où il casse les paliers.
    static func grainPixels(side: Int = grainSide, amplitude: Double = grainAmplitude) -> [UInt8] {
        let noise = grainNoise(side: side)
        var bytes = [UInt8](repeating: 0, count: noise.count * 4)
        var index = 0
        while index < noise.count {
            let alpha = UInt8((min(abs(noise[index]) * amplitude, 1) * 255).rounded())
            let value: UInt8 = noise[index] > 0 ? alpha : 0
            bytes[index * 4] = value
            bytes[index * 4 + 1] = value
            bytes[index * 4 + 2] = value
            bytes[index * 4 + 3] = alpha
            index += 1
        }
        return bytes
    }

    static func grainImage() -> CGImage? {
        let bytes = grainPixels()
        guard
            let provider = CGDataProvider(data: Data(bytes) as CFData),
            let space = CGColorSpace(name: CGColorSpace.sRGB)
        else { return nil }
        return CGImage(
            width: grainSide, height: grainSide, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: grainSide * 4, space: space,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )
    }
}

/// Le fond des vues « Halo » et « Console », et sa version éteinte sous le plan.
///
/// **Tout le fond tient dans ce fichier** : Baptiste changera peut-être encore de référence, et le
/// remplacer ne doit toucher qu'ici. Vivant (un son part), les couleurs sont pleines et bougent lentement ;
/// au repos il n'en reste qu'une trace, immobile — la couleur et le mouvement veulent dire « ça joue ».
///
/// **Le mouvement ne coûte rien à l'app.** La recette est calculée par pixel une seule fois, en petites
/// images-clés (`GrainientField.keyframes`, hors du MainActor), puis Core Animation les fond l'une dans
/// l'autre sur un calque (`GrainientMotionView`) : c'est le serveur de rendu qui anime, l'app ne se
/// réveille plus. L'ancien fond redessinait un `Canvas` vingt fois par seconde. Sous le calque, la même
/// recette en image fixe : c'est elle que montrent le repos, « Réduire les animations », et les rendus hors
/// écran, qui ne voient pas les calques.
struct GrainientBackground: View {
    /// Un son passe : le fond vit.
    var isLive: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Fenêtre à l'arrière-plan : le fond se fige, personne ne le regarde.
    @Environment(\.appearsActive) private var appearsActive
    @State private var stills = GrainientStills()
    @State private var motion: GrainientMotion?

    private struct MotionRequest: Hashable {
        var aspect: Double
        var animates: Bool
    }

    var body: some View {
        GeometryReader { proxy in
            let aspect = GrainientField.quantizedAspect(width: proxy.size.width, height: proxy.size.height)
            let animates = GrainientField.isAnimated(isLive: isLive, reduceMotion: reduceMotion)
            ZStack {
                BridgeTheme.ground
                still(aspect: aspect, gain: GrainientField.restGain)
                still(aspect: aspect, gain: GrainientField.liveGain)
                    .opacity(isLive ? 1 : 0)
                if animates, let motion {
                    GrainientMotionLayer(motion: motion, isPaused: !appearsActive)
                        .transition(.opacity)
                }
                if let grain = Self.grain {
                    Image(decorative: grain, scale: 2)
                        .resizable(resizingMode: .tile)
                }
            }
            .animation(.easeInOut(duration: 1.4), value: isLive)
            .task(id: MotionRequest(aspect: aspect, animates: animates)) {
                await prepareMotion(aspect: aspect, animates: animates)
            }
        }
        .allowsHitTesting(false)
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func still(aspect: Double, gain: Double) -> some View {
        if let image = stills.image(aspect: aspect, gain: gain) {
            Image(decorative: image, scale: 1)
                .resizable()
                .interpolation(.high)
        }
    }

    /// Calcule les images-clés quand le fond se met à vivre, ou quand la fenêtre a changé de proportions.
    private func prepareMotion(aspect: Double, animates: Bool) async {
        guard animates else {
            motion = nil
            return
        }
        guard motion?.aspect != aspect else { return }
        if motion != nil {
            // Une fenêtre qu'on étire passe par vingt proportions : attendre qu'elle se pose. D'ici là,
            // les images en place s'étirent avec elle.
            try? await Task.sleep(for: .milliseconds(300))
            if Task.isCancelled { return }
        }
        let frames = await Task.detached(priority: .utility) {
            GrainientField.keyframes(aspect: aspect)
        }.value
        if Task.isCancelled || frames.count != GrainientField.keyframeCount { return }
        motion = GrainientMotion(aspect: aspect, frames: frames)
    }

    /// Le carreau de grain, construit une fois.
    static let grain: CGImage? = GrainientField.grainImage()
}

/// Les images fixes du fond déjà calculées, par proportions et par assombrissement : le corps de la vue
/// est réévalué souvent, le calcul ne se refait pas.
final class GrainientStills {
    private struct Key: Hashable {
        var aspect: Double
        var gain: Double
    }

    private var images: [Key: CGImage] = [:]

    func image(aspect: Double, gain: Double) -> CGImage? {
        let key = Key(aspect: aspect, gain: gain)
        if let image = images[key] { return image }
        // Une fenêtre étirée longtemps ne garde pas une image par proportion traversée.
        if images.count >= 8 { images.removeAll() }
        let image = GrainientField.image(aspect: aspect, phase: 0, gain: gain)
        images[key] = image
        return image
    }
}

/// Un cycle d'images-clés, pour des proportions données.
struct GrainientMotion {
    var aspect: Double
    var frames: [CGImage]
}

/// Le calque animé, posé dans la vue SwiftUI.
struct GrainientMotionLayer: NSViewRepresentable {
    var motion: GrainientMotion
    var isPaused: Bool

    func makeNSView(context: Context) -> GrainientMotionView {
        GrainientMotionView()
    }

    func updateNSView(_ view: GrainientMotionView, context: Context) {
        view.show(motion)
        view.isPaused = isPaused
    }
}

/// Le calque qui joue le mouvement du fond : une animation d'images-clés sur `contents`, en mode
/// linéaire — Core Animation fond chaque image dans la suivante (vérifié par un rendu `CARenderer` : à
/// mi-chemin de deux images, le pixel vaut leur moyenne). Elle boucle sans fin et sans couture, la
/// dernière valeur étant la première.
final class GrainientMotionView: NSView {
    static let animationKey = "fond"

    /// Le calque animé : ce que vérifient les tests.
    let stage = CALayer()
    private var shown: GrainientMotion?
    /// L'instant, sur l'horloge du calque, où le premier cycle a commencé : un cycle recalculé pour
    /// d'autres proportions reprend à la même phase, sans saut.
    private var origin: CFTimeInterval?

    override init(frame: NSRect) {
        super.init(frame: frame)
        let host = CALayer()
        layer = host
        wantsLayer = true
        // Ni fondu ni glissement implicites : seule l'animation d'images-clés bouge.
        stage.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
        stage.contentsGravity = .resize
        stage.magnificationFilter = .linear
        stage.isOpaque = true
        stage.frame = host.bounds
        stage.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        host.addSublayer(stage)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("Jamais chargée d'un fichier d'interface")
    }

    /// Le fond ne prend aucun clic : la fenêtre se déplace par lui.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func show(_ motion: GrainientMotion) {
        if let shown, shown.aspect == motion.aspect, stage.animation(forKey: Self.animationKey) != nil {
            return
        }
        shown = motion
        install()
    }

    private func install() {
        guard let shown, let first = shown.frames.first else { return }
        let start = origin ?? stage.convertTime(CACurrentMediaTime(), from: nil)
        origin = start

        let animation = CAKeyframeAnimation(keyPath: "contents")
        animation.values = shown.frames + [first]
        animation.calculationMode = .linear
        animation.duration = GrainientField.period
        animation.repeatCount = .infinity
        animation.beginTime = start
        animation.isRemovedOnCompletion = false
        // Une bande avance de 48 points par seconde au plus : à vingt-quatre images par seconde, deux
        // points par image. Le serveur de rendu n'a pas à recomposer la fenêtre au rythme de l'écran.
        animation.preferredFrameRateRange = CAFrameRateRange(minimum: 15, maximum: 30, preferred: 24)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        stage.contents = first
        stage.add(animation, forKey: Self.animationKey)
        CATransaction.commit()
    }

    /// Figé où il en est, ou reparti de là.
    var isPaused = false {
        didSet {
            guard isPaused != oldValue else { return }
            if isPaused {
                let now = stage.convertTime(CACurrentMediaTime(), from: nil)
                stage.speed = 0
                stage.timeOffset = now
            } else {
                let pausedAt = stage.timeOffset
                stage.speed = 1
                stage.timeOffset = 0
                stage.beginTime = 0
                stage.beginTime = stage.convertTime(CACurrentMediaTime(), from: nil) - pausedAt
                // Par précaution : un calque qui aurait perdu son animation pendant que la fenêtre était
                // à l'arrière-plan la retrouve au retour, à la phase où il en était. La sonde ne l'a
                // jamais vu la perdre, mais rien ne l'aurait signalé : le fond serait resté fixe.
                if stage.animation(forKey: Self.animationKey) == nil { install() }
            }
        }
    }

    /// Une vue sortie de sa fenêtre peut y perdre son animation : elle la retrouve en y revenant.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil, stage.animation(forKey: Self.animationKey) == nil { install() }
    }
}
