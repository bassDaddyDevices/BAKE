import Foundation
import Testing
@testable import BakeGraph
@testable import BakeRender

/// The Chorus swarm: more than 8 voices and/or Reach. Frames are independent, so the output must be identical at any
/// core count and chunk size; and the classic path must still be untouched at the defaults (`ChorusGoldenTests`).
@Suite(.serialized)
struct ChorusSwarmTests {
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
        var merged = NodeCatalog.defaultParameters(for: .chorus)
        for (id, value) in parameters { merged[id] = value }
        let node = graph.add(.chorus, merged)
        let print = graph.add(.print, ["bitDepth": .choice("32f")])
        graph.connect(audio, to: node)
        graph.connect(node, to: print)
        let urls = [sourceAsset: source]
        let request = RenderRequest(
            plan: try compile(graph.project, assetURLs: urls), assetURLs: urls, outputDirectory: output, chunkFrames: chunk
        )
        return try TestAudio.read(try #require(try await RenderEngine.render(request).outputs[print])).samples
    }

    private static let configs: [(String, [String: ParameterValue])] = [
        ("voices16", ["voices": .choice("16")]),
        ("voices128reach", ["voices": .choice("128"), "reach": .number(400), "spread": .number(1)]),
        ("voices1024", ["voices": .choice("1024"), "reach": .number(5_000), "spread": .number(1), "mix": .number(1)]),
        ("reachOnly", ["reach": .number(250), "panSpread": .number(1)]),
    ]

    @Test func identicalAtAnyCoreCountAndChunkSize() async throws {
        let samples = TestAudio.samples(frames: 12_000, channels: 2)
        for (name, parameters) in Self.configs {
            let reference = try await render(parameters, samples, workers: 1)
            #expect(reference.allSatisfy { $0.count == 12_000 && $0.allSatisfy { $0.isFinite } }, "\(name)")
            for workers in [2, 8] {
                #expect(try await render(parameters, samples, workers: workers) == reference, "\(name) workers \(workers)")
            }
            #expect(try await render(parameters, samples, workers: 4, chunk: 777) == reference, "\(name) chunk 777")
        }
    }

    @Test func reachChangesTheSound() async throws {
        let samples = TestAudio.samples(frames: 12_000, channels: 2)
        let plain = try await render(["voices": .choice("16")], samples)
        let reached = try await render(["voices": .choice("16"), "reach": .number(300), "spread": .number(1)], samples)
        #expect(plain != reached)
    }

    /// With Reach the swarm reads the input's future: an impulse late in the file reaches output frames before it.
    @Test func negativeDelaysReadTheFuture() async throws {
        var channel = [Float](repeating: 0, count: 24_000)
        channel[20_000] = 1
        let output = try await render(
            ["voices": .choice("64"), "reach": .number(500), "spread": .number(1), "mix": .number(1), "detune": .number(0)],
            [channel, channel]
        )
        let early = output[0][..<19_990].contains { abs($0) > 1e-6 }
        #expect(early, "some voices should sound before the impulse")
    }

    @Test func silenceOutsideTheFileAndNoRunaway() async throws {
        let samples = TestAudio.samples(frames: 6_000, channels: 1)
        let output = try await render(["voices": .choice("32"), "reach": .number(5_000), "spread": .number(1)], samples)
        #expect(output[0].count == 6_000)
        #expect(output[0].allSatisfy { $0.isFinite && abs($0) < 4 })
    }

    @Test func catalogOffersTheSwarm() throws {
        let definition = NodeCatalog.definition(for: .chorus)
        let voices = try #require(definition.parameters.first { $0.id == "voices" })
        guard case .choice(let options, let fallback) = voices.kind else {
            Issue.record("voices should be a choice")
            return
        }
        #expect(options.last == "1024" && fallback == "4")
        #expect(NodeCatalog.defaultParameters(for: .chorus)["reach"] == .number(0))
    }
}
