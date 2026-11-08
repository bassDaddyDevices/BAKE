/// One feedback loop: a Feedback node, the node wired into its `return` pin, and the region between
/// them (every node on a path from the Feedback node's `out` to that return source, plus both ends).
/// The engine renders a region in lockstep blocks no longer than the loop's delay (spec §11).
public struct FeedbackLoop: Hashable, Sendable {
    public let feedback: NodeID
    public let returnSource: NodeID
    public let members: Set<NodeID>
}

extension ProjectFile {
    /// Whether `edge` ends on a Feedback node's `return` pin.
    func endsOnFeedbackReturn(_ edge: Edge) -> Bool {
        pin(edge.to)?.isFeedbackReturn == true
    }

    /// Return wires that close a loop: their source is downstream of the Feedback node they feed.
    /// A return wire from anywhere else is an ordinary input (rendered first, read delayed).
    func feedbackBackEdges() -> Set<Edge> {
        let forward = edges.filter { !endsOnFeedbackReturn($0) }
        return Set(edges.filter { edge in
            endsOnFeedbackReturn(edge) && Self.reach(from: [edge.to.node], along: forward, forward: true).contains(edge.from.node)
        })
    }

    /// Every wire except the back-edges: the graph the scheduler orders, which is acyclic unless
    /// something other than a return wire closes a cycle.
    func orderingEdges() -> [Edge] {
        let back = feedbackBackEdges()
        return edges.filter { !back.contains($0) }
    }

    /// The project's feedback loops, in the order their Feedback nodes were created.
    public func feedbackLoops() -> [FeedbackLoop] {
        let back = feedbackBackEdges()
        let ordering = edges.filter { !back.contains($0) }
        return nodes.compactMap { node -> FeedbackLoop? in
            guard let edge = back.first(where: { $0.to.node == node.id }) else { return nil }
            let downstream = Self.reach(from: [node.id], along: ordering, forward: true)
            let upstream = Self.reach(from: [edge.from.node], along: ordering, forward: false)
            return FeedbackLoop(feedback: node.id, returnSource: edge.from.node, members: downstream.intersection(upstream))
        }
    }

    /// Nodes reachable from `start` (included) by following `edges` forwards or backwards.
    static func reach(from start: [NodeID], along edges: [Edge], forward: Bool) -> Set<NodeID> {
        var next: [NodeID: [NodeID]] = [:]
        for edge in edges {
            if forward {
                next[edge.from.node, default: []].append(edge.to.node)
            } else {
                next[edge.to.node, default: []].append(edge.from.node)
            }
        }
        var seen = Set(start)
        var pending = start
        while let current = pending.popLast() {
            for neighbour in next[current] ?? [] where seen.insert(neighbour).inserted {
                pending.append(neighbour)
            }
        }
        return seen
    }
}
