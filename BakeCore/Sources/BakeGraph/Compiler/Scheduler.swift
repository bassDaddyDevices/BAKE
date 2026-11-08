/// Chooses the nodes that feed an output (Bake or Preview) node and orders them so each runs after its inputs.
enum Scheduler {
    static func schedule(_ project: ProjectFile) -> (order: [NodeID], loops: [FeedbackLoop], errors: [CompileError]) {
        let outputs = project.nodes.filter(\.kind.isOutput).map(\.id)
        guard !outputs.isEmpty else { return ([], [], [.noOutput]) }

        var creationIndex: [NodeID: Int] = [:]
        for (index, node) in project.nodes.enumerated() where creationIndex[node.id] == nil {
            creationIndex[node.id] = index
        }
        func created(_ id: NodeID) -> Int { creationIndex[id, default: .max] }

        // Walk upstream from every output node. Anything not reached is parked and skipped.
        var scheduled = Set(outputs)
        var stack = outputs
        while let current = stack.popLast() {
            for edge in project.edges where edge.to.node == current && !scheduled.contains(edge.from.node) {
                scheduled.insert(edge.from.node)
                stack.append(edge.from.node)
            }
        }

        // Kahn's algorithm. Ties go to the earliest-created node, so edge order never matters.
        // Wires closing a feedback loop are left out: the engine renders a loop in lockstep instead.
        let edges = project.orderingEdges().filter { scheduled.contains($0.from.node) && scheduled.contains($0.to.node) }
        var inDegree: [NodeID: Int] = [:]
        for edge in edges {
            inDegree[edge.to.node, default: 0] += 1
        }
        var ready = scheduled.filter { inDegree[$0, default: 0] == 0 }
        var order: [NodeID] = []
        while let next = ready.min(by: { created($0) < created($1) }) {
            ready.remove(next)
            order.append(next)
            for edge in edges where edge.from.node == next {
                inDegree[edge.to.node, default: 0] -= 1
                if inDegree[edge.to.node] == 0 {
                    ready.insert(edge.to.node)
                }
            }
        }

        var errors: [CompileError] = []
        if order.count < scheduled.count {
            let stuck = scheduled.subtracting(order).sorted { created($0) < created($1) }
            errors.append(.cycle(stuck))
        }

        // Required inputs only matter for nodes that will run.
        for node in project.nodes where scheduled.contains(node.id) {
            let definition = NodeCatalog.definition(for: node.kind)
            if definition.needsAnyInput, let group = definition.repeated.first(where: { $0.direction == .input }),
               !project.edges.contains(where: { $0.to.node == node.id && group.number(of: $0.to.pin) != nil }) {
                errors.append(.missingInput(PinRef(node: node.id, pin: group.id(1))))
            }
            for pin in NodeCatalog.pins(of: node) where pin.direction == .input && pin.isRequired {
                let target = PinRef(node: node.id, pin: pin.id)
                if !project.edges.contains(where: { $0.to == target }) {
                    errors.append(.missingInput(target))
                }
            }
        }

        let loops = project.feedbackLoops().filter { scheduled.contains($0.feedback) }
        errors += validate(loops, in: project, created: created)
        guard errors.isEmpty else { return (order, loops, errors) }
        for loop in loops {
            order = makeContiguous(loop.members, in: order, edges: edges)
        }
        return (order, loops, errors)
    }

    /// Every node in a loop must be causal (the loop renders in blocks no longer than its delay), and
    /// loops can't contain or overlap one another in v1.
    private static func validate(_ loops: [FeedbackLoop], in project: ProjectFile, created: (NodeID) -> Int) -> [CompileError] {
        var errors: [CompileError] = []
        for loop in loops {
            for id in loop.members.sorted(by: { created($0) < created($1) }) where id != loop.feedback {
                guard let node = project.node(id) else { continue }
                if node.kind == .feedback || loops.contains(where: { $0.feedback != loop.feedback && $0.members.contains(id) }) {
                    if !errors.contains(.nestedFeedback(id)) { errors.append(.nestedFeedback(id)) }
                } else if !NodeCatalog.isCausal(node) {
                    errors.append(.feedbackNotCausal(id))
                }
            }
        }
        return errors
    }

    /// Moves a loop's members next to each other without breaking the order: within the span from
    /// its first to its last member, nodes that don't depend on the loop go first, then the loop, then
    /// the nodes that do.
    private static func makeContiguous(_ members: Set<NodeID>, in order: [NodeID], edges: [Edge]) -> [NodeID] {
        let positions = order.indices.filter { members.contains(order[$0]) }
        guard let first = positions.first, let last = positions.last else { return order }
        let dependents = ProjectFile.reach(from: Array(members), along: edges, forward: true)
        let span = order[first...last]
        let before = span.filter { !members.contains($0) && !dependents.contains($0) }
        let after = span.filter { !members.contains($0) && dependents.contains($0) }
        return Array(order[..<first]) + before + span.filter { members.contains($0) } + after + Array(order[(last + 1)...])
    }
}
