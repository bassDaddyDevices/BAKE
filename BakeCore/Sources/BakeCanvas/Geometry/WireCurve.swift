import BakeGraph
import CoreGraphics

/// A wire: a cubic Bézier that leaves its output and enters its input horizontally.
public struct WireCurve: Equatable, Sendable {
    public let start: CGPoint
    public let control1: CGPoint
    public let control2: CGPoint
    public let end: CGPoint

    public init(from start: CGPoint, to end: CGPoint) {
        let bend = max(abs(end.x - start.x) / 2, 40)
        self.start = start
        self.end = end
        control1 = CGPoint(x: start.x + bend, y: start.y)
        control2 = CGPoint(x: end.x - bend, y: end.y)
    }

    /// The curve for a wire, from its source's output pin to its target's input pin.
    public init?(edge: Edge, in project: ProjectFile) {
        guard let source = project.node(edge.from.node), let target = project.node(edge.to.node),
              let start = NodeLayout.anchor(of: edge.from.pin, on: source, in: project),
              let end = NodeLayout.anchor(of: edge.to.pin, on: target, in: project) else { return nil }
        self.init(from: start, to: end)
    }

    public func point(at t: CGFloat) -> CGPoint {
        let u = 1 - t
        let a = u * u * u, b = 3 * u * u * t, c = 3 * u * t * t, d = t * t * t
        return CGPoint(
            x: a * start.x + b * control1.x + c * control2.x + d * end.x,
            y: a * start.y + b * control1.y + c * control2.y + d * end.y
        )
    }

    /// Distance from `point` to the curve, approximated by straight segments.
    public func distance(to point: CGPoint, segments: Int = 32) -> CGFloat {
        var best = CGFloat.infinity
        var previous = start
        for index in 1...segments {
            let next = self.point(at: CGFloat(index) / CGFloat(segments))
            best = min(best, Self.distance(from: point, toSegment: previous, next))
            previous = next
        }
        return best
    }

    private static func distance(from p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        let t = lengthSquared == 0 ? 0 : min(max(((p.x - a.x) * dx + (p.y - a.y) * dy) / lengthSquared, 0), 1)
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }
}
