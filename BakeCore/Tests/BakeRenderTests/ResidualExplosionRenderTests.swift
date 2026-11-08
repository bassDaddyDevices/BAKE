import Foundation
import Testing
@testable import BakeGraph
@testable import BakeRender

struct ResidualExplosionRenderTests {
    /// Audio → Residual Explosion → Bake (32-bit float), in `chunk`-frame render chunks.
    private func render(
        _ samples: [[Float]], _ parameters: [ParameterID: ParameterValue] = [:], chunk: Int = 4_096
    ) async throws -> [[Float]] {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.wav")
        try TestAudio.write(samples, to: source, sampleRate: 48_000)
        let output = directory.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var graph = TestProject()
        let audio = graph.add(.audio, asset: sourceAsset)
        var values = NodeCatalog.defaultParameters(for: .residualExplosion)
        values.merge(parameters) { $1 }
        let node = graph.add(.residualExplosion, values)
        let print = graph.add(.print, ["bitDepth": .choice("32f")])
        graph.connect(audio, to: node)
        graph.connect(node, to: print)
        let urls = [sourceAsset: source]
        let request = RenderRequest(
            plan: try compile(graph.project, assetURLs: urls), assetURLs: urls, outputDirectory: output, chunkFrames: chunk
        )
        return try TestAudio.read(try #require(try await RenderEngine.render(request).outputs[print])).samples
    }

    @Test func audioResidualExplosionPrintKeepsLengthAndChannels() async throws {
        let samples = TestAudio.samples(frames: 48_000, channels: 2)
        let rendered = try await render(samples)
        #expect(rendered.count == 2)
        #expect(rendered.allSatisfy { $0.count == 48_000 })
        #expect(rendered.allSatisfy { $0.allSatisfy { $0.isFinite } })
        #expect(rendered[0] != samples[0])
    }

    @Test func rendersAreChunkInvariantAndRepeatable() async throws {
        let samples = TestAudio.samples(frames: 48_000, channels: 2)
        let parameters: [ParameterID: ParameterValue] = ["mode": .choice("sparsify"), "severity": .number(0.6), "body": .number(0)]
        let whole = try await render(samples, parameters)
        #expect(try await render(samples, parameters, chunk: 777) == whole)
        #expect(try await render(samples, parameters) == whole)
    }

    @Test func bodyOneAndNoGainPassesTheSource() async throws {
        let samples = TestAudio.samples(frames: 48_000, channels: 2)
        let parameters: [ParameterID: ParameterValue] = [
            "residualGain": .number(0), "body": .number(1), "mix": .number(1), "oversampling": .choice("1"),
        ]
        let rendered = try await render(samples, parameters)
        for channel in 0..<2 {
            #expect(zip(rendered[channel], samples[channel]).allSatisfy { abs($0 - $1) < 1e-5 })
        }
    }

    @Test func oversamplingChangesTheSound() async throws {
        let samples = TestAudio.samples(frames: 48_000, channels: 2)
        let plain = try await render(samples, ["oversampling": .choice("1")])
        let oversampled = try await render(samples, ["oversampling": .choice("8")])
        #expect(plain != oversampled)
        #expect(oversampled.allSatisfy { $0.count == 48_000 && $0.allSatisfy { $0.isFinite } })
        #expect(try await render(samples, ["oversampling": .choice("8")], chunk: 777) == oversampled)
    }
}
