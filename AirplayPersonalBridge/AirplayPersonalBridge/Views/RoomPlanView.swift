//
//  RoomPlanView.swift
//  AirplayPersonalBridge
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Un élément sélectionnable du plan. Murs et meubles partagent la même sélection : on
/// s'attend à pouvoir attraper les deux ensemble et tout effacer d'un coup.
enum PlanElement: Hashable {
    case object(UUID)
    case wall(UUID)
}

/// L'éditeur de plan (CDC section 9, niveau « 2D vu du dessus », l'option retenue).
///
/// On trace des murs, on y pose des meubles, et chaque objet porte une hauteur. Ça reste
/// délibérément loin d'un logiciel d'architecture : pas de portes, pas de fenêtres, pas de
/// catalogue. Seul ce qui influe sur le trajet du son jusqu'aux oreilles a sa place ici.
///
/// **La vue ne se recadre jamais toute seule.** Une première version rejouait
/// `PlanTransform.fitting` à chaque modification : le plan sautait sous le curseur à chaque
/// clic, et sur un mur droit — dont l'emprise a une hauteur nulle — le zoom partait à
/// l'infini. L'échelle et le cadrage sont donc de l'état, que seul l'utilisateur change.
struct RoomPlanView: View {
    @Bindable var state: BridgeState

    enum Tool: String, CaseIterable, Identifiable {
        case select = "Sélection"
        case walls = "Murs"
        /// Trace une longueur connue sur l'image de fond pour en déduire son échelle.
        case calibrate = "Calibrer"
        var id: String { rawValue }
    }

    @State private var tool: Tool = .select
    /// Polyligne en cours de tracé, pas encore validée en segments.
    @State private var pendingWall: [CGPoint] = []
    @State private var hoverPoint: CGPoint?
    @State private var selection: Set<PlanElement> = []

    // MARK: Cadrage — état, jamais recalculé automatiquement

    /// Points d'écran par mètre.
    @State private var scale: Double = 70
    /// Position à l'écran de l'origine du modèle. `nil` tant que la vue n'a pas de taille.
    @State private var origin: CGPoint?
    @State private var viewSize: CGSize = .zero

    @State private var drag: DragMode?

    private enum DragMode {
        case move(id: UUID, offset: CGSize)
        case moveVertex(refs: [VertexRef], offset: CGSize)
        case moveBackground(startOrigin: CGPoint)
        case pan(startOrigin: CGPoint)
    }

    /// Une extrémité précise d'un segment de mur.
    ///
    /// Les murs étant une liste plate, un coin de pièce est **plusieurs** extrémités
    /// superposées — une par segment qui s'y rejoint. Déplacer un coin doit donc les
    /// bouger toutes ensemble, sinon l'angle se dédouble silencieusement et le plan se
    /// retrouve troué à un endroit qu'on ne voit qu'en zoomant.
    struct VertexRef: Equatable {
        let id: UUID
        let isStart: Bool
    }

    @State private var hoveredVertex: CGPoint?
    @State private var hoveredObject: UUID?
    /// Force l'affichage de toutes les cotes d'un coup, pour relire un plan terminé.
    @State private var showsAllLabels = false

    // MARK: Image de fond

    @State private var backgroundImage: NSImage?
    @State private var showsImporter = false
    /// Les deux points de la mesure de calibrage, en mètres du repère courant.
    @State private var calibration: [CGPoint] = []
    @State private var calibrationLength = ""
    @State private var showsCalibrationPrompt = false

    /// Pas du magnétisme, en mètres. 5 cm : assez fin pour placer une enceinte contre un
    /// mur, assez grossier pour que les murs restent droits sans effort.
    private let snap: Double = 0.05
    /// Incrément angulaire du tracé. 15° contient 0/90/180/270, donc les angles droits
    /// tombent d'eux-mêmes, tout en laissant tracer un pan en biais ou une diagonale à 45°.
    private let angleStep: Double = 15
    /// Rayon d'accrochage, en points d'écran : constant à l'œil quel que soit le zoom.
    private let snapRadius: Double = 14
    private let scaleRange: ClosedRange<Double> = 12...400

    private var transform: PlanTransform {
        PlanTransform(scale: scale, origin: origin ?? .zero)
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            ShadSeparator()
            planArea
            ShadSeparator()
            inspector
        }
        .background(Theme.background)
        .onDeleteCommand(perform: deleteSelection)
    }

    // MARK: - Zone de dessin

    private var planArea: some View {
        Canvas { context, size in
            guard origin != nil else { return }
            drawBackground(&context)
            drawGrid(&context, size: size)
            drawCalibration(&context)
            drawWalls(&context)
            drawPendingWall(&context)
            drawDistanceLines(&context)
            for object in state.roomLayout.objects { draw(object, in: &context) }
        }
        .background(Theme.background)
        .contentShape(Rectangle())
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
            viewSize = size
            // Le premier cadrage est le seul qui soit automatique.
            if origin == nil, size.width > 0 { fitToContent(in: size) }
        }
        .gesture(planGesture)
        .simultaneousGesture(
            MagnifyGesture()
                .onChanged { zoom(to: scale * $0.magnification, around: $0.startLocation) }
        )
        .onContinuousHover { phase in
            if case let .active(location) = phase {
                let model = transform.toModel(location)
                hoverPoint = snapPoint(model, from: pendingWall.last)
                hoveredVertex = tool == .select ? nearestWallVertex(to: model) : nil
                hoveredObject = tool == .select ? object(at: model)?.id : nil
            } else {
                hoverPoint = nil
                hoveredVertex = nil
                hoveredObject = nil
            }
        }
        .frame(minHeight: 260)
        .overlay(alignment: .bottomTrailing) { zoomControls }
        // L'aide passe en bas à gauche : en haut elle recouvrait la première rangée du plan
        // et se battait avec la barre d'outils juste au-dessus.
        .overlay(alignment: .bottomLeading) { hint }
        .onAppear(perform: loadBackgroundImage)
        .onChange(of: state.roomLayout.background?.fileName) { _, _ in loadBackgroundImage() }
        .fileImporter(
            isPresented: $showsImporter, allowedContentTypes: [.image]
        ) { result in
            if case let .success(url) = result { importBackground(from: url) }
        }
        .alert("Longueur réelle de la mesure", isPresented: $showsCalibrationPrompt) {
            TextField("mètres", text: $calibrationLength)
            Button("Calibrer", action: applyCalibration)
            Button("Annuler", role: .cancel) { calibration = [] }
        } message: {
            Text(
                "Indique en mètres la distance réelle entre les deux points que tu viens de "
                    + "tracer sur le plan."
            )
        }
    }

    private var zoomControls: some View {
        HStack(spacing: 4) {
            Button { zoom(to: scale / 1.25, around: center) } label: {
                Image(systemName: "minus").font(.system(size: 10, weight: .bold))
            }
            .shadButton(.outline, size: .small)
            Button { zoom(to: scale * 1.25, around: center) } label: {
                Image(systemName: "plus").font(.system(size: 10, weight: .bold))
            }
            .shadButton(.outline, size: .small)
            Button("Cadrer") { fitToContent(in: viewSize) }
                .shadButton(.outline, size: .small)
            Button {
                showsAllLabels.toggle()
            } label: {
                Image(systemName: showsAllLabels ? "text.bubble.fill" : "text.bubble")
                    .font(.system(size: 11))
            }
            .shadButton(showsAllLabels ? .primary : .outline, size: .small)
            .help("Afficher toutes les cotes d'un coup")
            Text(String(format: "%.0f px/m", scale))
                .font(Theme.Font.tiny.monospacedDigit())
                .foregroundStyle(Theme.mutedForeground)
        }
        .padding(10)
    }

    @ViewBuilder
    private var hint: some View {
        // Aide courte : une phrase de trois lignes finit par ne plus être lue, et occupe la
        // place du plan qu'on essaie justement de dégager.
        let text: String? = switch tool {
        case .walls:
            pendingWall.isEmpty
                ? "Clique pour commencer un mur • ⌥ libère l'angle"
                : "Reclique sur le départ pour fermer • ⎋ annule"
        case .calibrate:
            calibration.isEmpty
                ? "Clique les deux bouts d'une longueur connue"
                : "Clique le second point"
        case .select:
            selection.isEmpty ? "Glisse un point pour bouger un coin • ⇧-clic = sélection multiple" : nil
        }
        if let text {
            Text(text)
                .font(Theme.Font.tiny)
                .foregroundStyle(Theme.mutedForeground)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(Theme.card, in: Capsule())
                .overlay { Capsule().strokeBorder(Theme.border, lineWidth: 1) }
                .padding(10)
        }
    }

    private var center: CGPoint { CGPoint(x: viewSize.width / 2, y: viewSize.height / 2) }

    // MARK: - Barre d'outils et palette

    private var toolbar: some View {
        VStack(spacing: 8) {
            HStack {
                ShadTabs(
                    selection: $tool,
                    items: Tool.allCases.map { ($0, $0.rawValue) }
                )
                .onChange(of: tool) { _, _ in commitPendingWall() }

                Spacer()

                if tool == .walls && pendingWall.count >= 2 {
                    Button("Terminer") { commitPendingWall() }
                        .shadButton(.outline, size: .small)
                    Button("Fermer") { commitPendingWall(closing: true) }
                        .shadButton(.primary, size: .small)
                }
                if tool == .walls && !pendingWall.isEmpty {
                    Button("Annuler") { pendingWall = [] }
                        .shadButton(.ghost, size: .small)
                        .keyboardShortcut(.cancelAction)
                }
                if tool == .select && !selection.isEmpty {
                    Button("Supprimer", action: deleteSelection)
                        .shadButton(.destructive, size: .small)
                }

                Menu {
                    Button("Pivoter le plan 90° à droite") { rotatePlan(clockwise: true) }
                    Button("Pivoter le plan 90° à gauche") { rotatePlan(clockwise: false) }
                    Divider()
                    Button("Tout sélectionner") { selectAll() }
                    Divider()
                    Button("Importer un plan en fond…") { showsImporter = true }
                    if state.roomLayout.background != nil {
                        Button("Retirer le plan de fond", role: .destructive) {
                            state.roomLayout.background = nil
                            backgroundImage = nil
                            if tool == .calibrate { tool = .select }
                            state.persistRoomLayout()
                        }
                    }
                    Divider()
                    Button("Effacer les murs", role: .destructive) {
                        state.roomLayout.walls.removeAll()
                        selection = selection.filter { if case .wall = $0 { false } else { true } }
                        state.persistRoomLayout()
                    }
                    Button("Tout effacer", role: .destructive) {
                        state.roomLayout = RoomLayout()
                        selection = []
                        state.persistRoomLayout()
                    }
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 12, weight: .semibold))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 26, height: 26)
                .background(Theme.muted, in: RoundedRectangle(cornerRadius: Theme.Radius.md))
                .fixedSize()
            }

            palette
            if state.roomLayout.background != nil { backgroundBar }
        }
        .padding(8)
    }

    /// Réglages de l'image de fond. Ils n'apparaissent que si une image est chargée —
    /// afficher en permanence des commandes sans objet encombrerait pour rien.
    @ViewBuilder
    private var backgroundBar: some View {
        if let background = state.roomLayout.background {
            HStack(spacing: 8) {
                Image(systemName: "photo")
                    .foregroundStyle(.secondary)

                ShadSlider(
                    value: Binding(
                        get: { background.opacity },
                        set: { state.roomLayout.background?.opacity = $0 }
                    ),
                    range: 0.05...1
                )
                .frame(maxWidth: 110)
                .onChange(of: background.opacity) { _, _ in state.persistRoomLayout() }

                Toggle(isOn: Binding(
                    get: { background.isLocked },
                    set: {
                        state.roomLayout.background?.isLocked = $0
                        state.persistRoomLayout()
                    }
                )) {
                    Image(systemName: background.isLocked ? "lock.fill" : "lock.open")
                }
                .toggleStyle(.button)
                .buttonStyle(ShadButtonStyle(variant: .outline, size: .small))
                .help(
                    background.isLocked
                        ? "Image verrouillée — elle ne bougera pas"
                        : "Image déverrouillée — glisse-la pour la caler"
                )

                Text(String(format: "%.1f cm/px", background.metersPerPixel * 100))
                    .font(Theme.Font.tiny.monospacedDigit())
                    .foregroundStyle(Theme.mutedForeground)

                Spacer()
            }
        }
    }

    /// La bibliothèque de meubles, plus un raccourci par sortie découverte.
    ///
    /// Les modèles sont dans un menu et non en boutons alignés : la liste s'allonge, et une
    /// rangée de boutons devenait illisible avant même d'être complète.
    private var palette: some View {
        HStack(spacing: 6) {
            Menu {
                ForEach(RoomObject.Library.groups, id: \.0) { title, presets in
                    Section(title) {
                        ForEach(presets) { preset in
                            // Une seule position d'écoute par plan : la proposer deux fois
                            // laisserait croire qu'on peut écouter à deux endroits.
                            if preset.kind != .listener || state.roomLayout.listener == nil {
                                Button {
                                    add(preset)
                                } label: {
                                    Label(preset.label, systemImage: preset.kind.symbol)
                                }
                            }
                        }
                    }
                }
            } label: {
                Label("Ajouter un meuble", systemImage: "plus")
                    .font(Theme.Font.medium)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(Theme.muted, in: RoundedRectangle(cornerRadius: Theme.Radius.md))
            .fixedSize()

            // Raccourci : pose une enceinte **déjà rattachée** à cette sortie. Le bouton ne
            // disparaît plus une fois utilisé — une sortie AirPlay 2 peut porter deux
            // HomePod, et il faut pouvoir poser le second.
            ForEach(state.outputs) { output in
                Button {
                    let base = RoomObject.Library.genericSpeaker
                    add(
                        RoomObject.Preset(
                            label: base.label, kind: .speaker(outputID: output.id),
                            size: base.size, shape: base.shape, elevation: base.elevation,
                            note: base.note
                        ),
                        name: output.displayName
                    )
                } label: {
                    Label(output.displayName, systemImage: "hifispeaker.fill")
                }
                .shadButton(.outline, size: .small)
                .help("Ajoute une enceinte rattachée à \(output.displayName)")
            }

            Spacer()
        }
    }

    private func add(_ preset: RoomObject.Preset, name: String = "") {
        // Le nouvel objet apparaît au centre de ce qu'on regarde, pas à l'origine du
        // modèle : sur un plan qu'on a déplacé, un objet posé en (0,0) atterrit hors écran.
        let object = preset.makeObject(at: gridSnapped(transform.toModel(center)), name: name)
        state.roomLayout.objects.append(object)
        selection = [.object(object.id)]
        tool = .select
        state.persistRoomLayout()
    }

    // MARK: - Dessin

    /// L'image de fond, sous la grille pour que les cotes restent lisibles par-dessus.
    private func drawBackground(_ context: inout GraphicsContext) {
        guard let background = state.roomLayout.background, let image = backgroundImage else {
            return
        }
        let pixels = pixelSize(of: image)
        let size = CGSize(
            width: pixels.width * background.metersPerPixel * scale,
            height: pixels.height * background.metersPerPixel * scale
        )
        let topLeft = transform.toView(background.origin)
        let imageCenter = CGPoint(x: topLeft.x + size.width / 2, y: topLeft.y + size.height / 2)
        let rect = CGRect(
            x: -size.width / 2, y: -size.height / 2, width: size.width, height: size.height
        )

        // L'image tourne autour de son centre pour suivre les rotations du plan : un
        // décalque qui ne suivrait pas cesserait de correspondre au relevé.
        context.drawLayer { layer in
            layer.translateBy(x: imageCenter.x, y: imageCenter.y)
            layer.rotate(by: .degrees(background.rotation))
            layer.opacity = background.opacity
            layer.draw(Image(nsImage: image), in: rect)
            layer.opacity = 1
            if !background.isLocked {
                layer.stroke(
                    Path(rect), with: .color(Theme.info),
                    style: .init(lineWidth: 2, dash: [6, 4])
                )
            }
        }
    }

    /// La mesure de calibrage en cours.
    private func drawCalibration(_ context: inout GraphicsContext) {
        guard tool == .calibrate, let first = calibration.first else { return }
        let end = calibration.count > 1 ? calibration[1] : hoverPoint
        guard let end else { return }
        var path = Path()
        path.move(to: transform.toView(first))
        path.addLine(to: transform.toView(end))
        context.stroke(path, with: .color(Theme.destructive), style: .init(lineWidth: 2, lineCap: .round))
        for point in [first, end] {
            let view = transform.toView(point)
            context.stroke(
                Path(ellipseIn: CGRect(x: view.x - 5, y: view.y - 5, width: 10, height: 10)),
                with: .color(Theme.destructive), lineWidth: 2
            )
        }
    }

    /// Dimensions en **pixels** de l'image, pas en points : une capture d'écran Retina
    /// rapporte une taille en points deux fois plus petite que sa vraie définition, ce qui
    /// fausserait l'échelle d'un facteur 2 sans que rien ne le signale.
    private func pixelSize(of image: NSImage) -> CGSize {
        if let representation = image.representations.first {
            return CGSize(width: representation.pixelsWide, height: representation.pixelsHigh)
        }
        return image.size
    }

    private func drawGrid(_ context: inout GraphicsContext, size: CGSize) {
        // Graduation au mètre : c'est l'unité dans laquelle on raisonne, et elle donne
        // l'échelle sans avoir à écrire de cote partout. En dessous de 25 px/m elle
        // deviendrait un aplat, donc on l'espace.
        let step: Double = scale < 25 ? 5 : 1
        var path = Path()
        let topLeft = transform.toModel(.zero)
        let bottomRight = transform.toModel(CGPoint(x: size.width, y: size.height))
        var x = (topLeft.x / step).rounded(.down) * step
        while x <= bottomRight.x {
            let viewX = transform.toView(CGPoint(x: x, y: 0)).x
            path.move(to: CGPoint(x: viewX, y: 0))
            path.addLine(to: CGPoint(x: viewX, y: size.height))
            x += step
        }
        var y = (topLeft.y / step).rounded(.down) * step
        while y <= bottomRight.y {
            let viewY = transform.toView(CGPoint(x: 0, y: y)).y
            path.move(to: CGPoint(x: 0, y: viewY))
            path.addLine(to: CGPoint(x: size.width, y: viewY))
            y += step
        }
        context.stroke(path, with: .color(Theme.border), lineWidth: 1)
    }

    private func drawWalls(_ context: inout GraphicsContext) {
        for wall in state.roomLayout.walls {
            let a = transform.toView(wall.a)
            let b = transform.toView(wall.b)
            var path = Path()
            path.move(to: a)
            path.addLine(to: b)
            let isSelected = selection.contains(.wall(wall.id))
            context.stroke(
                path,
                with: .color(isSelected ? Theme.info : Theme.foreground.opacity(0.85)),
                style: .init(lineWidth: isSelected ? 8 : 6, lineCap: .round)
            )
            // Les cotes de mur ne s'affichent qu'à la sélection ou une fois assez zoomé :
            // sur une pièce entière tenant dans la fenêtre, elles se chevauchaient toutes.
            if showsAllLabels || isSelected || scale >= 45 {
                context.draw(
                    Text(String(format: "%.2f m", wall.length))
                        .font(.system(size: 9))
                        .foregroundStyle(isSelected ? Theme.info : Theme.mutedForeground),
                    at: CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2 - 9)
                )
            }
        }
        drawVertexHandles(&context)
    }

    /// Les poignées de sommet. Elles ne s'affichent qu'en mode Sélection : pendant un tracé
    /// elles se confondraient avec les points du mur en cours.
    private func drawVertexHandles(_ context: inout GraphicsContext) {
        guard tool == .select else { return }
        for vertex in uniqueWallVertices {
            let view = transform.toView(vertex)
            let isHovered = hoveredVertex.map {
                hypot($0.x - vertex.x, $0.y - vertex.y) < 0.002
            } ?? false
            let radius: CGFloat = isHovered ? 6.5 : 4
            let circle = Path(
                ellipseIn: CGRect(
                    x: view.x - radius, y: view.y - radius, width: radius * 2, height: radius * 2
                )
            )
            context.fill(circle, with: .color(isHovered ? Theme.info : Theme.background))
            context.stroke(
                circle, with: .color(isHovered ? Theme.info : Theme.foreground.opacity(0.55)),
                lineWidth: 1.5
            )
        }
    }

    private func drawPendingWall(_ context: inout GraphicsContext) {
        guard tool == .walls, let first = pendingWall.first else { return }
        var path = Path()
        path.move(to: transform.toView(first))
        for point in pendingWall.dropFirst() { path.addLine(to: transform.toView(point)) }
        // Le segment élastique jusqu'au curseur, avec sa cote et son angle : c'est ce qui
        // permet de tracer un mur à la bonne longueur, d'équerre, sans mesurer après coup.
        if let hoverPoint, let last = pendingWall.last {
            path.addLine(to: transform.toView(hoverPoint))
            let a = transform.toView(last)
            let b = transform.toView(hoverPoint)
            let length = hypot(hoverPoint.x - last.x, hoverPoint.y - last.y)
            var degrees = atan2(hoverPoint.y - last.y, hoverPoint.x - last.x) * 180 / .pi
            if degrees < 0 { degrees += 360 }
            context.draw(
                Text(String(format: "%.2f m • %.0f°", length, degrees))
                    .font(Theme.Font.small).foregroundStyle(Theme.info),
                at: CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2 - 12)
            )
            // Le carré d'angle droit, comme sur un plan d'architecte : il confirme d'un
            // coup d'œil que le coin est bien à 90°, sans lire l'angle.
            if pendingWall.count >= 2 {
                let previous = pendingWall[pendingWall.count - 2]
                if isRightAngle(at: last, from: previous, to: hoverPoint) {
                    drawRightAngleMark(&context, at: last, from: previous, to: hoverPoint)
                }
            }
        }
        context.stroke(
            path, with: .color(Theme.info), style: .init(lineWidth: 3, lineCap: .round, dash: [6, 4])
        )
        for (index, point) in pendingWall.enumerated() {
            let view = transform.toView(point)
            // Le point de départ est plus gros : c'est la cible sur laquelle recliquer
            // pour fermer la pièce.
            let radius: CGFloat = index == 0 ? 6 : 3.5
            context.fill(
                Path(
                    ellipseIn: CGRect(
                        x: view.x - radius, y: view.y - radius,
                        width: radius * 2, height: radius * 2
                    )
                ),
                with: .color(Theme.info)
            )
        }
    }

    private func isRightAngle(at corner: CGPoint, from previous: CGPoint, to next: CGPoint) -> Bool {
        let u = CGPoint(x: previous.x - corner.x, y: previous.y - corner.y)
        let v = CGPoint(x: next.x - corner.x, y: next.y - corner.y)
        let lengths = hypot(u.x, u.y) * hypot(v.x, v.y)
        guard lengths > 1e-6 else { return false }
        return abs((u.x * v.x + u.y * v.y) / lengths) < 0.02
    }

    private func drawRightAngleMark(
        _ context: inout GraphicsContext, at corner: CGPoint, from previous: CGPoint,
        to next: CGPoint
    ) {
        let size: Double = 12
        func unit(_ point: CGPoint) -> CGPoint {
            let view = transform.toView(point)
            let cornerView = transform.toView(corner)
            let length = hypot(view.x - cornerView.x, view.y - cornerView.y)
            guard length > 0 else { return .zero }
            return CGPoint(x: (view.x - cornerView.x) / length, y: (view.y - cornerView.y) / length)
        }
        let cornerView = transform.toView(corner)
        let u = unit(previous)
        let v = unit(next)
        var mark = Path()
        mark.move(to: CGPoint(x: cornerView.x + u.x * size, y: cornerView.y + u.y * size))
        mark.addLine(
            to: CGPoint(
                x: cornerView.x + (u.x + v.x) * size, y: cornerView.y + (u.y + v.y) * size
            )
        )
        mark.addLine(to: CGPoint(x: cornerView.x + v.x * size, y: cornerView.y + v.y * size))
        context.stroke(mark, with: .color(Theme.info), lineWidth: 1.5)
    }

    /// Le trait enceinte ↔ oreilles, avec la distance : la lecture directe de ce qui
    /// produit le délai suggéré.
    private func drawDistanceLines(_ context: inout GraphicsContext) {
        guard let listener = state.roomLayout.listener else { return }
        let listenerView = transform.toView(listener.position)
        let listenerDesignated = selection.contains(.object(listener.id))
            || hoveredObject == listener.id

        for output in state.outputs {
            let speakers = state.roomLayout.speakers(forOutput: output.id)
            guard !speakers.isEmpty else { continue }

            for speaker in speakers {
                let speakerView = transform.toView(speaker.position)
                var line = Path()
                line.move(to: speakerView)
                line.addLine(to: listenerView)
                context.stroke(
                    line, with: .color(Theme.warning.opacity(0.55)),
                    style: .init(lineWidth: 1.5, dash: [5, 4])
                )

                // La cote ne s'affiche que pour l'objet désigné. Avec trois enceintes et
                // une position d'écoute, quatre étiquettes convergeaient au même endroit
                // et se rendaient mutuellement illisibles.
                let designated = showsAllLabels || listenerDesignated
                    || selection.contains(.object(speaker.id)) || hoveredObject == speaker.id
                guard designated else { continue }

                let distance = state.roomLayout.distance(from: speaker, to: listener)
                let flat = hypot(
                    speaker.position.x - listener.position.x,
                    speaker.position.y - listener.position.y
                )
                // « 3D » n'apparaît que si la hauteur change vraiment la distance : sinon
                // la mention serait du bruit.
                let label = abs(distance - flat) > 0.02
                    ? String(format: "%.2f m (3D)", distance)
                    : String(format: "%.2f m", distance)
                context.draw(
                    Text(label).font(Theme.Font.tiny).foregroundStyle(Theme.warning),
                    at: CGPoint(
                        x: (speakerView.x + listenerView.x) / 2,
                        y: (speakerView.y + listenerView.y) / 2 - 8
                    )
                )
            }

            // Pour une paire stéréo, c'est la moyenne qui commande le délai : l'afficher
            // évite de croire que le réglage suit l'une des deux boîtes en particulier.
            if speakers.count > 1, showsAllLabels || listenerDesignated,
                let mean = state.roomLayout.distanceToListener(outputID: output.id)
            {
                let centroid = speakers.reduce(CGPoint.zero) {
                    CGPoint(x: $0.x + $1.position.x, y: $0.y + $1.position.y)
                }
                let middle = transform.toView(
                    CGPoint(
                        x: centroid.x / Double(speakers.count),
                        y: centroid.y / Double(speakers.count)
                    )
                )
                context.draw(
                    Text(String(format: "moyenne %.2f m", mean))
                        .font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.warning),
                    at: CGPoint(
                        x: (middle.x + listenerView.x) / 2, y: (middle.y + listenerView.y) / 2 + 8
                    )
                )
            }
        }
    }

    private func draw(_ object: RoomObject, in context: inout GraphicsContext) {
        let viewCenter = transform.toView(object.position)
        let width = object.size.width * scale
        let height = object.size.height * scale
        let isSelected = selection.contains(.object(object.id))

        context.drawLayer { layer in
            layer.translateBy(x: viewCenter.x, y: viewCenter.y)
            layer.rotate(by: .degrees(object.rotation))
            let rect = CGRect(x: -width / 2, y: -height / 2, width: width, height: height)
            let shape: Path = switch object.shape {
            case .ellipse:
                Path(ellipseIn: rect)
            case .lShape:
                // Le contour vient du modèle, converti en points d'écran : le dessin et le
                // test de clic partagent ainsi la même définition et ne peuvent pas diverger.
                Path { path in
                    let points = object.localPolygon.map {
                        CGPoint(x: $0.x * scale, y: $0.y * scale)
                    }
                    guard let first = points.first else { return }
                    path.move(to: first)
                    for point in points.dropFirst() { path.addLine(to: point) }
                    path.closeSubpath()
                }
            case .rectangle:
                Path(roundedRect: rect, cornerRadius: min(6, min(width, height) / 3))
            }
            layer.fill(shape, with: .color(fillColor(for: object)))
            layer.stroke(
                shape, with: .color(isSelected ? Theme.info : Theme.border),
                lineWidth: isSelected ? 2.5 : 1
            )
            // Le trait sur un bord marque l'avant du meuble : sans repère d'orientation,
            // faire tourner un canapé ne se voit pas et le réglage devient incontrôlable.
            // Sans objet sur un meuble rond, qui n'a pas de face.
            if !object.isRound {
                var front = Path()
                front.move(to: CGPoint(x: -width / 2, y: -height / 2))
                front.addLine(to: CGPoint(x: width / 2, y: -height / 2))
                layer.stroke(front, with: .color(Theme.foreground.opacity(0.5)), lineWidth: 2.5)
            }
        }

        // Icône et libellés hors du calque tourné : un texte pivoté serait illisible dès
        // qu'un meuble est de travers.
        //
        // Le point d'ancrage vient du modèle et suit la rotation de l'objet — c'est ce qui
        // met l'icône du canapé d'angle au milieu de sa méridienne quel que soit son sens.
        let angle = object.rotation * .pi / 180
        let offset = object.iconOffset
        let iconPoint = CGPoint(
            x: viewCenter.x + (offset.x * cos(angle) - offset.y * sin(angle)) * scale,
            y: viewCenter.y + (offset.x * sin(angle) + offset.y * cos(angle)) * scale
        )

        if object.kind == .listener {
            drawListenerFigure(&context, at: iconPoint, rotation: object.rotation)
        } else {
            let iconSize = min(22, max(9, min(width, height) * 0.5))
            // Une icône plus grande que l'objet déborde et brouille ses voisins ; sous
            // 9 points elle n'est de toute façon plus lisible. Mieux vaut rien.
            if min(width, height) > 12 {
                context.draw(
                    Text(Image(systemName: object.kind.symbol))
                        .font(.system(size: iconSize))
                        .foregroundStyle(Theme.foreground.opacity(0.75)),
                    at: iconPoint
                )
            }
        }

        let isHovered = hoveredObject == object.id
        // Le nom n'apparaît que si l'objet est assez large pour le porter, ou s'il est
        // désigné. C'est le principal remède à l'encombrement : sur un plan meublé, une
        // dizaine d'étiquettes permanentes se recouvrent et plus rien ne se lit.
        if showsAllLabels || isSelected || isHovered || width >= 64 {
            context.draw(
                Text(object.name.isEmpty ? object.kind.label : object.name)
                    .font(.caption2).bold(),
                at: CGPoint(x: viewCenter.x, y: viewCenter.y - height / 2 - 9)
            )
        }
        // La hauteur ne sert qu'au moment où on la règle : à la demande uniquement.
        if showsAllLabels || isSelected || isHovered {
            context.draw(
                Text(String(format: "%.2f m", object.elevation))
                    .font(.system(size: 9)).foregroundStyle(Theme.mutedForeground),
                at: CGPoint(x: viewCenter.x, y: viewCenter.y + height / 2 + 8)
            )
        }
    }

    /// La position d'écoute, dessinée **vue de dessus**.
    ///
    /// Le symbole système `figure.seated.side` est une silhouette de profil : posée sur un
    /// plan vu du dessus, elle jure avec tout le reste et ne dit pas où sont les oreilles —
    /// qui sont pourtant le seul point qui compte ici, puisque toutes les distances y
    /// aboutissent. On dessine donc des épaules, une tête, deux oreilles et le regard.
    private func drawListenerFigure(
        _ context: inout GraphicsContext, at point: CGPoint, rotation: Double
    ) {
        // Tailles anthropométriques ramenées à l'échelle du plan, bornées pour rester
        // lisibles quand on dézoome.
        let head = max(7, min(0.18 * scale, 26))
        let shoulders = head * 2.1

        context.drawLayer { layer in
            layer.translateBy(x: point.x, y: point.y)
            layer.rotate(by: .degrees(rotation))

            // Épaules : une ellipse large et peu profonde, qui donne l'orientation.
            layer.fill(
                Path(
                    ellipseIn: CGRect(
                        x: -shoulders / 2, y: -head * 0.35, width: shoulders, height: head * 1.15
                    )
                ),
                with: .color(Theme.warning.opacity(0.85))
            )

            // Tête.
            let headRect = CGRect(x: -head / 2, y: -head / 2, width: head, height: head)
            layer.fill(Path(ellipseIn: headRect), with: .color(Theme.warning))
            layer.stroke(
                Path(ellipseIn: headRect), with: .color(Theme.foreground.opacity(0.55)), lineWidth: 1
            )

            // Les deux oreilles : c'est là qu'arrivent les distances calculées.
            let ear = max(2, head * 0.17)
            for side in [-1.0, 1.0] {
                layer.fill(
                    Path(
                        ellipseIn: CGRect(
                            x: side * head * 0.5 - ear / 2, y: -ear / 2,
                            width: ear, height: ear * 1.6
                        )
                    ),
                    with: .color(Theme.foreground.opacity(0.6))
                )
            }

            // Nez : un petit triangle vers l'avant, qui dit dans quel sens on regarde.
            var nose = Path()
            nose.move(to: CGPoint(x: -head * 0.18, y: -head * 0.45))
            nose.addLine(to: CGPoint(x: 0, y: -head * 0.72))
            nose.addLine(to: CGPoint(x: head * 0.18, y: -head * 0.45))
            nose.closeSubpath()
            layer.fill(nose, with: .color(Theme.warning))
        }
    }

    private func fillColor(for object: RoomObject) -> Color {
        switch object.kind {
        case .speaker: Theme.info.opacity(0.30)
        case .listener: Theme.warning.opacity(0.28)
        case .tv: Theme.foreground.opacity(0.22)
        default: Theme.muted
        }
    }

    // MARK: - Cadrage

    private func zoom(to newScale: Double, around anchor: CGPoint) {
        guard let origin else { return }
        let clamped = min(max(newScale, scaleRange.lowerBound), scaleRange.upperBound)
        // Le point sous le curseur ne doit pas bouger : c'est ce qui rend un zoom
        // utilisable pour viser un détail.
        let model = PlanTransform(scale: scale, origin: origin).toModel(anchor)
        self.scale = clamped
        self.origin = CGPoint(x: anchor.x - model.x * clamped, y: anchor.y - model.y * clamped)
    }

    private func fitToContent(in size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        let fitted = PlanTransform.fitting(state.roomLayout, in: size)
        // L'échelle proposée est bornée — un mur droit a une emprise de hauteur nulle et
        // ferait diverger le calcul — puis le centrage est refait avec l'échelle retenue.
        scale = min(max(fitted.scale, scaleRange.lowerBound), scaleRange.upperBound)
        if let bounds = state.roomLayout.bounds {
            origin = CGPoint(
                x: (size.width - bounds.width * scale) / 2 - bounds.minX * scale,
                y: (size.height - bounds.height * scale) / 2 - bounds.minY * scale
            )
        } else {
            origin = CGPoint(x: size.width / 2 - 3 * scale, y: size.height / 2 - 3 * scale)
        }
    }

    // MARK: - Image de fond

    private func loadBackgroundImage() {
        guard let fileName = state.roomLayout.background?.fileName else {
            backgroundImage = nil
            return
        }
        backgroundImage = NSImage(
            contentsOf: RoomLayout.backgroundsDirectory.appending(path: fileName)
        )
    }

    /// L'image est **recopiée** dans le dossier de l'app plutôt que référencée à son
    /// emplacement d'origine : un plan qu'on a déplacé ou vidé de sa corbeille ne doit pas
    /// faire disparaître le fond d'un plan déjà calibré.
    private func importBackground(from url: URL) {
        let fileName = UUID().uuidString + "." + (url.pathExtension.isEmpty ? "png" : url.pathExtension)
        let destination = RoomLayout.backgroundsDirectory.appending(path: fileName)
        do {
            try FileManager.default.copyItem(at: url, to: destination)
        } catch {
            return
        }
        guard let image = NSImage(contentsOf: destination) else { return }
        let pixels = pixelSize(of: image)

        // Échelle de départ : on suppose que l'image couvre environ 8 m de large. C'est
        // arbitraire et faux, mais ça la rend visible à une taille plausible — le calibrage
        // est là pour la corriger, et une valeur par défaut absurde le rendrait pénible.
        let metersPerPixel = 8 / max(pixels.width, 1)
        let modelCenter = transform.toModel(center)
        state.roomLayout.background = RoomLayout.Background(
            fileName: fileName,
            origin: CGPoint(
                x: modelCenter.x - pixels.width * metersPerPixel / 2,
                y: modelCenter.y - pixels.height * metersPerPixel / 2
            ),
            metersPerPixel: metersPerPixel,
            pixelWidth: pixels.width,
            pixelHeight: pixels.height,
            isLocked: false
        )
        backgroundImage = image
        tool = .calibrate
        state.persistRoomLayout()
    }

    /// Applique le calibrage : la mesure tracée doit valoir la longueur saisie.
    ///
    /// On redimensionne l'image **autour du premier point cliqué**, qui reste donc fixe.
    /// Sans ce point d'ancrage, le plan se déplacerait en même temps qu'il change de
    /// taille et il faudrait le recaler après chaque calibrage.
    private func applyCalibration() {
        defer {
            calibration = []
            calibrationLength = ""
        }
        guard calibration.count == 2,
            var background = state.roomLayout.background,
            let realLength = Double(calibrationLength.replacingOccurrences(of: ",", with: ".")),
            realLength > 0
        else { return }

        let measured = hypot(
            calibration[1].x - calibration[0].x, calibration[1].y - calibration[0].y
        )
        guard measured > 1e-6 else { return }

        let factor = realLength / measured
        let anchor = calibration[0]
        background.metersPerPixel *= factor
        background.origin = CGPoint(
            x: anchor.x + (background.origin.x - anchor.x) * factor,
            y: anchor.y + (background.origin.y - anchor.y) * factor
        )
        background.isLocked = true
        state.roomLayout.background = background
        tool = .walls
        state.persistRoomLayout()
    }

    // MARK: - Magnétisme

    private func gridSnapped(_ point: CGPoint) -> CGPoint {
        CGPoint(x: (point.x / snap).rounded() * snap, y: (point.y / snap).rounded() * snap)
    }

    /// Le magnétisme du tracé, par ordre de priorité.
    ///
    /// 1. **Un angle de mur existant** l'emporte sur tout : c'est ce qui permet de raccorder
    ///    exactement, sans laisser un interstice invisible au zoom courant.
    /// 2. **L'angle depuis le point précédent**, arrondi à 15°, longueur arrondie au pas de
    ///    la grille. C'est ce qui rend les coins d'équerre sans y penser.
    /// 3. Sinon la grille seule.
    ///
    /// `⌥` désactive 2 et 3 pour tracer un pan de travers, cas rare mais réel.
    private func snapPoint(_ raw: CGPoint, from anchor: CGPoint?) -> CGPoint {
        if let vertex = nearestVertex(to: raw) { return vertex }
        guard !NSEvent.modifierFlags.contains(.option) else { return raw }
        guard let anchor else { return gridSnapped(raw) }

        let dx = raw.x - anchor.x
        let dy = raw.y - anchor.y
        let length = hypot(dx, dy)
        guard length > 0.01 else { return gridSnapped(raw) }

        let step = angleStep * .pi / 180
        let angle = (atan2(dy, dx) / step).rounded() * step
        let snappedLength = (length / snap).rounded() * snap
        return CGPoint(
            x: anchor.x + cos(angle) * snappedLength, y: anchor.y + sin(angle) * snappedLength
        )
    }

    private func nearestVertex(to point: CGPoint) -> CGPoint? {
        let tolerance = snapRadius / scale
        let candidates = state.roomLayout.wallVertices + pendingWall.dropLast()
        return candidates
            .map { ($0, hypot($0.x - point.x, $0.y - point.y)) }
            .filter { $0.1 < tolerance }
            .min { $0.1 < $1.1 }?.0
    }

    /// Sommet de mur sous le point, en excluant ceux qu'on est justement en train de
    /// déplacer — sans quoi une poignée s'accrocherait à elle-même et resterait figée.
    private func nearestWallVertex(
        to point: CGPoint, excluding excluded: [VertexRef] = []
    ) -> CGPoint? {
        let tolerance = snapRadius / scale
        return state.roomLayout.walls
            .flatMap { wall -> [CGPoint] in
                var points: [CGPoint] = []
                if !excluded.contains(VertexRef(id: wall.id, isStart: true)) { points.append(wall.a) }
                if !excluded.contains(VertexRef(id: wall.id, isStart: false)) { points.append(wall.b) }
                return points
            }
            .map { ($0, hypot($0.x - point.x, $0.y - point.y)) }
            .filter { $0.1 < tolerance }
            .min { $0.1 < $1.1 }?.0
    }

    /// Toutes les extrémités confondues avec ce point — c'est-à-dire le coin entier.
    private func vertexRefs(at point: CGPoint) -> [VertexRef] {
        let epsilon = 0.002
        return state.roomLayout.walls.flatMap { wall -> [VertexRef] in
            var refs: [VertexRef] = []
            if hypot(wall.a.x - point.x, wall.a.y - point.y) < epsilon {
                refs.append(VertexRef(id: wall.id, isStart: true))
            }
            if hypot(wall.b.x - point.x, wall.b.y - point.y) < epsilon {
                refs.append(VertexRef(id: wall.id, isStart: false))
            }
            return refs
        }
    }

    /// Les sommets sans doublon, au millimètre — un coin partagé par quatre segments ne
    /// doit dessiner qu'une poignée.
    private var uniqueWallVertices: [CGPoint] {
        var seen: Set<[Int]> = []
        var result: [CGPoint] = []
        for vertex in state.roomLayout.wallVertices {
            let key = [Int((vertex.x * 1000).rounded()), Int((vertex.y * 1000).rounded())]
            if seen.insert(key).inserted { result.append(vertex) }
        }
        return result
    }

    // MARK: - Interaction

    /// **Un seul geste** pour le clic, le déplacement d'objet et le panoramique.
    ///
    /// Une version précédente superposait `.onTapGesture` et un `DragGesture` : sur macOS
    /// le moindre tremblement de souris faisait gagner le glissé, et le clic — donc la pose
    /// d'un point de mur — se perdait par intermittence. Distinguer les deux à la fin du
    /// geste, sur la distance parcourue, est le seul moyen fiable.
    private var planGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard let origin else { return }
                if drag == nil {
                    let start = transform.toModel(value.startLocation)
                    if let background = state.roomLayout.background, !background.isLocked {
                        // Image déverrouillée : le glissé la cale, il ne déplace pas la vue.
                        // Les deux gestes seraient sinon indiscernables.
                        drag = .moveBackground(startOrigin: background.origin)
                    } else if tool == .select, let vertex = nearestWallVertex(to: start) {
                        // Les sommets priment sur les meubles : ils sont petits, on les
                        // vise délibérément, et un canapé posé dans un coin les rendrait
                        // sinon inatteignables.
                        drag = .moveVertex(
                            refs: vertexRefs(at: vertex),
                            offset: CGSize(
                                width: vertex.x - start.x, height: vertex.y - start.y
                            )
                        )
                    } else if tool == .select, let hit = object(at: start) {
                        if !selection.contains(.object(hit.id)) { selection = [.object(hit.id)] }
                        // On mémorise la prise plutôt que de recentrer l'objet sous le
                        // curseur : sinon un canapé de 2 m saute au premier pixel.
                        drag = .move(
                            id: hit.id,
                            offset: CGSize(
                                width: hit.position.x - start.x, height: hit.position.y - start.y
                            )
                        )
                    } else {
                        drag = .pan(startOrigin: origin)
                    }
                }
                switch drag {
                case let .move(id, offset):
                    guard let index = index(ofObject: id) else { return }
                    let model = transform.toModel(value.location)
                    state.roomLayout.objects[index].position = gridSnapped(
                        CGPoint(x: model.x + offset.width, y: model.y + offset.height)
                    )
                case let .moveVertex(refs, offset):
                    let model = transform.toModel(value.location)
                    let raw = CGPoint(x: model.x + offset.width, y: model.y + offset.height)
                    // Souder à un sommet voisin l'emporte sur la grille : c'est ainsi qu'on
                    // referme un coin resté ouvert, ce que le pas de 5 cm ne garantit pas.
                    let target = nearestWallVertex(to: raw, excluding: refs) ?? gridSnapped(raw)
                    for ref in refs {
                        guard let index = state.roomLayout.walls.firstIndex(where: {
                            $0.id == ref.id
                        }) else { continue }
                        if ref.isStart {
                            state.roomLayout.walls[index].a = target
                        } else {
                            state.roomLayout.walls[index].b = target
                        }
                    }
                case let .moveBackground(startOrigin):
                    state.roomLayout.background?.origin = CGPoint(
                        x: startOrigin.x + value.translation.width / scale,
                        y: startOrigin.y + value.translation.height / scale
                    )
                case let .pan(startOrigin):
                    self.origin = CGPoint(
                        x: startOrigin.x + value.translation.width,
                        y: startOrigin.y + value.translation.height
                    )
                case nil:
                    break
                }
            }
            .onEnded { value in
                let travelled = hypot(value.translation.width, value.translation.height)
                if travelled < 4 {
                    // Immobile : c'était un clic. On défait le mouvement parasite.
                    switch drag {
                    case let .pan(startOrigin): origin = startOrigin
                    case let .moveBackground(startOrigin):
                        state.roomLayout.background?.origin = startOrigin
                    default: break
                    }
                    handleClick(at: value.startLocation)
                } else {
                    switch drag {
                    case .move, .moveVertex, .moveBackground: state.persistRoomLayout()
                    default: break
                    }
                }
                drag = nil
            }
    }

    private func handleClick(at location: CGPoint) {
        let model = transform.toModel(location)
        switch tool {
        case .calibrate:
            calibration.append(model)
            if calibration.count == 2 { showsCalibrationPrompt = true }
        case .walls:
            let point = snapPoint(model, from: pendingWall.last)
            // Recliquer sur le premier point ferme la pièce : c'est le geste attendu, et ça
            // évite un bouton de plus pour le cas le plus courant.
            if let first = pendingWall.first, pendingWall.count >= 2,
                hypot(point.x - first.x, point.y - first.y) * scale < snapRadius
            {
                commitPendingWall(closing: true)
            } else {
                pendingWall.append(point)
            }
        case .select:
            let additive = NSEvent.modifierFlags.contains(.shift)
                || NSEvent.modifierFlags.contains(.command)
            guard let element = element(at: model) else {
                // Cliquer dans le vide désélectionne — sauf en ⇧-clic, où l'on est en
                // train de constituer une sélection et où tout perdre serait brutal.
                if !additive { selection = [] }
                return
            }
            if additive {
                if selection.contains(element) {
                    selection.remove(element)
                } else {
                    selection.insert(element)
                }
            } else {
                selection = [element]
            }
        }
    }

    /// Élément sous le point. Les meubles priment sur les murs : ils sont dessinés
    /// par-dessus, c'est donc eux qu'on croit viser.
    private func element(at model: CGPoint) -> PlanElement? {
        if let object = object(at: model) { return .object(object.id) }
        let tolerance = snapRadius / scale
        if let wall = state.roomLayout.walls
            .map({ ($0, $0.distance(to: model)) })
            .filter({ $0.1 < tolerance })
            .min(by: { $0.1 < $1.1 })?.0
        {
            return .wall(wall.id)
        }
        return nil
    }

    /// Objet sous le point, du dessus vers le dessous : le dernier dessiné est celui qu'on
    /// voit, c'est donc lui qu'on attrape.
    private func object(at model: CGPoint) -> RoomObject? {
        state.roomLayout.objects.last { $0.contains(model) }
    }

    private func index(ofObject id: UUID) -> Int? {
        state.roomLayout.objects.firstIndex { $0.id == id }
    }

    private func rotatePlan(clockwise: Bool) {
        commitPendingWall()
        state.roomLayout = state.roomLayout.rotatedQuarterTurn(clockwise: clockwise)
        state.persistRoomLayout()
        // Le plan a changé d'emprise : sans recadrage il partirait hors de la fenêtre, et
        // on croirait l'avoir perdu.
        fitToContent(in: viewSize)
    }

    private func selectAll() {
        selection = Set(
            state.roomLayout.walls.map { PlanElement.wall($0.id) }
                + state.roomLayout.objects.map { PlanElement.object($0.id) }
        )
    }

    /// Supprime **exactement** ce qui est sélectionné, murs et meubles confondus.
    private func deleteSelection() {
        guard !selection.isEmpty else { return }
        var walls: Set<UUID> = []
        var objects: Set<UUID> = []
        for element in selection {
            switch element {
            case let .wall(id): walls.insert(id)
            case let .object(id): objects.insert(id)
            }
        }
        // L'ordre compte : on vide la sélection **avant** de toucher aux tableaux, sinon
        // l'inspecteur est réévalué le temps d'une image en désignant un objet disparu.
        selection = []
        state.roomLayout.walls.removeAll { walls.contains($0.id) }
        state.roomLayout.objects.removeAll { objects.contains($0.id) }
        state.persistRoomLayout()
    }

    private func commitPendingWall(closing: Bool = false) {
        defer { pendingWall = [] }
        guard pendingWall.count >= 2 else { return }
        var points = pendingWall
        if closing, let first = points.first { points.append(first) }
        for (a, b) in zip(points, points.dropFirst()) {
            state.roomLayout.walls.append(RoomLayout.WallSegment(a: a, b: b))
        }
        state.persistRoomLayout()
        // Retour à la sélection une fois le tracé validé. Rester sur l'outil Murs faisait
        // qu'un clic destiné à sélectionner un mur posait un point de plus — le défaut le
        // plus déroutant de l'éditeur, parce que rien à l'écran ne disait pourquoi.
        if closing { tool = .select }
    }

    // MARK: - Inspecteur

    /// Un seul meuble sélectionné : ses réglages. Plusieurs éléments, ou des murs : un
    /// résumé et de quoi les effacer. Il n'y a rien à régler finement sur un mur — sa
    /// longueur se lit sur le plan et se change en le retraçant.
    @ViewBuilder
    private var inspector: some View {
        if selection.count == 1, case let .object(id) = selection.first!,
            let snapshot = state.roomLayout.objects.first(where: { $0.id == id })
        {
            ObjectInspector(
                // Liaison **par identité**, jamais par index. Supprimer un objet invalide
                // son index, mais SwiftUI réévalue le getter avant de reconstruire la vue :
                // une liaison indexée plantait l'app à chaque suppression. Le repli sur
                // l'instantané couvre l'image où l'objet n'existe déjà plus.
                object: Binding(
                    get: { state.roomLayout.objects.first { $0.id == id } ?? snapshot },
                    set: { newValue in
                        guard let index = index(ofObject: id) else { return }
                        state.roomLayout.objects[index] = newValue
                    }
                ),
                outputs: state.outputs,
                onCommit: { state.persistRoomLayout() },
                onDelete: deleteSelection
            )
            .id(id)
        } else if !selection.isEmpty {
            selectionSummary
        } else {
            HStack {
                if let dimensions = state.roomLayout.dimensions, dimensions.width > 0 {
                    Label(
                        String(format: "%.2f m × %.2f m", dimensions.width, dimensions.height),
                        systemImage: "ruler"
                    )
                } else {
                    Label(
                        "Choisis « Murs » et clique pour tracer, puis pose les meubles",
                        systemImage: "hand.point.up.left"
                    )
                }
                Spacer()
            }
            .shadMuted()
            .padding(10)
        }
    }

    private var selectionSummary: some View {
        let wallIDs = selection.compactMap { element -> UUID? in
            if case let .wall(id) = element { return id }
            return nil
        }
        let objectCount = selection.count - wallIDs.count
        let totalLength = state.roomLayout.walls
            .filter { wallIDs.contains($0.id) }
            .reduce(0) { $0 + $1.length }

        return HStack(spacing: 12) {
            if !wallIDs.isEmpty {
                Label(
                    "\(wallIDs.count) mur\(wallIDs.count > 1 ? "s" : "") — \(String(format: "%.2f m", totalLength)) au total",
                    systemImage: "square.split.bottomrightquarter"
                )
            }
            if objectCount > 0 {
                Label("\(objectCount) meuble\(objectCount > 1 ? "s" : "")", systemImage: "cube")
            }
            Spacer()
            Button(action: deleteSelection) {
                Label("Supprimer", systemImage: "trash")
            }
            .shadButton(.destructive, size: .small)
        }
        .font(Theme.Font.small)
        .foregroundStyle(Theme.mutedForeground)
        .padding(10)
    }
}

/// Réglages fins de l'objet sélectionné.
///
/// Des champs numériques plutôt que des poignées sur le plan : une hauteur ne se manipule
/// pas dans une vue du dessus, et une rotation au degré près à la souris est un exercice de
/// patience. Le plan sert au placement, l'inspecteur aux valeurs.
private struct ObjectInspector: View {
    @Binding var object: RoomObject
    let outputs: [OutputState]
    let onCommit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(
                    object.name.isEmpty ? object.kind.label : object.name,
                    systemImage: object.kind.symbol
                )
                .font(Theme.Font.title)
                Spacer()
                Button(action: onDelete) {
                    Image(systemName: "trash").font(.system(size: 11))
                }
                .shadButton(.ghost, size: .small)
                .help("Supprimer (touche Suppr)")
            }

            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
                GridRow {
                    Text("Position").shadMuted()
                    field("X", value: $object.position.x.asDouble)
                    field("Y", value: $object.position.y.asDouble)
                }
                GridRow {
                    Text(object.isRound ? "Diamètre" : "Taille")
                        .shadMuted()
                    if object.isRound {
                        // Un seul champ pour un meuble rond : deux cotes indépendantes
                        // permettraient d'en faire une ellipse par mégarde.
                        field("Ø", value: diameter)
                    } else {
                        field("L", value: $object.size.width.asDouble)
                        field("P", value: $object.size.height.asDouble)
                    }
                }
                if object.shape == .lShape {
                    GridRow {
                        Text("Angle").shadMuted()
                        field("Prof.", value: $object.armThickness)
                        Button {
                            object.isMirrored.toggle()
                        } label: {
                            Label(
                                object.isMirrored ? "L à droite" : "L à gauche",
                                systemImage: "arrow.left.arrow.right"
                            )
                        }
                        .shadButton(.outline, size: .small)
                        .help("Renvoie le retour du canapé de l'autre côté")
                    }
                }
                GridRow {
                    Text("Hauteur").shadMuted()
                    field(heightLabel, value: $object.elevation)
                    Text(heightHint).font(Theme.Font.tiny).foregroundStyle(Theme.mutedForeground)
                }
                if !object.isRound {
                    GridRow {
                        Text("Orientation").shadMuted()
                        ShadSlider(value: $object.rotation, range: 0...360, step: 5)
                        Text(String(format: "%.0f°", object.rotation))
                            .font(Theme.Font.small.monospacedDigit())
                    }
                }
                if case let .speaker(outputID) = object.kind {
                    GridRow {
                        Text("Sortie").shadMuted()
                        // C'est ce rattachement qui fait entrer l'enceinte dans le calcul
                        // du délai : une enceinte non rattachée n'est qu'un meuble.
                        Picker("", selection: outputBinding(current: outputID)) {
                            Text("Aucune").tag(String?.none)
                            ForEach(outputs) { output in
                                Text(output.displayName).tag(String?.some(output.id))
                            }
                        }
                        .labelsHidden()
                        .controlSize(.small)
                        Text(outputID == nil ? "hors du calcul" : "")
                            .font(Theme.Font.tiny).foregroundStyle(Theme.mutedForeground)
                    }
                }
            }
        }
        .padding(8)
        .onChange(of: object) { _, _ in onCommit() }
    }

    private var diameter: Binding<Double> {
        Binding(
            get: { Double(object.size.width) },
            set: { object.size = CGSize(width: $0, height: $0) }
        )
    }

    private func outputBinding(current: String?) -> Binding<String?> {
        Binding(
            get: { current },
            set: { object.kind = .speaker(outputID: $0) }
        )
    }

    /// La hauteur ne désigne pas la même chose selon l'objet, et l'ambiguïté se paierait
    /// directement en millisecondes de délai faux.
    private var heightLabel: String {
        switch object.kind {
        case .listener: "Oreilles"
        case .speaker: "H.-parleur"
        default: "Centre"
        }
    }

    private var heightHint: String {
        switch object.kind {
        case .listener: "hauteur d'oreilles, assis"
        case .speaker: "hauteur du haut-parleur"
        case .tv: "centre de l'écran"
        case .sofa: "hauteur d'assise"
        case .shelf, .tvStand: "hauteur du dessus"
        default: "hauteur du plateau"
        }
    }

    private func field(_ label: String, value: Binding<Double>) -> some View {
        HStack(spacing: 3) {
            Text(label).font(Theme.Font.tiny).foregroundStyle(Theme.mutedForeground)
            TextField("", value: value, format: .number.precision(.fractionLength(0...2)))
                .textFieldStyle(.plain)
                .font(Theme.Font.small.monospacedDigit())
                .frame(width: 46)
                .multilineTextAlignment(.trailing)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Theme.background, in: RoundedRectangle(cornerRadius: Theme.Radius.sm))
                .overlay {
                    RoundedRectangle(cornerRadius: Theme.Radius.sm)
                        .strokeBorder(Theme.border, lineWidth: 1)
                }
            Text("m").font(Theme.Font.tiny).foregroundStyle(Theme.mutedForeground)
        }
    }
}

/// `CGFloat` et `Double` sont le même type sur cette plateforme mais restent distincts pour
/// le système de types : un `Binding<CGFloat>` ne se passe pas là où un `Binding<Double>`
/// est attendu. Ce pont évite d'écrire la conversion à chaque champ de l'inspecteur.
extension Binding where Value == CGFloat {
    var asDouble: Binding<Double> {
        Binding<Double>(get: { Double(wrappedValue) }, set: { wrappedValue = CGFloat($0) })
    }
}

#Preview {
    @Previewable @State var state = BridgeState.previewWithRoom()
    RoomPlanView(state: state)
        .frame(width: 520, height: 660)
}
