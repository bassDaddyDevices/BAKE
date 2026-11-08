import Foundation
import Testing
@testable import BakeGraph
@testable import BakeRender

struct ChainRenderTests {
    /// Audio → Filters (LFO on cutoff) → Resonator (Metal) → Distortion → Print, stereo.
    private func chainRequest(in directory: URL, output folder: String, chunkFrames: Int) throws -> (RenderRequest, NodeID) {
        let source = directory.appendingPathComponent("source.wav")
        if !FileManager.default.fileExists(atPath: source.path) {
            try TestAudio.write(TestAudio.samples(frames: 24_000, channels: 2), to: source, sampleRate: 48_000)
        }
        let output = directory.appendingPathComponent(folder, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        var graph = TestProject()
        let audio = graph.add(.audio, asset: sourceAsset)
        let lfo = graph.add(.lfo, ["rate": .number(3), "shape": .choice("triangle")])
        let filters = graph.add(.filters, ["cutoff": .number(800), "slope": .choice("24")])
        let resonator = graph.add(.resonator, ["root": .number(110), "decay": .number(0.5)])
        let distortion = graph.add(.distortion, ["drive": .number(12), "oversampling": .choice("4")])
        let print = graph.add(.print, ["bitDepth": .choice("32f")])
        let index = try #require(graph.project.nodes.firstIndex { $0.id == filters })
        graph.project.nodes[index].setModulated("cutoff", true)
        graph.project.nodes[index].setTrim(0.3, for: "cutoff")
        graph.connect(audio, to: filters)
        graph.connect(lfo, to: filters, "mod.cutoff")
        graph.connect(filters, to: resonator)
        graph.connect(resonator, to: distortion)
        graph.connect(distortion, to: print)
        let urls = [sourceAsset: source]
        return (RenderRequest(plan: try compile(graph.project, assetURLs: urls), assetURLs: urls, outputDirectory: output, chunkFrames: chunkFrames), print)
    }

    @Test func cpuAndGpuNodesRenderTogether() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (request, print) = try chainRequest(in: directory, output: "out", chunkFrames: 4_096)

        let written = try #require(try await RenderEngine.render(request).outputs[print])

        let decoded = try TestAudio.read(written)
        #expect(decoded.samples.count == 2)
        #expect(decoded.samples[0].count == 24_000)
        #expect(decoded.samples.allSatisfy { channel in channel.allSatisfy { $0.isFinite } })
        #expect(TestAudio.rms(decoded.samples[0]) > 1e-3)
    }

    @Test func chunkSizeNeverChangesTheResult() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (small, print) = try chainRequest(in: directory, output: "small", chunkFrames: 777)
        let (large, _) = try chainRequest(in: directory, output: "large", chunkFrames: 65_536)

        let a = try #require(try await RenderEngine.render(small).outputs[print])
        let b = try #require(try await RenderEngine.render(large).outputs[print])

        #expect(try Data(contentsOf: a) == Data(contentsOf: b))
    }

    @Test func audioGainFollowsModulation() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("dc.wav")
        try TestAudio.write([[Float](repeating: 0.5, count: 4_800)], to: source, sampleRate: 48_000)
        let output = directory.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        var graph = TestProject()
        let audio = graph.add(.audio, asset: sourceAsset)
        let lfo = graph.add(.lfo, ["shape": .choice("square"), "rate": .number(10)])
        let print = graph.add(.print, ["bitDepth": .choice("32f")])
        let index = try #require(graph.project.nodes.firstIndex { $0.id == audio })
        graph.project.nodes[index].setModulated("gain", true)
        graph.connect(lfo, to: audio, "mod.gain")
        graph.connect(audio, to: print)
        let urls = [sourceAsset: source]
        let request = RenderRequest(plan: try compile(graph.project, assetURLs: urls), assetURLs: urls, outputDirectory: output)

        let written = try #require(try await RenderEngine.render(request).outputs[print])

        // Square LFO at +1 pushes gain to +24 dB (clamped max); at −1 down to −60 dB.
        let samples = try TestAudio.read(written).samples[0]
        #expect(samples[100] > 1)
        #expect(samples[2_500] < 0.01)
    }
}
