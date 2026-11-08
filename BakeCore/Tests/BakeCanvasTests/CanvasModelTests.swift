import BakeGraph
import CoreGraphics
import Testing
@testable import BakeCanvas

/// Stands in for the document binding: same write rule as `Binding.edit`, and counts writes —
/// each write is one undo step.
@MainActor
final class DocumentHarness {
    private(set) var project: ProjectFile
    private(set) var writes = 0

    init(_ project: ProjectFile) {
        self.project = project
    }

    func edit(_ change: (inout ProjectFile) -> Void) {
        if let edited = project.applying(change) {
            project = edited
            writes += 1
        }
    }
}

@MainActor
struct CanvasModelTests {
    private struct Fixture {
        let document: DocumentHarness
        let audio: NodeID, filters: NodeID, print: NodeID, lfo: NodeID
    }

    /// Audio, Filters, Print left to right; an LFO below. Filters has Cutoff ticked.
    private func fixture() -> Fixture {
        var project = ProjectFile()
        let audio = project.addNode(.audio, at: CanvasPoint(x: 0, y: 0))
        let filters = project.addNode(.filters, at: CanvasPoint(x: 400, y: 0))
        let print = project.addNode(.print, at: CanvasPoint(x: 800, y: 0))
        let lfo = project.addNode(.lfo, at: CanvasPoint(x: 0, y: 300))
        project.setModulated("cutoff", of: filters, true)
        return Fixture(document: DocumentHarness(project), audio: audio, filters: filters, print: print, lfo: lfo)
    }

    private func viewPoint(_ pin: PinID, on node: NodeID, _ document: DocumentHarness, _ model: CanvasModel) throws -> CGPoint {
        let card = try #require(document.project.node(node))
        let anchor = try #require(NodeLayout.anchor(of: pin, on: card, in: document.project))
        return model.viewport.toView(anchor)
    }

    // MARK: Moving

    @Test func nodeDragsWriteOnceWhenReleased() {
        let f = fixture()
        let model = CanvasModel()
        model.dragNode(f.filters, by: CGSize(width: 10, height: 0))
        model.dragNode(f.filters, by: CGSize(width: 30, height: 5))
        #expect(f.document.writes == 0)
        #expect(model.displayed(f.document.project).node(f.filters)?.position == CanvasPoint(x: 430, y: 5))

        f.document.edit { model.endNodeDrag(in: &$0) }

        #expect(f.document.writes == 1)
        #expect(f.document.project.node(f.filters)?.position == CanvasPoint(x: 430, y: 5))
    }

    @Test func dragDistancesFollowTheZoom() {
        let f = fixture()
        let model = CanvasModel()
        model.viewport.zoom(by: 2, around: .zero)
        model.dragNode(f.filters, by: CGSize(width: 20, height: 0))
        f.document.edit { model.endNodeDrag(in: &$0) }
        #expect(f.document.project.node(f.filters)?.position == CanvasPoint(x: 410, y: 0))
    }

    @Test func draggingASelectedNodeMovesTheWholeSelection() {
        let f = fixture()
        let model = CanvasModel()
        model.select(f.audio, extending: false)
        model.select(f.filters, extending: true)
        model.dragNode(f.filters, by: CGSize(width: 0, height: 50))
        f.document.edit { model.endNodeDrag(in: &$0) }
        #expect(f.document.project.node(f.audio)?.position == CanvasPoint(x: 0, y: 50))
        #expect(f.document.project.node(f.print)?.position == CanvasPoint(x: 800, y: 0))
    }

    @Test func draggingAnUnselectedNodeSelectsOnlyIt() {
        let f = fixture()
        let model = CanvasModel()
        model.select(f.audio, extending: false)
        model.dragNode(f.print, by: CGSize(width: 5, height: 0))
        #expect(model.selection == [f.print])
    }

    // MARK: Wiring

    @Test func wiringAnOutputToAnInputAddsOneEdge() throws {
        let f = fixture()
        let model = CanvasModel()
        let target = PinRef(node: f.filters, pin: "in")
        model.dragWire(from: PinRef(node: f.audio, pin: "out"), toView: try viewPoint("in", on: f.filters, f.document, model), in: f.document.project)

        #expect(model.pendingWire?.target == target)
        #expect(model.highlight(of: target) == .target)
        #expect(model.highlight(of: PinRef(node: f.print, pin: "in")) == .candidate)
        #expect(model.highlight(of: PinRef(node: f.lfo, pin: "out")) == .unavailable)

        f.document.edit { model.endWire(in: &$0) }

        #expect(f.document.writes == 1)
        #expect(f.document.project.edges == [Edge(from: PinRef(node: f.audio, pin: "out"), to: target)])
        #expect(model.pendingWire == nil)
    }

    @Test func controlWiresOnlyReachControlInputs() throws {
        let f = fixture()
        let model = CanvasModel()
        let lfoOut = PinRef(node: f.lfo, pin: "out")
        model.dragWire(from: lfoOut, toView: try viewPoint("in", on: f.print, f.document, model), in: f.document.project)
        #expect(model.pendingWire?.target == nil)
        #expect(model.highlight(of: PinRef(node: f.print, pin: "in")) == .unavailable)
        #expect(model.highlight(of: PinRef(node: f.filters, pin: "mod.cutoff")) == .candidate)
        f.document.edit { model.endWire(in: &$0) }
        #expect(f.document.writes == 0)
    }

    @Test func wiresCanBeDrawnBackwardsFromAnInput() throws {
        let f = fixture()
        let model = CanvasModel()
        model.dragWire(from: PinRef(node: f.filters, pin: "mod.cutoff"), toView: try viewPoint("out", on: f.lfo, f.document, model), in: f.document.project)
        f.document.edit { model.endWire(in: &$0) }
        #expect(f.document.project.edges == [Edge(from: PinRef(node: f.lfo, pin: "out"), to: PinRef(node: f.filters, pin: "mod.cutoff"))])
    }

    @Test func pickingUpAWiredInputMovesTheWireInOneStep() throws {
        let f = fixture()
        let model = CanvasModel()
        f.document.edit { try? $0.connect(from: PinRef(node: f.audio, pin: "out"), to: PinRef(node: f.filters, pin: "in")) }
        let before = f.document.writes

        model.dragWire(from: PinRef(node: f.filters, pin: "in"), toView: try viewPoint("in", on: f.print, f.document, model), in: f.document.project)
        #expect(model.displayed(f.document.project).edges.isEmpty)
        f.document.edit { model.endWire(in: &$0) }

        #expect(f.document.writes == before + 1)
        #expect(f.document.project.edges == [Edge(from: PinRef(node: f.audio, pin: "out"), to: PinRef(node: f.print, pin: "in"))])
    }

    @Test func droppingAPickedUpWireOnEmptySpaceDisconnectsIt() {
        let f = fixture()
        let model = CanvasModel()
        f.document.edit { try? $0.connect(from: PinRef(node: f.audio, pin: "out"), to: PinRef(node: f.filters, pin: "in")) }
        model.dragWire(from: PinRef(node: f.filters, pin: "in"), toView: CGPoint(x: 600, y: 900), in: f.document.project)
        f.document.edit { model.endWire(in: &$0) }
        #expect(f.document.project.edges.isEmpty)
    }

    @Test func droppingAPickedUpWireBackWhereItWasChangesNothing() throws {
        let f = fixture()
        let model = CanvasModel()
        f.document.edit { try? $0.connect(from: PinRef(node: f.audio, pin: "out"), to: PinRef(node: f.filters, pin: "in")) }
        let before = f.document.writes
        model.dragWire(from: PinRef(node: f.filters, pin: "in"), toView: try viewPoint("in", on: f.filters, f.document, model), in: f.document.project)
        f.document.edit { model.endWire(in: &$0) }
        #expect(f.document.writes == before)
    }

    // MARK: Parameters

    @Test func sliderDragsPreviewWithoutWritingThenCommitOnce() {
        let f = fixture()
        let model = CanvasModel()
        model.preview("cutoff", of: f.filters, value: .number(1_500))
        model.preview("cutoff", of: f.filters, value: .number(2_000))
        #expect(f.document.writes == 0)
        #expect(model.displayed(f.document.project).node(f.filters)?.parameters["cutoff"] == .number(2_000))

        f.document.edit { model.commitParameter(in: &$0) }
        f.document.edit { model.commitParameter(in: &$0) }

        #expect(f.document.writes == 1)
        #expect(f.document.project.node(f.filters)?.parameters["cutoff"] == .number(2_000))
    }

    @Test func trimDragsCommitOnce() {
        let f = fixture()
        let model = CanvasModel()
        model.previewTrim(0.2, for: "cutoff", of: f.filters)
        model.previewTrim(-0.5, for: "cutoff", of: f.filters)
        #expect(f.document.writes == 0)
        f.document.edit { model.commitTrim(in: &$0) }
        #expect(f.document.writes == 1)
        #expect(f.document.project.node(f.filters)?.modulationTrims["cutoff"] == -0.5)
    }

    // MARK: Selection, deletion, pages, adding

    @Test func deletingTheSelectionRemovesNodesAndTheirWires() {
        let f = fixture()
        let model = CanvasModel()
        f.document.edit { try? $0.connect(from: PinRef(node: f.audio, pin: "out"), to: PinRef(node: f.filters, pin: "in")) }
        model.select(f.filters, extending: false)
        f.document.edit { model.deleteSelection(in: &$0) }
        #expect(f.document.project.node(f.filters) == nil)
        #expect(f.document.project.edges.isEmpty)
        #expect(model.selection.isEmpty)
    }

    @Test func deletingInsideACustomNodeKeepsItsInputsAndOutputs() throws {
        let f = fixture()
        let model = CanvasModel()
        f.document.edit { try? $0.connect(from: PinRef(node: f.audio, pin: "out"), to: PinRef(node: f.filters, pin: "in")) }
        f.document.edit { try? $0.connect(from: PinRef(node: f.filters, pin: "out"), to: PinRef(node: f.print, pin: "in")) }
        f.document.edit { $0.groupNodes([f.filters]) }
        let definition = try #require(f.document.project.customNodes.first)
        let inside = DocumentHarness(try #require(f.document.project.inside(definition.id)))
        let boundary = inside.project.nodes.filter { $0.kind == .customInput || $0.kind == .customOutput }.map(\.id)
        #expect(boundary.count == 2)
        for id in inside.project.nodes.map(\.id) { model.select(id, extending: true) }
        inside.edit { model.deleteSelection(in: &$0) }
        #expect(inside.project.nodes.map(\.id) == boundary)
    }

    @Test func clickingAWireSelectsItAndDeleteRemovesOnlyTheWire() throws {
        let f = fixture()
        let model = CanvasModel()
        f.document.edit { try? $0.connect(from: PinRef(node: f.audio, pin: "out"), to: PinRef(node: f.filters, pin: "in")) }
        let edge = try #require(f.document.project.edges.first)
        let middle = try #require(WireCurve(edge: edge, in: f.document.project)).point(at: 0.5)

        model.click(atView: model.viewport.toView(middle), in: f.document.project)
        #expect(model.selectedEdge == edge)
        f.document.edit { model.deleteSelection(in: &$0) }
        #expect(f.document.project.edges.isEmpty)
        #expect(f.document.project.nodes.count == 4)

        model.click(atView: CGPoint(x: 5_000, y: 5_000), in: f.document.project)
        #expect(model.selectedEdge == nil)
    }

    @Test func activatingTwoPinsWiresThemEitherWayRound() {
        let f = fixture()
        let model = CanvasModel()
        let out = PinRef(node: f.audio, pin: "out"), into = PinRef(node: f.filters, pin: "in")
        // Input first, then output: still output → input.
        f.document.edit { model.activatePin(into, in: &$0) }
        #expect(model.wireStart == into)
        #expect(model.highlight(of: into) == .source)
        f.document.edit { model.activatePin(out, in: &$0) }
        #expect(f.document.project.edges == [Edge(from: out, to: into)])
        #expect(model.wireStart == nil)
        // The same pin twice cancels; a rejected pair makes nothing.
        f.document.edit { model.activatePin(out, in: &$0) }
        f.document.edit { model.activatePin(out, in: &$0) }
        #expect(model.wireStart == nil)
        f.document.edit { model.activatePin(PinRef(node: f.lfo, pin: "out"), in: &$0) }
        f.document.edit { model.activatePin(PinRef(node: f.print, pin: "in"), in: &$0) }
        #expect(f.document.project.edges.count == 1)
        f.document.edit { model.disconnect(into, in: &$0) }
        #expect(f.document.project.edges.isEmpty)
    }

    @Test func theKeyboardSelectsNudgesAndFlipsCards() {
        let f = fixture()
        let model = CanvasModel()
        let ids = f.document.project.nodes.map(\.id)
        model.selectNext(in: f.document.project)
        #expect(model.selection == [ids[0]])
        model.selectNext(in: f.document.project)
        #expect(model.selection == [ids[1]])
        model.selectNext(in: f.document.project, backwards: true)
        model.selectNext(in: f.document.project, backwards: true)
        #expect(model.selection == [ids[ids.count - 1]])
        let before = f.document.project.node(ids[ids.count - 1])?.position
        f.document.edit { model.nudgeSelection(dx: 1, dy: -1, in: &$0) }
        #expect(f.document.project.node(ids[ids.count - 1])?.position == CanvasPoint(x: (before?.x ?? 0) + 24, y: (before?.y ?? 0) - 24))
        model.flipSelection()
        #expect(model.page(of: ids[ids.count - 1]) == .modulation)
    }

    @Test func flippingTogglesTheVisiblePage() {
        let f = fixture()
        let model = CanvasModel()
        #expect(model.page(of: f.filters) == .macro)
        model.flip(f.filters)
        #expect(model.page(of: f.filters) == .modulation)
        model.flip(f.filters)
        #expect(model.page(of: f.filters) == .macro)
    }

    @Test func addedNodesAppearAtTheViewCentreSelectedAndCascade() {
        let document = DocumentHarness(ProjectFile())
        let model = CanvasModel()
        model.viewSize = CGSize(width: 800, height: 600)
        var first: NodeID?
        var second: NodeID?
        document.edit { first = model.addNode(.filters, in: &$0) }
        document.edit { second = model.addNode(.print, in: &$0) }
        let a = first.flatMap { document.project.node($0) }
        let b = second.flatMap { document.project.node($0) }
        #expect(a?.position == CanvasPoint(x: 280, y: 240))
        #expect(b?.position == CanvasPoint(x: 304, y: 264))
        #expect(model.selection == Set([second].compactMap { $0 }))
    }

    /// A node picked after a double-click lands centred where the click was, even zoomed and panned.
    @Test func aNodeAddedAtAPointIsCentredThere() {
        let document = DocumentHarness(ProjectFile())
        let model = CanvasModel()
        model.viewSize = CGSize(width: 800, height: 600)
        model.viewport = Viewport(offset: CGPoint(x: 100, y: 50), scale: 2)
        let position = model.cardPosition(atView: CGPoint(x: 300, y: 250))
        var added: NodeID?
        document.edit { added = model.addNode(.reverb, at: position, in: &$0) }
        let world = model.viewport.toWorld(CGPoint(x: 300, y: 250))
        #expect(position == CanvasPoint(x: Double(world.x - NodeLayout.width / 2).rounded(), y: Double(world.y - 60).rounded()))
        #expect(added.flatMap { document.project.node($0) }?.position == position)
        #expect(model.selection == Set([added].compactMap { $0 }))
    }
}
