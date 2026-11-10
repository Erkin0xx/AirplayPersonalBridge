//
//  OutputStatusMessage.swift
//  AirplayPersonalBridge
//

import SwiftUI

/// Le message d'une sortie, tel que le moteur le rédige. Partagé par la fenêtre et le panneau.
///
/// Ces messages disent quoi faire, et certains font plusieurs phrases (l'appairage d'un Apple TV, par
/// exemple). Repliés, ils gardent la liste lisible d'un coup d'œil ; un lien les déplie, pour qu'une
/// coupure ne passe jamais pour la fin du message.
struct OutputStatusMessage: View {
    let text: String
    let tone: OutputStatusTone
    /// La rangée est en retrait : même un avertissement n'y appelle pas le regard.
    var isMuted = false
    /// Les lignes visibles une fois replié.
    var foldedLines = 3
    /// Au-delà, le message ne tient pas dans ses lignes repliées : le lien apparaît.
    var foldedLength = 125

    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(text)
                .font(.subheadline)
                .foregroundStyle(color)
                .lineLimit(isExpanded ? nil : foldedLines)
                .truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(text)
            if text.count > foldedLength {
                Button(isExpanded ? "Réduire" : "Lire la suite") { isExpanded.toggle() }
                    .buttonStyle(.plain)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var color: Color {
        if isMuted { return .secondary }
        switch tone {
        case .muted: return .secondary
        case .warning: return PanelPalette.warningText
        case .critical: return PanelPalette.criticalText
        }
    }
}
