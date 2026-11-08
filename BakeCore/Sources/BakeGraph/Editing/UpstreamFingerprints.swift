import Foundation

extension ProjectFile {
    /// For each node, a fingerprint of everything that decides what it renders: itself, every node
    /// feeding it (directly or not), the wires between them, and the source files. Moving a card
    /// changes nothing; changing a setting changes that node's fingerprint and those downstream of
    /// it, never those upstream. Compare two snapshots to find which cards show an out-of-date render.
    /// Stable within a run of the app, not across runs.
    public func upstreamFingerprints() -> [NodeID: Int] {
        let byID = Dictionary(nodes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var feeders: [NodeID: [NodeID]] = [:]
        for edge in edges { feeders[edge.to.node, default: []].append(edge.from.node) }
        let paths = Dictionary(assets.map { ($0.id, $0.lastKnownPath) }, uniquingKeysWith: { first, _ in first })

        var result: [NodeID: Int] = [:]
        for node in nodes {
            // Everything upstream of this node, including itself.
            var cone: Set<NodeID> = [node.id]
            var pending = [node.id]
            while let current = pending.popLast() {
                for feeder in feeders[current] ?? [] where cone.insert(feeder).inserted { pending.append(feeder) }
            }
            var hasher = Hasher()
            for id in cone.sorted(by: { $0.rawValue.uuidString < $1.rawValue.uuidString }) {
                guard let member = byID[id] else { continue }
                hasher.combine(id)
                hasher.combine(member.kind)
                hasher.combine(member.parameters)
                hasher.combine(member.modulated)
                hasher.combine(member.modulationTrims)
                hasher.combine(member.assetID)
                hasher.combine(member.assetID.flatMap { paths[$0] })
                // A custom node renders its definition: editing the definition makes it out of date.
                hasher.combine(definition(of: member))
            }
            for edge in edges where cone.contains(edge.to.node) {
                hasher.combine(edge)
            }
            result[node.id] = hasher.finalize()
        }
        return result
    }
}
