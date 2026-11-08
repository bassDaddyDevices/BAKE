import Foundation
import Testing
@testable import BakeGraph
@testable import BakeRender

/// Adaptive Clipping's lookahead ceiling: stateless clipping that runs across frame ranges. Output must be identical at any core
/// count and chunk size; the default (no lookahead) is pinned by `AdaptiveClippingGoldenTests`.
@Suite(.serialized)
struct AdaptiveClippingLookaheadTests {
    private func render(
        _ parameters: [String: ParameterValue], _ samples: [[Float]], workers: Int? = nil, chunk: Int = 65_536
    ) async throws -> [[Float]] {
        await CoreCountGate.shared.acquire()
        Parallel.overrideCoreCount(workers)
        defer {
            Parallel.overrideCoreCount(nil)
            CoreCountGate.shared.releaseSoon()
        }
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.wav")
        try TestAudio.write(samples, to: source, sampleRate: 48_000)
        let output = directory.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var graph = TestProject()
        let audio = graph.add(.audio, asset: sourceAsset)
        var merged = NodeCatalog.defaultParameters(for: .adaptiveClipping)
        for (id, value) in parameters { merged[id] = value }
        let node = graph.add(.adaptiveClipping, merged)
        let print = graph.add(.print, ["bitDepth": .choice("32f")])
        graph.connect(audio, to: node)
        graph.connect(node, to: print)
        let urls = [sourceAsset: source]
        let request = RenderRequest(
            plan: try compile(graph.project, assetURLs: urls), assetURLs: urls, outputDirectory: output, chunkFrames: chunk
        )
        return try TestAudio.read(try #require(try await RenderEngine.render(request).outputs[print])).samples
    }

    private func burst(frames: Int, at start: Int) -> [Float] {
        (0..<frames).map { n in
            let t = Double(n) / 48_000
            let bed = 0.05 * sin(2 * Double.pi * 440 * t)
            let hit = n >= start ? 0.9 * sin(2 * Double.pi * 1_000 * t) : 0
            return Float(bed + hit)
        }
    }

    @Test func identicalAtAnyCoreCountAndChunkSize() async throws {
        let stereo = TestAudio.samples(frames: 12_000, channels: 2)
        let mono = TestAudio.samples(frames: 9_000, channels: 1)
        let configs: [[String: ParameterValue]] = [
            ["lookahead": .number(10)],
            ["lookahead": .number(40), "oversampling": .choice("1"), "knee": .choice("hard")],
            ["lookahead": .number(5), "oversampling": .choice("16"), "mix": .number(0.6), "makeup": .number(3)],
        ]
        for (index, parameters) in configs.enumerated() {
            for samples in [stereo, mono] {
                let reference = try await render(parameters, samples, workers: 1)
                #expect(reference.allSatisfy { $0.allSatisfy { $0.isFinite } }, "config \(index)")
                for workers in [2, 8] {
                    #expect(try await render(parameters, samples, workers: workers) == reference, "config \(index) workers \(workers)")
                }
                #expect(try await render(parameters, samples, workers: 4, chunk: 777) == reference, "config \(index) chunk 777")
            }
        }
    }

    /// The causal ceiling is still low when a loud hit starts, so it clamps the first frames; with lookahead it has already risen.
    @Test func lookaheadKeepsTheOnsetOfAHit() async throws {
        let input = burst(frames: 24_000, at: 12_000)
        let base: [String: ParameterValue] = ["knee": .choice("hard"), "oversampling": .choice("1"), "threshold": .number(-6)]
        var ahead = base
        ahead["lookahead"] = .number(10)
        let causal = try await render(base, [input])
        let anticipated = try await render(ahead, [input])
        func energy(_ output: [Float]) -> Float { output[12_000..<12_048].reduce(0) { $0 + abs($1) } }
        #expect(energy(anticipated[0]) > energy(causal[0]) * 1.5, "lookahead \(energy(anticipated[0])) vs causal \(energy(causal[0]))")
    }

    @Test func catalogOffersLookaheadOffByDefault() throws {
        let definition = NodeCatalog.definition(for: .adaptiveClipping)
        #expect(definition.parameters.contains { $0.id == "lookahead" })
        #expect(NodeCatalog.defaultParameters(for: .adaptiveClipping)["lookahead"] == .number(0))
    }
}
