//
//  RoomPlanView.swift
//  AirplayPersonalBridge
//

import AppKit
import AudioCore
import OSLog
import SwiftUI
import UniformTypeIdentifiers

/// L'éditeur de plan (CDC section 9, niveau « 2D vu du dessus », l'option retenue).
///
/// On trace des murs, on y pose des meubles, et chaque objet porte une hauteur. Ça reste
/// délibérément loin d'un logiciel d'architecture : pas de catalogue, pas de cotation. Seul
/// le trajet du son jusqu'aux oreilles entre dans un calcul. Portes, fenêtres et tapis n'y
/// participent pas : ce sont des repères, qui servent à reconnaître sa pièce d'un coup d'œil.
///
/// Cette vue porte l'édition et l'état d'interface ; le dessin vit dans `PlanRenderer`, ce
/// qui permet de le rendre hors de l'app.
///
/// **La vue ne se recadre jamais toute seule.** Une première version rejouait
/// `PlanTransform.fitting` à chaque modification : le plan sautait sous le curseur à chaque
/// clic, et sur un mur droit — dont l'emprise a une hauteur nulle — le zoom partait à
/// l'infini. L'échelle et le cadrage sont donc de l'état, que seul l'utilisateur change.
struct RoomPlanView: View {
    @Bindable var state: BridgeState
    /// La feuille de diagnostic : la barre d'outils de la fenêtre est celle de cette colonne.
    var showDiagnostics: () -> Void = {}

    enum Tool: String, CaseIterable, Identifiable {
        case select = "Sélection"
        case walls = "Murs"
        /// Trace une longueur connue sur l'image de fond pour en déduire son échelle.
        case calibrate = "Calibrer"
        var id: String { rawValue }

        var symbol: String {
            switch self {
            case .select: "cursorarrow"
            case .walls: "pencil.line"
            case .calibrate: "ruler"
            }
        }
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
    /// L'utilisateur a déplacé, zoomé ou recadré la vue : elle ne se recadre plus jamais d'elle-même.
    /// Jusque-là, le cadrage automatique suit la taille de la vue, qui passe par plusieurs valeurs
    /// pendant que la fenêtre se met en place.
    @State private var isFramedByUser = false

    @State private var drag: DragMode?
    /// Le plan tel qu'il était au début du glissé en cours. Il n'entre dans la pile
    /// d'annulation qu'à la fin, et seulement si le geste a vraiment déplacé quelque chose.
    @State private var planBeforeDrag: RoomLayout?
    @State private var history = PlanHistory()

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

    // MARK: Inspecteur

    @State private var showsInspector: Bool
    /// Ouvert par le bouton de la barre d'outils : il reste ouvert quand la sélection se vide, et
    /// montre alors le plan lui-même. Ouvert par une sélection, il se referme avec elle.
    @State private var isInspectorPinned = false

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
    /// En deçà de cette course, en points d'écran, un geste est un clic et ne déplace rien.
    private let clickTolerance: Double = 4
    private let scaleRange: ClosedRange<Double> = 12...400

    private static let log = Logger(subsystem: AudioLog.subsystem, category: "plan")

    private var transform: PlanTransform {
        PlanTransform(scale: scale, origin: origin ?? .zero)
    }

    init(
        state: BridgeState, initialSelection: Set<PlanElement> = [], showDiagnostics: @escaping () -> Void = {}
    ) {
        self.state = state
        self.showDiagnostics = showDiagnostics
        _selection = State(initialValue: initialSelection)
        _showsInspector = State(initialValue: !initialSelection.isEmpty)
    }

    private var renderer: PlanRenderer {
        PlanRenderer(
            layout: state.roomLayout, transform: transform, outputIDs: state.outputIDsDrawnOnPlan,
            selection: selection, hoveredObject: hoveredObject, hoveredVertex: hoveredVertex,
            showsAllLabels: showsAllLabels, showsVertexHandles: tool == .select,
            backgroundImage: backgroundImage
        )
    }

    /// Le plan plein cadre, prolongé sous la barre latérale de verre ; par-dessus, en verre, ce qui le
    /// pilote sur place. Les outils sont dans la barre d'outils, l'objet sélectionné dans l'inspecteur.
    var body: some View {
        planArea
            .overlay(alignment: .bottomTrailing) { zoomControls }
            // L'aide passe en bas à gauche : en haut elle recouvrait la première rangée du plan.
            .overlay(alignment: .bottomLeading) { hint }
            .overlay(alignment: .top) { wallDrawingControls }
            .toolbar { planToolbar }
            .inspector(isPresented: $showsInspector) {
                inspector
                    .inspectorColumnWidth(min: 270, ideal: 300, max: 380)
            }
            .onDeleteCommand(perform: deleteSelection)
            // Changer d'objet clôt les retouches en cours : les réglages d'un autre meuble sont
            // un nouveau pas d'annulation, pas la suite du précédent.
            .onChange(of: selection) { _, newSelection in
                history.endGroup()
                if !newSelection.isEmpty {
                    showsInspector = true
                } else if !isInspectorPinned {
                    showsInspector = false
                }
            }
            .onChange(of: showsInspector) { _, isShown in
                if !isShown { isInspectorPinned = false }
            }
    }

    // MARK: - Zone de dessin

    private var planArea: some View {
        Canvas { context, size in
            guard origin != nil else { return }
            renderer.draw(in: &context, size: size)
            drawCalibration(&context)
            drawPendingWall(&context)
        }
        .background(PlanPalette.canvas)
        .contentShape(Rectangle())
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
            let previous = viewSize
            viewSize = size
            // Le premier cadrage est le seul qui soit automatique : il suit la vue tant que
            // l'utilisateur n'a pas pris la main.
            if !isFramedByUser, size.width > 0 {
                fitToContent(in: size)
            } else if let current = origin, previous.width > 0 {
                // L'inspecteur qui s'ouvre, la barre latérale qui se replie : le plan garde son centre
                // à l'écran, comme une carte, au lieu de filer sous le panneau qui vient d'apparaître.
                origin = CGPoint(
                    x: current.x + (size.width - previous.width) / 2,
                    y: current.y + (size.height - previous.height) / 2
                )
            }
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
                hoveredObject = nil
                if tool == .select, case let .object(id) = element(at: model) {
                    hoveredObject = id
                }
            } else {
                hoverPoint = nil
                hoveredVertex = nil
                hoveredObject = nil
            }
        }
        .frame(minHeight: 260)
        // Sous la barre latérale de verre, le plan se prolonge en reflet flouté : la fenêtre se lit
        // comme un seul contenu, et non comme une colonne de commandes collée à un dessin.
        .backgroundExtensionEffect()
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

    // MARK: - Commandes flottantes

    /// Le zoom, comme celui de Plans : des boutons de verre posés sur le contenu, dans l'angle.
    private var zoomControls: some View {
        GlassEffectContainer(spacing: 8) {
            HStack(spacing: 8) {
                Text(String(format: "%.0f px/m", scale))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .frame(height: 28)
                    .floatingGlass(in: Capsule())
                    .accessibilityLabel("Échelle")
                    .accessibilityValue(String(format: "%.0f points par mètre", scale))

                HStack(spacing: 0) {
                    Button { zoom(to: scale / 1.25, around: center) } label: {
                        Label("Dézoomer", systemImage: "minus").labelStyle(.iconOnly).frame(width: 16)
                    }
                    Button { zoom(to: scale * 1.25, around: center) } label: {
                        Label("Zoomer", systemImage: "plus").labelStyle(.iconOnly).frame(width: 16)
                    }
                }
                .glassButtonStyle()

                Button("Cadrer") {
                    isFramedByUser = true
                    fitToContent(in: viewSize)
                }
                    .glassButtonStyle()
                    .help("Montrer tout le plan")

                Button {
                    showsAllLabels.toggle()
                } label: {
                    Label(
                        "Toutes les cotes",
                        systemImage: showsAllLabels ? "text.bubble.fill" : "text.bubble"
                    )
                    .labelStyle(.iconOnly)
                }
                .glassButtonStyle(prominent: showsAllLabels)
                .help("Afficher toutes les cotes d'un coup")
                .accessibilityValue(showsAllLabels ? "affichées" : "masquées")
            }
        }
        .padding(12)
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
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .frame(height: 28)
                .floatingGlass(in: Capsule())
                .padding(12)
        }
    }

    /// Le tracé en cours : ses trois issues, au-dessus du plan, là où l'œil est déjà. Elles n'existent
    /// que le temps du tracé, et la barre d'outils ne bouge pas pour elles.
    @ViewBuilder
    private var wallDrawingControls: some View {
        if tool == .walls && !pendingWall.isEmpty {
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    Button("Annuler le tracé") { pendingWall = [] }
                        .keyboardShortcut(.cancelAction)
                        .glassButtonStyle()
                    if pendingWall.count >= 2 {
                        Button("Terminer") { commitPendingWall() }
                            .glassButtonStyle()
                    }
                    if pendingWall.count >= 3 {
                        Button("Fermer la pièce") { commitPendingWall(closing: true) }
                            .glassButtonStyle(prominent: true)
                    }
                }
            }
            .padding(12)
        }
    }

    private var center: CGPoint { CGPoint(x: viewSize.width / 2, y: viewSize.height / 2) }

    // MARK: - Barre d'outils

    /// Calibrer sans image de fond faisait tracer une mesure, saisir une longueur, puis ne produisait
    /// aucun effet : l'outil n'existe qu'avec une image.
    private var availableTools: [Tool] {
        Tool.allCases.filter { $0 != .calibrate || state.roomLayout.background != nil }
    }

    @ToolbarContentBuilder
    private var planToolbar: some ToolbarContent {
        editingTools
        historyAndViewTools
        windowTools
    }

    @ToolbarContentBuilder
    private var editingTools: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Picker("Outil", selection: $tool) {
                ForEach(availableTools) { tool in
                    Label(tool.rawValue, systemImage: tool.symbol).tag(tool)
                }
            }
            .pickerStyle(.segmented)
            .labelStyle(.iconOnly)
            .help("Outil : Sélection, Murs" + (availableTools.contains(.calibrate) ? ", Calibrer" : ""))
            .onChange(of: tool) { _, _ in commitPendingWall() }
        }

        // Les outils de tracé à gauche, contre la barre latérale ; tout le reste au bord droit.
        ToolbarSpacer(.flexible)
        ToolbarItem {
            addMenu
        }

        if state.roomLayout.listeners.count >= 2 {
            ToolbarSpacer(.fixed)
            ToolbarItem {
                listeningPlacePicker
            }
        }

    }

    @ToolbarContentBuilder
    private var historyAndViewTools: some ToolbarContent {
        ToolbarSpacer(.fixed)
        ToolbarItemGroup {
            Button(action: undo) {
                Label("Annuler", systemImage: "arrow.uturn.backward")
            }
            .keyboardShortcut("z", modifiers: .command)
            .disabled(!canUndo)
            .help("Annuler (⌘Z)")

            Button(action: redo) {
                Label("Rétablir", systemImage: "arrow.uturn.forward")
            }
            .keyboardShortcut("z", modifiers: [.command, .shift])
            .disabled(!history.canRedo)
            .help("Rétablir (⇧⌘Z)")
        }

        ToolbarSpacer(.fixed)
        ToolbarItemGroup {
            moreMenu

            Button {
                showsInspector.toggle()
                isInspectorPinned = showsInspector
            } label: {
                Label("Inspecteur", systemImage: "sidebar.trailing")
            }
            .help(showsInspector ? "Masquer l'inspecteur" : "Afficher l'inspecteur du plan")
        }

    }

    /// Ce qui vaut pour toute la fenêtre ferme la barre : le diagnostic, puis l'action principale.
    @ToolbarContentBuilder
    private var windowTools: some ToolbarContent {
        ToolbarSpacer(.fixed)
        ToolbarItem {
            Button(action: showDiagnostics) {
                Label("Diagnostic", systemImage: "waveform.path.ecg")
            }
            .help("Compteurs de la capture et de chaque sortie")
        }
        ToolbarSpacer(.fixed)
        ToolbarItem {
            StreamingCommand(state: state)
        }
        .sharedBackgroundVisibility(.hidden)
    }

    /// La bibliothèque de meubles, plus un raccourci par sortie découverte.
    ///
    /// Les modèles sont dans un menu et non en boutons alignés : la liste s'allonge, et une
    /// rangée de boutons devenait illisible avant même d'être complète.
    private var addMenu: some View {
        Menu {
            // Raccourci : pose une enceinte **déjà rattachée** à cette sortie. L'entrée ne disparaît
            // pas une fois utilisée — une sortie AirPlay 2 peut porter deux HomePod, et il faut pouvoir
            // poser le second.
            if !state.outputs.isEmpty {
                Section("Enceinte rattachée à une sortie") {
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
                    }
                }
            }
            ForEach(RoomObject.Library.groups, id: \.0) { title, presets in
                Section(title) {
                    ForEach(presets) { preset in
                        Button {
                            add(preset)
                        } label: {
                            Label(preset.label, systemImage: preset.kind.symbol)
                        }
                    }
                }
            }
        } label: {
            Label("Ajouter", systemImage: "plus")
        }
        .help("Ajouter un meuble, ou une enceinte rattachée à une sortie")
    }

    private var moreMenu: some View {
        Menu {
            Button("Charger le plan du salon", action: loadSalonPlan)
            Divider()
            Button("Pivoter le plan 90° à droite") { rotatePlan(clockwise: true) }
            Button("Pivoter le plan 90° à gauche") { rotatePlan(clockwise: false) }
            Divider()
            Button("Tout sélectionner") { selectAll() }
            Button("Supprimer la sélection", role: .destructive, action: deleteSelection)
                .disabled(selection.isEmpty)
            Divider()
            Button("Importer un plan en fond…") { showsImporter = true }
            if state.roomLayout.background != nil {
                Button("Retirer le plan de fond", role: .destructive, action: removeBackground)
            }
            Divider()
            Button("Effacer les murs", role: .destructive) {
                history.record(state.roomLayout)
                state.roomLayout.walls.removeAll()
                selection = selection.filter { if case .wall = $0 { false } else { true } }
                state.persistRoomLayout()
            }
            Button("Tout effacer", role: .destructive) {
                history.record(state.roomLayout)
                state.roomLayout = RoomLayout()
                selection = []
                if tool == .calibrate { tool = .select }
                state.persistRoomLayout()
            }
        } label: {
            Label("Plus", systemImage: "ellipsis")
        }
        .menuIndicator(.hidden)
        .help("Plan du salon, rotation, image de fond, effacement")
    }

    private func removeBackground() {
        history.record(state.roomLayout)
        state.roomLayout.background = nil
        backgroundImage = nil
        if tool == .calibrate { tool = .select }
        state.persistRoomLayout()
    }

    /// Le choix du lieu d'écoute. Il n'apparaît qu'à partir de deux : avec un seul, il n'y a rien
    /// à choisir.
    @ViewBuilder
    private var listeningPlacePicker: some View {
        let listeners = state.roomLayout.listeners
        if let active = state.roomLayout.listener {
            Picker(
                "Écoute",
                selection: Binding(
                    get: { active.id },
                    set: { id in
                        history.record(state.roomLayout)
                        state.roomLayout.selectListener(id: id)
                        state.persistRoomLayout()
                    }
                )
            ) {
                ForEach(listeners) { listener in
                    Text(listener.name.isEmpty ? listener.kind.label : listener.name).tag(listener.id)
                }
            }
            .pickerStyle(.segmented)
            .help("Lieu d'écoute : recale les enceintes pour ce lieu, sans couper le son")
        }
    }

    private func add(_ preset: RoomObject.Preset, name: String = "") {
        // Le nouvel objet apparaît au centre de ce qu'on regarde, pas à l'origine du
        // modèle : sur un plan qu'on a déplacé, un objet posé en (0,0) atterrit hors écran.
        let object = preset.makeObject(at: gridSnapped(transform.toModel(center)), name: name)
        history.record(state.roomLayout)
        state.roomLayout.objects.append(object)
        selection = [.object(object.id)]
        tool = .select
        state.persistRoomLayout()
    }

    // MARK: - Annulation

    /// Un tracé de mur en cours s'annule point par point, avant de toucher au plan : c'est ce
    /// qu'on attend de ⌘Z au milieu d'un tracé, où le dernier geste est le dernier point posé.
    private var canUndo: Bool { !pendingWall.isEmpty || history.canUndo }

    private func undo() {
        if !pendingWall.isEmpty {
            pendingWall.removeLast()
            return
        }
        guard let previous = history.undo(from: state.roomLayout) else { return }
        restore(previous)
    }

    private func redo() {
        guard let next = history.redo(from: state.roomLayout) else { return }
        restore(next)
    }

    private func restore(_ layout: RoomLayout) {
        state.roomLayout = layout
        // Ne garder de la sélection que ce qui existe encore : l'inspecteur désignerait sinon
        // un objet disparu, et un clic sur « Supprimer » ne ferait rien.
        let wallIDs = Set(layout.walls.map(\.id))
        let objectIDs = Set(layout.objects.map(\.id))
        selection = selection.filter { element in
            switch element {
            case let .wall(id): wallIDs.contains(id)
            case let .object(id): objectIDs.contains(id)
            }
        }
        if tool == .calibrate, layout.background == nil { tool = .select }
        state.persistRoomLayout()
        // La vue ne se recadre jamais toute seule, sauf quand elle ne montrerait plus rien :
        // annuler le chargement d'un plan peut ramener une pièce située ailleurs.
        if let bounds = layout.bounds, let origin {
            let view = PlanTransform(scale: scale, origin: origin)
            let topLeft = view.toModel(.zero)
            let bottomRight = view.toModel(CGPoint(x: viewSize.width, y: viewSize.height))
            let visible = CGRect(
                x: topLeft.x, y: topLeft.y,
                width: bottomRight.x - topLeft.x, height: bottomRight.y - topLeft.y
            )
            if !visible.intersects(bounds) { fitToContent(in: viewSize) }
        }
    }

    /// Remplace le plan courant par celui du salon. ⌘Z le rend, le temps de la session.
    private func loadSalonPlan() {
        commitPendingWall()
        history.record(state.roomLayout)
        state.roomLayout = RoomLayout.salon.bindingSpeakers(
            toOutputs: state.outputs.map { (id: $0.id, name: $0.displayName) }
        )
        selection = []
        tool = .select
        state.persistRoomLayout()
        // Le plan change entièrement d'emprise : sans recadrage il partirait hors de la fenêtre.
        fitToContent(in: viewSize)
    }

    // MARK: - Dessin

    /// La mesure de calibrage en cours.
    private func drawCalibration(_ context: inout GraphicsContext) {
        guard tool == .calibrate, let first = calibration.first else { return }
        let end = calibration.count > 1 ? calibration[1] : hoverPoint
        guard let end else { return }
        var path = Path()
        path.move(to: transform.toView(first))
        path.addLine(to: transform.toView(end))
        context.stroke(path, with: .color(PlanPalette.measure), style: .init(lineWidth: 2, lineCap: .round))
        for point in [first, end] {
            let view = transform.toView(point)
            context.stroke(
                Path(ellipseIn: CGRect(x: view.x - 5, y: view.y - 5, width: 10, height: 10)),
                with: .color(PlanPalette.measure), lineWidth: 2
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
                    .font(.callout).foregroundStyle(PlanPalette.drawing),
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
            path, with: .color(PlanPalette.drawing), style: .init(lineWidth: 3, lineCap: .round, dash: [6, 4])
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
                with: .color(PlanPalette.drawing)
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
        context.stroke(mark, with: .color(PlanPalette.drawing), lineWidth: 1.5)
    }

    // MARK: - Cadrage

    private func zoom(to newScale: Double, around anchor: CGPoint) {
        guard let origin else { return }
        isFramedByUser = true
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
            Self.log.error(
                "Import du fond impossible : \(error.localizedDescription, privacy: .public)"
            )
            return
        }
        guard let image = NSImage(contentsOf: destination) else {
            Self.log.error("Fond illisible : \(url.lastPathComponent, privacy: .public)")
            try? FileManager.default.removeItem(at: destination)
            return
        }
        let pixels = PlanRenderer.pixelSize(of: image)
        history.record(state.roomLayout)

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
        // Ses réglages (opacité, verrou, échelle) sont dans l'inspecteur du plan : il s'ouvre, et
        // reste ouvert le temps de caler l'image.
        showsInspector = true
        isInspectorPinned = true
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
        history.record(state.roomLayout)
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
                    planBeforeDrag = state.roomLayout
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
                    } else if tool == .select, let hit = draggableObject(at: start) {
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
                let travelled = hypot(value.translation.width, value.translation.height)
                switch drag {
                case let .move(id, offset):
                    // Sous le seuil du clic, rien ne bouge. Le magnétisme s'appliquait dès le
                    // premier événement : un simple clic pour sélectionner un meuble le
                    // déplaçait jusqu'à 2,5 cm, sans que la sauvegarde le sache.
                    guard travelled >= clickTolerance, let index = index(ofObject: id) else {
                        return
                    }
                    let model = transform.toModel(value.location)
                    state.roomLayout.objects[index].position = gridSnapped(
                        CGPoint(x: model.x + offset.width, y: model.y + offset.height)
                    )
                case let .moveVertex(refs, offset):
                    guard travelled >= clickTolerance else { return }
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
                    // Un clic n'est pas une prise en main : seul un vrai glissé fige le cadrage.
                    if travelled >= clickTolerance { isFramedByUser = true }
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
                if travelled < clickTolerance {
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
                    case .move, .moveVertex, .moveBackground:
                        if let planBeforeDrag { history.record(planBeforeDrag) }
                        state.persistRoomLayout()
                    default: break
                    }
                }
                drag = nil
                planBeforeDrag = nil
            }
    }

    /// Le seul meuble que le glissé puisse emporter : celui qu'on voit sous le curseur. Un
    /// tapis ne suit la souris qu'une fois sélectionné, sinon déplacer la vue au-dessus de lui
    /// le ferait glisser sous les meubles.
    private func draggableObject(at model: CGPoint) -> RoomObject? {
        guard case let .object(id) = element(at: model),
            let hit = state.roomLayout.objects.first(where: { $0.id == id })
        else { return nil }
        if hit.kind.yieldsToEverything, !selection.contains(.object(id)) { return nil }
        return hit
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
            if let first = pendingWall.first, pendingWall.count >= 3,
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

    /// Élément sous le point. L'ordre de priorité est celui du dessin, et il vit dans le
    /// modèle pour pouvoir se vérifier sans lancer l'interface.
    private func element(at model: CGPoint) -> PlanElement? {
        state.roomLayout.element(at: model, wallTolerance: snapRadius / scale)
    }

    private func index(ofObject id: UUID) -> Int? {
        state.roomLayout.objects.firstIndex { $0.id == id }
    }

    private func rotatePlan(clockwise: Bool) {
        commitPendingWall()
        history.record(state.roomLayout)
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
        history.record(state.roomLayout)
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
        history.record(state.roomLayout)
        var points = pendingWall
        // Fermer une polyligne de deux points doublerait le mur sur lui-même : deux segments
        // superposés, dont le second reste dessous à l'effacement du premier.
        if closing, points.count >= 3, let first = points.first { points.append(first) }
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

    private var inspector: some View {
        PlanInspector(
            state: state, selection: selection, history: $history, showsAllLabels: $showsAllLabels,
            onDelete: deleteSelection, onImportBackground: { showsImporter = true },
            onRemoveBackground: removeBackground
        )
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
