extension GraphCompiler {
    /// What every node would render, for display while editing: all nodes (not only those a
    /// Print reaches), by the same length rules as a bake. Nodes that can't resolve yet are absent.
    /// A custom node shows the length of its first output.
    public static func previewShapes(_ project: ProjectFile, assets: [AssetID: AssetInfo]) -> [NodeID: SignalShape] {
        let flat = CustomNodeFlattener.flatten(project)
        var shapes = SignalResolver.resolve(order: dependencyOrder(flat.project), project: flat.project, assets: assets).shapes
        for (instance, outputs) in flat.outputs {
            if let first = project.node(instance).flatMap({ project.customInterface(of: $0)?.outputs.first?.id }),
               let source = outputs[first] { shapes[instance] = shapes[source.node] }
        }
        return shapes
    }

    /// Every node in dependency order; nodes on a cycle are left out. Feedback return wires don't
    /// count, so a loop's nodes still get their lengths.
    static func dependencyOrder(_ project: ProjectFile) -> [NodeID] {
        let ids = project.nodes.map(\.id)
        let known = Set(ids)
        var waiting = Dictionary(ids.map { ($0, 0) }, uniquingKeysWith: { first, _ in first })
        var next: [NodeID: [NodeID]] = [:]
        for edge in project.orderingEdges() where known.contains(edge.from.node) && known.contains(edge.to.node) {
            waiting[edge.to.node, default: 0] += 1
            next[edge.from.node, default: []].append(edge.to.node)
        }
        var ready = ids.filter { waiting[$0] == 0 }
        var order: [NodeID] = []
        while !ready.isEmpty {
            let id = ready.removeFirst()
            order.append(id)
            for target in next[id] ?? [] {
                waiting[target, default: 0] -= 1
                if waiting[target] == 0 { ready.append(target) }
            }
        }
        return order
    }
}
