import AppKit
import SwiftUI
import Testing

@testable import BridgeApp

/// Les options s'ouvrent dans une fenêtre surgissante : le panneau ne grandit plus pour les montrer.
///
/// C'est une superposition, qui ne pèse pas dans la mise en page : le test le fige, pour qu'un retour
/// à des options dépliées dans le flux ne passe pas inaperçu. Rendu à l'appui :
/// `MENUBAR_PNG_DIR=<dossier> swift test --filter MenuBarPanelExport`.
@MainActor
@Suite("Panneau — fenêtre surgissante des options")
struct PanelPopupTests {
    private func panelSize(
        _ scene: BridgeState.PanelScene, loginItem status: LoginItemStatus, presentsOptions: Bool
    ) -> CGSize {
        NSHostingView(
            rootView: MenuBarPanelContent(
                state: .preview(scene),
                loginItem: LoginItemController(service: PreviewLoginItemService(status: status)),
                preview: PanelPreviewOptions(presentsOptions: presentsOptions)
            )
        ).fittingSize
    }

    @Test("Ouvrir les options ne change pas la taille du panneau", arguments: BridgeState.PanelScene.allCases)
    func panelKeepsItsSize(scene: BridgeState.PanelScene) {
        let closed = panelSize(scene, loginItem: .disabled, presentsOptions: false)
        #expect(closed.width == PanelMetrics.width)
        #expect(panelSize(scene, loginItem: .disabled, presentsOptions: true) == closed)
    }

    /// Le message de l'ouverture de session se lit dans la fenêtre surgissante, et la rangée le signale :
    /// il ne déplie plus rien dans le panneau.
    @Test("Un message de l'ouverture de session n'allonge pas le panneau")
    func loginItemMessageKeepsPanelSize() {
        let quiet = panelSize(.streaming, loginItem: .disabled, presentsOptions: false)
        #expect(panelSize(.streaming, loginItem: .requiresApproval, presentsOptions: false) == quiet)
        #expect(panelSize(.streaming, loginItem: .requiresApproval, presentsOptions: true) == quiet)
    }

    @Test("La pointe de la carte tient dans son cadre, au milieu du bord inférieur")
    func beakStaysInFrame() {
        let frame = CGRect(x: 0, y: 0, width: 304, height: 240)
        let beak = PanelMetrics.popupBeak
        let pointed = PanelPopupShape(cornerRadius: PanelMetrics.popupRadius, beakHeight: beak).path(in: frame)
        let bounds = pointed.boundingRect
        #expect(frame.insetBy(dx: -0.01, dy: -0.01).contains(bounds))
        // La pointe est arrondie : elle s'arrête un peu avant le bord, jamais au-delà.
        #expect(bounds.maxY > frame.maxY - 2)
        #expect(pointed.contains(CGPoint(x: frame.midX, y: frame.maxY - beak / 2)))
        // De part et d'autre de la pointe, la carte s'arrête au-dessus d'elle.
        #expect(!pointed.contains(CGPoint(x: frame.midX - 3 * beak, y: frame.maxY - beak / 2)))
        #expect(pointed.contains(CGPoint(x: frame.midX - 3 * beak, y: frame.maxY - beak - 2)))
    }

    @Test("Sans pointe, la carte occupe tout son cadre")
    func plainCardFillsFrame() {
        let frame = CGRect(x: 0, y: 0, width: 304, height: 240)
        let plain = PanelPopupShape(cornerRadius: PanelMetrics.popupRadius, beakHeight: 0).path(in: frame)
        #expect(plain.boundingRect == frame)
        #expect(plain.contains(CGPoint(x: frame.midX, y: frame.maxY - 1)))
    }
}
