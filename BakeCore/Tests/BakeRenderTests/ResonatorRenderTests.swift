import Foundation
import Testing
@testable import BakeGraph
@testable import BakeRender

struct ResonatorRenderTests {
    /// A 2,000-frame noise burst followed by silence: 24,000 frames of mono at 48 kHz.
    private func burstSource(in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent("burst.wav")
        var samples = TestAudio.samples(frames: 24_000, channels: 1)
        for frame in 2_000..<24_000 { samples[0][frame] = 0 }
        try TestAudio.write(samples, to: url, sampleRate: 48_000)
        return url
    }

    private func request(in directory: URL, output folder: String) throws -> (RenderRequest, NodeID) {
        let source = try burstSource(in: directory)
        let output = directory.appendingPathComponent(folder, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var graph = TestProject()
        let audio = graph.add(.audio, asset: sourceAsset)
        let resonator = graph.add(.resonator, ["root": .number(220), "decay": .number(1)])
        let print = graph.add(.print, ["bitDepth": .choice("32f")])
        graph.connect(audio, to: resonator)
        graph.connect(resonator, to: print)
        let urls = [sourceAsset: source]
        return (RenderRequest(plan: try compile(graph.project, assetURLs: urls), assetURLs: urls, outputDirectory: output, chunkFrames: 3_000), print)
    }

    @Test func resonatorRingsAfterTheInputStops() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (request, print) = try request(in: directory, output: "out")

        let written = try #require(try await RenderEngine.render(request).outputs[print])

        let output = try TestAudio.read(written).samples[0]
        #expect(output.count == 24_000)
        #expect(output.allSatisfy { $0.isFinite })
        // The source is silent after frame 2,000; anything here is the Resonator ringing on the GPU.
        #expect(TestAudio.rms(Array(output[12_000...])) > 1e-4)
    }

    @Test func resonatorRendersAreByteIdentical() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (first, print) = try request(in: directory, output: "a")
        var second = first
        second.outputDirectory = directory.appendingPathComponent("b", isDirectory: true)
        try FileManager.default.createDirectory(at: second.outputDirectory, withIntermediateDirectories: true)

        let a = try #require(try await RenderEngine.render(first).outputs[print])
        let b = try #require(try await RenderEngine.render(second).outputs[print])

        #expect(try Data(contentsOf: a) == Data(contentsOf: b))
    }
}
