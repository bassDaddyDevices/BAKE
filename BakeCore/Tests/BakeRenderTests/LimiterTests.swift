import BakeDSP
import Foundation
import Testing
@testable import BakeGraph
@testable import BakeRender

struct LimiterTests {
    private static let rate = 48_000.0

    private func signal(_ value: Float) -> bake.dsp.ParameterSignal {
        var signal = bake.dsp.ParameterSignal()
        signal.base = value
        signal.minimum = -1_000_000
        signal.maximum = 1_000_000
        return signal
    }

    /// A sine with a few loud clicks and a loud burst.
    private func program() -> [Float] {
        let count = Int(Self.rate * 3)
        var samples = (0..<count).map { Float(0.5 * sin(2 * Double.pi * 220 * Double($0) / Self.rate)) }
        for index in stride(from: 0, to: count, by: 20_011) { samples[index] += 1.4 }
        for index in Int(Self.rate)..<(Int(Self.rate) + 4_000) { samples[index] *= 3 }
        return samples
    }

    private func limit(_ input: [Float], factor: Int = 4, ceiling: Double = -1, lookahead: Double = 5, release: Double = 100) -> (output: [Float], reduction: [Float]) {
        let count = input.count
        var settings = bake.dsp.LimiterSettings()
        settings.ceilingDb = ceiling
        settings.lookaheadMs = lookahead
        settings.releaseMs = release
        settings.sampleRate = Self.rate
        var taps = [Float](repeating: 0, count: Int(bake.dsp.limiterTapCount(Int32(factor))))
        bake.dsp.limiterDesign(Int32(factor), &taps)
        var peaks = [Float](repeating: 0, count: count)
        var reduction = [Float](repeating: 0, count: count)
        var output = [Float](repeating: 0, count: count)
        input.withUnsafeBufferPointer { buffer in
            var audio = bake.dsp.AudioInput()
            audio.channelCount = 1
            audio.frames = count
            audio.channels.0 = buffer.baseAddress
            bake.dsp.limiterPeaks(audio, Int32(factor), taps, 0, count, &peaks)
            bake.dsp.limiterSolve(peaks, count, signal(0), settings, &reduction)
            output.withUnsafeMutableBufferPointer { out in
                var pointer: UnsafeMutablePointer<Float>? = out.baseAddress
                bake.dsp.limiterRender(audio, reduction, signal(0), &pointer, 1, 0, count)
            }
        }
        return (output, reduction)
    }

    private func truePeak(_ input: [Float], factor: Int) -> Double {
        let count = input.count
        var taps = [Float](repeating: 0, count: Int(bake.dsp.limiterTapCount(Int32(factor))))
        bake.dsp.limiterDesign(Int32(factor), &taps)
        var peaks = [Float](repeating: 0, count: count)
        input.withUnsafeBufferPointer { buffer in
            var audio = bake.dsp.AudioInput()
            audio.channelCount = 1
            audio.frames = count
            audio.channels.0 = buffer.baseAddress
            bake.dsp.limiterPeaks(audio, Int32(factor), taps, 0, count, &peaks)
        }
        return Double(peaks.max() ?? 0)
    }

    @Test func noTruePeakGoesOverTheCeiling() {
        let result = limit(program())
        let ceiling = pow(10.0, -1.0 / 20.0)
        #expect(truePeak(result.output, factor: 4) <= ceiling + 0.001)
    }

    @Test func aHigherOversamplingHoldsTheCeilingMoreTightly() {
        let ceiling = pow(10.0, -1.0 / 20.0)
        let result = limit(program(), factor: 16)
        #expect(truePeak(result.output, factor: 16) <= ceiling + 0.001)
    }

    @Test func aSignalUnderTheCeilingIsUntouched() {
        let quiet = (0..<48_000).map { Float(0.3 * sin(2 * Double.pi * 440 * Double($0) / Self.rate)) }
        let result = limit(quiet)
        let deepest = result.reduction.max() ?? 1
        #expect(deepest == 0)
        #expect(result.output == quiet)
    }

    @Test func theGainStartsFallingBeforeAPeak() {
        var samples = [Float](repeating: 0.1, count: 48_000)
        samples[24_000] = 2
        let result = limit(samples, lookahead: 5)
        #expect(result.reduction[24_000 - 120] > 0.1)
    }

    @Test func releaseRecoversInTheReleaseTime() {
        var samples = [Float](repeating: 0.1, count: 96_000)
        samples[24_000] = 2
        let result = limit(samples, release: 200)
        let peak = result.reduction[24_000]
        var index = 24_000
        while index < result.reduction.count, result.reduction[index] > peak * 0.1 { index += 1 }
        let milliseconds = Double(index - 24_000) * 1000 / Self.rate
        #expect(abs(milliseconds - 200) < 25, "recovered after \(milliseconds) ms")
    }

    @Test func anyChunkSizeGivesTheSameBits() {
        let input = program()
        let whole = limit(input)
        let count = input.count
        var chunked = [Float](repeating: 0, count: count)
        input.withUnsafeBufferPointer { buffer in
            var audio = bake.dsp.AudioInput()
            audio.channelCount = 1
            audio.frames = count
            audio.channels.0 = buffer.baseAddress
            var start = 0
            while start < count {
                let length = min(777, count - start)
                chunked.withUnsafeMutableBufferPointer { out in
                    var pointer: UnsafeMutablePointer<Float>? = out.baseAddress.map { $0 + start }
                    bake.dsp.limiterRender(audio, whole.reduction, signal(0), &pointer, 1, start, length)
                }
                start += length
            }
        }
        #expect(whole.output == chunked)
    }

    @Test func theCatalogPutsItInTheEffectsGroup() {
        let definition = NodeCatalog.definition(for: .limiter)
        #expect(NodeKind.limiter.category == .effects)
        #expect(definition.lengthRule == .sameAsInput("in"))
        #expect(!NodeCatalog.isCausal(Node(kind: .limiter, parameters: [:])))
    }

    // MARK: Hold and Link

    /// Per-channel curves from the pass 2 functions, for a stereo pair measured at factor 1.
    private func linked(_ left: [Float], _ right: [Float], link: Double, hold: Double = 0) -> (curves: [[Float]], outputs: [[Float]]) {
        let count = left.count
        var settings = bake.dsp.LimiterSettings()
        settings.ceilingDb = -1
        settings.lookaheadMs = 5
        settings.releaseMs = 50
        settings.holdMs = hold
        settings.sampleRate = Self.rate
        var curves = [[Float]](repeating: [Float](repeating: 0, count: count), count: 2)
        var outputs = [[Float]](repeating: [Float](repeating: 0, count: count), count: 2)
        left.withUnsafeBufferPointer { l in
            right.withUnsafeBufferPointer { r in
                var audio = bake.dsp.AudioInput()
                audio.channelCount = 2
                audio.frames = count
                audio.channels.0 = l.baseAddress
                audio.channels.1 = r.baseAddress
                var first = [Float](repeating: 0, count: count)
                var second = [Float](repeating: 0, count: count)
                var peaks = [Float](repeating: 0, count: count)
                bake.dsp.limiterChannelPeaks(audio, 0, 1, nil, 0, count, &peaks)
                bake.dsp.limiterNeeded(peaks, count, signal(0), settings, &first)
                bake.dsp.limiterChannelPeaks(audio, 1, 1, nil, 0, count, &peaks)
                bake.dsp.limiterNeeded(peaks, count, signal(0), settings, &second)
                first.withUnsafeMutableBufferPointer { a in
                    second.withUnsafeMutableBufferPointer { b in
                        var pointers: [UnsafeMutablePointer<Float>?] = [a.baseAddress, b.baseAddress]
                        bake.dsp.limiterLink(&pointers, 2, count, link)
                    }
                }
                bake.dsp.limiterCurve(&first, count, settings, &curves[0])
                bake.dsp.limiterCurve(&second, count, settings, &curves[1])
                for channel in 0..<2 {
                    bake.dsp.limiterRenderChannel(audio, channel, curves[channel], signal(0), &outputs[channel], 0, count)
                }
            }
        }
        return (curves, outputs)
    }

    /// Left has a loud burst, right is a quiet steady tone.
    private func stereoProgram() -> (left: [Float], right: [Float]) {
        let count = Int(Self.rate * 2)
        var left = (0..<count).map { Float(0.2 * sin(2 * Double.pi * 200 * Double($0) / Self.rate)) }
        let right = (0..<count).map { Float(0.2 * sin(2 * Double.pi * 330 * Double($0) / Self.rate)) }
        for index in 24_000..<24_200 { left[index] = Float(1.5 * sin(2 * Double.pi * 500 * Double(index) / Self.rate)) }
        return (left, right)
    }

    @Test func linkOneGivesEveryChannelTheSameCurve() {
        let pair = stereoProgram()
        let result = linked(pair.left, pair.right, link: 1)
        #expect(result.curves[0] == result.curves[1])
        #expect((result.curves[0].max() ?? 0) > 1)
    }

    @Test func linkZeroLeavesTheQuietChannelAloneAndStillHoldsTheCeiling() {
        let pair = stereoProgram()
        let result = linked(pair.left, pair.right, link: 0)
        let quietReduction = result.curves[1].max() ?? 1
        #expect(quietReduction == 0)
        #expect(result.outputs[1] == pair.right)
        let ceiling = Float(pow(10.0, -1.0 / 20.0))
        let loudest = result.outputs[0].map { abs($0) }.max() ?? 0
        #expect(loudest <= ceiling + 0.001)
    }

    @Test func aMiddleLinkSharesPartOfTheReduction() {
        let pair = stereoProgram()
        let apart = linked(pair.left, pair.right, link: 0)
        let half = linked(pair.left, pair.right, link: 0.5)
        let loud = apart.curves[0].max() ?? 0
        let shared = half.curves[1].max() ?? 0
        #expect(abs(Double(shared) - Double(loud) / 2) < 0.25, "shared \(shared) of \(loud)")
    }

    @Test func holdKeepsTheReductionDeepAfterAPeak() {
        let pair = stereoProgram()
        let none = linked(pair.left, pair.right, link: 1, hold: 0)
        let held = linked(pair.left, pair.right, link: 1, hold: 100)
        let probe = 24_200 + Int(0.05 * Self.rate)
        #expect(held.curves[0][probe] > none.curves[0][probe] + 1)
        let neverLess = zip(held.curves[0], none.curves[0]).allSatisfy { $0 + 0.0001 >= $1 }
        #expect(neverLess)
    }

    @Test func theNewSettingsDefaultToTheOldBehaviour() {
        let definition = NodeCatalog.definition(for: .limiter)
        let ids = definition.parameters.map { $0.id }
        #expect(ids.contains("hold"))
        #expect(ids.contains("link"))
        func defaultNumber(_ id: String) -> Double? {
            guard let parameter = definition.parameters.first(where: { $0.id == id }),
                  case .number(_, let value, _) = parameter.kind else { return nil }
            return value
        }
        let hold = defaultNumber("hold")
        let link = defaultNumber("link")
        #expect(hold == 0)
        #expect(link == 1)
    }
}
