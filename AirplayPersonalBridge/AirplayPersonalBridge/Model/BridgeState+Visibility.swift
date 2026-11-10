//
//  BridgeState+Visibility.swift
//  AirplayPersonalBridge
//

import Foundation

/// Le masquage, vu de l'état : ce que les vues montrent, et le geste qui masque (`HiddenElements`).
///
/// Rien d'ici ne touche à `outputs`, à la coche d'une enceinte ni au moteur : une enceinte masquée et
/// cochée continue de jouer, et son volume, sa paire et sa session restent ce qu'ils étaient.
extension BridgeState {
    /// Les enceintes que la fenêtre et le panneau montrent, dans l'ordre de la liste.
    var visibleOutputs: [OutputState] {
        hiddenElements.visible(outputs) { $0.id }
    }

    /// Les enceintes de la liste que le masquage retire de la vue. Un identifiant masqué que la liste n'a
    /// plus ne compte pas : il n'y a rien à signaler pour une enceinte qui ne serait pas là de toute façon.
    var hiddenOutputCount: Int {
        outputs.count { hiddenElements.outputIDs.contains($0.id) }
    }

    func isHidden(_ output: OutputState) -> Bool {
        hiddenElements.outputIDs.contains(output.id)
    }

    func isVisible(_ block: WindowBlock) -> Bool {
        !hiddenElements.blocks.contains(block)
    }

    /// Masque ou réaffiche une enceinte, **avec toute sa paire stéréo** : comme la coche, un geste vaut
    /// pour les deux membres. Un membre que la liste n'a plus suit aussi, par le `tsid` gardé dans les
    /// réglages.
    func setHidden(_ isHidden: Bool, outputID: String) {
        var pairKeys: [String: String] = [:]
        for (id, record) in settings.outputs {
            if let key = record.tightSyncIdentifier, !key.isEmpty { pairKeys[id] = key }
        }
        // La liste fait foi sur ce que les réglages ont gardé : le `tsid` vient d'être relu du réseau.
        for output in outputs {
            pairKeys[output.id] = output.stereoPairKey
        }
        hiddenElements.setHidden(isHidden, outputID: outputID, pairKeys: pairKeys)
    }

    func setHidden(_ isHidden: Bool, for output: OutputState) {
        setHidden(isHidden, outputID: output.id)
    }

    func setVisible(_ isVisible: Bool, block: WindowBlock) {
        if isVisible {
            hiddenElements.blocks.remove(block)
        } else {
            hiddenElements.blocks.insert(block)
        }
    }

    /// Les enceintes que les Réglages listent : celles de la liste, puis les masquées qu'elle n'a plus.
    var knownSpeakers: [KnownSpeaker] {
        KnownSpeaker.list(
            listed: outputs.map { (id: $0.id, name: $0.displayName) },
            hidden: hiddenElements.outputIDs,
            name: { [settings] id in
                settings.outputs[id]?.displayName ?? Self.displayName(fromOutputID: id)
            }
        )
    }

    /// La ligne discrète de la vue en cours : ce qu'elle ne montre pas. `nil` si elle montre tout.
    var hiddenSummary: String? {
        let blocks = hiddenElements.blocks.count { $0.layouts.contains(windowLayout) }
        return HiddenElementsCopy.summary(speakers: hiddenOutputCount, blocks: blocks)
    }

    /// Des enceintes sont là, mais toutes masquées : la vue ne doit pas dire qu'elle n'en trouve aucune.
    var hidesEverySpeaker: Bool {
        !outputs.isEmpty && visibleOutputs.isEmpty
    }
}
