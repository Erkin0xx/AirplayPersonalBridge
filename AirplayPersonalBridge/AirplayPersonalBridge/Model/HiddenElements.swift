//
//  HiddenElements.swift
//  AirplayPersonalBridge
//

import Foundation

/// Un bloc de la fenêtre qu'on peut masquer depuis les Réglages.
///
/// La liste est courte, et c'est voulu : n'y entre que ce qui est décoratif ou fait doublon avec une
/// autre commande. L'état, les avertissements, Diffuser/Arrêter, la source et le bouton de silence n'y
/// entreront jamais : masqués, ils laisseraient un son partir ou se taire sans que rien ne le dise.
enum WindowBlock: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Les ondes derrière la sphère de la vue Halo : un décor, la sphère et les égaliseurs disent déjà
    /// qu'un son part.
    case haloWaves
    /// Le réglage du volume général (anneau, curseur, valeur en dB) : en diffusion, les touches de volume
    /// du Mac le pilotent, et le panneau de la barre de menus le porte aussi. Le bouton de silence reste.
    case masterVolume
    /// Le lieu d'écoute en haut de la vue Console : le même choix est dans les outils du plan et dans le
    /// panneau de la barre de menus.
    case listeningPlaces

    var id: String { rawValue }

    var title: String {
        switch self {
        case .haloWaves: "Ondes autour de la sphère"
        case .masterVolume: "Volume général"
        case .listeningPlaces: "Lieu d'écoute"
        }
    }

    /// Ce que l'interrupteur précise sous son titre : où est le bloc, et ce qui le remplace.
    var detail: String {
        switch self {
        case .haloWaves: "Vue Halo. Un décor : la sphère dit déjà qu'un son part."
        case .masterVolume: "Les touches de volume du Mac le règlent aussi. Le bouton de silence reste."
        case .listeningPlaces: "Vue Console. Le même choix est dans la vue Plan et la barre de menus."
        }
    }

    /// Les vues de la fenêtre où ce bloc se voit.
    var layouts: Set<WindowLayout> {
        switch self {
        case .haloWaves: [.halo]
        case .masterVolume: Set(WindowLayout.allCases)
        case .listeningPlaces: [.console]
        }
    }
}

/// Ce que Baptiste a masqué dans la fenêtre : des enceintes, des blocs.
///
/// **Purement visuel.** Une enceinte cochée et masquée continue de jouer : rien d'ici n'atteint le moteur,
/// les groupes de volume ni les paires stéréo. Un identifiant qui ne correspond plus à aucune enceinte
/// reste dans la liste sans gêner : elle reviendra masquée si elle revient.
struct HiddenElements: Codable, Equatable, Sendable {
    /// Des `OutputState.id`.
    var outputIDs: Set<String> = []
    var blocks: Set<WindowBlock> = []

    private enum CodingKeys: String, CodingKey {
        case outputIDs = "outputs"
        case blocks
    }

    init(outputIDs: Set<String> = [], blocks: Set<WindowBlock> = []) {
        self.outputIDs = outputIDs
        self.blocks = blocks
    }

    /// Tolérant, comme le reste des réglages : une liste absente ou illisible est vide, et un bloc
    /// inconnu (écrit par une version plus récente, ou retiré depuis) est ignoré sans coûter les autres.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        outputIDs = Set((try? container.decode([String].self, forKey: .outputIDs)) ?? [])
        let names = (try? container.decode([String].self, forKey: .blocks)) ?? []
        blocks = Set(names.compactMap(WindowBlock.init(rawValue:)))
    }

    /// Triées : un ensemble n'a pas d'ordre, et le fichier ne doit pas changer d'une écriture à l'autre
    /// sans que rien n'ait changé.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(outputIDs.sorted(), forKey: .outputIDs)
        try container.encode(blocks.map(\.rawValue).sorted(), forKey: .blocks)
    }
}

// MARK: - Enceintes

extension HiddenElements {
    /// Les éléments à montrer, dans leur ordre.
    func visible<Element>(_ elements: [Element], id: (Element) -> String) -> [Element] {
        elements.filter { !outputIDs.contains(id($0)) }
    }

    /// Les identifiants que touche un geste sur `id` : lui, et les autres membres de sa paire stéréo.
    /// Masquer vaut pour toute la paire, comme cocher (`StereoPairs`).
    ///
    /// - Parameter pairKeys: le `tsid` de chaque enceinte connue qui en a un.
    static func targets(of id: String, pairKeys: [String: String]) -> Set<String> {
        guard let key = pairKeys[id], !key.isEmpty else { return [id] }
        return Set(pairKeys.filter { $0.value == key }.keys).union([id])
    }

    /// Masque ou réaffiche une enceinte, avec sa paire.
    mutating func setHidden(_ isHidden: Bool, outputID: String, pairKeys: [String: String]) {
        let targets = Self.targets(of: outputID, pairKeys: pairKeys)
        if isHidden {
            outputIDs.formUnion(targets)
        } else {
            outputIDs.subtract(targets)
        }
    }
}

/// Une enceinte telle que les Réglages la listent : celles de la fenêtre, puis celles qu'on a masquées et
/// que le réseau ne montre plus.
struct KnownSpeaker: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    var isHidden: Bool
    /// Présente dans la liste des enceintes de l'app. Sinon, on ne la connaît plus que par son masquage.
    var isListed: Bool

    /// Les enceintes de la liste dans leur ordre, puis les masquées que la liste n'a plus, par nom.
    ///
    /// - Parameters:
    ///   - listed: les enceintes de l'app (`BridgeState.outputs`).
    ///   - name: le nom d'une enceinte absente de la liste, d'après ce qu'on en a gardé.
    static func list(
        listed: [(id: String, name: String)], hidden: Set<String>, name: (String) -> String
    ) -> [KnownSpeaker] {
        let listedIDs = Set(listed.map(\.id))
        let present = listed.map {
            KnownSpeaker(id: $0.id, name: $0.name, isHidden: hidden.contains($0.id), isListed: true)
        }
        let absent = hidden.subtracting(listedIDs)
            .map { KnownSpeaker(id: $0, name: name($0), isHidden: true, isListed: false) }
            .sorted {
                let order = $0.name.localizedCaseInsensitiveCompare($1.name)
                return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
            }
        return present + absent
    }
}

// MARK: - Ce que la fenêtre en dit

/// Les mots du masquage : hors des vues pour être testés.
enum HiddenElementsCopy {
    /// La ligne discrète d'une vue : « 1 enceinte masquée », « 2 enceintes masquées · 1 élément masqué ».
    /// `nil` quand rien n'est masqué.
    static func summary(speakers: Int, blocks: Int) -> String? {
        var parts: [String] = []
        if speakers == 1 { parts.append("1 enceinte masquée") }
        if speakers > 1 { parts.append("\(speakers) enceintes masquées") }
        if blocks == 1 { parts.append("1 élément masqué") }
        if blocks > 1 { parts.append("\(blocks) éléments masqués") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// La commande du menu contextuel et du bouton au survol : elle dit qu'elle emmène la paire.
    static func hideTitle(partners: [String]) -> String {
        partners.isEmpty ? "Masquer cette enceinte" : "Masquer la paire stéréo"
    }

    /// L'aide de la commande : où retrouver ce qu'on masque, et que cela ne coupe rien.
    static func hideHelp(name: String, partners: [String], isEnabled: Bool) -> String {
        let subject = StereoPairs.names(partners).map { "\(name) et \($0)" } ?? name
        var sentences = ["Masquer \(subject) de la fenêtre et de la barre de menus."]
        if isEnabled {
            sentences.append(
                partners.isEmpty
                    ? "Elle reste cochée et continue de jouer."
                    : "Elles restent cochées et continuent de jouer."
            )
        }
        sentences.append("À réafficher dans les Réglages (⌘,).")
        return sentences.joined(separator: " ")
    }
}
