/// Why a wire can't be made. The canvas uses these to dim invalid drop targets.
public enum ConnectionRejection: Error, Hashable, Sendable {
    case unknownPin
    case sameNode
    /// Wires run from an output pin to an input pin.
    case notOutputToInput
    /// Control signals can't feed audio inputs.
    case typeMismatch
    /// Inputs take one wire.
    case inputOccupied
    case cycle
}

/// Edits the canvas makes. Each keeps the graph valid under the compiler's structure rules
/// (see StructureValidator), so a hand-built graph never fails for structural reasons.
extension ProjectFile {
    public func index(of node: NodeID) -> Int? {
        nodes.firstIndex { $0.id == node }
    }

    public func node(_ id: NodeID) -> Node? {
        index(of: id).map { nodes[$0] }
    }

    public func pin(_ ref: PinRef) -> PinDefinition? {
        guard let node = node(ref.node) else { return nil }
        return NodeCatalog.pins(of: node, in: self).first { $0.id == ref.pin }
    }

    /// The wire feeding an input, if any.
    public func edge(into input: PinRef) -> Edge? {
        edges.first { $0.to == input }
    }

    /// Adds a node with every parameter stored at its catalog default (so later default changes never
    /// alter this document); `position` is its card's top-left corner in world coordinates.
    @discardableResult
    public mutating func addNode(_ kind: NodeKind, at position: CanvasPoint, id: NodeID = NodeID()) -> NodeID {
        nodes.append(Node(id: id, kind: kind, position: position, parameters: NodeCatalog.defaultParameters(for: kind)))
        return id
    }

    public mutating func moveNodes(_ ids: Set<NodeID>, byX dx: Double, y dy: Double) {
        for index in nodes.indices where ids.contains(nodes[index].id) {
            nodes[index].position.x += dx
            nodes[index].position.y += dy
        }
    }

    /// Removes nodes, every wire touching them, and audio files no remaining node uses.
    public mutating func removeNodes(_ ids: Set<NodeID>) {
        let neighbours = Set(edges.filter { ids.contains($0.from.node) || ids.contains($0.to.node) }
            .flatMap { [$0.from.node, $0.to.node] }).subtracting(ids)
        nodes.removeAll { ids.contains($0.id) }
        edges.removeAll { ids.contains($0.from.node) || ids.contains($0.to.node) }
        pruneUnusedAssets()
        normalizePins(of: neighbours)
    }

    public mutating func removeEdge(_ edge: Edge) {
        edges.removeAll { $0 == edge }
        normalizePins(of: [edge.from.node, edge.to.node])
    }

    /// Nil if a wire from `source` to `target` is allowed.
    public func checkConnection(from source: PinRef, to target: PinRef) -> ConnectionRejection? {
        guard let sourcePin = pin(source), let targetPin = pin(target) else { return .unknownPin }
        guard source.node != target.node else { return .sameNode }
        guard sourcePin.direction == .output, targetPin.direction == .input else { return .notOutputToInput }
        // Audio may drive a control input (audio-rate modulation); control may not drive audio, except
        // into an Outputs card, which hands it out of its custom node, or from an Inputs card, whose
        // port then carries audio.
        if sourcePin.signal == .control && targetPin.signal == .audio
            && node(target.node)?.kind != .customOutput && node(source.node)?.kind != .customInput {
            return .typeMismatch
        }
        if edge(into: target) != nil { return .inputOccupied }
        // A Feedback node's Return is the one input that may close a loop.
        if !targetPin.isFeedbackReturn && isDownstream(source.node, of: target.node) { return .cycle }
        return nil
    }

    public mutating func connect(from source: PinRef, to target: PinRef) throws(ConnectionRejection) {
        if let rejection = checkConnection(from: source, to: target) { throw rejection }
        edges.append(Edge(from: source, to: target))
        addPortIfSpare(source, wiredTo: target)
        addPortIfSpare(target, wiredTo: source)
        normalizePins(of: [source.node, target.node])
    }

    /// A wire onto an Inputs or Outputs card's spare pin makes it a port, named after the other end.
    private mutating func addPortIfSpare(_ end: PinRef, wiredTo other: PinRef) {
        guard let index = index(of: end.node), [.customInput, .customOutput].contains(nodes[index].kind) else { return }
        let ports = nodes[index].ports ?? []
        guard !ports.contains(where: { $0.id == end.pin }) else { return }
        nodes[index].ports = ports + [CustomPort(id: end.pin, name: Self.unique(portName(for: other), among: ports.map(\.name)))]
    }

    /// Stores a value after checking it against the catalog (numbers clamped); wrong types are ignored.
    public mutating func setParameter(_ parameter: ParameterID, of node: NodeID, to value: ParameterValue) {
        guard let index = index(of: node),
              let definition = NodeCatalog.parameter(parameter, of: nodes[index], in: self),
              let resolved = NodeCatalog.resolve(value, for: definition) else { return }
        nodes[index].parameters[parameter] = resolved
        normalizePins(of: [node])
    }

    /// Ticks or unticks a Page 2 parameter. Unticking removes the wire on its spawned pin too.
    public mutating func setModulated(_ parameter: ParameterID, of node: NodeID, _ isModulated: Bool) {
        guard let index = index(of: node),
              NodeCatalog.parameter(parameter, of: nodes[index], in: self)?.isModulatable == true else { return }
        nodes[index].setModulated(parameter, isModulated)
        if !isModulated {
            let spawned = PinRef(node: node, pin: NodeCatalog.modulationPinID(for: parameter))
            edges.removeAll { $0.to == spawned }
        }
    }

    public mutating func setTrim(_ trim: Double, for parameter: ParameterID, of node: NodeID) {
        guard let index = index(of: node) else { return }
        nodes[index].setTrim(trim, for: parameter)
    }

    /// Keeps repeated pins consistent after an edit: growing groups end one spare past their highest
    /// wired pin, and wires to pins that no longer exist (a setting lowered a count) are dropped.
    private mutating func normalizePins(of ids: Set<NodeID>) {
        for index in nodes.indices where ids.contains(nodes[index].id) {
            let id = nodes[index].id
            for group in NodeCatalog.definition(for: nodes[index].kind).repeated {
                guard case .growing(let parameter, let minimum, let maximum) = group.count else { continue }
                let wired = edges.compactMap { edge -> Int? in
                    let end = group.direction == .input ? edge.to : edge.from
                    return end.node == id ? group.number(of: end.pin) : nil
                }
                let count = min(max((wired.max() ?? 0) + 1, minimum), maximum)
                nodes[index].parameters[parameter] = .number(Double(count))
            }
        }
        let dangling = Set(edges.filter { edge in
            (ids.contains(edge.from.node) || ids.contains(edge.to.node)) && (pin(edge.from) == nil || pin(edge.to) == nil)
        })
        if !dangling.isEmpty { edges.removeAll { dangling.contains($0) } }
    }

    /// Whether `node` can be reached by following wires forward from `start` (or is `start`).
    /// Wires that close a feedback loop don't count, so edits inside a loop aren't taken for cycles.
    func isDownstream(_ node: NodeID, of start: NodeID) -> Bool {
        ProjectFile.reach(from: [start], along: orderingEdges(), forward: true).contains(node)
    }
}
