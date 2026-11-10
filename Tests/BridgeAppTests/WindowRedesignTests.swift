import CoreGraphics
import Foundation
import Testing

@testable import BridgeApp

/// Ce que la fenêtre dit et dessine, hors des vues : la légende d'une carte d'enceinte, le sol de la pièce,
/// l'onde des enceintes qui jouent.
@Suite("Fenêtre — carte d'enceinte, sol et onde")
struct WindowRedesignTests {
    // MARK: - Légende d'une carte

    @Test("Cochée, la carte dit l'état ; décochée, seulement ce qu'elle est")
    func captionStates() {
        func caption(_ connection: OutputConnectionState, enabled: Bool = true, muted: Bool = false) -> String {
            SpeakerCardCaption.text(
                connection: connection, isEnabled: enabled, isMuted: muted, proto: "AirPlay 2", partners: []
            )
        }
        #expect(caption(.streaming) == "Diffusion")
        #expect(caption(.streaming, muted: true) == "Coupée")
        #expect(caption(.connecting) == "Connexion…")
        #expect(caption(.idle) == "Prête")
        #expect(caption(.failed("refus")) == "Échec")
        #expect(caption(.idle, enabled: false) == "AirPlay 2")
        // Décochée, une session qui s'attarde ne fait pas dire « Diffusion » à une enceinte qu'on a retirée.
        #expect(caption(.streaming, enabled: false) == "AirPlay 2")
    }

    @Test("La paire stéréo suit l'état, cochée ou non")
    func captionNamesThePair() {
        let streaming = SpeakerCardCaption.text(
            connection: .streaming, isEnabled: true, isMuted: false, proto: "AirPlay 2",
            partners: ["Salon (2)"]
        )
        #expect(streaming == "Diffusion · stéréo avec Salon (2)")
        let unchecked = SpeakerCardCaption.text(
            connection: .idle, isEnabled: false, isMuted: false, proto: "AirPlay 2", partners: ["Salon"]
        )
        #expect(unchecked == "AirPlay 2 · stéréo avec Salon")
    }

    // MARK: - Sol de la pièce

    private func wall(_ ax: Double, _ ay: Double, _ bx: Double, _ by: Double) -> RoomLayout.WallSegment {
        RoomLayout.WallSegment(a: CGPoint(x: ax, y: ay), b: CGPoint(x: bx, y: by))
    }

    @Test("Quatre murs bout à bout donnent un sol à quatre coins")
    func closedRoom() {
        let walls = [wall(0, 0, 4, 0), wall(4, 0, 4, 3), wall(4, 3, 0, 3), wall(0, 3, 0, 0)]
        let outlines = PlanRenderer.floorOutlines(of: walls)
        #expect(outlines.count == 1)
        #expect(Set(outlines.first?.map { "\($0.x),\($0.y)" } ?? []) == ["0.0,0.0", "4.0,0.0", "4.0,3.0", "0.0,3.0"])
    }

    @Test("Une porte laisse la suite ouverte : le sol se referme d'un trait, dans l'ordre des murs")
    func roomWithDoor() {
        // Le quatrième mur manque : c'est la porte. Le premier mur de la liste est celui du milieu : partir
        // de son coin donnerait un polygone croisé.
        let walls = [wall(4, 0, 4, 3), wall(0, 0, 4, 0), wall(4, 3, 0, 3)]
        let outlines = PlanRenderer.floorOutlines(of: walls)
        #expect(outlines.count == 1)
        let corners = outlines.first ?? []
        #expect(corners.count == 4)
        // D'un bout à l'autre, jamais en partant du milieu : sinon le polygone se croiserait.
        #expect(corners.first == CGPoint(x: 0, y: 0) || corners.first == CGPoint(x: 0, y: 3))
        #expect(corners.last == CGPoint(x: 0, y: 3) || corners.last == CGPoint(x: 0, y: 0))
        #expect(corners.first != corners.last)
    }

    @Test("Des murs tracés dans le désordre ou à rebours donnent le même sol")
    func unorderedWalls() {
        let walls = [wall(4, 3, 0, 3), wall(4, 0, 0, 0), wall(0, 0, 0, 3), wall(4, 0, 4, 3)]
        #expect(PlanRenderer.floorOutlines(of: walls).first?.count == 4)
    }

    @Test("Un mur seul, un point, ou un embranchement ne donnent aucun sol")
    func noFloor() {
        #expect(PlanRenderer.floorOutlines(of: []).isEmpty)
        #expect(PlanRenderer.floorOutlines(of: [wall(0, 0, 4, 0)]).isEmpty)
        #expect(PlanRenderer.floorOutlines(of: [wall(1, 1, 1, 1)]).isEmpty)
        // Un T : trois murs partent du même coin. Mieux vaut aucun sol qu'un sol faux.
        let branching = [wall(0, 0, 2, 0), wall(2, 0, 4, 0), wall(2, 0, 2, 3), wall(2, 3, 0, 3)]
        #expect(PlanRenderer.floorOutlines(of: branching).isEmpty)
    }

    @Test("Deux pièces séparées ont chacune leur sol")
    func twoRooms() {
        let first = [wall(0, 0, 2, 0), wall(2, 0, 2, 2), wall(2, 2, 0, 2), wall(0, 2, 0, 0)]
        let second = [wall(5, 0, 7, 0), wall(7, 0, 7, 2), wall(7, 2, 5, 2), wall(5, 2, 5, 0)]
        #expect(PlanRenderer.floorOutlines(of: first + second).count == 2)
    }

    // MARK: - Onde

    @Test("Trois anneaux, régulièrement espacés dans la course")
    func ringsAreEvenlySpaced() {
        let rings = SpeakerPulse.rings(at: 0)
        #expect(rings.count == SpeakerPulse.ringCount)
        let progress = rings.map(\.progress).sorted()
        #expect(abs(progress[1] - progress[0] - 1.0 / 3) < 1e-9)
        #expect(abs(progress[2] - progress[1] - 1.0 / 3) < 1e-9)
    }

    @Test("Un anneau naît et meurt transparent : la boucle n'a pas de couture")
    func ringsFadeAtBothEnds() {
        // Juste avant et juste après le retour au bord.
        let ending = SpeakerPulse.rings(at: SpeakerPulse.period * 0.9999)[0]
        let starting = SpeakerPulse.rings(at: SpeakerPulse.period * 1.0001)[0]
        #expect(ending.progress > 0.99)
        #expect(starting.progress < 0.01)
        #expect(ending.opacity < 0.01)
        #expect(starting.opacity < 0.01)
        // Au plus fort, il reste discret.
        let peak = (0..<200).map { SpeakerPulse.rings(at: SpeakerPulse.period * Double($0) / 200)[0].opacity }.max()
        #expect((peak ?? 0) > 0.3)
        #expect((peak ?? 1) <= 0.6)
    }

    @Test("La même onde revient à chaque période")
    func ringsArePeriodic() {
        let now = SpeakerPulse.rings(at: 1.234)
        let later = SpeakerPulse.rings(at: 1.234 + SpeakerPulse.period)
        for (a, b) in zip(now, later) {
            #expect(abs(a.progress - b.progress) < 1e-9)
            #expect(abs(a.opacity - b.opacity) < 1e-9)
        }
    }
}
