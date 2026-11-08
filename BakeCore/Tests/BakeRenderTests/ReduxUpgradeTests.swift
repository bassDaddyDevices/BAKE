import Foundation
import Testing
@testable import BakeGraph
@testable import BakeRender

/// The linear-phase anti-alias, noise-shaped dither, fractional bit depth and per-channel multicore of Redux.
/// What saved patches sound like is pinned separately in `ReduxGoldenTests`.
@Suite(.serialized)
struct ReduxUpgradeTests {
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
        var merged = NodeCatalog.defaultParameters(for: .redux)
        for (id, value) in parameters { merged[id] = value }
        let node = graph.add(.redux, merged)
        let print = graph.add(.print, ["bitDepth": .choice("32f")])
        graph.connect(audio, to: node)
        graph.connect(node, to: print)
        let urls = [sourceAsset: source]
        let request = RenderRequest(
            plan: try compile(graph.project, assetURLs: urls), assetURLs: urls, outputDirectory: output, chunkFrames: chunk
        )
        return try TestAudio.read(try #require(try await RenderEngine.render(request).outputs[print])).samples
    }

    private func sine(_ hz: Double, amplitude: Float, frames: Int, channels: Int = 1) -> [[Float]] {
        (0..<channels).map { channel in
            (0..<frames).map { Float(Double(amplitude) * sin(2 * .pi * hz * Double($0) / 48_000 + Double(channel))) }
        }
    }

    private func rms(_ values: ArraySlice<Float>) -> Double {
        sqrt(values.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(max(values.count, 1)))
    }

    // MARK: Determinism

    @Test(arguments: [
        ["reduxMode": ParameterValue.choice("downsampling"), "rateDivider": .number(8), "mode": .choice("linear")],
        ["reduxMode": .choice("classic"), "bitDepth": .number(3.5), "rateDivider": .number(3), "dither": .choice("shaped")],
        ["reduxMode": .choice("bitReduction"), "bitDepth": .number(5), "dither": .choice("shaped")],
    ])
    func identicalOnAnyCoreCountAndChunking(parameters: [String: ParameterValue]) async throws {
        let samples = TestAudio.samples(frames: 12_000, channels: 4)
        let one = try await render(parameters, samples, workers: 1)
        #expect(one.count == 4 && one.allSatisfy { $0.count == 12_000 && $0.allSatisfy { $0.isFinite } })
        #expect(one[0] != samples[0])
        #expect(try await render(parameters, samples, workers: 8) == one)
        #expect(try await render(parameters, samples, workers: 8, chunk: 777) == one)
    }

    // MARK: Noise-shaped dither

    /// Quantisation error energy in the low half of the spectrum against the high half, from the first
    /// sum and difference of neighbouring errors: about 1 for white noise, 0.2 for white noise shaped by (1 - z^-1)^2.
    private func lowToHighRatio(_ output: [Float], _ input: [Float]) -> Double {
        let error = zip(output, input).map { $0 - $1 }
        var low = 0.0, high = 0.0
        for n in 1..<error.count {
            low += Double((error[n] + error[n - 1]) * (error[n] + error[n - 1]))
            high += Double((error[n] - error[n - 1]) * (error[n] - error[n - 1]))
        }
        return low / high
    }

    @Test func shapedDitherPushesTheNoiseUp() async throws {
        let input = sine(220, amplitude: 0.5, frames: 20_000)
        let base: [String: ParameterValue] = ["reduxMode": .choice("bitReduction"), "bitDepth": .number(4)]
        let flat = try await render(base.merging(["dither": .choice("triangular")]) { $1 }, input)[0]
        let shaped = try await render(base.merging(["dither": .choice("shaped")]) { $1 }, input)[0]
        #expect(lowToHighRatio(flat, input[0]) > 0.5)
        #expect(lowToHighRatio(shaped, input[0]) < 0.25)
        #expect(shaped.allSatisfy { $0.isFinite && abs($0) <= 1 })
    }

    // MARK: Fractional bit depth

    @Test func fractionalBitDepthKeepsItsFraction() async throws {
        let ramp = [(0..<20_001).map { Float($0) / 10_000 - 1 }]
        let base: [String: ParameterValue] = ["reduxMode": .choice("bitReduction"), "bitDepth": .number(3.5)]
        let fractional = try await render(base.merging(["bitSteps": .choice("fractional")]) { $1 }, ramp)[0]
        let whole = try await render(base.merging(["bitSteps": .choice("whole")]) { $1 }, ramp)[0]
        // 2^2.5 = 5.66 levels a side: -5...5 steps plus the clamped ends. Whole bits round 3.5 up to 4 bits: 17 levels.
        #expect((11...13).contains(Set(fractional).count), "\(Set(fractional).count)")
        #expect(Set(whole).count == 17, "\(Set(whole).count)")
    }

    @Test func wholeBitDepthIsTheSameEitherWay() async throws {
        let samples = TestAudio.samples(frames: 8_000, channels: 2)
        let base: [String: ParameterValue] = ["reduxMode": .choice("classic"), "bitDepth": .number(4), "rateDivider": .number(3)]
        let a = try await render(base.merging(["bitSteps": .choice("fractional")]) { $1 }, samples)
        let b = try await render(base.merging(["bitSteps": .choice("whole")]) { $1 }, samples)
        #expect(a == b)
    }

    // MARK: Linear-phase anti-alias

    private let downsample: [String: ParameterValue] = [
        "reduxMode": .choice("downsampling"), "rateDivider": .number(8), "mode": .choice("linear"),
    ]

    @Test func linearPhaseKeepsWhatIsBelowTheNewNyquist() async throws {
        let frames = 30_000
        let input = sine(200, amplitude: 0.5, frames: frames)
        let output = try await render(downsample.merging(["antiAlias": .choice("linearPhase")]) { $1 }, input)[0]
        let edge = 6_000
        let ratio = rms(output[edge..<(frames - edge)]) / rms(input[0][edge..<(frames - edge)][...])
        #expect(abs(20 * log10(ratio)) < 0.5, "\(20 * log10(ratio)) dB")
    }

    @Test func linearPhaseRemovesWhatWouldAlias() async throws {
        let frames = 30_000
        let input = sine(9_000, amplitude: 0.5, frames: frames)
        let output = try await render(downsample.merging(["antiAlias": .choice("linearPhase")]) { $1 }, input)[0]
        let edge = 6_000
        let ratio = rms(output[edge..<(frames - edge)]) / rms(input[0][edge..<(frames - edge)][...])
        #expect(ratio < 0.01, "\(ratio)")
    }

    @Test func theAntiAliasChoiceChangesTheSound() async throws {
        let samples = TestAudio.samples(frames: 12_000, channels: 1)
        let biquad = try await render(downsample.merging(["antiAlias": .choice("biquad")]) { $1 }, samples)
        let linear = try await render(downsample.merging(["antiAlias": .choice("linearPhase")]) { $1 }, samples)
        #expect(biquad != linear)
    }
}
