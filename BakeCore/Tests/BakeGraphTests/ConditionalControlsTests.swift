import Testing
@testable import BakeGraph

struct ConditionalControlsTests {
    private func node(_ kind: NodeKind, _ parameters: [ParameterID: ParameterValue] = [:]) -> Node {
        var node = Node(kind: kind)
        for (id, value) in parameters { node.parameters[id] = value }
        return node
    }

    private func visible(_ node: Node) -> [ParameterID] { NodeCatalog.visibleParameters(of: node).map(\.id) }

    @Test func aFreeLFOShowsRateAndAClockedOneShowsCyclesPerBang() {
        let free = visible(node(.lfo))
        #expect(free.contains("rate") && !free.contains("cyclesPerBang"))
        let clocked = visible(node(.lfo, ["sync": .choice("clock")]))
        #expect(!clocked.contains("rate") && clocked.contains("cyclesPerBang"))
        #expect(clocked.contains("sync") && clocked.contains("depth"))
    }

    @Test func firLengthOnlyShowsForLinearPhase() {
        #expect(!visible(node(.filters)).contains("firTaps"))
        #expect(visible(node(.filters, ["phase": .choice("linear")])).contains("firTaps"))
    }

    @Test func sustainLoopIsHiddenInOneShot() {
        #expect(!visible(node(.envelope)).contains("loop"))
        #expect(visible(node(.envelope, ["triggerMode": .choice("gate")])).contains("loop"))
        #expect(visible(node(.envelope, ["triggerMode": .choice("classic")])).contains("loop"))
    }

    @Test func parametersWithoutARuleAlwaysShow() {
        for kind in NodeKind.allCases {
            let definition = NodeCatalog.definition(for: kind)
            let ruled = Set(definition.parameters.filter { $0.shownWhen != nil }.map(\.id))
            let shown = Set(visible(node(kind)))
            for parameter in definition.parameters where parameter.role != .hidden && !ruled.contains(parameter.id) {
                #expect(shown.contains(parameter.id), "\(kind).\(parameter.id)")
            }
        }
    }

    /// Every rule must point at a choice on the same node and name only values it can take.
    @Test(arguments: NodeKind.allCases)
    func rulesPointAtRealChoices(kind: NodeKind) {
        let definition = NodeCatalog.definition(for: kind)
        for parameter in definition.parameters {
            guard let rule = parameter.shownWhen else { continue }
            guard case .choice(let options, _)? = definition.parameter(rule.parameter)?.kind else {
                Issue.record("\(kind).\(parameter.id) depends on \(rule.parameter), which isn't a choice")
                continue
            }
            #expect(rule.values.isSubset(of: Set(options)), "\(kind).\(parameter.id)")
        }
    }

    @Test func hidingKeepsTheValue() {
        let filters = node(.filters, ["firTaps": .choice("16385")])
        #expect(!visible(filters).contains("firTaps"))
        #expect(NodeCatalog.resolvedParameters(of: filters)["firTaps"] == .choice("16385"))
    }
}
