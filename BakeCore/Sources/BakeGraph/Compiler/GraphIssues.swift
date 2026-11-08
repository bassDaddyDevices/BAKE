import Foundation

/// Problems to show on the canvas: on nodes, on pins, and project-wide. Messages are short,
/// plain, and say what to do.
public struct GraphIssues: Equatable, Sendable {
    public private(set) var nodes: [NodeID: [String]] = [:]
    public private(set) var pins: Set<PinRef> = []
    public private(set) var general: [String] = []
    /// Problems inside each custom node's definition, on its own cards: what the canvas shows while
    /// editing inside it.
    public private(set) var inside: [UUID: GraphIssues] = [:]

    public init() {}

    public var isEmpty: Bool {
        nodes.isEmpty && pins.isEmpty && general.isEmpty
    }

    public mutating func add(_ message: String, to node: NodeID, pin: PinRef? = nil) {
        if !(nodes[node] ?? []).contains(message) {
            nodes[node, default: []].append(message)
        }
        if let pin { pins.insert(pin) }
    }

    public mutating func addGeneral(_ message: String) {
        if !general.contains(message) { general.append(message) }
    }

    /// The problems behind a failed compile, in plain language. One inside a custom node lands on
    /// the card inside, and on the custom node named after that card ("Filters: …").
    public init(_ failure: CompileFailure, in project: ProjectFile) {
        self.init()
        for (index, error) in failure.errors.enumerated() {
            guard let from = failure.inside[index], let view = project.inside(from.definition) else {
                record(error, in: project)
                continue
            }
            var found = GraphIssues()
            found.record(from.error, in: view)
            inside[from.definition, default: GraphIssues()].merge(found)
            for (node, messages) in found.nodes.sorted(by: { $0.key.rawValue.uuidString < $1.key.rawValue.uuidString }) {
                let title = view.node(node)?.kind.title ?? "Inside"
                for message in messages { add("\(title): \(message)", to: from.instance) }
            }
            for message in found.general { add(message, to: from.instance) }
        }
    }

    private mutating func merge(_ other: GraphIssues) {
        for (node, messages) in other.nodes {
            for message in messages { add(message, to: node) }
        }
        pins.formUnion(other.pins)
        for message in other.general { addGeneral(message) }
    }

    private mutating func record(_ error: CompileError, in project: ProjectFile) {
        func name(_ parameter: ParameterID, of node: NodeID) -> String {
            project.node(node).flatMap { NodeCatalog.definition(for: $0.kind).parameter(parameter)?.name } ?? parameter
        }
        switch error {
        case .noOutput:
            addGeneral("Add a Bake node — nothing would be baked.")
        case .duplicateNode(let node):
            add("This node appears twice in the file.", to: node)
        case .unknownNode:
            addGeneral("A wire points to a node that no longer exists.")
        case .unknownPin(let pin):
            add("A wire uses a pin this node doesn't have.", to: pin.node, pin: pin)
        case .wrongDirection(let edge), .typeMismatch(let edge):
            add("This wire's signal types don't match.", to: edge.to.node, pin: edge.to)
        case .multipleEdgesToInput(let pin):
            add("This input has more than one wire.", to: pin.node, pin: pin)
        case .invalidModulation(let node, let parameter):
            add("\(name(parameter, of: node)) can't be modulated.", to: node)
        case .invalidParameter(let node, let parameter):
            add("\(name(parameter, of: node)) has an invalid value.", to: node)
        case .missingInput(let pin):
            add("Needs an input.", to: pin.node, pin: pin)
        case .cycle(let nodes):
            for node in nodes { add("Part of a loop — wires can't feed back. Use a Feedback node's Return.", to: node) }
        case .unresolvableAsset(let node):
            if let file = project.audioFileName(for: node) {
                add("Can't find “\(file)” — choose the file again.", to: node)
            } else {
                add("No audio file — drop one on this node or choose one.", to: node)
            }
        case .invalidLength(let node):
            if project.node(node)?.kind == .audio {
                add("This file has no audio in it, or its Start and End leave none.", to: node)
            } else {
                add("Renders no audio — check its crop and ratio.", to: node)
            }
        case .missingCustomDefinition(let node):
            add("This custom node's definition is missing from the document.", to: node)
        case .nestedCustomNode(let node):
            add("Custom nodes can't contain other custom nodes yet.", to: node)
        case .outputTooLarge(let node, let bytes):
            let size = (Double(bytes) / 1_073_741_824).formatted(.number.precision(.fractionLength(1)))
            add("This file would be \(size) GB, more than the 4 GB a WAV can hold. Make it shorter, use fewer channels or a lower bit depth.", to: node)
        case .outputInCustomNode(let node):
            add("Custom nodes can't contain a Bake or Preview node. Open it and remove them.", to: node)
        case .feedbackNotCausal(let node):
            // Where a setting makes it causal, say which; otherwise it has to leave the loop.
            let fix = switch project.node(node)?.kind {
            case .filters?: "Set Phase to Minimum, or move it outside the loop."
            case .distortion?, .waveshaper?, .wavefolder?: "Set Oversampling to 1×, or move it outside the loop."
            default: "Move it outside the loop."
            }
            add("Can't run inside a feedback loop: it looks ahead in its input. \(fix)", to: node)
        case .feedbackLengthMismatch(let node):
            add("Changes the length inside a feedback loop. Move it outside the loop.", to: node)
        case .nestedFeedback(let node):
            add("Feedback loops can't sit inside each other yet.", to: node)
        }
    }
}
