import Darwin
import Foundation
import Testing
@testable import BakeGraph
@testable import BakeRender

/// NFR-3: a 10-minute 48 kHz stereo file bakes through the full v1 chain on a 16 GB Mac (it replaces
/// the older `tenMinuteBake`, adding the memory check). Slow (it
/// renders ten minutes of Stretch), so it runs only with `BAKE_LONG_TESTS=1 swift test --filter
/// LongBakeTests`; run it on its own, since peak memory is the whole process's.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["BAKE_LONG_TESTS"] != nil))
struct LongBakeTests {
    /// What BAKE may use on a 16 GB Mac: the engine's own budget, 75 % of memory.
    private static let budget = 16 * 1_073_741_824 * 3 / 4

    /// The PRD's v1 chain: Audio → Stretch → Filters (LFO on Cutoff) → Distortion → Bake.
    private func chain() -> (TestProject, NodeID) {
        var graph = TestProject()
        let audio = graph.add(.audio, asset: sourceAsset)
        let stretch = graph.add(.stretch, ["ratio": .number(1)])
        let lfo = graph.add(.lfo, ["rate": .number(0.5)])
        let filters = graph.add(.filters, ["cutoff": .number(1_200)], modulated: ["cutoff"])
        let distortion = graph.add(.distortion)
        let print = graph.add(.print, ["bitDepth": .choice("24")])
        graph.connect(audio, to: stretch)
        graph.connect(stretch, to: filters)
        graph.connect(lfo, to: filters, "mod.cutoff")
        graph.connect(filters, to: distortion)
        graph.connect(distortion, to: print)
        return (graph, print)
    }

    private static func peakResidentBytes() -> Int {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Int(usage.ru_maxrss)  // bytes on macOS
    }

    @Test func tenMinutesOfStereoBakeThroughTheV1ChainWithin16GB() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let frames = 10 * 60 * 48_000
        let source = directory.appendingPathComponent("ten-minutes.wav")
        try TestAudio.write(TestAudio.samples(frames: frames, channels: 2), to: source, sampleRate: 48_000, bitDepth: 24, isFloat: false)
        let output = directory.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        let (graph, bake) = chain()
        let urls = [sourceAsset: source]
        let plan = try compile(graph.project, assetURLs: urls)
        #expect(plan.peakMemoryBytes < Self.budget)

        let start = Date()
        let result = try await RenderEngine.render(RenderRequest(plan: plan, assetURLs: urls, outputDirectory: output))
        let seconds = Date().timeIntervalSince(start)
        let baked = try #require(result.outputs[bake])
        let info = try AssetInfoReader.info(for: baked)
        #expect(info.frameCount == frames && info.channelCount == 2)

        let resident = Self.peakResidentBytes()
        #expect(resident < Self.budget)
        let gigabytes = { (bytes: Int) in (Double(bytes) / 1_073_741_824).formatted(.number.precision(.fractionLength(2))) }
        print("NFR-3: planned \(gigabytes(plan.peakMemoryBytes)) GB, peak resident \(gigabytes(resident)) GB, "
              + "rendered 10 min in \(seconds.formatted(.number.precision(.fractionLength(1)))) s "
              + "(\((600 / seconds).formatted(.number.precision(.fractionLength(1))))× real time)")
    }

    /// How fast the heaviest nodes render, for the performance pass: 30 s of stereo through each.
    /// Reports times only; the floor is real time, so a bake never takes longer than its audio.
    @Test(arguments: [
        ("stretch", NodeKind.stretch, [ParameterID: ParameterValue]()),
        ("stretch 4×", .stretch, ["ratio": .number(4)]),
        ("filters linear phase", .filters, ["phase": .choice("linear")]),
        ("distortion 8× oversampled", .distortion, ["oversampling": .choice("8")]),
        ("granular cloud", .granularCloud, [:]),
        ("spectral resynthesis", .spectralResynthesis, [:]),
        ("vocoder", .vocoder, [:]),
        ("fractal filter", .fractalFilter, [:]),
        ("temporal shatter", .temporalShatter, [:]),
        ("half time granular", .halfTime, ["mode": .choice("granular")]),
        ("wavetable factory", .wavetableFactory, [:]),
        ("chorus", .chorus, [:]),
    ])
    func heavyNodesRenderFasterThanRealTime(name: String, kind: NodeKind, parameters: [ParameterID: ParameterValue]) async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let seconds = 30
        let source = directory.appendingPathComponent("source.wav")
        try TestAudio.write(TestAudio.samples(frames: seconds * 48_000, channels: 2), to: source, sampleRate: 48_000)
        let output = directory.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        var graph = TestProject()
        let audio = graph.add(.audio, asset: sourceAsset)
        let node = graph.add(kind, parameters)
        let bake = graph.add(.print, ["bitDepth": .choice("32f")])
        for pin in NodeCatalog.pins(of: graph.project.node(node)!) where pin.direction == .input && pin.signal == .audio {
            graph.project.edges.append(Edge(from: PinRef(node: audio, pin: "out"), to: PinRef(node: node, pin: pin.id)))
        }
        let outPin = NodeCatalog.pins(of: graph.project.node(node)!).first { $0.direction == .output }?.id ?? "out"
        graph.project.edges.append(Edge(from: PinRef(node: node, pin: outPin), to: PinRef(node: bake, pin: "in")))
        let urls = [sourceAsset: source]
        let plan = try compile(graph.project, assetURLs: urls)
        let start = Date()
        _ = try await RenderEngine.render(RenderRequest(plan: plan, assetURLs: urls, outputDirectory: output))
        let elapsed = Date().timeIntervalSince(start)
        let speed = Double(seconds) / elapsed
        print("speed: \(name): \(speed.formatted(.number.precision(.fractionLength(1))))× real time (\(elapsed.formatted(.number.precision(.fractionLength(2)))) s)")
        #expect(speed > 1, "\(name) renders slower than real time")
    }
}
