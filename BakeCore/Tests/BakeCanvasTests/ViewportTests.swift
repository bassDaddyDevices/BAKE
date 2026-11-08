import BakeGraph
import CoreGraphics
import Testing
@testable import BakeCanvas

struct ViewportTests {
    @Test func worldAndViewRoundTrip() {
        let viewport = Viewport(offset: CGPoint(x: 30, y: -20), scale: 2)
        let world = CGPoint(x: 10, y: 5)
        #expect(viewport.toView(world) == CGPoint(x: 50, y: -10))
        #expect(viewport.toWorld(viewport.toView(world)) == world)
    }

    @Test func zoomKeepsThePointUnderTheCursorFixed() {
        var viewport = Viewport(offset: CGPoint(x: 100, y: 50), scale: 1)
        let cursor = CGPoint(x: 300, y: 200)
        let before = viewport.toWorld(cursor)
        viewport.zoom(by: 1.5, around: cursor)
        let after = viewport.toWorld(cursor)
        #expect(viewport.scale == 1.5)
        #expect(abs(after.x - before.x) < 1e-9 && abs(after.y - before.y) < 1e-9)
    }

    @Test func scaleIsClamped() {
        var viewport = Viewport()
        viewport.zoom(by: 100, around: .zero)
        #expect(viewport.scale == Viewport.scaleRange.upperBound)
        viewport.zoom(by: 0.0001, around: .zero)
        #expect(viewport.scale == Viewport.scaleRange.lowerBound)
    }

    @Test func panningMovesTheOffset() {
        var viewport = Viewport()
        viewport.pan(by: CGSize(width: 12, height: -4))
        #expect(viewport.offset == CGPoint(x: 12, y: -4))
    }

    @Test func canvasPointsConvert() {
        #expect(CGPoint(CanvasPoint(x: 1.5, y: -2)) == CGPoint(x: 1.5, y: -2))
        #expect(CanvasPoint(CGPoint(x: 3, y: 4)) == CanvasPoint(x: 3, y: 4))
    }
}
