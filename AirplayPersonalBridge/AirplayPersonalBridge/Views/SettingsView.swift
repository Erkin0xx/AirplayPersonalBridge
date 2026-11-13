//
//  SettingsView.swift
//  AirplayPersonalBridge
//

import SwiftUI

/// La fenêtre Réglages de l'app (scène `Settings`, ⌘,) : ce que la fenêtre montre.
///
/// C'est ici que se réaffiche ce qu'on a masqué d'un clic droit dans une vue (`HiddenElements`) : une
/// enceinte, ou un bloc. Rien de ce qui s'y règle ne change ce qui joue. Les options du Mac restent dans le
/// bouton « … » de la fenêtre et dans le panneau : on y revient en écoutant, elles doivent rester à un clic.
///
/// La scène elle-même est dans `AirplayPersonalBridgeApp.swift`, que seul Xcode compile ; cette vue est
/// compilée par `swift build`, pour être testée et rendue hors écran.
struct SettingsView: View {
    @Bindable var state: BridgeState
    /// Les enceintes absentes de la liste qu'on vient de réafficher : elles gardent leur ligne tant que la
    /// fenêtre est ouverte, sinon l'interrupteur disparaîtrait sous le doigt, sans retour possible.
    @State private var reshown: [String: String] = [:]

    static let size = CGSize(width: 500, height: 700)

    var body: some View {
        Form {
            Section("Affichage") {
                Picker("Vue de la fenêtre", selection: $state.windowLayout) {
                    ForEach(WindowLayout.allCases) { layout in
                        Text(layout.title).tag(layout)
                    }
                }
                .pickerStyle(.segmented)
                .help("Trois mises en scène du même réglage : rien ne change dans ce qui joue.")
            }

            Section {
                Toggle("Afficher le widget", isOn: $state.widget.isShown)
                Picker("Style", selection: $state.widget.style) {
                    ForEach(WidgetStyle.allCases) { style in
                        Text(style.title).tag(style)
                    }
                }
                .pickerStyle(.segmented)
                .help("Halo : le disque et l'anneau du volume. Bandeau : un bouton et de grandes pastilles.")
                Toggle("Toujours au-dessus", isOn: $state.widget.floatsOnTop)
            } header: {
                Text("Widget")
            } footer: {
                Text(
                    "Une petite fenêtre, sur tous les bureaux : diffuser, volume général, volume de chaque "
                        + "enceinte. On la déplace par son fond ; clic droit sur le fond pour son menu."
                )
            }

            Section {
                let speakers = Self.rows(known: state.knownSpeakers, reshown: reshown)
                if speakers.isEmpty {
                    Text("Aucune enceinte connue pour l'instant.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(speakers) { speaker in
                        speakerRow(speaker)
                    }
                }
            } header: {
                Text("Enceintes affichées")
            } footer: {
                Text(
                    "Une enceinte masquée disparaît de la fenêtre et de la barre de menus. Cochée, elle "
                        + "continue de jouer. Les deux membres d'une paire stéréo se masquent ensemble."
                )
            }

            Section {
                ForEach(WindowBlock.allCases) { block in
                    Toggle(isOn: blockBinding(block)) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(block.title)
                            Text(block.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            } header: {
                Text("Éléments affichés")
            } footer: {
                HStack {
                    Text("L'état, les avertissements, la source et Diffuser restent toujours visibles.")
                    Spacer(minLength: 12)
                    Button("Tout réafficher") {
                        rememberUnlisted()
                        state.hiddenElements = HiddenElements()
                    }
                    .disabled(state.hiddenElements == HiddenElements())
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: Self.size.width, height: Self.size.height)
        .navigationTitle("Réglages")
        // Le thème de l'app, comme la fenêtre principale.
        .tint(BridgeTheme.accent)
        .preferredColorScheme(.dark)
    }

    // MARK: - Enceintes

    /// Les lignes de la section : les enceintes connues, puis celles qu'on vient de réafficher et que plus
    /// rien d'autre ne retient. Hors de la vue pour être testé.
    static func rows(known: [KnownSpeaker], reshown: [String: String]) -> [KnownSpeaker] {
        let knownIDs = Set(known.map(\.id))
        let extra = reshown.filter { !knownIDs.contains($0.key) }
            .map { KnownSpeaker(id: $0.key, name: $0.value, isHidden: false, isListed: false) }
            .sorted { ($0.name, $0.id) < ($1.name, $1.id) }
        return known + extra
    }

    private func speakerRow(_ speaker: KnownSpeaker) -> some View {
        let output = state.outputs.first { $0.id == speaker.id }
        return Toggle(isOn: speakerBinding(speaker)) {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(speaker.name)
                    Text(Self.detail(for: speaker, output: output, partners: partners(of: output)))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(
                    systemName: SpeakerSymbol.name(
                        displayName: speaker.name,
                        proto: output?.proto ?? OutputProtocol(outputID: speaker.id) ?? .raop,
                        unavailability: output?.unavailability
                    )
                )
                .foregroundStyle(.secondary)
            }
        }
        .accessibilityLabel("Afficher \(speaker.name) dans la fenêtre")
    }

    private func partners(of output: OutputState?) -> [String] {
        output.map { state.stereoPartners(of: $0).map(\.displayName) } ?? []
    }

    /// Sous le nom : ce qu'elle est, sa paire, et qu'elle joue encore si elle est masquée et cochée.
    static func detail(for speaker: KnownSpeaker, output: OutputState?, partners: [String]) -> String {
        guard let output else { return "Absente du réseau" }
        var parts = [output.proto.rawValue]
        if let pair = PanelStereoPair.legend(partners: partners) { parts.append(pair) }
        if output.presence == .offline { parts.append("hors ligne") }
        if speaker.isHidden, output.isEnabled { parts.append("masquée, joue toujours") }
        return parts.joined(separator: " · ")
    }

    private func speakerBinding(_ speaker: KnownSpeaker) -> Binding<Bool> {
        Binding(
            get: { !state.hiddenElements.outputIDs.contains(speaker.id) },
            set: { isShown in
                rememberUnlisted()
                state.setHidden(!isShown, outputID: speaker.id)
            }
        )
    }

    /// Avant tout changement : une enceinte absente de la liste n'est connue que par son masquage.
    private func rememberUnlisted() {
        for speaker in state.knownSpeakers where !speaker.isListed {
            reshown[speaker.id] = speaker.name
        }
    }

    // MARK: - Blocs

    private func blockBinding(_ block: WindowBlock) -> Binding<Bool> {
        Binding(
            get: { state.isVisible(block) },
            set: { state.setVisible($0, block: block) }
        )
    }
}

#Preview {
    SettingsView(state: .preview(.streaming))
}
