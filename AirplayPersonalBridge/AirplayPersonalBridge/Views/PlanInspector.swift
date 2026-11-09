//
//  PlanInspector.swift
//  AirplayPersonalBridge
//

import SwiftUI

/// L'inspecteur du plan, dans la colonne `.inspector` de la fenêtre.
///
/// Un seul meuble sélectionné : ses réglages. Plusieurs éléments, ou des murs : un résumé et de quoi les
/// effacer. Rien de sélectionné : le plan lui-même, ses dimensions et son image de fond. Des formulaires
/// groupés, comme les Réglages Système : le libellé à gauche, la valeur à droite.
///
/// Il ne détient aucun état : la sélection, l'historique et les cotes appartiennent à l'éditeur
/// (`RoomPlanView`), qui le relie à ses propres gestes.
struct PlanInspector: View {
    @Bindable var state: BridgeState
    let selection: Set<PlanElement>
    @Binding var history: PlanHistory
    @Binding var showsAllLabels: Bool
    var onDelete: () -> Void
    var onImportBackground: () -> Void
    var onRemoveBackground: () -> Void

    /// Il n'y a rien à régler finement sur un mur — sa longueur se lit sur le plan et se change en le
    /// retraçant.
    var body: some View {
        if selection.count == 1, let only = selection.first, case let .object(id) = only,
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
                        guard let index = state.roomLayout.objects.firstIndex(where: { $0.id == id })
                        else { return }
                        // Toutes les retouches d'un même objet forment un seul pas d'annulation.
                        history.record(state.roomLayout, group: "inspecteur \(id)")
                        // Une taille nulle ou négative rendrait l'objet invisible et impossible
                        // à rattraper au clic : il ne resterait qu'à tout sélectionner.
                        var edited = newValue
                        edited.size = CGSize(
                            width: max(newValue.size.width, 0.01),
                            height: max(newValue.size.height, 0.01)
                        )
                        state.roomLayout.objects[index] = edited
                    }
                ),
                outputs: state.outputs,
                onCommit: { state.persistRoomLayout() },
                onDelete: onDelete
            )
            .id(id)
        } else if !selection.isEmpty {
            selectionSummary
        } else {
            planSummary
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

        return Form {
            Section("Sélection") {
                if !wallIDs.isEmpty {
                    LabeledContent {
                        Text(String(format: "%.2f m au total", totalLength)).monospacedDigit()
                    } label: {
                        Label(
                            "\(wallIDs.count) mur\(wallIDs.count > 1 ? "s" : "")",
                            systemImage: "square.split.bottomrightquarter"
                        )
                    }
                }
                if objectCount > 0 {
                    Label("\(objectCount) meuble\(objectCount > 1 ? "s" : "")", systemImage: "cube")
                }
            }
            Section {
                Button(role: .destructive, action: onDelete) {
                    Label("Supprimer", systemImage: "trash")
                }
                .help("Supprimer (touche Suppr)")
            } footer: {
                Text("Un mur ne se règle pas : sa longueur se lit sur le plan, et se change en le retraçant.")
            }
        }
        .formStyle(.grouped)
        .scrollEdgeEffectStyle(.soft, for: .vertical)
    }

    /// Rien de sélectionné : le plan lui-même, ses dimensions et son image de fond.
    private var planSummary: some View {
        Form {
            Section("Pièce") {
                if let dimensions = state.roomLayout.dimensions, dimensions.width > 0 {
                    LabeledContent("Dimensions") {
                        Text(String(format: "%.2f m × %.2f m", dimensions.width, dimensions.height))
                            .monospacedDigit()
                    }
                } else {
                    Label(
                        "Choisis « Murs » et clique pour tracer, puis pose les meubles",
                        systemImage: "hand.point.up.left"
                    )
                    .foregroundStyle(.secondary)
                }
                Toggle("Toutes les cotes", isOn: $showsAllLabels)
            }
            backgroundSection
        }
        .formStyle(.grouped)
        .scrollEdgeEffectStyle(.soft, for: .vertical)
    }

    /// Réglages de l'image de fond. Ils n'apparaissent que si une image est chargée —
    /// afficher en permanence des commandes sans objet encombrerait pour rien.
    @ViewBuilder
    private var backgroundSection: some View {
        if let background = state.roomLayout.background {
            Section("Plan de fond") {
                LabeledContent("Opacité") {
                    Slider(
                        value: Binding(
                            get: { background.opacity },
                            set: {
                                history.record(state.roomLayout, group: "opacité du fond")
                                state.roomLayout.background?.opacity = $0
                            }
                        ),
                        in: 0.05...1
                    ) {
                        Text("Opacité du plan de fond")
                    }
                    .labelsHidden()
                    .onChange(of: background.opacity) { _, _ in state.persistRoomLayout() }
                }
                Toggle(
                    isOn: Binding(
                        get: { background.isLocked },
                        set: {
                            history.record(state.roomLayout)
                            state.roomLayout.background?.isLocked = $0
                            state.persistRoomLayout()
                        }
                    )
                ) {
                    Label("Verrouillée", systemImage: background.isLocked ? "lock.fill" : "lock.open")
                }
                .help(
                    background.isLocked
                        ? "Image verrouillée — elle ne bougera pas"
                        : "Image déverrouillée — glisse-la pour la caler"
                )
                LabeledContent("Échelle") {
                    Text(String(format: "%.1f cm/px", background.metersPerPixel * 100)).monospacedDigit()
                }
                Button("Retirer le plan de fond", role: .destructive, action: onRemoveBackground)
            }
        } else {
            Section("Plan de fond") {
                Button("Importer un plan en fond…", action: onImportBackground)
            }
        }
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
        Form {
            Section {
                // Rien d'autre ne permettait de nommer un objet. Or le nom d'une enceinte
                // n'est pas qu'une étiquette : c'est lui qui la rattache à sa sortie.
                TextField("Nom", text: $object.name, prompt: Text(object.kind.label))
            } header: {
                Label(
                    object.name.isEmpty ? object.kind.label : object.name,
                    systemImage: object.kind.symbol
                )
                .font(.headline)
                .foregroundStyle(.primary)
            }

            Section {
                LabeledContent("Position") {
                    HStack(spacing: 6) {
                        MeasureField(
                            label: "X", accessibilityLabel: "Position X", value: $object.position.x.asDouble,
                            showsUnit: false
                        )
                        MeasureField(label: "Y", accessibilityLabel: "Position Y", value: $object.position.y.asDouble)
                    }
                }
                if object.isRound {
                    // Un seul champ pour un meuble rond : deux cotes indépendantes
                    // permettraient d'en faire une ellipse par mégarde.
                    LabeledContent("Diamètre") {
                        MeasureField(label: "Ø", accessibilityLabel: "Diamètre", value: diameter)
                    }
                } else {
                    LabeledContent("Taille") {
                        HStack(spacing: 6) {
                            MeasureField(
                                label: "L", accessibilityLabel: "Largeur", value: $object.size.width.asDouble,
                                showsUnit: false
                            )
                            MeasureField(label: "P", accessibilityLabel: "Profondeur", value: $object.size.height.asDouble)
                        }
                    }
                }
                if object.shape == .lShape {
                    LabeledContent("Retour") {
                        MeasureField(
                            label: "Prof.", accessibilityLabel: "Profondeur du retour", value: $object.armThickness
                        )
                    }
                    Picker("Côté du retour", selection: $object.isMirrored) {
                        Text("À gauche").tag(false)
                        Text("À droite").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .help("Renvoie le retour du canapé de l'autre côté")
                }
                if object.kind == .door {
                    Picker("Charnière", selection: $object.isMirrored) {
                        Text("À gauche").tag(false)
                        Text("À droite").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .help("Fait pivoter la porte de l'autre côté")
                }
                // Un tapis, une porte ou une fenêtre n'interviennent dans aucun calcul :
                // leur demander une hauteur laisserait croire le contraire.
                if !object.kind.hasNoAcousticHeight {
                    LabeledContent("Hauteur") {
                        MeasureField(label: nil, accessibilityLabel: "Hauteur, \(heightHint)", value: $object.elevation)
                    }
                }
                // Une chaise de bureau est ronde mais a un dossier, donc un sens.
                if !object.isRound || object.kind == .chair {
                    LabeledContent("Orientation") {
                        HStack(spacing: 8) {
                            // Arrondie à la main plutôt que par `step:`, qui dessinerait 72 graduations.
                            Slider(
                                value: Binding(
                                    get: { object.rotation },
                                    set: { object.rotation = ($0 / 5).rounded() * 5 }
                                ),
                                in: 0...360
                            ) {
                                Text("Orientation")
                            }
                            .labelsHidden()
                            .accessibilityValue(String(format: "%.0f degrés", object.rotation))
                            Text(String(format: "%.0f°", object.rotation))
                                .monospacedDigit()
                                .frame(minWidth: 34, alignment: .trailing)
                                .accessibilityHidden(true)
                        }
                    }
                }
            } header: {
                Text("Dimensions")
            } footer: {
                // La hauteur ne désigne pas la même chose selon l'objet, et l'ambiguïté se paierait
                // directement en millisecondes de délai faux : le pied de section dit laquelle.
                if !object.kind.hasNoAcousticHeight {
                    Text("Hauteur : \(heightHint), en mètres depuis le sol.")
                }
            }

            if case let .speaker(outputID) = object.kind {
                Section {
                    // C'est ce rattachement qui fait entrer l'enceinte dans le calcul
                    // du délai : une enceinte non rattachée n'est qu'un meuble.
                    Picker("Sortie", selection: outputBinding(current: outputID)) {
                        Text("Aucune").tag(String?.none)
                        ForEach(outputs) { output in
                            Text(output.displayName).tag(String?.some(output.id))
                        }
                    }
                } footer: {
                    if outputID == nil {
                        Text("Hors du calcul : rattachée à une sortie, elle compterait dans son délai.")
                    }
                }
            }

            Section {
                Button(role: .destructive, action: onDelete) {
                    Label("Supprimer", systemImage: "trash")
                }
                .help("Supprimer (touche Suppr)")
            }
        }
        .formStyle(.grouped)
        .scrollEdgeEffectStyle(.soft, for: .vertical)
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

    private var heightHint: String {
        switch object.kind {
        case .listener: "hauteur d'oreilles, assis"
        case .speaker: "hauteur du haut-parleur"
        case .tv: "centre de l'écran"
        case .sofa, .armchair, .chair: "hauteur d'assise"
        case .shelf, .tvStand, .sideboard, .console, .radiator: "hauteur du dessus"
        case .plant, .lamp: "hauteur du sommet"
        case .device, .decor: "hauteur de pose"
        default: "hauteur du plateau"
        }
    }
}

/// Un champ en mètres : sa lettre, sa valeur, et l'unité, une fois par rangée.
private struct MeasureField: View {
    let label: String?
    let accessibilityLabel: String
    @Binding var value: Double
    var showsUnit = true

    var body: some View {
        HStack(spacing: 3) {
            if let label {
                Text(label)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            TextField(accessibilityLabel, value: $value, format: .number.precision(.fractionLength(0...2)))
                .labelsHidden()
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .frame(width: 46)
            if showsUnit {
                Text("m")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
        }
    }
}
