import Testing
@testable import BakeGraph

/// Spec §11: a Feedback node's Return may close a loop; the compiler orders the rest, keeps each loop's
/// steps together, and rejects what a loop rendered in short blocks can't run.
struct FeedbackCompilerTests {
    private static let longAsset = AssetID(testUUID(9_001))
    private let assets = oneSecondStereo.merging([longAsset: AssetInfo(frameCount: 480_000, channelCount: 2, sampleRate: 48_000)]) { $1 }

    /// Audio → Feedback → Filters → Distortion → back into Return; Distortion → Bake.
    private func loop(middle: NodeKind = .distortion, _ parameters: [ParameterID: ParameterValue] = ["oversampling": .choice("1")])
        -> (graph: TestGraph, feedback: NodeID, filters: NodeID, middle: NodeID, bake: NodeID) {
        var graph = TestGraph()
        let audio = graph.add(.audio)
        let feedback = graph.add(.feedback)
        let filters = graph.add(.filters)
        let node = graph.add(middle, parameters)
        let bake = graph.add(.print)
        graph.connect(audio, to: feedback)
        graph.connect(feedback, to: filters)
        graph.connect(filters, to: node)
        graph.connect(node, to: feedback, "return")
        graph.connect(node, to: bake)
        return (graph, feedback, filters, node, bake)
    }

    private func errors(_ project: ProjectFile) -> [CompileError] {
        do {
            _ = try GraphCompiler.compile(project, assets: assets)
            return []
        } catch {
            return error.errors
        }
    }

    @Test func aReturnWireClosesALoopThatRendersInLockstep() throws {
        let (graph, feedback, filters, middle, _) = loop()
        let plan = try GraphCompiler.compile(graph.project, assets: assets)
        #expect(plan.loops.count == 1)
        let loop = try #require(plan.loops.first)
        #expect(Set(plan.steps[loop.steps].map(\.node)) == [feedback, filters, middle])
        // 10 ms at 48 kHz.
        #expect(loop.blockFrames == 480)
        // One second plus the 2 s tail, for every node in the loop.
        #expect(plan.steps[loop.steps].allSatisfy { $0.shape.frames == 144_000 })
        // The Feedback step reads the buffer the end of the loop writes.
        let feedbackStep = try #require(plan.steps.first { $0.node == feedback })
        let middleStep = try #require(plan.steps.first { $0.node == middle })
        #expect(feedbackStep.inputs["return"]?.slot == middleStep.outputs["out"]?.slot)
    }

    @Test func noBufferALoopUsesIsReusedInsideIt() throws {
        let (graph, _, _, _, _) = loop()
        let plan = try GraphCompiler.compile(graph.project, assets: assets)
        let loop = try #require(plan.loops.first)
        let written = plan.steps[loop.steps].flatMap { $0.outputs.values.map(\.slot) }
        #expect(Set(written).count == written.count)
        let read = Set(plan.steps[loop.steps].flatMap { $0.inputs.values.map(\.slot) })
        // Every buffer a loop step reads is either written inside the loop or by a step before it.
        for slot in read {
            let writers = plan.steps.indices.filter { plan.steps[$0].outputs.values.contains { $0.slot == slot } }
            #expect(writers.contains { $0 < loop.steps.upperBound })
        }
    }

    @Test func aPatchWithoutFeedbackHasNoLoops() throws {
        var graph = TestGraph()
        let audio = graph.add(.audio)
        let filters = graph.add(.filters)
        let bake = graph.add(.print)
        graph.connect(audio, to: filters)
        graph.connect(filters, to: bake)
        #expect(try GraphCompiler.compile(graph.project, assets: assets).loops.isEmpty)
    }

    @Test func nodesBetweenLoopStepsMoveOutOfTheWay() throws {
        // Created between the loop's nodes: Redux reads the loop but isn't on its path back, so it
        // must render after the whole loop; the LFO doesn't depend on it and goes before.
        var graph = TestGraph()
        let audio = graph.add(.audio)
        let feedback = graph.add(.feedback)
        let filters = graph.add(.filters)
        let redux = graph.add(.redux)
        let lfo = graph.add(.lfo)
        let mixer = graph.add(.mixer)
        let bakeA = graph.add(.print)
        let bakeB = graph.add(.print)
        graph.connect(audio, to: feedback)
        graph.connect(feedback, to: filters)
        graph.connect(filters, to: redux)
        graph.connect(filters, to: mixer, "in1")
        graph.connect(lfo, to: mixer, "mod.gain")
        graph.project.nodes[5].setModulated("gain", true)
        graph.connect(mixer, to: feedback, "return")
        graph.connect(redux, to: bakeA)
        graph.connect(mixer, to: bakeB)
        let plan = try GraphCompiler.compile(graph.project, assets: assets)
        let order = plan.steps.map(\.node)
        let loop = try #require(plan.loops.first)
        #expect(order[loop.steps] == [feedback, filters, mixer])
        #expect(try #require(order.firstIndex(of: redux)) >= loop.steps.upperBound)
        #expect(try #require(order.firstIndex(of: lfo)) < loop.steps.lowerBound)
    }

    @Test func nodesThatLookAheadCantSitInALoop() {
        for kind in [NodeKind.reverse, .stretch, .halfTime, .granularCloud] {
            let (graph, _, _, middle, _) = loop(middle: kind, [:])
            #expect(errors(graph.project) == [.feedbackNotCausal(middle)], "\(kind): \(errors(graph.project))")
        }
        // Oversampled shapers and linear-phase Filters read ahead too.
        let (oversampled, _, _, distortion, _) = loop(middle: .distortion, ["oversampling": .choice("8")])
        #expect(errors(oversampled.project) == [.feedbackNotCausal(distortion)])
        let (linear, _, _, filters, _) = loop(middle: .filters, ["phase": .choice("linear")])
        #expect(errors(linear.project) == [.feedbackNotCausal(filters)])
    }

    @Test func aLoopNodeOfAnotherLengthIsRejected() {
        // A Mixer in the loop also fed by a 10 s file renders 10 s; the loop is 3 s.
        var graph = TestGraph()
        let audio = graph.add(.audio)
        let long = graph.add(.audio, asset: Self.longAsset)
        let feedback = graph.add(.feedback)
        let mixer = graph.add(.mixer)
        let bake = graph.add(.print)
        graph.connect(audio, to: feedback)
        graph.connect(feedback, to: mixer, "in1")
        graph.connect(long, to: mixer, "in2")
        graph.connect(mixer, to: feedback, "return")
        graph.connect(mixer, to: bake)
        #expect(errors(graph.project) == [.feedbackLengthMismatch(mixer)])
    }

    @Test func aFeedbackNodeInsideALoopIsRejected() {
        var graph = TestGraph()
        let audio = graph.add(.audio)
        let outer = graph.add(.feedback)
        let inner = graph.add(.feedback)
        let filters = graph.add(.filters)
        let bake = graph.add(.print)
        graph.connect(audio, to: outer)
        graph.connect(outer, to: inner)
        graph.connect(inner, to: filters)
        graph.connect(filters, to: outer, "return")
        graph.connect(filters, to: bake)
        #expect(errors(graph.project) == [.nestedFeedback(inner)])
    }

    @Test func anyOtherCycleIsStillACycle() {
        var graph = TestGraph()
        let audio = graph.add(.audio)
        let mixer = graph.add(.mixer)
        let filters = graph.add(.filters)
        let bake = graph.add(.print)
        graph.connect(audio, to: mixer, "in1")
        graph.connect(mixer, to: filters)
        graph.connect(filters, to: mixer, "in2")
        graph.connect(filters, to: bake)
        // The loop and everything downstream of it, as before.
        #expect(errors(graph.project) == [.cycle([mixer, filters, bake])])
    }

    @Test func aReturnFromOutsideTheLoopIsAnOrdinaryInput() throws {
        // The Return's source doesn't depend on the Feedback node: nothing loops, and the source
        // renders first.
        var graph = TestGraph()
        let audio = graph.add(.audio)
        let feedback = graph.add(.feedback)
        let other = graph.add(.audio)
        let bake = graph.add(.print)
        graph.connect(audio, to: feedback)
        graph.connect(other, to: feedback, "return")
        graph.connect(feedback, to: bake)
        let plan = try GraphCompiler.compile(graph.project, assets: assets)
        #expect(plan.loops.isEmpty)
        let order = plan.steps.map(\.node)
        #expect(try #require(order.firstIndex(of: other)) < #require(order.firstIndex(of: feedback)))
    }

    @Test func theCanvasLetsOnlyAReturnCloseALoop() throws {
        var graph = TestGraph()
        let audio = graph.add(.audio)
        let feedback = graph.add(.feedback)
        let filters = graph.add(.filters)
        let distortion = graph.add(.distortion)
        graph.connect(audio, to: feedback)
        graph.connect(feedback, to: filters)
        graph.connect(filters, to: distortion)
        var project = graph.project
        #expect(project.checkConnection(from: PinRef(node: distortion, pin: "out"), to: PinRef(node: feedback, pin: "return")) == nil)
        try project.connect(from: PinRef(node: distortion, pin: "out"), to: PinRef(node: feedback, pin: "return"))
        // Edits inside the loop aren't mistaken for cycles: a second path Filters → Distortion's
        // Page 2 pin is fine once ticked.
        project.setModulated("drive", of: distortion, true)
        #expect(project.checkConnection(from: PinRef(node: filters, pin: "out"), to: PinRef(node: distortion, pin: "mod.drive")) == nil)
        // A plain input can't close the loop.
        _ = audio
        let mixer = project.addNode(.mixer, at: CanvasPoint())
        try project.connect(from: PinRef(node: distortion, pin: "out"), to: PinRef(node: mixer, pin: "in1"))
        project.setModulated("q", of: filters, true)
        #expect(project.checkConnection(from: PinRef(node: mixer, pin: "out"), to: PinRef(node: filters, pin: "mod.q")) == .cycle)
    }

    @Test func previewLengthsCoverLoopNodes() {
        let (graph, feedback, filters, middle, _) = loop()
        let shapes = GraphCompiler.previewShapes(graph.project, assets: assets)
        for id in [feedback, filters, middle] { #expect(shapes[id]?.frames == 144_000) }
    }
}
