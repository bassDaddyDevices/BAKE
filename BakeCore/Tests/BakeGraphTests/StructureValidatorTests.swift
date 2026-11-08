import Testing
@testable import BakeGraph

struct StructureValidatorTests {
    @Test func validV1GraphHasNoStructuralErrors() {
        var graph = TestGraph()
        let audio = graph.add(.audio)
        let filters = graph.add(.filters, modulated: ["cutoff"])
        let lfo = graph.add(.lfo)
        let output = graph.add(.print)
        graph.connect(audio, to: filters)
        graph.connect(lfo, to: filters, "mod.cutoff")
        graph.connect(filters, to: output)
        #expect(StructureValidator.validate(graph.project).isEmpty)
    }

    @Test func edgeToMissingNode() {
        var graph = TestGraph()
        let audio = graph.add(.audio)
        let ghost = NodeID(testUUID(99))
        graph.connect(audio, to: ghost)
        #expect(StructureValidator.validate(graph.project) == [.unknownNode(ghost)])
    }

    @Test func edgeToMissingPin() {
        var graph = TestGraph()
        let audio = graph.add(.audio)
        let filters = graph.add(.filters)
        graph.connect(audio, to: filters, "mod.cutoff") // cutoff not ticked on Page 2
        #expect(StructureValidator.validate(graph.project) == [.unknownPin(PinRef(node: filters, pin: "mod.cutoff"))])
    }

    @Test func edgeMustGoFromOutputToInput() {
        var graph = TestGraph()
        let a = graph.add(.filters)
        let b = graph.add(.filters)
        graph.connect(a, "in", to: b, "in")
        #expect(StructureValidator.validate(graph.project) == [.wrongDirection(graph.project.edges[0])])
    }

    @Test func controlCannotFeedAnAudioInput() {
        var graph = TestGraph()
        let lfo = graph.add(.lfo)
        let filters = graph.add(.filters)
        graph.connect(lfo, to: filters)
        #expect(StructureValidator.validate(graph.project) == [.typeMismatch(graph.project.edges[0])])
    }

    @Test func audioCanModulateAControlInput() {
        var graph = TestGraph()
        let audio = graph.add(.audio)
        let filters = graph.add(.filters, modulated: ["cutoff"])
        graph.connect(audio, to: filters, "mod.cutoff")
        #expect(StructureValidator.validate(graph.project).isEmpty)
    }

    @Test func inputAcceptsOnlyOneWire() {
        var graph = TestGraph()
        let a = graph.add(.audio)
        let b = graph.add(.audio)
        let filters = graph.add(.filters)
        graph.connect(a, to: filters)
        graph.connect(b, to: filters)
        #expect(StructureValidator.validate(graph.project) == [.multipleEdgesToInput(PinRef(node: filters, pin: "in"))])
    }

    @Test func outputsMayFanOut() {
        var graph = TestGraph()
        let audio = graph.add(.audio)
        let filters = graph.add(.filters)
        let distortion = graph.add(.distortion)
        graph.connect(audio, to: filters)
        graph.connect(audio, to: distortion)
        #expect(StructureValidator.validate(graph.project).isEmpty)
    }

    @Test func onlyModulatableParametersCanBeTicked() {
        var graph = TestGraph()
        let stretch = graph.add(.stretch, modulated: ["ratio"])
        #expect(StructureValidator.validate(graph.project) == [.invalidModulation(stretch, "ratio")])
    }

    @Test func invalidParameterValuesAreReported() {
        var graph = TestGraph()
        let filters = graph.add(.filters, ["type": .choice("banana")])
        #expect(StructureValidator.validate(graph.project) == [.invalidParameter(filters, "type")])
    }

    @Test func duplicateNodeIDsAreReported() {
        var graph = TestGraph()
        let audio = graph.add(.audio)
        graph.project.nodes.append(Node(id: audio, kind: .lfo))
        #expect(StructureValidator.validate(graph.project) == [.duplicateNode(audio)])
    }
}
