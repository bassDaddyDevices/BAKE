import Foundation
import Testing
@testable import BakeGraph
@testable import BakeRender

/// M6 step 2: files and situations a real user hits. Each must bake correctly or fail with a clear
/// error before writing anything; none may crash.
struct EdgeCaseTests {

    private func render(_ graph: TestProject, assets: [AssetID: URL], into output: URL, chunk: Int = 65_536) async throws -> RenderResult {
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let plan = try compile(graph.project, assetURLs: assets)
        return try await RenderEngine.render(RenderRequest(plan: plan, assetURLs: assets, outputDirectory: output, chunkFrames: chunk))
    }

    /// Audio → Filters → Distortion → Stretch → Bake, the v1 chain.
    private func chain(asset: AssetID = sourceAsset) -> (TestProject, NodeID) {
        var graph = TestProject()
        let audio = graph.add(.audio, asset: asset)
        let filters = graph.add(.filters)
        let distortion = graph.add(.distortion)
        let stretch = graph.add(.stretch)
        let print = graph.add(.print, ["bitDepth": .choice("32f")])
        graph.connect(audio, to: filters)
        graph.connect(filters, to: distortion)
        graph.connect(distortion, to: stretch)
        graph.connect(stretch, to: print)
        return (graph, print)
    }

    @Test func anEmptyFileIsRefusedBeforeAnythingRenders() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("empty.wav")
        try TestAudio.write([[]], to: source, sampleRate: 48_000)
        #expect(try AssetInfoReader.info(for: source).frameCount == 0)
        let (graph, _) = chain()
        await #expect(throws: (any Error).self) {
            _ = try await render(graph, assets: [sourceAsset: source], into: directory.appendingPathComponent("out"))
        }
        let written = (try? FileManager.default.contentsOfDirectory(atPath: directory.appendingPathComponent("out").path)) ?? []
        #expect(written.isEmpty)
    }

    @Test(arguments: [1, 2, 7])
    func aFewSamplesBakeThroughTheWholeChain(frames: Int) async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("tiny.wav")
        try TestAudio.write(TestAudio.samples(frames: frames, channels: 2), to: source, sampleRate: 48_000)
        let (graph, print) = chain()
        let result = try await render(graph, assets: [sourceAsset: source], into: directory.appendingPathComponent("out"))
        let baked = try TestAudio.read(try #require(result.outputs[print]))
        #expect(baked.samples.count == 2)
        #expect(baked.samples.allSatisfy { $0.allSatisfy(\.isFinite) })
    }

    @Test func sixChannelsBakeThroughTheWholeChain() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("surround.wav")
        try TestAudio.write(TestAudio.samples(frames: 9_600, channels: 6), to: source, sampleRate: 48_000)
        let (graph, print) = chain()
        let result = try await render(graph, assets: [sourceAsset: source], into: directory.appendingPathComponent("out"), chunk: 777)
        let baked = try TestAudio.read(try #require(result.outputs[print]))
        #expect(baked.samples.count == 6)
        #expect(baked.samples.allSatisfy { channel in channel.contains { $0 != 0 } && channel.allSatisfy(\.isFinite) })
    }

    @Test func monoAndStereoAtDifferentRatesMixTogether() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let low = directory.appendingPathComponent("low.wav"), high = directory.appendingPathComponent("high.aiff")
        let second = AssetID(testUUID(90_001))
        try TestAudio.write(TestAudio.samples(frames: 2_205, channels: 1), to: low, sampleRate: 22_050)
        try TestAudio.write(TestAudio.samples(frames: 38_400, channels: 2), to: high, sampleRate: 192_000, bitDepth: 24, isFloat: false)
        var graph = TestProject()
        let a = graph.add(.audio, asset: sourceAsset)
        let b = graph.add(.audio, asset: second)
        let mixer = graph.add(.mixer)
        let encoder = graph.add(.midSideEncoder)
        let print = graph.add(.print, ["bitDepth": .choice("32f")])
        graph.connect(a, to: mixer, "in1")
        graph.connect(b, to: mixer, "in2")
        graph.connect(mixer, to: encoder)
        graph.project.edges.append(Edge(from: PinRef(node: encoder, pin: "mid"), to: PinRef(node: print, pin: "in")))
        let result = try await render(graph, assets: [sourceAsset: low, second: high], into: directory.appendingPathComponent("out"))
        let baked = try TestAudio.read(try #require(result.outputs[print]))
        // 0.1 s and 0.2 s at 48 kHz: the mix is as long as the longer.
        #expect(baked.samples[0].count == 9_600)
        #expect(baked.samples.allSatisfy { $0.allSatisfy(\.isFinite) })
    }

    @Test func aMonoSourceIntoMidSideIsSafe() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("mono.wav")
        try TestAudio.write(TestAudio.samples(frames: 4_800, channels: 1), to: source, sampleRate: 48_000)
        var graph = TestProject()
        let audio = graph.add(.audio, asset: sourceAsset)
        let encoder = graph.add(.midSideEncoder)
        let decoder = graph.add(.midSideDecoder)
        let print = graph.add(.print, ["bitDepth": .choice("32f")])
        graph.connect(audio, to: encoder)
        graph.project.edges.append(Edge(from: PinRef(node: encoder, pin: "mid"), to: PinRef(node: decoder, pin: "mid")))
        graph.project.edges.append(Edge(from: PinRef(node: encoder, pin: "side"), to: PinRef(node: decoder, pin: "side")))
        graph.connect(decoder, to: print)
        let result = try await render(graph, assets: [sourceAsset: source], into: directory.appendingPathComponent("out"))
        let baked = try TestAudio.read(try #require(result.outputs[print]))
        #expect(baked.samples.allSatisfy { $0.allSatisfy(\.isFinite) })
    }

    @Test func aFolderThatCantBeWrittenFailsClearlyAndLeavesNothing() async throws {
        let directory = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.appendingPathComponent("out").path)
            try? FileManager.default.removeItem(at: directory)
        }
        let source = directory.appendingPathComponent("source.wav")
        try TestAudio.write(TestAudio.samples(frames: 4_800, channels: 2), to: source, sampleRate: 48_000)
        let output = directory.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: output.path)
        let (graph, _) = chain()
        await #expect(throws: RenderError.self) {
            _ = try await render(graph, assets: [sourceAsset: source], into: output)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: output.path).isEmpty)
    }

    @Test func aSourceDeletedAfterCompilingFailsClearly() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.wav")
        try TestAudio.write(TestAudio.samples(frames: 4_800, channels: 2), to: source, sampleRate: 48_000)
        let (graph, _) = chain()
        let plan = try compile(graph.project, assetURLs: [sourceAsset: source])
        try FileManager.default.removeItem(at: source)
        let output = directory.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        await #expect(throws: RenderError.unreadableAsset(source)) {
            _ = try await RenderEngine.render(RenderRequest(plan: plan, assetURLs: [sourceAsset: source], outputDirectory: output))
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: output.path).isEmpty)
    }

    @Test func anEmptyFileSaysSoOnItsAudioNode() throws {
        var graph = TestProject()
        let audio = graph.add(.audio, asset: sourceAsset)
        let print = graph.add(.print)
        graph.connect(audio, to: print)
        do {
            _ = try GraphCompiler.compile(graph.project, assets: [sourceAsset: AssetInfo(frameCount: 0, channelCount: 2, sampleRate: 48_000)])
            Issue.record("an empty file compiled")
        } catch {
            #expect(GraphIssues(error, in: graph.project).nodes[audio] == ["This file has no audio in it, or its Start and End leave none."])
        }
    }

    /// Three and a half hours of stereo at 48 kHz: 4.8 billion bytes at 32-bit float (too big for a
    /// WAV), 3.6 billion at 24-bit (fits).
    @Test func aBakeTooBigForAWAVIsRefusedBeforeRendering() throws {
        let frames = 7 * 30 * 60 * 48_000
        func patch(_ bitDepth: String) -> (ProjectFile, NodeID) {
            var graph = TestProject()
            let audio = graph.add(.audio, asset: sourceAsset)
            let print = graph.add(.print, ["bitDepth": .choice(bitDepth)])
            graph.connect(audio, to: print)
            return (graph.project, print)
        }
        let assets = [sourceAsset: AssetInfo(frameCount: frames, channelCount: 2, sampleRate: 48_000)]
        let (big, bake) = patch("32f")
        do {
            _ = try GraphCompiler.compile(big, assets: assets)
            Issue.record("a 4 GB bake compiled")
        } catch {
            #expect(error.errors == [.outputTooLarge(bake, bytes: frames * 2 * 4)])
            #expect(GraphIssues(error, in: big).nodes[bake]?.first?.hasPrefix("This file would be 4.5 GB") == true)
        }
        #expect(throws: Never.self) { try GraphCompiler.compile(patch("24").0, assets: assets) }
        #expect(WAVLimit.bytes(frames: .max, channels: 2, bitDepth: nil) == .max)
    }
}
