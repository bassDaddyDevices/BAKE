/// What a custom node shows on its card, read from its definition (spec §12): the ports of its Inputs
/// and Outputs cards, in order, then one control per Macro inside and one per promoted parameter.
public struct CustomNodeInterface: Hashable, Sendable {
    public struct Port: Hashable, Sendable {
        public let id: PinID
        public let name: String
        public let signal: SignalType
    }

    public let inputs: [Port]
    public let outputs: [Port]
    /// Macros first (`macro.N`), then promoted parameters in the order of their nodes.
    public let controls: [ParameterDefinition]
}

extension ProjectFile {
    /// A custom node's pins and controls; nil for any other node or a missing definition.
    public func customInterface(of node: Node) -> CustomNodeInterface? {
        definition(of: node).map(\.interface)
    }
}

extension CustomNodeDefinition {
    /// An input carries control when everything it feeds inside is a control input (an LFO into a
    /// filter's Cutoff stays wireable after grouping); an output carries what feeds it.
    public var interface: CustomNodeInterface {
        let inner = Dictionary(nodes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        func signal(of ref: PinRef) -> SignalType? {
            inner[ref.node].flatMap { node in NodeCatalog.pins(of: node).first { $0.id == ref.pin }?.signal }
        }
        let inputs = inputPorts.map { port in
            let targets = edges.filter { $0.from == PinRef(node: inputCard?.id ?? NodeID(), pin: port.id) }.map(\.to)
            let control = !targets.isEmpty && targets.allSatisfy { signal(of: $0) == .control }
            return CustomNodeInterface.Port(id: port.id, name: port.name, signal: control ? .control : .audio)
        }
        let outputs = outputPorts.map { port in
            let source = edges.first { $0.to == PinRef(node: outputCard?.id ?? NodeID(), pin: port.id) }?.from
            return CustomNodeInterface.Port(id: port.id, name: port.name, signal: source.flatMap(signal(of:)) ?? .audio)
        }
        return CustomNodeInterface(inputs: inputs, outputs: outputs, controls: macroControls + promotedControls)
    }

    private var macroControls: [ParameterDefinition] {
        macros.enumerated().map { index, macro in
            let label: String = if case .text(let text)? = macro.parameters["label"], !text.isEmpty { text } else { "Macro" }
            return .number(Self.macroParameter(index + 1), label, 0...1, default: macro.parameters["value"]?.numberValue ?? 0, modulatable: true)
        }
    }

    /// Each promoted parameter as the inner one, under its own ID, defaulting to the inner node's value.
    /// It's modulatable on the custom node unless something inside already modulates it.
    private var promotedControls: [ParameterDefinition] {
        var controls: [ParameterDefinition] = []
        for node in nodes {
            guard let promoted = node.promoted, !promoted.isEmpty else { continue }
            let values = NodeCatalog.resolvedParameters(of: node)
            for parameter in NodeCatalog.definition(for: node.kind).parameters where promoted.contains(parameter.id) {
                let wiredInside = edges.contains { $0.to == PinRef(node: node.id, pin: NodeCatalog.modulationPinID(for: parameter.id)) }
                let kind: ParameterKind = switch (parameter.kind, values[parameter.id]) {
                case let (.number(range, _, unit), .number(value)?): .number(range: range, defaultValue: value, unit: unit)
                case let (.choice(options, _), .choice(value)?): .choice(options: options, defaultValue: value)
                case let (.text, .text(value)?): .text(defaultValue: value)
                default: parameter.kind
                }
                controls.append(ParameterDefinition(
                    id: Self.promotedParameter(parameter.id, of: node.id), name: parameter.name, kind: kind, role: .macro,
                    isModulatable: parameter.isModulatable && !wiredInside, modulationScale: parameter.modulationScale,
                    taper: parameter.taper, isInteger: parameter.isInteger
                ))
            }
        }
        return controls
    }
}

extension NodeCatalog {
    /// `pins(of:)`, with a custom node's pins read from its definition in `project`.
    public static func pins(of node: Node, in project: ProjectFile) -> [PinDefinition] {
        if node.kind == .customInput || node.kind == .customOutput { return boundaryPins(of: node, in: project) }
        guard node.kind == .custom else { return pins(of: node) }
        guard let interface = project.customInterface(of: node) else { return [] }
        let inputs = interface.inputs.map { PinDefinition(id: $0.id, direction: .input, signal: $0.signal, isRequired: false) }
        let outputs = interface.outputs.map { PinDefinition(id: $0.id, direction: .output, signal: $0.signal, isRequired: false) }
        let modulatable = Set(interface.controls.filter(\.isModulatable).map(\.id))
        let spawned = node.modulated.filter(modulatable.contains).map {
            PinDefinition(id: modulationPinID(for: $0), direction: .input, signal: .control, isRequired: false)
        }
        return inputs + outputs + spawned
    }

    /// An Inputs or Outputs card's pins, each carrying what the custom node's matching pin carries, so
    /// wires inside are coloured like the ones outside.
    private static func boundaryPins(of card: Node, in project: ProjectFile) -> [PinDefinition] {
        let pins = boundaryPins(of: card) ?? []
        func signal(of ref: PinRef) -> SignalType? {
            project.node(ref.node).flatMap { node in NodeCatalog.pins(of: node).first { $0.id == ref.pin }?.signal }
        }
        return pins.map { pin in
            let carried: SignalType
            if card.kind == .customInput {
                let targets = project.edges.filter { $0.from == PinRef(node: card.id, pin: pin.id) }.map(\.to)
                carried = !targets.isEmpty && targets.allSatisfy { signal(of: $0) == .control } ? .control : .audio
            } else {
                carried = project.edge(into: PinRef(node: card.id, pin: pin.id)).flatMap { signal(of: $0.from) } ?? .audio
            }
            return PinDefinition(id: pin.id, direction: pin.direction, signal: carried, isRequired: false)
        }
    }

    /// A node's parameters; a custom node's are its Macros and promoted parameters.
    public static func parameters(of node: Node, in project: ProjectFile) -> [ParameterDefinition] {
        guard node.kind == .custom else { return definition(for: node.kind).parameters }
        return project.customInterface(of: node)?.controls ?? []
    }

    public static func parameter(_ id: ParameterID, of node: Node, in project: ProjectFile) -> ParameterDefinition? {
        parameters(of: node, in: project).first { $0.id == id }
    }

    /// `resolvedParameters(of:)`, with a custom node's controls defaulting to the values inside.
    public static func resolvedParameters(of node: Node, in project: ProjectFile) -> [ParameterID: ParameterValue] {
        guard node.kind == .custom else { return resolvedParameters(of: node) }
        var resolved: [ParameterID: ParameterValue] = [:]
        for parameter in parameters(of: node, in: project) {
            resolved[parameter.id] = resolve(node.parameters[parameter.id], for: parameter) ?? parameter.defaultValue
        }
        return resolved
    }

    /// `visibleParameters(of:)`; a custom node shows all its controls.
    public static func visibleParameters(of node: Node, in project: ProjectFile) -> [ParameterDefinition] {
        node.kind == .custom ? parameters(of: node, in: project) : visibleParameters(of: node)
    }

    /// `label(of:on:)`, with a custom node's pins named after its ports and controls.
    public static func label(of pin: PinID, on node: Node, in project: ProjectFile) -> String {
        guard node.kind == .custom, let interface = project.customInterface(of: node) else { return label(of: pin, on: node) }
        if let port = (interface.inputs + interface.outputs).first(where: { $0.id == pin }) { return port.name }
        if let parameter = parameter(forModulationPin: pin), let control = self.parameter(parameter, of: node, in: project) {
            return control.name
        }
        return pin
    }
}
