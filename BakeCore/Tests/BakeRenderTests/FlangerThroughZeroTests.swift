import BakeDSP
import Foundation
import Testing
@testable import BakeGraph
@testable import BakeRender

/// The through-zero read head and Dispersion. What saved Flangers sound like is pinned in `FlangerGoldenTests`.
@Suite(.serialized)
struct FlangerThroughZeroTests {
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
        var merged = NodeCatalog.defaultParameters(for: .flanger)
        for (id, value) in parameters { merged[id] = value }
        let node = graph.add(.flanger, merged)
        let print = graph.add(.print, ["bitDepth": .choice("32f")])
        graph.connect(audio, to: node)
        graph.connect(node, to: print)
        let urls = [sourceAsset: source]
        let request = RenderRequest(
            plan: try compile(graph.project, assetURLs: urls), assetURLs: urls, outputDirectory: output, chunkFrames: chunk
        )
        return try TestAudio.read(try #require(try await RenderEngine.render(request).outputs[print])).samples
    }

    private func sine(_ hz: Double, frames: Int, channels: Int = 1) -> [[Float]] {
        (0..<channels).map { channel in
            (0..<frames).map { Float(0.5 * sin(2 * .pi * hz * Double($0) / 48_000 + Double(channel))) }
        }
    }

    private func rms(_ values: ArraySlice<Float>) -> Double {
        sqrt(values.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(max(values.count, 1)))
    }

    // MARK: Determinism

    @Test(arguments: [
        ["readHead": ParameterValue.choice("throughZero"), "depth": .number(1), "feedback": .number(0.6)],
        ["readHead": .choice("throughZero"), "dispersion": .number(0.4), "wetPolarity": .choice("negative"), "delay": .number(20)],
        ["readHead": .choice("causal"), "delay": .number(30), "feedback": .number(0.5)],
    ])
    func identicalOnAnyCoreCountAndChunking(parameters: [String: ParameterValue]) async throws {
        let samples = TestAudio.samples(frames: 12_000, channels: 4)
        let one = try await render(parameters, samples, workers: 1)
        #expect(one.count == 4 && one.allSatisfy { $0.count == 12_000 && $0.allSatisfy { $0.isFinite } })
        #expect(one[0] != samples[0])
        #expect(try await render(parameters, samples, workers: 8) == one)
        #expect(try await render(parameters, samples, workers: 8, chunk: 777) == one)
    }

    // MARK: Through-zero

    /// With the sweep off (depth 0) the wet head sits a fixed Delay behind the input: output = x(n) + x(n − Delay).
    @Test func aFixedHeadIsAPlainCombFilter() async throws {
        let input = TestAudio.samples(frames: 6_000, channels: 1)
        let output = try await render([
            "readHead": .choice("throughZero"), "depth": .number(0), "feedback": .number(0), "mix": .number(1), "delay": .number(4),
        ], input)[0]
        let delay = 192 // 4 ms at 48 kHz
        for n in delay..<input[0].count {
            #expect(abs(output[n] - (input[0][n] + input[0][n - delay])) < 2e-4, "frame \(n)")
        }
    }

    /// At depth 1 the head starts at zero distance, where a negative wet polarity cancels the dry signal.
    @Test func negativeWetPolarityNullsAtTheZeroCrossing() async throws {
        let input = sine(1_000, frames: 4_000)
        let parameters: [String: ParameterValue] = [
            "readHead": .choice("throughZero"), "depth": .number(1), "rate": .number(0.05), "feedback": .number(0),
            "mix": .number(1), "delay": .number(4),
        ]
        let nulled = try await render(parameters.merging(["wetPolarity": .choice("negative")]) { $1 }, input)[0]
        let doubled = try await render(parameters.merging(["wetPolarity": .choice("positive")]) { $1 }, input)[0]
        // The head drifts at 0.0006 samples per frame from zero, so stay near the start.
        let early = 20..<220
        #expect(rms(nulled[early]) < 0.05 * rms(input[0][early]), "\(rms(nulled[early]))")
        #expect(rms(doubled[early]) > 1.8 * rms(input[0][early]), "\(rms(doubled[early]))")
    }

    /// Through zero the head reads ahead of the input, so a click shows up in the wet signal before it arrives.
    @Test func theHeadReadsTheInputsFuture() async throws {
        var input = [Float](repeating: 0, count: 8_000)
        input[4_000] = 1
        // Depth 1, rate at its floor: the head sweeps from +Delay towards −Delay over the whole file's first seconds, so
        // early on it sits near zero and drifts ahead; a fixed ahead-read is easier to pin with the head near its start.
        let output = try await render([
            "readHead": .choice("throughZero"), "depth": .number(1), "rate": .number(5), "feedback": .number(0),
            "mix": .number(1), "delay": .number(10),
        ], [input])[0]
        // The LFO crosses a full sweep many times before frame 4,000, so the wet head leads the click for some of
        // the frames before it: energy before the click that a causal flanger can't produce.
        let before = output[3_000..<4_000].reduce(0.0) { $0 + Double(abs($1)) }
        #expect(before > 0.1, "\(before)")
        let causal = try await render([
            "readHead": .choice("causal"), "depth": .number(1), "rate": .number(5), "feedback": .number(0),
            "mix": .number(1), "delay": .number(10),
        ], [input])[0]
        #expect(causal[3_000..<4_000].allSatisfy { $0 == 0 })
    }

    // MARK: Dispersion

    @Test func dispersionIsAllPass() {
        let input = TestAudio.samples(frames: 40_000, channels: 1)[0]
        var output = [Float](repeating: 0, count: input.count)
        for sections in [1, 16, 64, 256] {
            input.withUnsafeBufferPointer { source in
                output.withUnsafeMutableBufferPointer { destination in
                    bake.dsp.renderFlangerDispersion(source.baseAddress!, input.count, destination.baseAddress!, Int32(sections))
                }
            }
            let ratio = rms(output[10_000..<30_000]) / rms(input[10_000..<30_000])
            #expect(abs(ratio - 1) < 0.02, "\(sections) sections: \(ratio)")
        }
    }

    @Test func dispersionDelaysDCByTheFormulaAndNyquistByMore() {
        #expect(bake.dsp.flangerDispersionDelay(0) == 0)
        let expected = 100.0 * (1 - 0.7) / (1 + 0.7)
        #expect(abs(bake.dsp.flangerDispersionDelay(100) - expected) < 1e-9)
        #expect(bake.dsp.flangerDispersionSections(0) == 0 && bake.dsp.flangerDispersionSections(1) == 256)
    }

    @Test func dispersionChangesTheSoundAndZeroLeavesItAlone() async throws {
        let samples = TestAudio.samples(frames: 12_000, channels: 1)
        let base: [String: ParameterValue] = ["readHead": .choice("throughZero")]
        let flat = try await render(base, samples)[0]
        let zero = try await render(base.merging(["dispersion": .number(0)]) { $1 }, samples)[0]
        let bent = try await render(base.merging(["dispersion": .number(0.5)]) { $1 }, samples)[0]
        #expect(flat == zero)
        #expect(bent != flat && bent.allSatisfy { $0.isFinite })
    }
}
