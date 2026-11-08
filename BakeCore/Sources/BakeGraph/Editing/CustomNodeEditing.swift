import Foundation

extension ProjectFile {
    /// Whether these nodes can become one custom node: some nodes, all present, none of them the
    /// patch's own in or out (Audio, Bake, Preview), a custom node or a custom node's boundary (no
    /// nesting in v1), and every feedback loop wholly inside or wholly outside (a loop cut in two
    /// would be a cycle through the custom node).
    public func canGroup(_ ids: Set<NodeID>) -> Bool {
        let members = nodes.filter { ids.contains($0.id) }
        guard !members.isEmpty, members.count == ids.count, members.allSatisfy({ node in
            !node.kind.isOutput && !node.kind.isBatch && ![.audio, .custom, .customInput, .customOutput].contains(node.kind)
        }) else { return false }
        return feedbackLoops().allSatisfy { $0.members.isSubset(of: ids) || $0.members.isDisjoint(with: ids) }
    }

    /// Turns nodes into one custom node (Group Selection). Wires that crossed the selection come in
    /// through the Inputs card (one port per outside source, so a source feeding several nodes inside
    /// is one pin) and leave through the Outputs card (one port per inside source). Ports are named
    /// after what they reach inside and ordered like the cards outside, so wires stay straight; the
    /// custom node takes the group's place, and every Macro inside becomes one of its controls.
    /// Returns the custom node.
    @discardableResult
    public mutating func groupNodes(_ ids: Set<NodeID>, name: String? = nil) -> NodeID? {
        guard canGroup(ids) else { return nil }
        let members = nodes.filter { ids.contains($0.id) }
        let inside = edges.filter { ids.contains($0.from.node) && ids.contains($0.to.node) }
        let incoming = edges.filter { !ids.contains($0.from.node) && ids.contains($0.to.node) }
        let outgoing = edges.filter { ids.contains($0.from.node) && !ids.contains($0.to.node) }

        // Inputs in the order of their sources outside (top to bottom), outputs in the order of what
        // they feed outside.
        var sources: [PinRef] = []
        for edge in incoming.sorted(by: { place(of: $0.from) < place(of: $1.from) }) where !sources.contains(edge.from) {
            sources.append(edge.from)
        }
        func firstConsumer(_ result: PinRef) -> (Double, Double, Double) {
            outgoing.filter { $0.from == result }.map { place(of: $0.to) }.min { $0 < $1 } ?? (0, 0, 0)
        }
        var results: [PinRef] = []
        for edge in outgoing where !results.contains(edge.from) { results.append(edge.from) }
        results.sort { firstConsumer($0) < firstConsumer($1) }

        var inputPorts: [CustomPort] = []
        for (index, source) in sources.enumerated() {
            let target = incoming.filter { $0.from == source }.map(\.to).min { place(of: $0) < place(of: $1) }
            let base = target.map(portName(for:)) ?? "In"
            inputPorts.append(CustomPort(id: "in\(index + 1)", name: Self.unique(base, among: inputPorts.map(\.name))))
        }
        var outputPorts: [CustomPort] = []
        for (index, result) in results.enumerated() {
            outputPorts.append(CustomPort(id: "out\(index + 1)", name: Self.unique(portName(for: result), among: outputPorts.map(\.name))))
        }

        let minX = members.map(\.position.x).min() ?? 0
        let minY = members.map(\.position.y).min() ?? 0
        let maxX = members.map(\.position.x).max() ?? 0
        let gap = 300.0
        let inputCard = Node(kind: .customInput, position: CanvasPoint(x: minX - gap, y: minY), ports: inputPorts)
        let outputCard = Node(kind: .customOutput, position: CanvasPoint(x: maxX + gap, y: minY), ports: outputPorts)
        var innerEdges = inside
        for edge in incoming {
            guard let index = sources.firstIndex(of: edge.from) else { continue }
            innerEdges.append(Edge(from: PinRef(node: inputCard.id, pin: inputPorts[index].id), to: edge.to))
        }
        for (index, result) in results.enumerated() {
            innerEdges.append(Edge(from: result, to: PinRef(node: outputCard.id, pin: outputPorts[index].id)))
        }

        let definition = CustomNodeDefinition(
            name: name ?? "Custom \(customNodes.count + 1)", nodes: [inputCard] + members + [outputCard], edges: innerEdges
        )
        var instance = Node(kind: .custom, position: CanvasPoint(x: minX, y: minY), customDefinition: definition.id)
        for (index, macro) in definition.macros.enumerated() {
            instance.parameters[CustomNodeDefinition.macroParameter(index + 1)] = macro.parameters["value"] ?? .number(0)
        }

        var outerEdges = edges.filter { !ids.contains($0.from.node) && !ids.contains($0.to.node) }
        for (index, source) in sources.enumerated() {
            outerEdges.append(Edge(from: source, to: PinRef(node: instance.id, pin: inputPorts[index].id)))
        }
        for edge in outgoing {
            guard let index = results.firstIndex(of: edge.from) else { continue }
            outerEdges.append(Edge(from: PinRef(node: instance.id, pin: outputPorts[index].id), to: edge.to))
        }

        // The custom node takes the first member's place in creation order.
        let slot = nodes.firstIndex { ids.contains($0.id) } ?? nodes.endIndex
        nodes.removeAll { ids.contains($0.id) }
        nodes.insert(instance, at: min(slot, nodes.endIndex))
        edges = outerEdges
        customNodes.append(definition)
        return instance.id
    }

    /// Where a pin sits, for ordering ports: its card's top, then left, then the pin's row.
    private func place(of ref: PinRef) -> (Double, Double, Double) {
        guard let node = node(ref.node) else { return (0, 0, 0) }
        let row = NodeCatalog.pins(of: node, in: self).firstIndex { $0.id == ref.pin } ?? 0
        return (node.position.y, node.position.x, Double(row))
    }

    /// Puts a custom node's nodes back in its place (Ungroup): the inverse of `groupNodes`. Nodes keep
    /// their IDs from the definition unless another node already has one. A definition no other
    /// custom node uses is removed. Returns the restored nodes.
    @discardableResult
    public mutating func ungroup(_ id: NodeID) -> Set<NodeID> {
        guard let instance = node(id), let definition = definition(of: instance) else { return [] }
        let taken = Set(nodes.map(\.id))
        let naming: CustomNodeFlattener.Naming = definition.nodes.contains { taken.contains($0.id) } ? .derived : .original
        let flat = CustomNodeFlattener.flatten(self, only: id, naming: naming)
        guard flat.errors.isEmpty else { return [] }
        let restored = Set(flat.origin.keys)
        self = flat.project
        if !nodes.contains(where: { $0.customDefinition == definition.id }) {
            customNodes.removeAll { $0.id == definition.id }
        }
        return restored
    }
}

extension ProjectFile {
    /// What the canvas edits inside a custom node (Edit Inside): the definition's nodes and wires, with
    /// the document's settings, files and definitions, and always an Inputs and an Outputs card to
    /// wire onto. Nil if the document has no such definition.
    public func inside(_ definition: UUID) -> ProjectFile? {
        guard let found = customNodes.first(where: { $0.id == definition }) else { return nil }
        var nodes = found.nodes
        let left = (nodes.map(\.position.x).min() ?? 0) - 300
        let right = (nodes.map(\.position.x).max() ?? 0) + 300
        let top = nodes.map(\.position.y).min() ?? 0
        if found.inputCard == nil { nodes.insert(Node(kind: .customInput, position: CanvasPoint(x: left, y: top), ports: []), at: 0) }
        if found.outputCard == nil { nodes.append(Node(kind: .customOutput, position: CanvasPoint(x: right, y: top), ports: [])) }
        return ProjectFile(
            schemaVersion: schemaVersion, settings: settings, nodes: nodes, edges: found.edges,
            assets: assets, customNodes: customNodes
        )
    }

    /// Writes an edited `inside` view back into its definition, so every custom node using it changes.
    /// Files are merged and then pruned against the whole document: the inside view can't see the
    /// patch's own Audio nodes, so its file list alone would drop them. Wires to pins a custom node
    /// no longer has (a port removed, a control no longer promoted) are dropped.
    public mutating func storeInside(_ inner: ProjectFile, into definition: UUID) {
        guard let index = customNodes.firstIndex(where: { $0.id == definition }) else { return }
        customNodes[index].nodes = inner.nodes
        customNodes[index].edges = inner.edges
        let known = Set(assets.map(\.id))
        assets += inner.assets.filter { !known.contains($0.id) }
        pruneUnusedAssets()
        let instances = Set(nodes.filter { $0.customDefinition == definition }.map(\.id))
        let stale = Set(edges.filter { edge in
            (instances.contains(edge.from.node) && pin(edge.from) == nil) || (instances.contains(edge.to.node) && pin(edge.to) == nil)
        })
        edges.removeAll { stale.contains($0) }
    }

    /// Adds a custom node using one of the document's definitions, with its controls at the values inside.
    @discardableResult
    public mutating func addCustomNode(_ definition: UUID, at position: CanvasPoint) -> NodeID? {
        guard let found = customNodes.first(where: { $0.id == definition }) else { return nil }
        var node = Node(kind: .custom, position: position, customDefinition: definition)
        for control in found.interface.controls {
            node.parameters[control.id] = control.defaultValue
        }
        nodes.append(node)
        return node.id
    }
}

/// Shaping a custom node's interface from inside it: its Inputs and Outputs cards' ports, and which
/// inner parameters it shows as its own controls.
extension ProjectFile {
    public mutating func renamePort(_ pin: PinID, of card: NodeID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = index(of: card),
              let port = nodes[index].ports?.firstIndex(where: { $0.id == pin }) else { return }
        nodes[index].ports?[port].name = trimmed
    }

    /// Moves a port up (negative) or down; the custom node's pins follow, and every wire stays on its pin.
    public mutating func movePort(_ pin: PinID, of card: NodeID, by offset: Int) {
        guard let index = index(of: card), var ports = nodes[index].ports,
              let from = ports.firstIndex(where: { $0.id == pin }) else { return }
        let to = min(max(from + offset, 0), ports.count - 1)
        guard to != from else { return }
        ports.insert(ports.remove(at: from), at: to)
        nodes[index].ports = ports
    }

    /// Removes a port and its wires inside; `storeInside` drops the wires outside.
    public mutating func removePort(_ pin: PinID, of card: NodeID) {
        guard let index = index(of: card) else { return }
        nodes[index].ports?.removeAll { $0.id == pin }
        edges.removeAll { ($0.from.node == card && $0.from.pin == pin) || ($0.to.node == card && $0.to.pin == pin) }
    }

    /// Shows or hides an inner parameter on the custom node (ComfyUI's widget promotion).
    public mutating func setPromoted(_ parameter: ParameterID, of node: NodeID, _ isPromoted: Bool) {
        guard let index = index(of: node), Self.canPromote(nodes[index].kind),
              NodeCatalog.definition(for: nodes[index].kind).parameter(parameter) != nil else { return }
        var promoted = nodes[index].promoted ?? []
        promoted.removeAll { $0 == parameter }
        if isPromoted { promoted.append(parameter) }
        nodes[index].promoted = promoted.isEmpty ? nil : promoted
    }

    /// Whether a node's parameters can be promoted: anything inside but the boundary cards, outputs and
    /// Macros (a Macro is already a control).
    public static func canPromote(_ kind: NodeKind) -> Bool {
        !kind.isOutput && ![.custom, .customInput, .customOutput, .macro].contains(kind)
    }

    /// A name for a port wired to `ref`, after what's there: the parameter for a modulation pin
    /// ("Cutoff"), the card for its main pin ("Filters"), the card and pin otherwise ("Vocoder Carrier").
    func portName(for ref: PinRef) -> String {
        guard let node = node(ref.node) else { return "" }
        let label = NodeCatalog.label(of: ref.pin, on: node, in: self)
        if NodeCatalog.parameter(forModulationPin: ref.pin) != nil, !label.isEmpty { return label }
        if [.customInput, .customOutput].contains(node.kind) { return label.isEmpty ? "Thru" : label }
        let title = node.kind == .custom ? (definition(of: node)?.name ?? node.kind.title) : node.kind.title
        return ["", "In", "Out"].contains(label) ? title : "\(title) \(label)"
    }

    /// `base`, or `base 2`, `base 3`… if a sibling already has it.
    static func unique(_ base: String, among names: [String]) -> String {
        guard names.contains(base) else { return base }
        var number = 2
        while names.contains("\(base) \(number)") { number += 1 }
        return "\(base) \(number)"
    }
}

extension ProjectFile {
    /// Whether a chain can become a Feedback Group: it can be grouped, holds no Feedback node of its
    /// own, and has audio coming in and going out.
    public func canMakeFeedbackGroup(_ ids: Set<NodeID>) -> Bool {
        guard canGroup(ids), !nodes.contains(where: { ids.contains($0.id) && $0.kind == .feedback }) else { return false }
        func audio(_ ref: PinRef) -> Bool { pin(ref)?.signal == .audio }
        let entersAudio = edges.contains { !ids.contains($0.from.node) && ids.contains($0.to.node) && audio($0.to) }
        let leavesAudio = edges.contains { ids.contains($0.from.node) && !ids.contains($0.to.node) && audio($0.from) }
        return entersAudio && leavesAudio
    }

    /// Turns a chain into a Feedback Group (issue 004): a custom node with a Feedback node inside,
    /// whose Out feeds the chain and whose Return is the chain's end. Its first audio input comes
    /// in through the Feedback node, its first audio output is the chain's end, and the Feedback
    /// node's Feedback, Delay and Drive show on the card. Returns the custom node.
    @discardableResult
    public mutating func makeFeedbackGroup(_ ids: Set<NodeID>) -> NodeID? {
        guard canMakeFeedbackGroup(ids) else { return nil }
        let number = customNodes.count { $0.name.hasPrefix("Feedback") } + 1
        guard let custom = groupNodes(ids, name: "Feedback \(number)"),
              let instance = node(custom), let index = customNodes.firstIndex(where: { $0.id == instance.customDefinition }),
              let interface = customInterface(of: instance),
              let entry = interface.inputs.first(where: { $0.signal == .audio }),
              let exit = interface.outputs.first(where: { $0.signal == .audio }) else { return nil }
        var definition = customNodes[index]
        guard let inputCard = definition.inputCard, let outputCard = definition.outputCard,
              let end = definition.edges.first(where: { $0.to == PinRef(node: outputCard.id, pin: exit.id) })?.from else { return nil }

        // The Feedback node sits where the Inputs card was; the Inputs card moves left of it.
        var feedback = Node(kind: .feedback, position: inputCard.position, parameters: NodeCatalog.defaultParameters(for: .feedback))
        feedback.promoted = ["gain", "delay", "drive"]
        let entryPin = PinRef(node: inputCard.id, pin: entry.id)
        var edges = definition.edges.map { edge in
            edge.from == entryPin ? Edge(from: PinRef(node: feedback.id, pin: "out"), to: edge.to) : edge
        }
        edges.append(Edge(from: entryPin, to: PinRef(node: feedback.id, pin: "in")))
        edges.append(Edge(from: end, to: PinRef(node: feedback.id, pin: "return")))
        var nodes = definition.nodes
        if let card = nodes.firstIndex(where: { $0.id == inputCard.id }) { nodes[card].position.x -= 300 }
        nodes.insert(feedback, at: 1)
        definition.nodes = nodes
        definition.edges = edges
        customNodes[index] = definition
        return custom
    }
}

extension ProjectFile {
    /// Renames a definition: every custom node using it shows the new name.
    public mutating func renameCustomNode(_ definition: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = customNodes.firstIndex(where: { $0.id == definition }) else { return }
        customNodes[index].name = trimmed
    }
}
