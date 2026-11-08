import CryptoKit
import Foundation

/// Expands every custom node into the nodes of its definition before anything else compiles
/// (spec §12), so the scheduler, planner and engine only ever see ordinary nodes.
///
/// - Each copied node gets an ID derived from the custom node's and its own, so two instances never
///   collide and a plan is the same on every compile.
/// - A wire into the custom node's input `inK` feeds whatever the Inputs card's `inK` feeds inside; a
///   wire from its `outK` comes from whatever feeds the Outputs card's `outK`. The boundary cards
///   themselves disappear.
/// - The custom node's `macro.N` value becomes its Nth Macro's Value, and a wire into `mod.macro.N`
///   modulates that Macro's Value with the same trim. Promoted parameters work the same way on the
///   inner node's own parameter.
enum CustomNodeFlattener {
    struct Result {
        var project: ProjectFile
        /// Each copied node's custom node, to point errors back at the card the user sees.
        var origin: [NodeID: NodeID]
        /// Each copied node's ID in its definition, to point errors at the card inside.
        var inner: [NodeID: NodeID] = [:]
        /// Each custom node's outputs, by pin, as the flattened pins that produce them.
        var outputs: [NodeID: [PinID: PinRef]]
        var errors: [CompileError]
    }

    /// Where a custom node's output comes from: a node inside, or straight from one of its inputs.
    private enum Source {
        case pin(PinRef)
        case input(PinID)
    }

    private struct Expansion {
        var nodes: [Node] = []
        var edges: [Edge] = []
        /// Input pin → the flattened pins it feeds.
        var inputTargets: [PinID: [PinRef]] = [:]
        var outputSources: [PinID: Source] = [:]
        /// Flattened node → its node in the definition.
        var inner: [NodeID: NodeID] = [:]
        /// Control → the flattened pin its modulation drives.
        var controls: [ParameterID: PinRef] = [:]
    }

    /// How copied nodes are named: derived per instance (compiling), or kept as in the definition
    /// (ungrouping, when those IDs are free).
    enum Naming {
        case derived
        case original
    }

    /// Flattens every custom node, or only `only` (the others stay as they are).
    static func flatten(_ project: ProjectFile, only: NodeID? = nil, naming: Naming = .derived) -> Result {
        let instances = project.nodes.filter { $0.kind == .custom && (only == nil || $0.id == only) }
        guard !instances.isEmpty else { return Result(project: project, origin: [:], outputs: [:], errors: []) }

        var errors: [CompileError] = []
        var expansions: [NodeID: Expansion] = [:]
        var origin: [NodeID: NodeID] = [:]
        for instance in instances {
            guard let definition = project.definition(of: instance) else {
                errors.append(.missingCustomDefinition(instance.id))
                continue
            }
            // v1: no custom node inside another. A Feedback loop inside is fine: it can't reach
            // outside, since a wire around the custom node would be a cycle.
            if definition.nodes.contains(where: { $0.kind == .custom }) {
                errors.append(.nestedCustomNode(instance.id))
                continue
            }
            // Nor a Bake or Preview: every copy of the custom node would write its own.
            if definition.nodes.contains(where: { $0.kind.isOutput }) {
                errors.append(.outputInCustomNode(instance.id))
                continue
            }
            let expansion = expand(instance, definition, in: project, naming: naming)
            for node in expansion.nodes { origin[node.id] = instance.id }
            expansions[instance.id] = expansion
        }
        guard errors.isEmpty else { return Result(project: project, origin: [:], outputs: [:], errors: errors) }

        // Each instance's sources resolved through any chain of custom nodes and pass-throughs.
        func source(of pin: PinRef, depth: Int = 0) -> PinRef? {
            guard let expansion = expansions[pin.node] else { return pin }
            guard depth < 64, let output = expansion.outputSources[pin.pin] else { return nil }
            switch output {
            case .pin(let inner):
                return inner
            case .input(let input):
                let into = PinRef(node: pin.node, pin: input)
                guard let edge = project.edges.first(where: { $0.to == into }) else { return nil }
                return source(of: edge.from, depth: depth + 1)
            }
        }
        func targets(of pin: PinRef) -> [PinRef] {
            guard let expansion = expansions[pin.node] else { return [pin] }
            if let targets = expansion.inputTargets[pin.pin] { return targets }
            if let parameter = NodeCatalog.parameter(forModulationPin: pin.pin), let control = expansion.controls[parameter] {
                return [control]
            }
            // Not a pin a custom node has: left pointing at the (vanished) custom node, so it's reported.
            return [pin]
        }

        var flattened = project
        flattened.nodes = project.nodes.flatMap { node in expansions[node.id]?.nodes ?? [node] }
        var edges: [Edge] = []
        for edge in project.edges {
            guard let from = source(of: edge.from) else { continue }
            for to in targets(of: edge.to) {
                edges.append(Edge(from: from, to: to))
            }
        }
        // A custom node's input passed straight to its output is handled by `source(of:)`; its other
        // internal wires are added as they are.
        for instance in instances {
            edges += expansions[instance.id]?.edges ?? []
        }
        flattened.edges = edges

        var outputs: [NodeID: [PinID: PinRef]] = [:]
        for (id, expansion) in expansions {
            for pin in expansion.outputSources.keys {
                outputs[id, default: [:]][pin] = source(of: PinRef(node: id, pin: pin))
            }
        }
        let inner = expansions.values.reduce(into: [NodeID: NodeID]()) { $0.merge($1.inner) { first, _ in first } }
        return Result(project: flattened, origin: origin, inner: inner, outputs: outputs, errors: [])
    }

    private static func expand(
        _ instance: Node, _ definition: CustomNodeDefinition, in project: ProjectFile, naming: Naming
    ) -> Expansion {
        var expansion = Expansion()
        let boundary = Set([definition.inputCard?.id, definition.outputCard?.id].compactMap(\.self))
        let macros = Dictionary(uniqueKeysWithValues: definition.macros.enumerated().map { ($1.id, $0 + 1) })
        let known = Set(definition.nodes.map(\.id))
        func mapped(_ id: NodeID) -> NodeID { naming == .original ? id : derivedID(instance: instance.id, inner: id) }
        // Whether something outside modulates the instance's control.
        func modulates(_ parameter: ParameterID) -> Bool {
            project.edges.contains { $0.to == PinRef(node: instance.id, pin: NodeCatalog.modulationPinID(for: parameter)) }
        }

        // The definition's cards keep their layout, moved so their top-left sits where the custom
        // node does. The boundary cards don't count: they sit beside the others.
        let placed = definition.nodes.filter { !boundary.contains($0.id) }
        let originX = placed.map(\.position.x).min() ?? 0
        let originY = placed.map(\.position.y).min() ?? 0
        for node in placed {
            var copy = Node(
                id: mapped(node.id), kind: node.kind,
                position: CanvasPoint(x: instance.position.x + node.position.x - originX, y: instance.position.y + node.position.y - originY),
                parameters: node.parameters, modulated: node.modulated, modulationTrims: node.modulationTrims,
                assetID: node.assetID, outputFolder: node.outputFolder
            )
            // Each control the instance has: its value set on the inner parameter, and its
            // modulation pin passed through with the instance's trim.
            var controls: [(ParameterID, ParameterID)] = []
            if let number = macros[node.id] { controls.append((CustomNodeDefinition.macroParameter(number), "value")) }
            for parameter in node.promoted ?? [] {
                controls.append((CustomNodeDefinition.promotedParameter(parameter, of: node.id), parameter))
            }
            for (control, parameter) in controls {
                if let value = instance.parameters[control] { copy.parameters[parameter] = value }
                expansion.controls[control] = PinRef(node: copy.id, pin: NodeCatalog.modulationPinID(for: parameter))
                if modulates(control) {
                    copy.setModulated(parameter, true)
                    copy.setTrim(instance.modulationTrims[control] ?? 1, for: parameter)
                }
            }
            expansion.inner[copy.id] = node.id
            expansion.nodes.append(copy)
        }

        let inputCard = definition.inputCard?.id
        let outputCard = definition.outputCard?.id
        for edge in definition.edges where known.contains(edge.from.node) && known.contains(edge.to.node) {
            let input = edge.from.node == inputCard ? edge.from.pin : nil
            let output = edge.to.node == outputCard ? edge.to.pin : nil
            switch (input, output) {
            case let (input?, output?):
                expansion.outputSources[output] = .input(input)
            case let (input?, nil):
                expansion.inputTargets[input, default: []].append(PinRef(node: mapped(edge.to.node), pin: edge.to.pin))
            case let (nil, output?):
                expansion.outputSources[output] = .pin(PinRef(node: mapped(edge.from.node), pin: edge.from.pin))
            case (nil, nil):
                expansion.edges.append(Edge(
                    from: PinRef(node: mapped(edge.from.node), pin: edge.from.pin),
                    to: PinRef(node: mapped(edge.to.node), pin: edge.to.pin)
                ))
            }
        }
        // Ports with nothing wired inside still exist: a wire into one goes nowhere.
        for port in definition.inputPorts where expansion.inputTargets[port.id] == nil {
            expansion.inputTargets[port.id] = []
        }
        return expansion
    }

    /// The first 16 bytes of SHA-256(instance ID ‖ inner ID): unique per instance, the same every compile.
    static func derivedID(instance: NodeID, inner: NodeID) -> NodeID {
        var bytes = Data()
        withUnsafeBytes(of: instance.rawValue.uuid) { bytes.append(contentsOf: $0) }
        withUnsafeBytes(of: inner.rawValue.uuid) { bytes.append(contentsOf: $0) }
        let digest = Array(SHA256.hash(data: bytes))
        let uuid = UUID(uuid: (
            digest[0], digest[1], digest[2], digest[3], digest[4], digest[5], digest[6], digest[7],
            digest[8], digest[9], digest[10], digest[11], digest[12], digest[13], digest[14], digest[15]
        ))
        return NodeID(uuid)
    }

    /// `3` for `in3` with prefix `in`; nil otherwise.
    static func number(of id: String, prefix: String) -> Int? {
        guard id.hasPrefix(prefix), let number = Int(id.dropFirst(prefix.count)), number >= 1 else { return nil }
        return number
    }
}
