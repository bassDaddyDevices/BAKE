import Testing
@testable import BakeGraph

struct GraphCompilerTests {
    /// Audio → Filters → Distortion → Print.
    private func chain() -> (graph: TestGraph, audio: NodeID, filters: NodeID, distortion: NodeID, output: NodeID) {
        var graph = TestGraph()
        let audio = graph.add(.audio)
        let filters = graph.add(.filters)
        let distortion = graph.add(.distortion)
        let output = graph.add(.print)
        graph.connect(audio, to: filters)
        graph.connect(filters, to: distortion)
        graph.connect(distortion, to: output)
        return (graph, audio, filters, distortion, output)
    }

    @Test func chainNeedsOnlyTwoBuffers() throws {
        let (graph, audio, filters, distortion, output) = chain()
        let plan = try GraphCompiler.compile(graph.project, assets: oneSecondStereo)
        #expect(plan.steps.map(\.node) == [audio, filters, distortion, output])
        #expect(plan.bufferCapacities == [96_000, 96_000])
        #expect(plan.peakMemoryBytes == 2 * 96_000 * MemoryLayout<Float>.size)
        // Ping-pong: each step reads one buffer and writes the other.
        #expect(plan.steps[1].inputs["in"]?.slot == 0)
        #expect(plan.steps[1].outputs["out"]?.slot == 1)
        #expect(plan.steps[2].outputs["out"]?.slot == 0)
        #expect(plan.steps[3].inputs["in"]?.slot == 0)
        #expect(plan.steps[3].outputs.isEmpty)
    }

    @Test func fannedOutBuffersStayAliveUntilTheirLastReader() throws {
        var graph = TestGraph()
        let audio = graph.add(.audio)
        let filters = graph.add(.filters)
        let distortion = graph.add(.distortion)
        let printA = graph.add(.print)
        let printB = graph.add(.print)
        graph.connect(audio, to: filters)
        graph.connect(audio, to: distortion)
        graph.connect(filters, to: printA)
        graph.connect(distortion, to: printB)
        let plan = try GraphCompiler.compile(graph.project, assets: oneSecondStereo)
        let audioSlot = try #require(plan.steps.first { $0.node == audio }?.outputs["out"]?.slot)
        let distortionStep = try #require(plan.steps.first { $0.node == distortion })
        #expect(distortionStep.inputs["in"]?.slot == audioSlot)
        #expect(distortionStep.outputs["out"]?.slot != audioSlot)
        #expect(plan.bufferCapacities.count == 3)
    }

    @Test func aStepNeverReadsAndWritesTheSameBuffer() throws {
        var graph = TestGraph()
        let audio = graph.add(.audio)
        let lfo = graph.add(.lfo)
        let stretch = graph.add(.stretch, ["ratio": .number(0.5)], modulated: ["pitchSemitones"])
        let filters = graph.add(.filters, modulated: ["cutoff"])
        let output = graph.add(.print)
        graph.connect(audio, to: stretch)
        graph.connect(lfo, to: stretch, "mod.pitchSemitones")
        graph.connect(lfo, to: filters, "mod.cutoff")
        graph.connect(stretch, to: filters)
        graph.connect(filters, to: output)
        let plan = try GraphCompiler.compile(graph.project, assets: oneSecondStereo)
        for step in plan.steps {
            let read = Set(step.inputs.values.map(\.slot))
            let written = Set(step.outputs.values.map(\.slot))
            #expect(read.isDisjoint(with: written), "\(step.kind) step aliases a buffer")
        }
    }

    @Test func modulationInputsAreBoundToTheControlBuffer() throws {
        var graph = TestGraph()
        let audio = graph.add(.audio)
        let lfo = graph.add(.lfo)
        let filters = graph.add(.filters, modulated: ["cutoff"])
        let output = graph.add(.print)
        graph.connect(audio, to: filters)
        graph.connect(lfo, to: filters, "mod.cutoff")
        graph.connect(filters, to: output)
        let plan = try GraphCompiler.compile(graph.project, assets: oneSecondStereo)
        let step = try #require(plan.steps.first { $0.node == filters })
        #expect(step.inputs["mod.cutoff"]?.shape == SignalShape(frames: 48_000, channels: 1))
        #expect(step.parameters["cutoff"] == .number(1_000))
    }

    @Test func compilingIsDeterministic() throws {
        var graph = chain().graph
        let first = try GraphCompiler.compile(graph.project, assets: oneSecondStereo)
        #expect(try GraphCompiler.compile(graph.project, assets: oneSecondStereo) == first)
        graph.project.edges.reverse()
        #expect(try GraphCompiler.compile(graph.project, assets: oneSecondStereo) == first)
    }

    @Test func structuralErrorsStopCompilationFirst() {
        var graph = TestGraph()
        let lfo = graph.add(.lfo)
        let filters = graph.add(.filters)
        graph.connect(lfo, to: filters) // control into audio, and there's no Print node either
        let project = graph.project
        #expect(throws: CompileFailure(errors: [.typeMismatch(project.edges[0])])) {
            try GraphCompiler.compile(project)
        }
    }

    @Test func missingAssetsFailCompilation() {
        let (graph, audio, _, _, _) = chain()
        #expect(throws: CompileFailure(errors: [.unresolvableAsset(audio)])) {
            try GraphCompiler.compile(graph.project, assets: [:])
        }
    }

    @Test func stepsCarryAssetsAndSampleRate() throws {
        let (graph, audio, _, _, _) = chain()
        let plan = try GraphCompiler.compile(graph.project, assets: oneSecondStereo)
        #expect(plan.steps.first { $0.node == audio }?.assetID == testAsset)
        #expect(plan.sampleRate == 48_000)
    }

    @Test func stepsCarryClampedModulationTrims() throws {
        var graph = TestGraph()
        let audio = graph.add(.audio)
        let lfo = graph.add(.lfo)
        let filters = graph.add(.filters, modulated: ["cutoff", "q"])
        let output = graph.add(.print)
        graph.connect(audio, to: filters)
        graph.connect(lfo, to: filters, "mod.cutoff")
        graph.connect(filters, to: output)
        let index = try #require(graph.project.nodes.firstIndex { $0.id == filters })
        graph.project.nodes[index].setTrim(0.5, for: "cutoff")

        let plan = try GraphCompiler.compile(graph.project, assets: oneSecondStereo)

        let step = try #require(plan.steps.first { $0.node == filters })
        #expect(step.modulationTrims == ["cutoff": 0.5, "q": 1])
    }
}
