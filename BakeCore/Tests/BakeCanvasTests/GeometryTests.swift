import BakeGraph
import CoreGraphics
import Testing
@testable import BakeCanvas

struct NodeLayoutTests {
    @Test func inputsSitOnTheLeftEdgeAndOutputsOnTheRight() throws {
        let node = Node(kind: .filters, position: CanvasPoint(x: 100, y: 200))
        let input = try #require(NodeLayout.anchor(of: "in", on: node, in: ProjectFile()))
        let output = try #require(NodeLayout.anchor(of: "out", on: node, in: ProjectFile()))
        #expect(input == CGPoint(x: 100, y: 200 + NodeLayout.headerHeight + NodeLayout.portRowHeight / 2))
        #expect(output == CGPoint(x: 100 + NodeLayout.width, y: input.y))
    }

    @Test func spawnedModulationPinsAddRowsBelowTheInputs() throws {
        var node = Node(kind: .filters)
        node.setModulated("q", true)
        node.setModulated("cutoff", true)
        #expect(NodeLayout.portRows(of: node, in: ProjectFile()) == 3)
        let q = try #require(NodeLayout.anchor(of: "mod.q", on: node, in: ProjectFile()))
        #expect(q.y == NodeLayout.headerHeight + 2.5 * NodeLayout.portRowHeight)
    }

    @Test func cardsGrowWithRepeatedPins() throws {
        var project = ProjectFile()
        let audio = project.addNode(.audio, at: CanvasPoint())
        let mixer = project.addNode(.mixer, at: CanvasPoint())
        #expect(NodeLayout.portRows(of: try #require(project.node(mixer)), in: project) == 2)
        try project.connect(from: PinRef(node: audio, pin: "out"), to: PinRef(node: mixer, pin: "in2"))
        #expect(NodeLayout.portRows(of: try #require(project.node(mixer)), in: project) == 3)

        let splitter = project.addNode(.channelSplitter, at: CanvasPoint())
        project.setParameter("channels", of: splitter, to: .choice("4"))
        let node = try #require(project.node(splitter))
        for pin in ["in", "out1", "out2", "out3", "out4"] {
            #expect(NodeLayout.anchor(of: pin, on: node, in: ProjectFile()) != nil, "\(pin)")
        }
    }

    @Test func everyCardHasAtLeastOnePortRow() {
        #expect(NodeLayout.portRows(of: Node(kind: .lfo), in: ProjectFile()) == 1)
        #expect(NodeLayout.portRows(of: Node(kind: .print), in: ProjectFile()) == 1)
    }

    @Test func unknownPinsHaveNoAnchor() {
        #expect(NodeLayout.anchor(of: "mod.cutoff", on: Node(kind: .filters), in: ProjectFile()) == nil)
    }
}

struct WireCurveTests {
    private let curve = WireCurve(from: CGPoint(x: 0, y: 0), to: CGPoint(x: 200, y: 100))

    @Test func curvesStartAndEndOnThePins() {
        #expect(curve.point(at: 0) == CGPoint(x: 0, y: 0))
        #expect(curve.point(at: 1) == CGPoint(x: 200, y: 100))
    }

    @Test func wiresLeaveAndEnterHorizontally() {
        #expect(curve.control1.y == 0 && curve.control1.x > 0)
        #expect(curve.control2.y == 100 && curve.control2.x < 200)
    }

    @Test func distanceIsZeroOnTheCurveAndLargeAwayFromIt() {
        #expect(curve.distance(to: curve.point(at: 0.5)) < 0.01)
        #expect(curve.distance(to: CGPoint(x: 100, y: 400)) > 100)
    }
}

struct CanvasHitTestTests {
    @Test func pinsAreFoundWithinTheirRadius() throws {
        var project = ProjectFile()
        let filters = project.addNode(.filters, at: CanvasPoint(x: 0, y: 0))
        let node = try #require(project.node(filters))
        let anchor = try #require(NodeLayout.anchor(of: "in", on: node, in: ProjectFile()))
        #expect(CanvasHitTest.pin(at: CGPoint(x: anchor.x + 4, y: anchor.y + 3), in: project) == PinRef(node: filters, pin: "in"))
        #expect(CanvasHitTest.pin(at: CGPoint(x: anchor.x + 60, y: anchor.y), in: project) == nil)
    }

    @Test func theNearestPinWins() {
        var project = ProjectFile()
        let left = project.addNode(.filters, at: CanvasPoint(x: 0, y: 0))
        let right = project.addNode(.print, at: CanvasPoint(x: Double(NodeLayout.width) + 10, y: 0))
        let y = NodeLayout.headerHeight + NodeLayout.portRowHeight / 2
        #expect(CanvasHitTest.pin(at: CGPoint(x: NodeLayout.width + 3, y: y), in: project) == PinRef(node: left, pin: "out"))
        #expect(CanvasHitTest.pin(at: CGPoint(x: NodeLayout.width + 8, y: y), in: project) == PinRef(node: right, pin: "in"))
    }

    @Test func wiresAreFoundNearTheirCurve() throws {
        var project = ProjectFile()
        let audio = project.addNode(.audio, at: CanvasPoint(x: 0, y: 0))
        let filters = project.addNode(.filters, at: CanvasPoint(x: 500, y: 200))
        try project.connect(from: PinRef(node: audio, pin: "out"), to: PinRef(node: filters, pin: "in"))
        let edge = try #require(project.edges.first)
        let middle = try #require(WireCurve(edge: edge, in: project)).point(at: 0.5)
        #expect(CanvasHitTest.edge(at: CGPoint(x: middle.x, y: middle.y + 3), in: project) == edge)
        #expect(CanvasHitTest.edge(at: CGPoint(x: middle.x, y: middle.y + 80), in: project) == nil)
    }
}
