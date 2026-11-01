import CoreGraphics
import Foundation
import Testing

@testable import BridgeApp

@Suite("Plan de la pièce — géométrie")
struct RoomLayoutTests {
    private func speaker(_ output: String, x: Double, y: Double, elevation: Double = 1.10)
        -> RoomObject
    {
        RoomObject(
            kind: .speaker(outputID: output), position: CGPoint(x: x, y: y),
            size: CGSize(width: 0.15, height: 0.15), elevation: elevation, shape: .ellipse
        )
    }

    private let listener = RoomObject(
        kind: .listener, position: .zero, size: CGSize(width: 0.45, height: 0.40), elevation: 1.10
    )

    @Test("La sortie la plus lointaine garde 0 ms, les autres se retardent de leur avance")
    func suggestedDelaysFollowDistance() throws {
        let layout = RoomLayout(
            objects: [listener, speaker("proche", x: 1, y: 0), speaker("loin", x: 4.43, y: 0)]
        )
        let delays = layout.suggestedDelaysMS(for: ["proche", "loin"])
        #expect(delays["loin"] == 0)
        // 3,43 m d'écart à 343 m/s : 10 ms exactement.
        #expect(abs(try #require(delays["proche"]) - 10) < 0.001)
    }

    @Test("Quatre quarts de tour ramènent le plan à son point de départ")
    func fourQuarterTurnsAreIdentity() {
        let layout = RoomLayout(
            walls: [RoomLayout.WallSegment(a: CGPoint(x: 0, y: 0), b: CGPoint(x: 3, y: 1))],
            objects: [speaker("a", x: 1, y: 2)]
        )
        var rotated = layout
        for _ in 0..<4 { rotated = rotated.rotatedQuarterTurn(clockwise: true) }
        #expect(abs(rotated.walls[0].b.x - 3) < 1e-9)
        #expect(abs(rotated.objects[0].position.y - 2) < 1e-9)
    }
}
