import BakeDSP
import Foundation
import Testing
@testable import BakeGraph
@testable import BakeRender

struct FlangerTests {
    private func flanger(
        _ input: [Float], delay: Float = 4, rate: Float = 0.25, depth: Float = 0.7,
        feedback: Float = 0.35, mix: Float = 0.5, polarity: bake.dsp.FlangerPolarity = .positive,
        damping: Double = 0.2, interpolation: bake.dsp.FlangerInterpolation = .cubic,
        delayModulation: [Float]? = nil, rateModulation: [Float]? = nil,
        depthModulation: [Float]? = nil, feedbackModulation: [Float]? = nil, mixModulation: [Float]? = nil,
        chunk: Int? = nil
    ) -> [Float] {
        var state = bake.dsp.FlangerState()
        var line = [Float](repeating: 0, count: 48_000 * 15 / 1_000 + 8)
        var output = [Float](repeating: 0, count: input.count)
        var delaySignal = signal(delay, 0.1, 15, scale: .exponential)
        var rateSignal = signal(rate, 0.05, 5, scale: .exponential)
        var depthSignal = signal(depth, 0, 1)
        var feedbackSignal = signal(feedback, 0, 0.95)
        var mixSignal = signal(mix, 0, 1)
        let delayValues = delayModulation ?? []
        let rateValues = rateModulation ?? []
        let depthValues = depthModulation ?? []
        let feedbackValues = feedbackModulation ?? []
        let mixValues = mixModulation ?? []
        delayValues.withUnsafeBufferPointer { pointer in
            if delayModulation != nil { delaySignal.modulation = pointer.baseAddress; delaySignal.modulationFrames = pointer.count }
            rateValues.withUnsafeBufferPointer { pointer in
                if rateModulation != nil { rateSignal.modulation = pointer.baseAddress; rateSignal.modulationFrames = pointer.count }
                depthValues.withUnsafeBufferPointer { pointer in
                    if depthModulation != nil { depthSignal.modulation = pointer.baseAddress; depthSignal.modulationFrames = pointer.count }
                    feedbackValues.withUnsafeBufferPointer { pointer in
                        if feedbackModulation != nil { feedbackSignal.modulation = pointer.baseAddress; feedbackSignal.modulationFrames = pointer.count }
                        mixValues.withUnsafeBufferPointer { pointer in
                            if mixModulation != nil { mixSignal.modulation = pointer.baseAddress; mixSignal.modulationFrames = pointer.count }
                            input.withUnsafeBufferPointer { source in
                                output.withUnsafeMutableBufferPointer { destination in
                                    line.withUnsafeMutableBufferPointer { delayLine in
                                        var start = 0
                                        while start < input.count {
                                            let count = min(chunk ?? input.count, input.count - start)
                                            bake.dsp.renderFlanger(
                                                &state, delaySignal, rateSignal, depthSignal, feedbackSignal, mixSignal,
                                                polarity, interpolation, damping, 48_000,
                                                delayLine.baseAddress!, delayLine.count,
                                                source.baseAddress! + start, destination.baseAddress! + start,
                                                start, count
                                            )
                                            start += count
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        return output
    }

    /// Review finding: at full depth the sweep passes through delays under 2 samples, where cubic
    /// interpolation read the not-yet-written slot (a sample from 15 ms ago) — a click per sweep.
    @Test func sweepingThroughTinyDelaysNeverClicks() {
        let input = (0..<48_000).map { Float(0.5 * sin(2 * Double.pi * 200 * Double($0) / 48_000)) }
        let maximumInputStep = zip(input, input.dropFirst()).map { abs($1 - $0) }.max() ?? 0
        for interpolation in [bake.dsp.FlangerInterpolation.cubic, .linear] {
            let output = flanger(input, delay: 0.1, rate: 5, depth: 1, feedback: 0, mix: 1, interpolation: interpolation)
            let largestStep = zip(output, output.dropFirst()).map { abs($1 - $0) }.max() ?? 0
            #expect(largestStep < maximumInputStep * 2.2, "\(interpolation): \(largestStep)")   // dry + delayed: at most ~2× the input's own step
        }
    }

    @Test func impulseAppearsAtTheSelectedDelayAndMixZeroIsDry() {
        var impulse = [Float](repeating: 0, count: 256)
        impulse[0] = 1
        let dry = flanger(impulse, delay: 1, depth: 0, feedback: 0, mix: 0)
        #expect(dry == impulse)
        let wet = flanger(impulse, delay: 1, depth: 0, feedback: 0, mix: 1)
        #expect(wet[47] == 0)
        #expect(abs(wet[48] - 1) < 1e-6)
        #expect(wet[49] == 0)
    }

    @Test func chunksOf777MatchOneWholeRender() {
        let input = TestAudio.samples(frames: 8_003, channels: 1)[0]
        let whole = flanger(input, delay: 5.2, rate: 0.73, depth: 0.86, feedback: 0.7, mix: 0.63)
        let chunked = flanger(input, delay: 5.2, rate: 0.73, depth: 0.86, feedback: 0.7, mix: 0.63, chunk: 777)
        #expect(chunked == whole)
    }

    @Test func repeatedRendersAreDeterministic() {
        let input = TestAudio.samples(frames: 4_096, channels: 1)[0]
        #expect(flanger(input) == flanger(input))
    }

    @Test func allParameterExtremesStayFinite() {
        let input = TestAudio.samples(frames: 4_096, channels: 1)[0]
        for delay in [Float(0.1), 15] {
            for rate in [Float(0.05), 5] {
                for depth in [Float(0), 1] {
                    for feedback in [Float(0), 0.95] {
                        for mix in [Float(0), 1] {
                            for polarity in [bake.dsp.FlangerPolarity.positive, .negative] {
                                for damping in [0.0, 0.95] {
                                    for interpolation in [bake.dsp.FlangerInterpolation.linear, .cubic] {
                                        let output = flanger(input, delay: delay, rate: rate, depth: depth, feedback: feedback, mix: mix, polarity: polarity, damping: damping, interpolation: interpolation)
                                        #expect(output.allSatisfy { $0.isFinite })
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    @Test func everyModulatableParameterChangesOutput() {
        let input = sine(frequency: 440, frames: 8_192, amplitude: 0.6)
        let modulation = (0..<input.count).map { Float(sin(Double($0) * 2 * .pi / 1_024)) }
        #expect(flanger(input, delay: 4) != flanger(input, delay: 4, delayModulation: modulation))
        #expect(flanger(input, rate: 0.25) != flanger(input, rate: 0.25, rateModulation: modulation))
        #expect(flanger(input, depth: 0.5) != flanger(input, depth: 0.5, depthModulation: modulation))
        #expect(flanger(input, feedback: 0.35) != flanger(input, feedback: 0.35, feedbackModulation: modulation.map { ($0 + 1) * 0.5 }))
        #expect(flanger(input, mix: 0.5) != flanger(input, mix: 0.5, mixModulation: modulation))
    }

    @Test func everySettingChangesOutput() {
        let input = TestAudio.samples(frames: 8_192, channels: 1)[0]
        #expect(flanger(input, feedback: 0.8, polarity: .positive) != flanger(input, feedback: 0.8, polarity: .negative))
        #expect(flanger(input, feedback: 0.8, damping: 0) != flanger(input, feedback: 0.8, damping: 0.95))
        #expect(flanger(input, feedback: 0, interpolation: .linear) != flanger(input, feedback: 0, interpolation: .cubic))
    }

    @Test func audioFlangerPrintPreservesStereoShape() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.wav")
        let samples = TestAudio.samples(frames: 8_192, channels: 2)
        try TestAudio.write(samples, to: source, sampleRate: 48_000)
        let output = directory.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var graph = TestProject()
        let audio = graph.add(.audio, asset: sourceAsset)
        let flanger = graph.add(.flanger, ["delay": .number(3.5), "mix": .number(0.7)])
        let print = graph.add(.print, ["bitDepth": .choice("32f")])
        graph.connect(audio, to: flanger)
        graph.connect(flanger, to: print)
        let urls = [sourceAsset: source]
        let request = RenderRequest(plan: try compile(graph.project, assetURLs: urls), assetURLs: urls, outputDirectory: output)
        let written = try #require(try await RenderEngine.render(request).outputs[print])
        let rendered = try TestAudio.read(written).samples
        #expect(rendered.count == 2)
        #expect(rendered.allSatisfy { $0.count == 8_192 })
        #expect(rendered.allSatisfy { channel in channel.allSatisfy { $0.isFinite } })
        #expect(rendered[0] != samples[0])
    }
}
