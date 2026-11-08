/// Gives every output pin a pooled buffer, and recycles a buffer once its last reader has run.
enum BufferPlanner {
    static func plan(
        order: [NodeID], loops: [FeedbackLoop] = [], shapes: [NodeID: SignalShape], outputShapes: [PinRef: SignalShape],
        project: ProjectFile
    ) -> RenderPlan {
        let nodes = Dictionary(project.nodes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var stepIndex: [NodeID: Int] = [:]
        for (index, id) in order.enumerated() {
            stepIndex[id] = index
        }

        // The last step that reads each output pin. A loop's return wire is read by its Feedback
        // step, which comes before the step that writes it.
        var lastRead: [PinRef: Int] = [:]
        for edge in project.edges {
            guard stepIndex[edge.from.node] != nil, let reader = stepIndex[edge.to.node] else { continue }
            lastRead[edge.from] = max(lastRead[edge.from] ?? reader, reader)
        }

        // Each loop's steps, which the scheduler made contiguous.
        let loopRanges: [(range: Range<Int>, blockFrames: Int)] = loops.compactMap { loop in
            let indices = loop.members.compactMap { stepIndex[$0] }
            guard let first = indices.min(), let last = indices.max(), let feedback = nodes[loop.feedback] else { return nil }
            return (first..<(last + 1), NodeCatalog.feedbackDelayFrames(feedback, sampleRate: project.settings.sampleRate))
        }

        var capacities: [Int] = []
        var freeSlots: [Int] = []
        var bindings: [PinRef: BufferBinding] = [:]
        var steps: [RenderStep] = []

        func takeSlot(for sampleCount: Int) -> Int {
            // Best fit: the smallest free buffer that's big enough; the lowest slot breaks ties.
            let fitting = freeSlots.filter { capacities[$0] >= sampleCount }
            if let slot = fitting.min(by: { (capacities[$0], $0) < (capacities[$1], $1) }) {
                freeSlots.removeAll { $0 == slot }
                return slot
            }
            capacities.append(sampleCount)
            return capacities.count - 1
        }

        func bindOutputs(of id: NodeID) {
            guard let node = nodes[id], let shape = shapes[id] else { return }
            for pin in NodeCatalog.pins(of: node) where pin.direction == .output {
                let ref = PinRef(node: id, pin: pin.id)
                guard bindings[ref] == nil else { continue }
                let pinShape = outputShapes[ref] ?? shape
                bindings[ref] = BufferBinding(slot: takeSlot(for: pinShape.sampleCount), shape: pinShape)
            }
        }

        for (index, id) in order.enumerated() {
            guard let node = nodes[id], let shape = shapes[id] else { continue }
            let loop = loopRanges.first { $0.range.contains(index) }
            // Every step of a loop writes in every block, so all their outputs exist before the first
            // runs; this also gives the Feedback step its return buffer.
            if let loop, loop.range.lowerBound == index {
                for member in order[loop.range] { bindOutputs(of: member) }
            }

            let incoming = project.edges.filter { $0.to.node == id }
            var inputs: [PinID: BufferBinding] = [:]
            for edge in incoming {
                inputs[edge.to.pin] = bindings[edge.from]
            }

            // Outputs are taken before this step's inputs are released, so a step never reads and writes one buffer.
            bindOutputs(of: id)
            var outputs: [PinID: BufferBinding] = [:]
            for pin in NodeCatalog.pins(of: node) where pin.direction == .output {
                outputs[pin.id] = bindings[PinRef(node: id, pin: pin.id)]
            }

            steps.append(RenderStep(
                node: id,
                kind: node.kind,
                parameters: NodeCatalog.resolvedParameters(of: node),
                modulationTrims: Dictionary(uniqueKeysWithValues: node.modulated.map {
                    ($0, min(max(node.modulationTrims[$0] ?? 1, -1), 1))
                }),
                assetID: node.assetID,
                shape: shape,
                inputs: inputs,
                outputs: outputs
            ))

            if let loop {
                // Nothing a loop step touches is recycled until the whole loop has rendered.
                guard index == loop.range.upperBound - 1 else { continue }
                var released: Set<Int> = []
                for member in order[loop.range] {
                    for source in Set(project.edges.filter({ $0.to.node == member }).map(\.from))
                    where (lastRead[source] ?? .max) <= index {
                        if let slot = bindings[source]?.slot { released.insert(slot) }
                    }
                    guard let memberNode = nodes[member] else { continue }
                    for pin in NodeCatalog.pins(of: memberNode) where pin.direction == .output {
                        let ref = PinRef(node: member, pin: pin.id)
                        if lastRead[ref] == nil, let slot = bindings[ref]?.slot { released.insert(slot) }
                    }
                }
                freeSlots += released.sorted()
                continue
            }

            // Release inputs read for the last time here, and outputs nobody reads.
            for source in Set(incoming.map(\.from)) where lastRead[source] == index {
                if let slot = bindings[source]?.slot {
                    freeSlots.append(slot)
                }
            }
            for (pin, binding) in outputs where lastRead[PinRef(node: id, pin: pin)] == nil {
                freeSlots.append(binding.slot)
            }
        }
        var plan = RenderPlan(sampleRate: project.settings.sampleRate, steps: steps, bufferCapacities: capacities)
        plan.loops = loopRanges.map { RenderLoop(steps: $0.range, blockFrames: $0.blockFrames) }
        return plan
    }
}
