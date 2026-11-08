import Testing
@testable import BakeGraph

struct RepeatedPinsTests {
    private func pinIDs(of id: NodeID, in project: ProjectFile, _ direction: PinDirection) -> [PinID] {
        guard let node = project.node(id) else { return [] }
        return NodeCatalog.pins(of: node).filter { $0.direction == direction }.map(\.id)
    }

    @Test func aNewMixerHasTwoInputs() {
        var project = ProjectFile()
        let mixer = project.addNode(.mixer, at: CanvasPoint())
        #expect(pinIDs(of: mixer, in: project, .input) == ["in1", "in2"])
        #expect(pinIDs(of: mixer, in: project, .output) == ["out"])
    }

    @Test func wiringTheLastMixerInputAddsASpareAndUnwiringShrinksIt() throws {
        var project = ProjectFile()
        let audio = project.addNode(.audio, at: CanvasPoint())
        let mixer = project.addNode(.mixer, at: CanvasPoint())
        let wire = Edge(from: PinRef(node: audio, pin: "out"), to: PinRef(node: mixer, pin: "in2"))

        try project.connect(from: wire.from, to: wire.to)
        #expect(pinIDs(of: mixer, in: project, .input) == ["in1", "in2", "in3"])

        project.removeEdge(wire)
        #expect(pinIDs(of: mixer, in: project, .input) == ["in1", "in2"])
    }

    @Test func aGapInTheMiddleKeepsTheInputsAfterIt() throws {
        var project = ProjectFile()
        let audio = project.addNode(.audio, at: CanvasPoint())
        let mixer = project.addNode(.mixer, at: CanvasPoint())
        for pin in ["in1", "in2", "in3"] {
            try project.connect(from: PinRef(node: audio, pin: "out"), to: PinRef(node: mixer, pin: pin))
        }
        project.removeEdge(Edge(from: PinRef(node: audio, pin: "out"), to: PinRef(node: mixer, pin: "in2")))
        #expect(pinIDs(of: mixer, in: project, .input) == ["in1", "in2", "in3", "in4"])
    }

    @Test func mixersStopGrowingAtSixteen() throws {
        var project = ProjectFile()
        let audio = project.addNode(.audio, at: CanvasPoint())
        let mixer = project.addNode(.mixer, at: CanvasPoint())
        for index in 1...16 {
            try project.connect(from: PinRef(node: audio, pin: "out"), to: PinRef(node: mixer, pin: "in\(index)"))
        }
        #expect(pinIDs(of: mixer, in: project, .input).count == 16)
    }

    @Test func removingASourceShrinksTheMixer() throws {
        var project = ProjectFile()
        let audio = project.addNode(.audio, at: CanvasPoint())
        let mixer = project.addNode(.mixer, at: CanvasPoint())
        try project.connect(from: PinRef(node: audio, pin: "out"), to: PinRef(node: mixer, pin: "in2"))
        project.removeNodes([audio])
        #expect(pinIDs(of: mixer, in: project, .input) == ["in1", "in2"])
    }

    @Test func macrosFollowOutputCountAndDropWiresWhenShrunk() throws {
        var project = ProjectFile()
        let macro = project.addNode(.macro, at: CanvasPoint())
        #expect(pinIDs(of: macro, in: project, .output) == ["out1"])
        let lfo2 = project.addNode(.lfo, at: CanvasPoint())
        let lfo3 = project.addNode(.lfo, at: CanvasPoint())
        project.setParameter("outputs", of: macro, to: .choice("3"))
        #expect(pinIDs(of: macro, in: project, .output) == ["out1", "out2", "out3"])
        try project.connect(from: PinRef(node: macro, pin: "out2"), to: PinRef(node: lfo2, pin: "reset"))
        try project.connect(from: PinRef(node: macro, pin: "out3"), to: PinRef(node: lfo3, pin: "reset"))
        project.setParameter("outputs", of: macro, to: .choice("1"))
        #expect(project.edges.isEmpty)
        #expect(pinIDs(of: macro, in: project, .output) == ["out1"])
    }

    @Test func aFactoryStartsWithTwoInputsAndGrowsAsInputsAreConnected() throws {
        var project = ProjectFile()
        let first = project.addNode(.singleCycle, at: CanvasPoint())
        let second = project.addNode(.singleCycle, at: CanvasPoint())
        let factory = project.addNode(.wavetableFactory, at: CanvasPoint())
        #expect(pinIDs(of: factory, in: project, .input) == ["in1", "in2"])
        try project.connect(from: PinRef(node: first, pin: "out"), to: PinRef(node: factory, pin: "in2"))
        #expect(pinIDs(of: factory, in: project, .input) == ["in1", "in2", "in3"])
        try project.connect(from: PinRef(node: second, pin: "out"), to: PinRef(node: factory, pin: "in3"))
        #expect(pinIDs(of: factory, in: project, .input) == ["in1", "in2", "in3", "in4"])
    }

    @Test func shrinkingFactoryInputCountDropsVanishedInputWires() throws {
        var project = ProjectFile()
        let first = project.addNode(.singleCycle, at: CanvasPoint())
        let last = project.addNode(.singleCycle, at: CanvasPoint())
        let factory = project.addNode(.wavetableFactory, at: CanvasPoint())
        try project.connect(from: PinRef(node: first, pin: "out"), to: PinRef(node: factory, pin: "in2"))
        try project.connect(from: PinRef(node: last, pin: "out"), to: PinRef(node: factory, pin: "in3"))
        project.removeEdge(Edge(from: PinRef(node: last, pin: "out"), to: PinRef(node: factory, pin: "in3")))
        #expect(project.edges == [Edge(from: PinRef(node: first, pin: "out"), to: PinRef(node: factory, pin: "in2"))])
    }

    @Test func splitterOutputsFollowItsChannelsSetting() {
        var project = ProjectFile()
        let splitter = project.addNode(.channelSplitter, at: CanvasPoint())
        #expect(pinIDs(of: splitter, in: project, .output) == ["out1", "out2"])
        project.setParameter("channels", of: splitter, to: .choice("4"))
        #expect(pinIDs(of: splitter, in: project, .output) == ["out1", "out2", "out3", "out4"])
    }

    @Test func shrinkingASplitterDropsWiresOnVanishedOutputs() throws {
        var project = ProjectFile()
        let splitter = project.addNode(.channelSplitter, at: CanvasPoint())
        let first = project.addNode(.print, at: CanvasPoint())
        let fourth = project.addNode(.print, at: CanvasPoint())
        project.setParameter("channels", of: splitter, to: .choice("4"))
        try project.connect(from: PinRef(node: splitter, pin: "out1"), to: PinRef(node: first, pin: "in"))
        try project.connect(from: PinRef(node: splitter, pin: "out4"), to: PinRef(node: fourth, pin: "in"))

        project.setParameter("channels", of: splitter, to: .choice("2"))

        #expect(project.edges == [Edge(from: PinRef(node: splitter, pin: "out1"), to: PinRef(node: first, pin: "in"))])
    }

    @Test func pinsHaveReadableLabels() {
        var project = ProjectFile()
        let splitter = project.addNode(.channelSplitter, at: CanvasPoint())
        let mixer = project.addNode(.mixer, at: CanvasPoint())
        let filters = project.addNode(.filters, at: CanvasPoint())
        project.setModulated("cutoff", of: filters, true)
        let node = { (id: NodeID) in project.node(id)! }

        #expect(NodeCatalog.label(of: "out1", on: node(splitter)) == "L")
        #expect(NodeCatalog.label(of: "out2", on: node(splitter)) == "R")
        #expect(NodeCatalog.label(of: "in2", on: node(mixer)) == "In 2")
        #expect(NodeCatalog.label(of: "in", on: node(filters)) == "In")
        #expect(NodeCatalog.label(of: "out", on: node(filters)) == "Out")
        #expect(NodeCatalog.label(of: "mod.cutoff", on: node(filters)) == "Cutoff")
    }

    @Test func hiddenParametersAreNeverDrawn() throws {
        let count = try #require(NodeCatalog.definition(for: .mixer).parameter("inputCount"))
        #expect(count.role == .hidden)
    }

    @Test func existingKindsKeepTheirPins() {
        #expect(NodeCatalog.pins(of: Node(kind: .filters)).map(\.id) == ["in", "out"])
        #expect(NodeCatalog.pins(of: Node(kind: .print)).map(\.id) == ["in"])
    }
}
