/// Checks that nodes and edges are well-formed, regardless of what will run.
enum StructureValidator {
    static func validate(_ project: ProjectFile) -> [CompileError] {
        var errors: [CompileError] = []
        var nodesByID: [NodeID: Node] = [:]

        for node in project.nodes {
            guard nodesByID[node.id] == nil else {
                errors.append(.duplicateNode(node.id))
                continue
            }
            nodesByID[node.id] = node

            let definition = NodeCatalog.definition(for: node.kind)
            for parameterID in node.modulated where definition.parameter(parameterID)?.isModulatable != true {
                errors.append(.invalidModulation(node.id, parameterID))
            }
            for parameter in definition.parameters where NodeCatalog.resolve(node.parameters[parameter.id], for: parameter) == nil {
                errors.append(.invalidParameter(node.id, parameter.id))
            }
        }

        var wiredInputs: Set<PinRef> = []
        var reportedInputs: Set<PinRef> = []
        for edge in project.edges {
            guard let source = nodesByID[edge.from.node] else {
                errors.append(.unknownNode(edge.from.node))
                continue
            }
            guard let target = nodesByID[edge.to.node] else {
                errors.append(.unknownNode(edge.to.node))
                continue
            }
            guard let sourcePin = NodeCatalog.pins(of: source).first(where: { $0.id == edge.from.pin }) else {
                errors.append(.unknownPin(edge.from))
                continue
            }
            guard let targetPin = NodeCatalog.pins(of: target).first(where: { $0.id == edge.to.pin }) else {
                errors.append(.unknownPin(edge.to))
                continue
            }
            guard sourcePin.direction == .output, targetPin.direction == .input else {
                errors.append(.wrongDirection(edge))
                continue
            }
            // Audio may drive a control input (audio-rate modulation); control may not drive audio.
            if sourcePin.signal == .control && targetPin.signal == .audio {
                errors.append(.typeMismatch(edge))
                continue
            }
            // Report each over-wired input once, in edge order, so errors are deterministic.
            if !wiredInputs.insert(edge.to).inserted, reportedInputs.insert(edge.to).inserted {
                errors.append(.multipleEdgesToInput(edge.to))
            }
        }
        return errors
    }
}
