import Foundation

/// One pin of a custom node, as its Inputs or Outputs card holds it. The ID is the pin's ID on both
/// sides (the Inputs card's output `in3` is the custom node's input `in3`) and never changes, so
/// renaming and reordering keep every wire attached.
public struct CustomPort: Hashable, Codable, Sendable {
    public let id: PinID
    public var name: String

    public init(id: PinID, name: String) {
        self.id = id
        self.name = name
    }
}

/// A saved group of nodes used as one (spec §12). Its one Inputs and one Outputs card hold the custom
/// node's pins, in order; every Macro inside, and every parameter promoted inside, becomes one of
/// its controls. Documents embed the definitions their custom nodes use, so they open anywhere.
public struct CustomNodeDefinition: Identifiable, Hashable, Codable, Sendable {
    public let id: UUID
    public var name: String
    public var version: Int
    public var nodes: [Node]
    public var edges: [Edge]

    /// Definitions from before named ports (one Custom Input or Output card per pin) are merged into
    /// one Inputs and one Outputs card; their pins keep the IDs `in1…inN` and `out1…outN` they had.
    public init(id: UUID = UUID(), name: String, version: Int = 1, nodes: [Node] = [], edges: [Edge] = []) {
        self.id = id
        self.name = name
        self.version = version
        (self.nodes, self.edges) = Self.mergingBoundaries(nodes, edges)
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, version, nodes, edges
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(UUID.self, forKey: .id),
            name: try container.decode(String.self, forKey: .name),
            version: try container.decode(Int.self, forKey: .version),
            nodes: try container.decode([Node].self, forKey: .nodes),
            edges: try container.decode([Edge].self, forKey: .edges)
        )
    }

    /// The Inputs card: the custom node's input pins.
    public var inputCard: Node? { nodes.first { $0.kind == .customInput } }
    /// The Outputs card: the custom node's output pins.
    public var outputCard: Node? { nodes.first { $0.kind == .customOutput } }
    public var inputPorts: [CustomPort] { inputCard?.ports ?? [] }
    public var outputPorts: [CustomPort] { outputCard?.ports ?? [] }
    /// The Macro nodes, in creation order: the custom node's controls `macro.1…macro.N`.
    public var macros: [Node] { nodes.filter { $0.kind == .macro } }

    /// The custom node's parameter for its `n`th Macro (1-based).
    public static func macroParameter(_ number: Int) -> ParameterID { "macro.\(number)" }

    /// The custom node's parameter for `parameter` of the node `inner`, promoted inside.
    public static func promotedParameter(_ parameter: ParameterID, of inner: NodeID) -> ParameterID {
        "p.\(inner.rawValue.uuidString).\(parameter)"
    }

    /// The inner node and parameter a promoted control stands for; nil for anything else.
    public static func promotedTarget(of parameter: ParameterID) -> (node: NodeID, parameter: ParameterID)? {
        guard parameter.hasPrefix("p.") else { return nil }
        let rest = parameter.dropFirst(2)
        guard let dot = rest.firstIndex(of: "."), let uuid = UUID(uuidString: String(rest[..<dot])) else { return nil }
        return (NodeID(uuid), String(rest[rest.index(after: dot)...]))
    }

    /// One Inputs and one Outputs card at most, with ports; older one-card-per-pin boundaries merged.
    static func mergingBoundaries(_ nodes: [Node], _ edges: [Edge]) -> ([Node], [Edge]) {
        var nodes = nodes
        var edges = edges
        for (kind, prefix, legacyPin) in [(NodeKind.customInput, "in", "out"), (.customOutput, "out", "in")] {
            let cards = nodes.filter { $0.kind == kind }
            guard cards.count > 1 || cards.contains(where: { $0.ports == nil }) else { continue }
            var merged = cards[0]
            merged.ports = []
            merged.parameters = [:]
            var moved: [PinRef: PinRef] = [:]
            for card in cards {
                if let ports = card.ports {
                    merged.ports?.append(contentsOf: ports)
                    for port in ports { moved[PinRef(node: card.id, pin: port.id)] = PinRef(node: merged.id, pin: port.id) }
                } else {
                    let number = (merged.ports?.count ?? 0) + 1
                    let name: String = if case .text(let text)? = card.parameters["name"], !text.isEmpty { text }
                        else { "\(prefix == "in" ? "In" : "Out") \(number)" }
                    let port = CustomPort(id: "\(prefix)\(number)", name: name)
                    merged.ports?.append(port)
                    moved[PinRef(node: card.id, pin: legacyPin)] = PinRef(node: merged.id, pin: port.id)
                }
            }
            let removed = Set(cards.dropFirst().map(\.id))
            nodes = nodes.compactMap { node in
                if node.id == merged.id { return merged }
                return removed.contains(node.id) ? nil : node
            }
            edges = edges.map { Edge(from: moved[$0.from] ?? $0.from, to: moved[$0.to] ?? $0.to) }
        }
        return (nodes, edges)
    }
}
