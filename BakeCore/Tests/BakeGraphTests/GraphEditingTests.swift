import Foundation
import Testing
@testable import BakeGraph

struct GraphEditingTests {
    private func pin(_ node: NodeID, _ id: PinID) -> PinRef {
        PinRef(node: node, pin: id)
    }

    @Test func addedNodesUseCatalogDefaultsAtTheirPosition() throws {
        var project = ProjectFile()
        let id = project.addNode(.filters, at: CanvasPoint(x: 40, y: 80))
        let node = try #require(project.node(id))
        #expect(node.kind == .filters)
        #expect(node.position == CanvasPoint(x: 40, y: 80))
        #expect(node.parameters == NodeCatalog.defaultParameters(for: .filters))
    }

    @Test func movingShiftsOnlyTheGivenNodes() {
        var project = ProjectFile()
        let a = project.addNode(.audio, at: CanvasPoint(x: 0, y: 0))
        let b = project.addNode(.print, at: CanvasPoint(x: 100, y: 0))
        project.moveNodes([a], byX: 10, y: -5)
        #expect(project.node(a)?.position == CanvasPoint(x: 10, y: -5))
        #expect(project.node(b)?.position == CanvasPoint(x: 100, y: 0))
    }

    @Test func removingNodesRemovesTheirWires() throws {
        var project = ProjectFile()
        let audio = project.addNode(.audio, at: CanvasPoint())
        let filters = project.addNode(.filters, at: CanvasPoint())
        let print = project.addNode(.print, at: CanvasPoint())
        try project.connect(from: pin(audio, "out"), to: pin(filters, "in"))
        try project.connect(from: pin(filters, "out"), to: pin(print, "in"))

        project.removeNodes([filters])

        #expect(project.nodes.map(\.id) == [audio, print])
        #expect(project.edges.isEmpty)
    }

    @Test func connectionsFollowTheCompilerRules() throws {
        var project = ProjectFile()
        let audio = project.addNode(.audio, at: CanvasPoint())
        let filters = project.addNode(.filters, at: CanvasPoint())
        let distortion = project.addNode(.distortion, at: CanvasPoint())
        let lfo = project.addNode(.lfo, at: CanvasPoint())
        let print = project.addNode(.print, at: CanvasPoint())
        project.setModulated("cutoff", of: filters, true)

        #expect(project.checkConnection(from: pin(audio, "out"), to: pin(filters, "nope")) == .unknownPin)
        #expect(project.checkConnection(from: pin(filters, "out"), to: pin(filters, "in")) == .sameNode)
        #expect(project.checkConnection(from: pin(filters, "in"), to: pin(print, "in")) == .notOutputToInput)
        #expect(project.checkConnection(from: pin(lfo, "out"), to: pin(print, "in")) == .typeMismatch)
        #expect(project.checkConnection(from: pin(lfo, "out"), to: pin(filters, "mod.cutoff")) == nil)
        // Audio may drive a control input (audio-rate modulation).
        #expect(project.checkConnection(from: pin(audio, "out"), to: pin(filters, "mod.cutoff")) == nil)

        try project.connect(from: pin(audio, "out"), to: pin(filters, "in"))
        #expect(project.checkConnection(from: pin(audio, "out"), to: pin(filters, "in")) == .inputOccupied)

        try project.connect(from: pin(filters, "out"), to: pin(distortion, "in"))
        #expect(project.checkConnection(from: pin(distortion, "out"), to: pin(filters, "mod.cutoff")) == .cycle)
    }

    @Test func rejectedConnectionsThrowAndLeaveTheGraphAlone() {
        var project = ProjectFile()
        let lfo = project.addNode(.lfo, at: CanvasPoint())
        let print = project.addNode(.print, at: CanvasPoint())
        #expect(throws: ConnectionRejection.typeMismatch) {
            try project.connect(from: pin(lfo, "out"), to: pin(print, "in"))
        }
        #expect(project.edges.isEmpty)
    }

    @Test func untickingAModulatedParameterRemovesItsWire() throws {
        var project = ProjectFile()
        let lfo = project.addNode(.lfo, at: CanvasPoint())
        let filters = project.addNode(.filters, at: CanvasPoint())
        project.setModulated("cutoff", of: filters, true)
        try project.connect(from: pin(lfo, "out"), to: pin(filters, "mod.cutoff"))

        project.setModulated("cutoff", of: filters, false)

        #expect(project.node(filters)?.modulated.isEmpty == true)
        #expect(project.edges.isEmpty)
    }

    @Test func onlyModulatableParametersCanBeTicked() {
        var project = ProjectFile()
        let filters = project.addNode(.filters, at: CanvasPoint())
        // Slope sets the filter's structure (how many sections), so it can't be modulated.
        project.setModulated("slope", of: filters, true)
        #expect(project.node(filters)?.modulated.isEmpty == true)
    }

    @Test func parametersAreClampedAndTypeChecked() {
        var project = ProjectFile()
        let filters = project.addNode(.filters, at: CanvasPoint())
        project.setParameter("cutoff", of: filters, to: .number(99_999))
        #expect(project.node(filters)?.parameters["cutoff"] == .number(20_000))
        project.setParameter("cutoff", of: filters, to: .choice("loud"))
        project.setParameter("type", of: filters, to: .choice("bogus"))
        #expect(project.node(filters)?.parameters["cutoff"] == .number(20_000))
        #expect(project.node(filters)?.parameters["type"] == .choice("lowpass")) // rejected value leaves the stored default
    }

    @Test func trimsAreClamped() {
        var project = ProjectFile()
        let filters = project.addNode(.filters, at: CanvasPoint())
        project.setTrim(3, for: "cutoff", of: filters)
        #expect(project.node(filters)?.modulationTrims["cutoff"] == 1)
    }

    @Test func modulationPinsMapBackToTheirParameter() {
        #expect(NodeCatalog.parameter(forModulationPin: "mod.cutoff") == "cutoff")
        #expect(NodeCatalog.parameter(forModulationPin: "in") == nil)
    }

    @Test func theV1GraphBuiltByEditingCompiles() throws {
        var project = ProjectFile()
        let asset = AssetID()
        let audio = project.addNode(.audio, at: CanvasPoint())
        let stretch = project.addNode(.stretch, at: CanvasPoint())
        let filters = project.addNode(.filters, at: CanvasPoint())
        let distortion = project.addNode(.distortion, at: CanvasPoint())
        let print = project.addNode(.print, at: CanvasPoint())
        let lfo = project.addNode(.lfo, at: CanvasPoint())
        let audioIndex = try #require(project.index(of: audio))
        project.nodes[audioIndex].assetID = asset
        project.setModulated("cutoff", of: filters, true)
        try project.connect(from: pin(audio, "out"), to: pin(stretch, "in"))
        try project.connect(from: pin(stretch, "out"), to: pin(filters, "in"))
        try project.connect(from: pin(filters, "out"), to: pin(distortion, "in"))
        try project.connect(from: pin(distortion, "out"), to: pin(print, "in"))
        try project.connect(from: pin(lfo, "out"), to: pin(filters, "mod.cutoff"))

        let plan = try GraphCompiler.compile(project, assets: [asset: AssetInfo(frameCount: 48_000, channelCount: 2, sampleRate: 48_000)])

        #expect(plan.steps.count == 6)
    }
}
