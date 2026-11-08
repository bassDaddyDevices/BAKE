/// One pin on one node.
public struct PinRef: Hashable, Codable, Sendable {
    public var node: NodeID
    public var pin: PinID

    public init(node: NodeID, pin: PinID) {
        self.node = node
        self.pin = pin
    }
}

/// A wire from an output pin to an input pin.
public struct Edge: Hashable, Codable, Sendable {
    public var from: PinRef
    public var to: PinRef

    public init(from: PinRef, to: PinRef) {
        self.from = from
        self.to = to
    }
}
