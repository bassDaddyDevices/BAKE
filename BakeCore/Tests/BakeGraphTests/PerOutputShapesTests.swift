import Testing
@testable import BakeGraph

struct PerOutputShapesTests {
    private let oneSecondMono = AssetID(testUUID(9_001))
    private let twoSecondsStereo = AssetID(testUUID(9_002))

    private var assets: [AssetID: AssetInfo] {
        [
            testAsset: AssetInfo(frameCount: 48_000, channelCount: 2, sampleRate: 48_000),
            oneSecondMono: AssetInfo(frameCount: 48_000, channelCount: 1, sampleRate: 48_000),
            twoSecondsStereo: AssetInfo(frameCount: 96_000, channelCount: 2, sampleRate: 48_000),
        ]
    }

    private func resolve(_ graph: TestGraph) -> (shapes: [NodeID: SignalShape], outputShapes: [PinRef: SignalShape], errors: [CompileError]) {
        SignalResolver.resolve(order: Scheduler.schedule(graph.project).order, project: graph.project, assets: assets)
    }

    @Test func splitterOutputsAreMono() {
        var graph = TestGraph()
        let audio = graph.add(.audio)
        let splitter = graph.add(.channelSplitter)
        let bake = graph.add(.print)
        graph.connect(audio, to: splitter)
        graph.connect(splitter, "out2", to: bake)

        let result = resolve(graph)

        #expect(result.errors.isEmpty)
        #expect(result.shapes[splitter] == SignalShape(frames: 48_000, channels: 2))
        #expect(result.outputShapes[PinRef(node: splitter, pin: "out1")] == SignalShape(frames: 48_000, channels: 1))
        #expect(result.outputShapes[PinRef(node: splitter, pin: "out2")] == SignalShape(frames: 48_000, channels: 1))
        #expect(result.shapes[bake] == SignalShape(frames: 48_000, channels: 1))
    }

    @Test func mixersTakeTheLongestAndWidestInput() {
        var graph = TestGraph()
        let mono = graph.add(.audio, asset: oneSecondMono)
        let stereo = graph.add(.audio, asset: twoSecondsStereo)
        let mixer = graph.add(.mixer)
        let bake = graph.add(.print)
        graph.connect(mono, to: mixer, "in1")
        graph.connect(stereo, to: mixer, "in2")
        graph.connect(mixer, to: bake)

        let result = resolve(graph)

        #expect(result.errors.isEmpty)
        #expect(result.shapes[mixer] == SignalShape(frames: 96_000, channels: 2))
    }

    @Test func mergersTakeTheirChannelsFromTheSetting() {
        var graph = TestGraph()
        let mono = graph.add(.audio, asset: oneSecondMono)
        let longer = graph.add(.audio, asset: twoSecondsStereo)
        let merger = graph.add(.channelMerger, ["channels": .choice("4")])
        let bake = graph.add(.print)
        graph.connect(mono, to: merger, "in1")
        graph.connect(longer, to: merger, "in3")
        graph.connect(merger, to: bake)

        #expect(resolve(graph).shapes[merger] == SignalShape(frames: 96_000, channels: 4))
    }

    @Test func aMixerWithNothingWiredNeedsAnInput() {
        var graph = TestGraph()
        let mixer = graph.add(.mixer)
        let bake = graph.add(.print)
        graph.connect(mixer, to: bake)

        #expect(Scheduler.schedule(graph.project).errors == [.missingInput(PinRef(node: mixer, pin: "in1"))])
    }

    @Test func buffersAreSizedPerOutput() throws {
        var graph = TestGraph()
        let audio = graph.add(.audio)
        let splitter = graph.add(.channelSplitter)
        let left = graph.add(.print)
        let right = graph.add(.print)
        graph.connect(audio, to: splitter)
        graph.connect(splitter, "out1", to: left)
        graph.connect(splitter, "out2", to: right)

        let plan = try GraphCompiler.compile(graph.project, assets: assets)

        let step = try #require(plan.steps.first { $0.node == splitter })
        #expect(step.outputs["out1"]?.shape == SignalShape(frames: 48_000, channels: 1))
        #expect(step.outputs["out2"]?.shape == SignalShape(frames: 48_000, channels: 1))
        #expect(step.outputs["out1"]?.slot != step.outputs["out2"]?.slot)
    }

    @Test func existingNodesKeepTheirShapes() {
        var graph = TestGraph()
        let audio = graph.add(.audio)
        let stretch = graph.add(.stretch, ["ratio": .number(2)])
        let filters = graph.add(.filters)
        let bake = graph.add(.print)
        graph.connect(audio, to: stretch)
        graph.connect(stretch, to: filters)
        graph.connect(filters, to: bake)

        let result = resolve(graph)

        #expect(result.shapes[bake] == SignalShape(frames: 96_000, channels: 2))
        #expect(result.outputShapes[PinRef(node: stretch, pin: "out")] == SignalShape(frames: 96_000, channels: 2))
    }
}
