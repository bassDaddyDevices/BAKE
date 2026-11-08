/// Brings older documents up to the current schema without changing how they sound.
enum ProjectMigration {
    /// The value a parameter had before its default changed (or before it existed). Documents
    /// saved at schema `upTo` or earlier that never set it get this value written in.
    struct FrozenDefault {
        let kind: NodeKind
        let parameter: ParameterID
        let value: ParameterValue
        let upTo: Int
    }

    static let frozenDefaults: [FrozenDefault] = [
        // v2: Distortion's default drive dropped from 12 to 6 dB.
        FrozenDefault(kind: .distortion, parameter: "drive", value: .number(12), upTo: 1),
        // v2: Resonator gained Mix (new nodes 50%); older ones were fully wet.
        FrozenDefault(kind: .resonator, parameter: "mix", value: .number(1), upTo: 1),
        // v3: Waveshaper gained a curve, bias and oversampling; older ones are plain 1x tanh.
        FrozenDefault(kind: .waveshaper, parameter: "curve", value: .choice("tanh"), upTo: 2),
        FrozenDefault(kind: .waveshaper, parameter: "bias", value: .number(0), upTo: 2),
        FrozenDefault(kind: .waveshaper, parameter: "oversampling", value: .choice("1"), upTo: 2),
        // v3: Wavefolder gained a fold type and oversampling; older ones are 1x triangle folds.
        FrozenDefault(kind: .wavefolder, parameter: "foldShape", value: .choice("triangle"), upTo: 2),
        FrozenDefault(kind: .wavefolder, parameter: "oversampling", value: .choice("1"), upTo: 2),
        // v4: Envelope gained Mode (new nodes One-shot); older ones keep the classic trigger.
        FrozenDefault(kind: .envelope, parameter: "triggerMode", value: .choice("classic"), upTo: 3),
        // v6: Looper gained Repeat mode (new nodes repeat on each bang); older ones loop once.
        FrozenDefault(kind: .looper, parameter: "mode", value: .choice("once"), upTo: 5),
        // v6: an unwired Envelope repeats every Every ms; older ones run once.
        FrozenDefault(kind: .envelope, parameter: "repeat", value: .choice("once"), upTo: 5),
        // v8: Wavetable Factory gained Source (new nodes read the whole input); older ones read the first 1,024 frames.
        FrozenDefault(kind: .wavetableFactory, parameter: "source", value: .choice("first1024"), upTo: 7),
        // v8: Redux gained Bit Steps and Anti-alias (new nodes keep the fraction and use the linear-phase FIR);
        // older ones round to whole bits and use the biquad cascade.
        FrozenDefault(kind: .redux, parameter: "bitSteps", value: .choice("whole"), upTo: 7),
        FrozenDefault(kind: .redux, parameter: "antiAlias", value: .choice("biquad"), upTo: 7),
        // v9: Granular Cloud (Size, Density, Spray) and Stutter (Repeats) widened their ranges, which changes how
        // far a wired modulation signal moves them; older documents keep the ranges they were made with.
        FrozenDefault(kind: .granularCloud, parameter: "modulationRange", value: .choice("legacy"), upTo: 8),
        FrozenDefault(kind: .stutter, parameter: "modulationRange", value: .choice("legacy"), upTo: 8),
        // v9: Flanger gained a through-zero read head and a Delay range of 50 ms; older ones are causal and reach 15 ms.
        FrozenDefault(kind: .flanger, parameter: "readHead", value: .choice("causal"), upTo: 8),
        FrozenDefault(kind: .flanger, parameter: "modulationRange", value: .choice("legacy"), upTo: 8),
    ]

    /// v10: the Switch became many inputs into one output. Saved Switches (one input, N outputs) become the fan-out
    /// kind, which keeps their pins, wires and sound exactly; node IDs and pin IDs don't change, so no wire moves.
    private static func moveSwitchesToFanOut(_ nodes: inout [Node]) {
        for index in nodes.indices where nodes[index].kind == .stepSwitch { nodes[index].kind = .stepSwitchFanOut }
    }

    /// v11: Concatenate's one input `in` became `in1`, `in2`, …; a saved wire moves to `in1` and bakes the same.
    private static func moveConcatenateWires(nodes: [Node], edges: inout [Edge]) {
        let joins = Set(nodes.filter { $0.kind == .concatenate }.map(\.id))
        for index in edges.indices where joins.contains(edges[index].to.node) && edges[index].to.pin == "in" {
            edges[index] = Edge(from: edges[index].from, to: PinRef(node: edges[index].to.node, pin: "in1"))
        }
    }

    static func migrate(_ project: inout ProjectFile) {
        if project.schemaVersion <= 10 {
            moveConcatenateWires(nodes: project.nodes, edges: &project.edges)
            for index in project.customNodes.indices {
                moveConcatenateWires(nodes: project.customNodes[index].nodes, edges: &project.customNodes[index].edges)
            }
        }
        if project.schemaVersion <= 9 {
            moveSwitchesToFanOut(&project.nodes)
            for index in project.customNodes.indices { moveSwitchesToFanOut(&project.customNodes[index].nodes) }
        }
        for rule in frozenDefaults where project.schemaVersion <= rule.upTo {
            for index in project.nodes.indices
            where project.nodes[index].kind == rule.kind && project.nodes[index].parameters[rule.parameter] == nil {
                project.nodes[index].parameters[rule.parameter] = rule.value
            }
        }
        project.schemaVersion = ProjectFile.currentSchemaVersion
    }
}
