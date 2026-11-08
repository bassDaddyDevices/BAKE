import Foundation

/// One problem that stops a graph from compiling. Carries node/pin IDs so the canvas can highlight it.
public enum CompileError: Error, Hashable, Sendable {
    /// No Print node, so nothing would be baked.
    case noOutput
    case duplicateNode(NodeID)
    case unknownNode(NodeID)
    case unknownPin(PinRef)
    /// Edges must run from an output pin to an input pin.
    case wrongDirection(Edge)
    /// Control signals can't feed audio inputs.
    case typeMismatch(Edge)
    case multipleEdgesToInput(PinRef)
    /// A Page 2 tick on a parameter that can't be modulated.
    case invalidModulation(NodeID, ParameterID)
    case invalidParameter(NodeID, ParameterID)
    case missingInput(PinRef)
    /// Nodes that couldn't be ordered: the loop itself and anything downstream of it.
    case cycle([NodeID])
    case unresolvableAsset(NodeID)
    /// A node would render zero or fewer frames.
    case invalidLength(NodeID)
    /// A custom node whose definition isn't in the document.
    case missingCustomDefinition(NodeID)
    /// A custom node whose definition holds another custom node (not in v1).
    case nestedCustomNode(NodeID)
    /// A custom node whose definition holds a Bake or Preview node.
    case outputInCustomNode(NodeID)
    /// A Bake or Preview whose WAV would pass 4 GB, more than the format can hold.
    case outputTooLarge(NodeID, bytes: Int)
    /// A node inside a feedback loop looks ahead in its input (or analyses all of it), which a loop
    /// rendered in short blocks can't give it.
    case feedbackNotCausal(NodeID)
    /// A node inside a feedback loop renders a different length from the loop's Feedback node.
    case feedbackLengthMismatch(NodeID)
    /// A Feedback node (or another loop's node) inside a feedback loop; not supported in v1.
    case nestedFeedback(NodeID)
}

extension CompileError {
    /// The same error with every node it names passed through `map` (a flattened node → its custom node).
    func mappingNodes(_ map: (NodeID) -> NodeID) -> CompileError {
        func pin(_ ref: PinRef) -> PinRef {
            let node = map(ref.node)
            return node == ref.node ? ref : PinRef(node: node, pin: ref.pin)
        }
        func edge(_ edge: Edge) -> Edge { Edge(from: pin(edge.from), to: pin(edge.to)) }
        switch self {
        case .noOutput: return self
        case .duplicateNode(let node): return .duplicateNode(map(node))
        case .unknownNode(let node): return .unknownNode(map(node))
        case .unknownPin(let ref): return .unknownPin(pin(ref))
        case .wrongDirection(let value): return .wrongDirection(edge(value))
        case .typeMismatch(let value): return .typeMismatch(edge(value))
        case .multipleEdgesToInput(let ref): return .multipleEdgesToInput(pin(ref))
        case .invalidModulation(let node, let parameter): return .invalidModulation(map(node), parameter)
        case .invalidParameter(let node, let parameter): return .invalidParameter(map(node), parameter)
        case .missingInput(let ref): return .missingInput(pin(ref))
        case .cycle(let nodes):
            var seen: Set<NodeID> = []
            return .cycle(nodes.map(map).filter { seen.insert($0).inserted })
        case .unresolvableAsset(let node): return .unresolvableAsset(map(node))
        case .invalidLength(let node): return .invalidLength(map(node))
        case .missingCustomDefinition(let node): return .missingCustomDefinition(map(node))
        case .nestedCustomNode(let node): return .nestedCustomNode(map(node))
        case .outputInCustomNode(let node): return .outputInCustomNode(map(node))
        case .outputTooLarge(let node, let bytes): return .outputTooLarge(map(node), bytes: bytes)
        case .feedbackNotCausal(let node): return .feedbackNotCausal(map(node))
        case .feedbackLengthMismatch(let node): return .feedbackLengthMismatch(map(node))
        case .nestedFeedback(let node): return .nestedFeedback(map(node))
        }
    }
}

/// Every problem found in the first stage that failed.
public struct CompileFailure: Error, Equatable, Sendable {
    /// An error that came from inside a custom node, as its definition's own cards see it.
    public struct Inside: Equatable, Sendable {
        public let instance: NodeID
        public let definition: UUID
        public let error: CompileError
    }

    /// Every error on the cards the patch shows: one inside a custom node is on the custom node.
    public let errors: [CompileError]
    /// For each of `errors` (by index) that came from inside a custom node: the same error there.
    public let inside: [Int: Inside]

    public init(errors: [CompileError], inside: [Int: Inside] = [:]) {
        self.errors = errors
        self.inside = inside
    }
}
