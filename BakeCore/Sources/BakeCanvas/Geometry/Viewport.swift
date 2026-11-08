import BakeGraph
import CoreGraphics

/// Maps world coordinates (where nodes live) to view coordinates: view = world × scale + offset.
public struct Viewport: Equatable, Sendable {
    public static let scaleRange: ClosedRange<CGFloat> = 0.25...3

    public var offset: CGPoint
    public private(set) var scale: CGFloat

    public init(offset: CGPoint = .zero, scale: CGFloat = 1) {
        self.offset = offset
        self.scale = Self.clamped(scale)
    }

    public func toView(_ world: CGPoint) -> CGPoint {
        CGPoint(x: world.x * scale + offset.x, y: world.y * scale + offset.y)
    }

    public func toWorld(_ view: CGPoint) -> CGPoint {
        CGPoint(x: (view.x - offset.x) / scale, y: (view.y - offset.y) / scale)
    }

    public mutating func pan(by delta: CGSize) {
        offset.x += delta.width
        offset.y += delta.height
    }

    /// Zooms by `factor`, keeping the world point under `anchor` (view coordinates) still.
    public mutating func zoom(by factor: CGFloat, around anchor: CGPoint) {
        let world = toWorld(anchor)
        scale = Self.clamped(scale * factor)
        offset = CGPoint(x: anchor.x - world.x * scale, y: anchor.y - world.y * scale)
    }

    private static func clamped(_ scale: CGFloat) -> CGFloat {
        min(max(scale, scaleRange.lowerBound), scaleRange.upperBound)
    }
}

extension CGPoint {
    public init(_ point: CanvasPoint) {
        self.init(x: CGFloat(point.x), y: CGFloat(point.y))
    }
}

extension CanvasPoint {
    public init(_ point: CGPoint) {
        self.init(x: Double(point.x), y: Double(point.y))
    }
}
