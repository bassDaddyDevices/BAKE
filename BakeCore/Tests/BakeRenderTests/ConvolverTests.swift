import Foundation
import Testing
@testable import BakeGraph
@testable import BakeRender

struct ConvolverTests {
    private let impulseAsset = AssetID(testUUID(9_300))

    /// `input` through a Convolver, with `impulse` on its `ir` pin (or unwired when nil).
    private func run(
        input: [[Float]], impulse: [[Float]]? = nil, _ parameters: [ParameterID: ParameterValue] = [:], chunk: Int = 4_096
    ) async throws -> [[Float]] {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var patch = Patch()
        let inputURL = directory.appendingPathComponent("input.wav")
        try TestAudio.write(input, to: inputURL, sampleRate: 48_000)
        patch.assets[sourceAsset] = inputURL
        let source = patch.graph.add(.audio, asset: sourceAsset)
        let node = patch.graph.add(.convolver, parameters)
        patch.wire(source, "out", to: node, "in")
        if let impulse {
            let impulseURL = directory.appendingPathComponent("impulse.wav")
            try TestAudio.write(impulse, to: impulseURL, sampleRate: 48_000)
            patch.assets[impulseAsset] = impulseURL
            patch.wire(patch.graph.add(.audio, asset: impulseAsset), "out", to: node, "ir")
        }
        patch.bake("out", from: node)
        return try #require(try await patch.render(in: directory, chunkFrames: chunk)["out"])
    }

    private func impulse(at frame: Int, length: Int, amplitude: Float = 1) -> [Float] {
        var values = [Float](repeating: 0, count: length)
        values[frame] = amplitude
        return values
    }

    private func direct(_ x: [Float], _ h: [Float]) -> [Float] {
        var y = [Float](repeating: 0, count: x.count + h.count - 1)
        for i in 0..<x.count { for j in 0..<h.count { y[i + j] += x[i] * h[j] } }
        return y
    }

    private func maxDifference(_ a: [Float], _ b: [Float]) -> Float {
        zip(a, b).map { abs($0 - $1) }.max() ?? 0
    }

    private let noise = TestAudio.samples(frames: 6_000, channels: 1)

    @Test func aDelayedImpulseDelaysTheInputAndLengthensTheOutput() async throws {
        let output = try await run(input: noise, impulse: [impulse(at: 100, length: 200, amplitude: 0.5)], ["normalize": .choice("off")])
        let expectedFrames: Int = 6_199
        #expect(output[0].count == expectedFrames)
        let expected = direct(noise[0], impulse(at: 100, length: 200, amplitude: 0.5))
        #expect(maxDifference(output[0], expected) < 2e-5)
    }

    @Test func normalizeBringsASingleSpikeToUnity() async throws {
        let output = try await run(input: noise, impulse: [impulse(at: 10, length: 50, amplitude: 0.25)])
        #expect(maxDifference(output[0], direct(noise[0], impulse(at: 10, length: 50))) < 2e-5)
    }

    @Test func aLongImpulseResponseMatchesDirectConvolution() async throws {
        let response = (0..<9_000).map { Float(sin(Double($0) * 0.3)) * Float(exp(-Double($0) / 2_000)) * 0.1 }
        let output = try await run(input: noise, impulse: [response], ["normalize": .choice("off")])
        let longFrames: Int = 14_999
        #expect(output[0].count == longFrames)
        #expect(maxDifference(output[0], direct(noise[0], response)) < 1e-4)
    }

    @Test func unwiredIRConvolvesTheInputWithItself() async throws {
        let short = Array(noise[0].prefix(900))
        let output = try await run(input: [short], ["normalize": .choice("off")])
        let selfFrames: Int = 1_799
        #expect(output[0].count == selfFrames)
        // The output peaks near 900 times the noise power, so the float FFT's rounding is judged against that peak.
        let expected = direct(short, short)
        let peak = expected.map { abs($0) }.max() ?? 1
        let difference = maxDifference(output[0], expected)
        #expect(difference < 5e-6 * max(peak, 1), "difference \(difference) against a peak of \(peak)")
    }

    @Test func anyChunkSizeGivesTheSameBits() async throws {
        let response = (0..<5_000).map { Float(cos(Double($0) * 0.11)) * 0.05 }
        let whole = try await run(input: noise, impulse: [response], chunk: 65_536)
        let chunked = try await run(input: noise, impulse: [response], chunk: 777)
        #expect(whole == chunked)
    }

    @Test func mixZeroIsTheDryInputFollowedBySilence() async throws {
        let output = try await run(input: noise, impulse: [impulse(at: 5, length: 300)], ["mix": .number(0)])
        #expect(Array(output[0].prefix(6_000)) == noise[0])
        #expect(output[0].dropFirst(6_000).allSatisfy { $0 == 0 })
    }

    @Test func aMonoInputThroughAStereoImpulseResponseMakesStereo() async throws {
        let left = impulse(at: 0, length: 100), right = impulse(at: 50, length: 100)
        let output = try await run(input: noise, impulse: [left, right], ["normalize": .choice("off")])
        #expect(output.count == 2)
        #expect(maxDifference(output[0], direct(noise[0], left)) < 2e-5)
        #expect(maxDifference(output[1], direct(noise[0], right)) < 2e-5)
    }

    @Test func trueStereoMixesAllFourPaths() async throws {
        let inputs = TestAudio.samples(frames: 3_000, channels: 2)
        let ll = impulse(at: 0, length: 64, amplitude: 1), lr = impulse(at: 10, length: 64, amplitude: 0.5)
        let rl = impulse(at: 20, length: 64, amplitude: 0.25), rr = impulse(at: 30, length: 64, amplitude: 2)
        let output = try await run(input: inputs, impulse: [ll, lr, rl, rr], ["normalize": .choice("off"), "stereo": .choice("trueStereo")])
        #expect(output.count == 2)
        let left = zip(direct(inputs[0], ll), direct(inputs[1], rl)).map(+)
        let right = zip(direct(inputs[0], lr), direct(inputs[1], rr)).map(+)
        #expect(maxDifference(output[0], left) < 2e-5)
        #expect(maxDifference(output[1], right) < 2e-5)
    }

    @Test func reverseTrimStretchAndPreDelayShapeTheImpulseResponse() async throws {
        let response: [Float] = [1, 0, 0, 0, 0, 0, 0, 0, 0, 0.5]       // 10 frames
        let reverseParameters: [ParameterID: ParameterValue] = ["normalize": .choice("off"), "reverse": .choice("on")]
        let preDelayParameters: [ParameterID: ParameterValue] = ["normalize": .choice("off"), "preDelay": .number(1)]
        let trimParameters: [ParameterID: ParameterValue] = ["normalize": .choice("off"), "trim": .number(0.000_104_166_666_666_666_67)]
        let reversed = try await run(input: [impulse(at: 0, length: 400)], impulse: [response], reverseParameters)
        let reversedHead: [Float] = [0.5, 0, 0, 0, 0, 0, 0, 0, 0, 1]
        let head = Array(reversed[0].prefix(10))
        #expect(maxDifference(head, reversedHead) < 1e-6)
        let delayed = try await run(input: [impulse(at: 0, length: 400)], impulse: [response], preDelayParameters)
        let delayedFrames: Int = 457     // 400 + (10 + 48) − 1
        #expect(delayed[0].count == delayedFrames)
        #expect(abs(delayed[0][48] - 1) < 1e-5)
        let trimmed = try await run(input: [impulse(at: 0, length: 400)], impulse: [response], trimParameters)
        let trimmedFrames: Int = 404     // 400 + 5 − 1
        #expect(trimmed[0].count == trimmedFrames)
        #expect(abs(trimmed[0][9]) < 1e-6)
    }

    @Test func theCatalogUsesTheConvolvedLengthRule() {
        #expect(NodeCatalog.definition(for: .convolver).lengthRule == .convolved("in", ir: "ir"))
        #expect(NodeKind.convolver.category == .time)
    }

    @Test func thePlanSizesTheOutput() {
        let input = SignalShape(frames: 1_000, channels: 1)
        let ir = SignalShape(frames: 500, channels: 2)
        let defaults = NodeCatalog.defaultParameters(for: .convolver)
        #expect(ConvolverPlan.shape(input: input, impulse: ir, parameters: defaults, sampleRate: 48_000) == SignalShape(frames: 1_499, channels: 2))
        #expect(ConvolverPlan.shape(input: input, impulse: nil, parameters: defaults, sampleRate: 48_000) == SignalShape(frames: 1_999, channels: 1))
        var stretched = defaults
        stretched["stretch"] = .number(2)
        stretched["preDelay"] = .number(1)
        let stretchedFrames: Int = 1_048
        #expect(ConvolverPlan.impulseFrames(raw: 500, parameters: stretched, sampleRate: 48_000) == stretchedFrames)
        var four = defaults
        four["stereo"] = .choice("trueStereo")
        #expect(ConvolverPlan.shape(input: SignalShape(frames: 10, channels: 2), impulse: SignalShape(frames: 4, channels: 4), parameters: four, sampleRate: 48_000).channels == 2)
    }
}
