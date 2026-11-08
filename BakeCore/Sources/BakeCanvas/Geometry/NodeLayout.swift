import BakeGraph
import CoreGraphics

public enum PortSide: Sendable {
    case left
    case right
}

/// Where a pin sits on its card.
public struct PortSlot: Hashable, Sendable {
    public let pin: PinDefinition
    public let side: PortSide
    public let row: Int
}

/// Fixed card metrics. Pin anchors come from these numbers — not from SwiftUI layout — so wires
/// stay attached during drags; the card views use the same constants.
public enum NodeLayout {
    public static let width: CGFloat = 240
    public static let headerHeight: CGFloat = 32
    public static let portRowHeight: CGFloat = 24
    public static let pinRadius: CGFloat = 6

    /// Inputs on the left (fixed pins, then spawned modulation pins), outputs on the right; each
    /// side fills rows from the top.
    public static func ports(of node: Node, in project: ProjectFile) -> [PortSlot] {
        let pins = NodeCatalog.pins(of: node, in: project)
        let inputs = pins.filter { $0.direction == .input }
        let outputs = pins.filter { $0.direction == .output }
        return inputs.enumerated().map { PortSlot(pin: $1, side: .left, row: $0) }
            + outputs.enumerated().map { PortSlot(pin: $1, side: .right, row: $0) }
    }

    public static func portRows(of node: Node, in project: ProjectFile) -> Int {
        let pins = NodeCatalog.pins(of: node, in: project)
        let inputs = pins.count { $0.direction == .input }
        return max(inputs, pins.count - inputs, 1)
    }

    /// A pin's centre in world coordinates. `Node.position` is the card's top-left corner.
    public static func anchor(of pin: PinID, on node: Node, in project: ProjectFile) -> CGPoint? {
        guard let slot = ports(of: node, in: project).first(where: { $0.pin.id == pin }) else { return nil }
        let x = CGFloat(node.position.x) + (slot.side == .left ? 0 : width)
        let y = CGFloat(node.position.y) + headerHeight + (CGFloat(slot.row) + 0.5) * portRowHeight
        return CGPoint(x: x, y: y)
    }
}
