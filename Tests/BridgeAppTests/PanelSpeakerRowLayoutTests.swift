import AppKit
import AudioCore
import SwiftUI
import Testing

@testable import BridgeApp

/// Une rangée qui accepte d'être plus courte que son contenu le laisse déborder sur sa voisine : son
/// message ne se tasse pas, et se retrouve centré dans un cadre trop court. C'est ce que montrait la
/// capture du 2026-11-09, le message de la Geneva éteinte recouvrant le nom de « Salon ».
///
/// Le panneau comprime ses rangées dès que sa fenêtre est moins haute que son contenu, par exemple
/// quand un message apparaît alors qu'il est ouvert. Rendu à l'appui, sans fenêtre comprimée :
/// `MENUBAR_PNG_DIR=<dossier> swift test --filter PanelMessageRenderingExport`.
@MainActor
@Suite("Panneau — une rangée d'enceinte ne déborde pas sur la suivante")
struct PanelSpeakerRowLayoutTests {
    /// La largeur des rangées dans le panneau.
    private static let rowWidth = PanelMetrics.width - 2 * PanelMetrics.rowInset

    private static let longMessage =
        "« Salon (2) » a refusé la requête SETUP (réponse 400). Cette version de l'appareil attend peut-être "
        + "un autre format ; redémarrer l'appareil peut aussi lever un blocage."

    private func row(_ output: OutputState) -> some View {
        PanelSpeakerRow(output: output, isAudible: true, reservesDrawerColumn: true) {}
            .frame(width: Self.rowWidth)
    }

    /// La hauteur que prend la rangée quand le panneau lui propose `proposed`.
    private func height(of output: OutputState, proposing proposed: CGFloat) -> CGFloat {
        NSHostingController(rootView: row(output))
            .sizeThatFits(in: CGSize(width: Self.rowWidth, height: proposed)).height
    }

    private func naturalHeight(of output: OutputState) -> CGFloat {
        NSHostingView(rootView: row(output)).fittingSize.height
    }

    @Test(
        "Avec un message, la rangée garde la hauteur de son contenu, même comprimée",
        arguments: [true, false]
    )
    func messageKeepsItsRoom(isEnabled: Bool) {
        let geneva = OutputState(
            id: "raop/AABBCCDDEEFF@Geneva", displayName: "Geneva", host: "192.168.1.42", port: 7000,
            proto: .raop
        )
        geneva.isEnabled = isEnabled
        let bare = naturalHeight(of: geneva)

        geneva.connection = .waiting(attempt: 2, message: Self.longMessage, nextAttemptAt: nil)
        let natural = naturalHeight(of: geneva)
        #expect(natural > bare + 20, "le message doit allonger la rangée")

        // Ce que propose un panneau resté à la hauteur d'avant le message, puis bien moins encore.
        for proposed in [bare, 1] {
            #expect(height(of: geneva, proposing: proposed) >= natural, "proposé : \(proposed)")
        }
    }

    /// Cocher ne fait jamais sauter le panneau : la légende d'une paire stéréo se loge sur la ligne du
    /// nom, sans ajouter de ligne, cochée ou non.
    @Test("La légende d'une paire stéréo ne change pas la hauteur de la rangée", arguments: [true, false])
    func stereoLegendKeepsRowHeight(isEnabled: Bool) {
        let salon = OutputState(
            id: "airplay2/Salon", displayName: "Salon", host: "192.168.1.158", port: 7000,
            proto: .airplay2
        )
        salon.isEnabled = isEnabled
        let paired = PanelSpeakerRow(
            output: salon, isAudible: true, reservesDrawerColumn: true, stereoPartnerNames: ["Salon (2)"]
        ) {}
        let height = NSHostingView(rootView: paired.frame(width: Self.rowWidth)).fittingSize.height
        #expect(height == naturalHeight(of: salon))
    }

    @Test("Le message d'une enceinte introuvable tient sur une ligne")
    func receiverMissingFitsOneLine() {
        let geneva = OutputState(
            id: "raop/AABBCCDDEEFF@Geneva", displayName: "Geneva", host: "192.168.1.42", port: 7000,
            proto: .raop
        )
        geneva.connection = .connecting
        let withoutMessage = naturalHeight(of: geneva)
        // Le texte tel que le moteur le relaie : `"\(error)"`.
        let error = RAOPDiscoveryError.notFound(name: "F8F25A011261@Erki’s geneva", seen: ["111111111111@Salon"])
        geneva.connection = .waiting(attempt: 1, message: "\(error)", nextAttemptAt: nil)
        let withMessage = naturalHeight(of: geneva)
        // Une ligne de 11 pt, plus la marge sous le message : bien moins que deux lignes.
        #expect(withMessage - withoutMessage < 22, "\(withMessage - withoutMessage) pt de plus")
    }
}
