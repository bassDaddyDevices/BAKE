import Foundation
import Testing
@testable import BakeGraph
@testable import BakeRender

/// Filters (biquad and linear-phase) and Tape Degrade carry per-channel state, so they split by channel;
/// the output must be identical on any number of cores and any chunking.
@Suite(.serialized)
struct ParallelFiltersTapeTests {
    fileprivate struct Case: CustomStringConvertible, Sendable {
        let name: String
        let kind: NodeKind
        let parameters: [String: ParameterValue]
        var description: String { name }
    }

    private static let cases = [
        Case(name: "filters/biquad", kind: .filters, parameters: ["cutoff": .number(900), "slope": .choice("48")]),
        Case(name: "filters/linearPhase", kind: .filters, parameters: [
            "phase": .choice("linear"), "firTaps": .choice("1025"), "cutoff": .number(900),
        ]),
        Case(name: "tapeDegrade/default", kind: .tapeDegrade, parameters: [:]),
        Case(name: "tapeDegrade/rough", kind: .tapeDegrade, parameters: [
            "wow": .number(0.8), "flutter": .number(0.6), "hiss": .number(0.3), "dropouts": .number(0.5), "seed": .number(9),
        ]),
    ]

    private func render(_ item: Case, _ samples: [[Float]], workers: Int, chunk: Int = 65_536) async throws -> [[Float]] {
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
        var parameters = NodeCatalog.defaultParameters(for: item.kind)
        for (id, value) in item.parameters { parameters[id] = value }
        let node = graph.add(item.kind, parameters)
        let print = graph.add(.print, ["bitDepth": .choice("32f")])
        graph.connect(audio, to: node)
        graph.connect(node, to: print)
        let urls = [sourceAsset: source]
        let request = RenderRequest(
            plan: try compile(graph.project, assetURLs: urls), assetURLs: urls, outputDirectory: output, chunkFrames: chunk
        )
        return try TestAudio.read(try #require(try await RenderEngine.render(request).outputs[print])).samples
    }

    @Test(arguments: cases)
    fileprivate func sameBitsOnAnyNumberOfCores(item: Case) async throws {
        let samples = TestAudio.samples(frames: 12_000, channels: 4)
        let one = try await render(item, samples, workers: 1)
        #expect(one.count == 4 && one.allSatisfy { $0.count == 12_000 && $0.allSatisfy { $0.isFinite } })
        #expect(one[0] != samples[0])
        #expect(try await render(item, samples, workers: 2) == one)
        #expect(try await render(item, samples, workers: 8) == one)
        #expect(try await render(item, samples, workers: 8, chunk: 777) == one)
    }
}
