import Foundation
import Testing
@testable import BakeGraph
@testable import BakeRender

struct StretchRenderTests {
    /// Audio → Stretch → Filters (LFO on cutoff) → Distortion → Resonator → Print: every v1 node.
    private func fullChain(asset: AssetID) throws -> (project: ProjectFile, print: NodeID) {
        var graph = TestProject()
        let audio = graph.add(.audio, asset: asset)
        let lfo = graph.add(.lfo)
        let stretch = graph.add(.stretch, ["ratio": .number(1.5), "pitchSemitones": .number(-3)])
        let filters = graph.add(.filters)
        let distortion = graph.add(.distortion)
        let resonator = graph.add(.resonator)
        let print = graph.add(.print, ["bitDepth": .choice("24")])
        let index = try #require(graph.project.nodes.firstIndex { $0.id == filters })
        graph.project.nodes[index].setModulated("cutoff", true)
        graph.connect(audio, to: stretch)
        graph.connect(stretch, to: filters)
        graph.connect(lfo, to: filters, "mod.cutoff")
        graph.connect(filters, to: distortion)
        graph.connect(distortion, to: resonator)
        graph.connect(resonator, to: print)
        return (graph.project, print)
    }

    @Test func stretchRendersAtTheRequestedRatio() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.wav")
        try TestAudio.write(TestAudio.samples(frames: 24_000, channels: 2), to: source, sampleRate: 48_000)
        let output = directory.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        var graph = TestProject()
        let audio = graph.add(.audio, asset: sourceAsset)
        let stretch = graph.add(.stretch, ["ratio": .number(2.5), "pitchSemitones": .number(-5)])
        let print = graph.add(.print, ["bitDepth": .choice("32f")])
        graph.connect(audio, to: stretch)
        graph.connect(stretch, to: print)
        let urls = [sourceAsset: source]
        let request = RenderRequest(plan: try compile(graph.project, assetURLs: urls), assetURLs: urls, outputDirectory: output, chunkFrames: 5_000)

        let written = try #require(try await RenderEngine.render(request).outputs[print])

        let decoded = try TestAudio.read(written)
        #expect(decoded.samples.count == 2)
        #expect(decoded.samples[0].count == 60_000)
        #expect(decoded.samples.allSatisfy { channel in channel.allSatisfy { $0.isFinite } })
        #expect(TestAudio.rms(decoded.samples[0]) > 0.01)
    }

    @Test func everyV1NodeRendersTogether() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.wav")
        try TestAudio.write(TestAudio.samples(frames: 12_000, channels: 2), to: source, sampleRate: 48_000)
        let output = directory.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let (project, print) = try fullChain(asset: sourceAsset)
        let urls = [sourceAsset: source]
        let request = RenderRequest(plan: try compile(project, assetURLs: urls), assetURLs: urls, outputDirectory: output)

        let written = try #require(try await RenderEngine.render(request).outputs[print])

        let decoded = try TestAudio.read(written)
        #expect(decoded.samples[0].count == 18_000)
        #expect(decoded.samples.allSatisfy { channel in channel.allSatisfy { $0.isFinite } })
        #expect(TestAudio.rms(decoded.samples[0]) > 1e-3)
    }

    /// PRD NFR-3: the full v1 chain on 10 minutes of 48 kHz stereo must fit a 16 GB machine.
    @Test func fullV1ChainFitsTheMemoryBudget() throws {
        let asset = AssetID(testUUID(77))
        let tenMinutes = AssetInfo(frameCount: 48_000 * 600, channelCount: 2, sampleRate: 48_000)
        let (project, _) = try fullChain(asset: asset)

        let plan = try GraphCompiler.compile(project, assets: [asset: tenMinutes])

        // Pool buffers plus the Audio node's decoded source and cropped-region copies.
        let sourceCopies = 2 * 48_000 * 600 * 2 * MemoryLayout<Float>.size
        #expect(plan.peakMemoryBytes + sourceCopies < 4 * 1_024 * 1_024 * 1_024)
    }
}
