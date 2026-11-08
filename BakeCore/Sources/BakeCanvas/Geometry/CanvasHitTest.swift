import BakeGraph
import CoreGraphics

/// Geometric hit tests in world coordinates; callers divide view tolerances by the zoom scale.
public enum CanvasHitTest {
    /// The pin nearest `point` within `radius`.
    public static func pin(at point: CGPoint, in project: ProjectFile, radius: CGFloat = 12) -> PinRef? {
        var best: (pin: PinRef, distance: CGFloat)?
        for node in project.nodes {
            for slot in NodeLayout.ports(of: node, in: project) {
                guard let anchor = NodeLayout.anchor(of: slot.pin.id, on: node, in: project) else { continue }
                let distance = hypot(point.x - anchor.x, point.y - anchor.y)
                if distance <= radius, distance < (best?.distance ?? .infinity) {
                    best = (PinRef(node: node.id, pin: slot.pin.id), distance)
                }
            }
        }
        return best?.pin
    }

    /// The wire nearest `point` within `tolerance`.
    public static func edge(at point: CGPoint, in project: ProjectFile, tolerance: CGFloat = 6) -> Edge? {
        var best: (edge: Edge, distance: CGFloat)?
        for edge in project.edges {
            guard let curve = WireCurve(edge: edge, in: project) else { continue }
            let distance = curve.distance(to: point)
            if distance <= tolerance, distance < (best?.distance ?? .infinity) {
                best = (edge, distance)
            }
        }
        return best?.edge
    }
}
