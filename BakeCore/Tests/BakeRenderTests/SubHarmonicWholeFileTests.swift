import Foundation
import Testing
@testable import BakeGraph
@testable import BakeRender

/// The Sub Harmonic's whole-file analysis: the sub lines up with the dry signal and starts on the onset. The default (causal)
/// is pinned by `SubHarmonicGoldenTests`.
@Suite(.serialized)
struct SubHarmonicWholeFileTests {
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
        var merged = NodeCatalog.defaultParameters(for: .subHarmonic)
        for (id, value) in parameters { merged[id] = value }
        let node = graph.add(.subHarmonic, merged)
        let print = graph.add(.print, ["bitDepth": .choice("32f")])
        graph.connect(audio, to: node)
        graph.connect(node, to: print)
        let urls = [sourceAsset: source]
        let request = RenderRequest(
            plan: try compile(graph.project, assetURLs: urls), assetURLs: urls, outputDirectory: output, chunkFrames: chunk
        )
        return try TestAudio.read(try #require(try await RenderEngine.render(request).outputs[print])).samples
    }

    private func sine(_ frequency: Double, _ frames: Int, from start: Int = 0) -> [Float] {
        (0..<frames).map { $0 < start ? 0 : Float(0.5 * sin(2 * Double.pi * frequency * Double($0) / 48_000)) }
    }

    private func risingCrossings(_ samples: [Float], in range: Range<Int>) -> [Int] {
        range.filter { $0 > 0 && samples[$0 - 1] <= 0 && samples[$0] > 0 }
    }

    private func meanDistance(from crossings: [Int], to references: [Int]) -> Double {
        guard !crossings.isEmpty, !references.isEmpty else { return .infinity }
        let total = crossings.map { c in references.map { abs($0 - c) }.min() ?? 0 }.reduce(0, +)
        return Double(total) / Double(crossings.count)
    }

    private static let subOnly: [String: ParameterValue] = ["sub1": .number(1), "sub2": .number(0), "dry": .number(0), "tone": .number(200)]

    @Test func identicalAtAnyChunkSize() async throws {
        let samples = TestAudio.samples(frames: 12_000, channels: 2)
        for analysis in ["causal", "wholeFile"] {
            var parameters = Self.subOnly
            parameters["analysis"] = .choice(analysis)
            parameters["sub2"] = .number(0.4)
            let reference = try await render(parameters, samples, workers: 1)
            #expect(reference.allSatisfy { $0.count == 12_000 && $0.allSatisfy { $0.isFinite } }, "\(analysis)")
            #expect(try await render(parameters, samples, workers: 4, chunk: 777) == reference, "\(analysis) chunk 777")
            #expect(try await render(parameters, samples, workers: 8) == reference, "\(analysis) workers 8")
        }
    }

    /// The sub's toggles happen at the input's zero crossings; only the whole-file analysis keeps them there.
    @Test func wholeFileSubLinesUpWithTheDrySignal() async throws {
        let input = sine(110, 24_000)
        let reference = risingCrossings(input, in: 6_000..<18_000)
        var causal = Self.subOnly
        causal["analysis"] = .choice("causal")
        var whole = Self.subOnly
        whole["analysis"] = .choice("wholeFile")
        let lagged = try await render(causal, [input])
        let aligned = try await render(whole, [input])
        let causalDistance = meanDistance(from: risingCrossings(lagged[0], in: 6_000..<18_000), to: reference)
        let wholeDistance = meanDistance(from: risingCrossings(aligned[0], in: 6_000..<18_000), to: reference)
        #expect(causalDistance > 20, "causal sub lags the input by \(causalDistance) frames")
        #expect(wholeDistance < 4, "whole-file sub is \(wholeDistance) frames from the input's crossings")
    }

    /// The sub is audible no later than with the causal analysis when a note starts.
    @Test func wholeFileSubStartsOnTheOnset() async throws {
        let input = sine(110, 24_000, from: 12_000)
        func firstAudible(_ output: [Float]) -> Int {
            output.firstIndex { abs($0) > 0.02 } ?? output.count
        }
        var causal = Self.subOnly
        causal["analysis"] = .choice("causal")
        var whole = Self.subOnly
        whole["analysis"] = .choice("wholeFile")
        let a = try await render(causal, [input])
        let b = try await render(whole, [input])
        #expect(firstAudible(b[0]) < firstAudible(a[0]), "whole file \(firstAudible(b[0])) vs causal \(firstAudible(a[0]))")
    }

    @Test func catalogOffersTheAnalysisSettingOffByDefault() throws {
        let definition = NodeCatalog.definition(for: .subHarmonic)
        let parameter = try #require(definition.parameters.first { $0.id == "analysis" })
        guard case .choice(let options, let fallback) = parameter.kind else {
            Issue.record("analysis should be a choice")
            return
        }
        #expect(options == ["causal", "wholeFile"] && fallback == "causal")
    }
}
