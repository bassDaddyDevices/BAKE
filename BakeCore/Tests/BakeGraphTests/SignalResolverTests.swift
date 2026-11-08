import Testing
@testable import BakeGraph

struct SignalResolverTests {
    private func resolve(
        _ graph: TestGraph, assets: [AssetID: AssetInfo] = oneSecondStereo
    ) -> (shapes: [NodeID: SignalShape], errors: [CompileError]) {
        let result = SignalResolver.resolve(order: Scheduler.schedule(graph.project).order, project: graph.project, assets: assets)
        return (result.shapes, result.errors)
    }

    @Test func aGeneratedLengthUsesTheChosenFrameSizeAndRoundedCount() {
        #expect(SignalResolver.generatedShape(frameSize: .choice("2048"), count: .number(3.6)) == SignalShape(frames: 8_192, channels: 1))
        #expect(SignalResolver.generatedShape(frameSize: .choice("256"), count: .number(2.4)) == SignalShape(frames: 512, channels: 1))
    }

    @Test func invalidGeneratedLengthsAreRejected() {
        for (frameSize, count): (ParameterValue?, ParameterValue?) in [
            (.choice("0"), .number(1)),
            (.choice("2048"), .number(0)),
            (.choice("2048"), .number(.nan)),
            (.choice("2048"), .number(.infinity)),
            (.text("2048"), .number(2)),
        ] {
            #expect(SignalResolver.generatedShape(frameSize: frameSize, count: count) == nil)
        }
        #expect(SignalResolver.generatedShape(frameSize: .choice("4096"), count: .number(Double(Int.max) - 4096)) == nil)
    }

    @Test func generatedNodesProduceMonoBuffersAtTheDeclaredLengths() throws {
        var graph = TestGraph()
        let single = graph.add(.singleCycle, ["frameSize": .choice("512"), "cycles": .number(4)])
        let input = graph.add(.audio)
        let factory = graph.add(.wavetableFactory, ["frameSize": .choice("256"), "slots": .number(9)])
        let print = graph.add(.print)
        graph.connect(single, to: factory, "in1")
        graph.connect(input, to: factory, "in2")
        graph.connect(factory, to: print)
        let plan = try GraphCompiler.compile(graph.project, assets: oneSecondStereo)
        #expect(plan.steps.first { $0.node == single }?.outputs["out"]?.shape == SignalShape(frames: 2_048, channels: 1))
        #expect(plan.steps.first { $0.node == factory }?.outputs["out"]?.shape == SignalShape(frames: 2_304, channels: 1))
    }

    @Test func audioSpansItsSourceFile() {
        var graph = TestGraph()
        let audio = graph.add(.audio)
        let output = graph.add(.print)
        graph.connect(audio, to: output)
        let result = resolve(graph)
        #expect(result.errors.isEmpty)
        #expect(result.shapes[audio] == SignalShape(frames: 48_000, channels: 2))
        #expect(result.shapes[output] == SignalShape(frames: 48_000, channels: 2))
    }

    @Test func sourcesAreConvertedToTheProjectRate() {
        var graph = TestGraph()
        let audio = graph.add(.audio)
        let output = graph.add(.print)
        graph.connect(audio, to: output)
        let cdQuality = [testAsset: AssetInfo(frameCount: 44_100, channelCount: 1, sampleRate: 44_100)]
        #expect(resolve(graph, assets: cdQuality).shapes[audio] == SignalShape(frames: 48_000, channels: 1))
    }

    @Test func cropAndLoopScaleTheLength() {
        var graph = TestGraph()
        let audio = graph.add(.audio, ["cropStart": .number(0.25), "cropEnd": .number(0.75), "loopCount": .number(2)])
        let output = graph.add(.print)
        graph.connect(audio, to: output)
        #expect(resolve(graph).shapes[audio] == SignalShape(frames: 48_000, channels: 2))
    }

    @Test func emptyCropIsInvalid() {
        var graph = TestGraph()
        let audio = graph.add(.audio, ["cropStart": .number(0.6), "cropEnd": .number(0.4)])
        let output = graph.add(.print)
        graph.connect(audio, to: output)
        #expect(resolve(graph).errors == [.invalidLength(audio)])
    }

    @Test func missingAssetIsReported() {
        var graph = TestGraph()
        let audio = graph.add(.audio)
        let output = graph.add(.print)
        graph.connect(audio, to: output)
        #expect(resolve(graph, assets: [:]).errors == [.unresolvableAsset(audio)])
    }

    @Test func stretchScalesLengthAndKeepsChannels() {
        var graph = TestGraph()
        let audio = graph.add(.audio)
        let stretch = graph.add(.stretch, ["ratio": .number(2.5)])
        let output = graph.add(.print)
        graph.connect(audio, to: stretch)
        graph.connect(stretch, to: output)
        let result = resolve(graph)
        #expect(result.shapes[stretch] == SignalShape(frames: 120_000, channels: 2))
        #expect(result.shapes[output] == SignalShape(frames: 120_000, channels: 2))
    }

    @Test func controlGeneratorsSpanTheirLongestConsumer() {
        var graph = TestGraph()
        let audio = graph.add(.audio)
        let lfo = graph.add(.lfo)
        let filters = graph.add(.filters, modulated: ["cutoff"])
        let stretch = graph.add(.stretch, ["ratio": .number(2)], modulated: ["pitchSemitones"])
        let output = graph.add(.print)
        graph.connect(audio, to: filters)
        graph.connect(filters, to: stretch)
        graph.connect(stretch, to: output)
        graph.connect(lfo, to: filters, "mod.cutoff")
        graph.connect(lfo, to: stretch, "mod.pitchSemitones")
        // Filters spans 48k frames, Stretch 96k; the LFO must cover the longer one, in mono.
        #expect(resolve(graph).shapes[lfo] == SignalShape(frames: 96_000, channels: 1))
    }
}
