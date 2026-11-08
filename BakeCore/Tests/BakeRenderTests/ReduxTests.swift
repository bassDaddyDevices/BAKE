import BakeDSP
import Foundation
import Testing
@testable import BakeGraph
@testable import BakeRender

struct ReduxTests {
    private func reduce(
        _ input: [Float], bits: Float = 4, divider: Float = 1, mix: Float = 1,
        algorithm: bake.dsp.ReduxAlgorithm = .classic,
        mode: bake.dsp.ReduxMode = .sampleAndHold, dither: bake.dsp.ReduxDither = .off,
        bitwiseOp: bake.dsp.ReduxBitwiseOp = .bitXor, mask: Int32 = 21_845,
        bitModulation: [Float]? = nil, dividerModulation: [Float]? = nil, mixModulation: [Float]? = nil,
        chunk: Int? = nil
    ) -> [Float] {
        var state = bake.dsp.ReduxState()
        var output = [Float](repeating: 0, count: input.count)
        let modulationA = bitModulation ?? []
        let modulationB = dividerModulation ?? []
        let modulationC = mixModulation ?? []
        var bitSignal = signal(bits, 1, 32)
        var dividerSignal = signal(divider, 1, 256)
        var mixSignal = signal(mix, 0, 1)
        modulationA.withUnsafeBufferPointer { pointer in
            if bitModulation != nil {
                bitSignal.modulation = pointer.baseAddress
                bitSignal.modulationFrames = pointer.count
            }
            modulationB.withUnsafeBufferPointer { pointer in
                if dividerModulation != nil {
                    dividerSignal.modulation = pointer.baseAddress
                    dividerSignal.modulationFrames = pointer.count
                }
                modulationC.withUnsafeBufferPointer { pointer in
                    if mixModulation != nil {
                        mixSignal.modulation = pointer.baseAddress
                        mixSignal.modulationFrames = pointer.count
                    }
                    input.withUnsafeBufferPointer { source in
                        output.withUnsafeMutableBufferPointer { destination in
                            var start = 0
                            while start < input.count {
                                let count = min(chunk ?? input.count, input.count - start)
                                bake.dsp.renderRedux(
                                    &state, algorithm, mode, dither, bitwiseOp, mask,
                                    bitSignal, dividerSignal, mixSignal,
                                    source.baseAddress! + start, destination.baseAddress! + start,
                                    start, count, 0, 48_000
                                )
                                start += count
                            }
                        }
                    }
                }
            }
        }
        return output
    }

    @Test func bitDepthRateDividerAndInterpolationHaveKnownBehaviour() {
        let bitCrushed = reduce([-0.9, -0.4, 0.1, 0.4, 0.9], bits: 2)
        #expect(bitCrushed == [-1, -0.5, 0, 0.5, 1])

        let input: [Float] = [-1, -1, 1, 1, 1, -1, -1]
        let held = reduce(input, bits: 1, divider: 3)
        let linear = reduce(input, bits: 1, divider: 3, mode: .linear)
        #expect(held == [-1, -1, -1, 1, 1, 1, -1])
        #expect(linear[3] == -1)
        #expect(abs(linear[4] + 1.0 / 3.0) < 1e-6)
        #expect(abs(linear[5] - 1.0 / 3.0) < 1e-6)
    }

    @Test func chunksOf777MatchOneWholeRender() {
        let input = TestAudio.samples(frames: 6_013, channels: 1)[0]
        for mode in [bake.dsp.ReduxMode.sampleAndHold, .linear] {
            #expect(reduce(input, bits: 5, divider: 7, mode: mode) == reduce(input, bits: 5, divider: 7, mode: mode, chunk: 777))
        }
    }

    @Test func ditheredRendersAreDeterministic() {
        let input = TestAudio.samples(frames: 2_048, channels: 1)[0]
        let a = reduce(input, bits: 8, dither: .triangular)
        let b = reduce(input, bits: 8, dither: .triangular)
        #expect(a == b)
        #expect(a != reduce(input, bits: 8, dither: .off))
    }

    @Test func parameterExtremesAndSettingsStayFinite() {
        let input = TestAudio.samples(frames: 1_024, channels: 1)[0]
        for bits in [Float(1), 32] {
            for divider in [Float(1), 256] {
                for amount in [Float(0), 1] {
                    for mode in [bake.dsp.ReduxMode.sampleAndHold, .linear] {
                        for dither in [bake.dsp.ReduxDither.off, .triangular] {
                            let rendered = reduce(input, bits: bits, divider: divider, mix: amount, mode: mode, dither: dither)
                            #expect(rendered.allSatisfy { $0.isFinite })
                        }
                    }
                }
            }
        }
    }

    @Test func bitDepthRateAndMixModulationChangeTheOutput() {
        let input = (0..<256).map { $0.isMultiple(of: 2) ? Float(0.73) : Float(-0.61) }
        let bipolar = [Float](repeating: 1, count: input.count)
        let bitDepthModulationChanges = reduce(input, bits: 2) != reduce(input, bits: 2, bitModulation: bipolar)
        let dividerModulationChanges = reduce(input, bits: 8, divider: 1) != reduce(input, bits: 8, divider: 1, dividerModulation: bipolar)
        let mixModulationChanges = reduce(input, bits: 2, mix: 1) != reduce(input, bits: 2, mix: 1, mixModulation: [Float](repeating: -1, count: input.count))
        #expect(bitDepthModulationChanges)
        #expect(dividerModulationChanges)
        #expect(mixModulationChanges)
    }

    /// Classic is the shipped behaviour: Bit Depth and Rate Divider together, bit-identical to the
    /// pre-modes kernel. The reference here re-implements that kernel independently.
    @Test func classicMatchesTheShippedBitAndRateBehaviour() {
        let input = TestAudio.samples(frames: 2_000, channels: 1)[0]
        for bits in [Float(2), 8] {
            for divider in [Float(1), 5] {
                func legacy() -> [Float] {
                    var previous: Float = 0, current: Float = 0, phase = 0
                    var output: [Float] = []
                    let step = 1 / Float(1 << (Int(bits) - 1))
                    for source in input {
                        if phase == 0 {
                            previous = current
                            current = min(max((source / step).rounded() * step, -1), 1)
                        }
                        output.append(source + (current - source) * 1)   // the kernel always blends by Mix
                        phase = (phase + 1) % Int(divider)
                    }
                    return output
                }
                #expect(reduce(input, bits: bits, divider: divider, algorithm: .classic) == legacy())
            }
        }
    }

    @Test func eachModeHasItsOwnKnownBehaviour() {
        let input: [Float] = [0.9, 0.9, 0.9, 0.9]
        // Bit Reduction quantises and ignores the divider.
        #expect(reduce(input, bits: 2, divider: 4, algorithm: .bitReduction) == [1, 1, 1, 1])
        // Sample & Hold holds the first sample and does not quantise.
        #expect(reduce(input, bits: 32, divider: 2, algorithm: .sampleAndHold) == [0.9, 0.9, 0.9, 0.9])
        // Bitwise XOR and OR with mask 0 are the identity on the integer sample.
        #expect(reduce([0.5, -0.5], bits: 8, algorithm: .bitwise, bitwiseOp: .bitXor, mask: 0) == [0.5, -0.5])
        #expect(reduce([0.5, -0.5], bits: 8, algorithm: .bitwise, bitwiseOp: .bitOr, mask: 0) == [0.5, -0.5])
        // Bitwise AND with mask 0 zeroes everything.
        #expect(reduce([0.5, -0.5], bits: 8, algorithm: .bitwise, bitwiseOp: .bitAnd, mask: 0) == [0, 0])
    }

    /// Review fix: the 16-bit default mask swamped 8-bit samples and every sample clipped. The mask
    /// now works within the sample's own magnitude bits, so defaults stay musical at any bit depth.
    @Test func bitwiseDefaultsStayInRangeAtEveryBitDepth() {
        let input = sine(frequency: 220, frames: 48_000, amplitude: 0.5)
        for bits in [Float(4), 8, 12, 16, 24] {
            let output = reduce(input, bits: bits, algorithm: .bitwise, bitwiseOp: .bitXor, mask: 21_845)
            // The largest positive integer sample is (levels − 1) / levels, so +1 only appears if the
            // result left the integer range and was clamped. (−1 is a real value at any depth.)
            #expect(output.allSatisfy { $0 < 1 }, "\(bits) bits: a result was clamped")
            if bits >= 8 {
                let clipped = output.filter { abs($0) >= 0.999 }.count
                #expect(Double(clipped) / Double(output.count) < 0.05, "\(bits) bits: \(clipped) samples at full scale")
            }
            #expect(output != input, "\(bits) bits: XOR did nothing")
        }
    }

    @Test func downsamplingAttenuatesAboveTheNewNyquist() {
        // Divider 4 at 48 kHz: the new Nyquist is 6 kHz, so a 12 kHz tone must drop by at least 40 dB.
        let input = sine(frequency: 12_000, frames: 24_000, amplitude: 0.5)
        let output = reduce(input, bits: 32, divider: 4, algorithm: .downsampling)
        let inputLevel = TestAudio.rms(Array(input[12_000...]))
        let outputLevel = TestAudio.rms(Array(output[12_000...]))
        #expect(decibels(outputLevel / inputLevel) < -40)
    }

    @Test func everyModeIsChunkInvariant() {
        let input = TestAudio.samples(frames: 6_013, channels: 1)[0]
        for algorithm in [bake.dsp.ReduxAlgorithm.classic, .bitReduction, .downsampling, .sampleAndHold, .bitwise] {
            let whole = reduce(input, bits: 6, divider: 5, algorithm: algorithm)
            let chunked = reduce(input, bits: 6, divider: 5, algorithm: algorithm, chunk: 777)
            #expect(whole == chunked, "\(algorithm)")
        }
    }

    @Test func audioReduxPrintRendersSameLengthAndChannels() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.wav")
        let samples = TestAudio.samples(frames: 2_048, channels: 2)
        try TestAudio.write(samples, to: source, sampleRate: 48_000)
        let output = directory.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        var graph = TestProject()
        let audio = graph.add(.audio, asset: sourceAsset)
        let redux = graph.add(.redux, ["bitDepth": .number(4), "rateDivider": .number(3)])
        let print = graph.add(.print, ["bitDepth": .choice("32f")])
        graph.connect(audio, to: redux)
        graph.connect(redux, to: print)
        let urls = [sourceAsset: source]
        let request = RenderRequest(plan: try compile(graph.project, assetURLs: urls), assetURLs: urls, outputDirectory: output)
        let written = try #require(try await RenderEngine.render(request).outputs[print])
        let rendered = try TestAudio.read(written)

        #expect(rendered.samples.count == 2)
        #expect(rendered.samples.allSatisfy { $0.count == 2_048 })
        #expect(rendered.samples.allSatisfy { $0.allSatisfy { $0.isFinite } })
        #expect(rendered.samples[0] != samples[0])
    }
}
