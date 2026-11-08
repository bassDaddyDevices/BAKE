import BakeDSP
import Foundation
import Testing
@testable import BakeGraph
@testable import BakeRender

struct FrequencyShifterTests {
    private static let rate = 48_000.0

    private func signal(_ value: Float) -> bake.dsp.ParameterSignal {
        var signal = bake.dsp.ParameterSignal()
        signal.base = value
        signal.minimum = -1_000_000
        signal.maximum = 1_000_000
        return signal
    }

    private func tone(_ frequency: Double, seconds: Double = 2) -> [Float] {
        (0..<Int(Self.rate * seconds)).map { Float(0.5 * sin(2 * Double.pi * frequency * Double($0) / Self.rate)) }
    }

    private func transform(_ input: [Float], precision: Int32) -> [Float] {
        let count = input.count
        var result = [Float](repeating: 0, count: count)
        var tables = [Double](repeating: 0, count: Int(bake.dsp.hilbertTableDoubles(precision)))
        bake.dsp.hilbertDesign(precision, &tables)
        var scratch = [Double](repeating: 0, count: Int(bake.dsp.hilbertScratchDoubles(precision)))
        let block = Int(bake.dsp.hilbertBlockFrames(precision))
        input.withUnsafeBufferPointer { buffer in
            var audio = bake.dsp.AudioInput()
            audio.channelCount = 1
            audio.frames = count
            audio.channels.0 = buffer.baseAddress
            var start = 0
            while start < count {
                let length = min(block, count - start)
                result.withUnsafeMutableBufferPointer { out in
                    bake.dsp.hilbertBlock(audio, 0, precision, tables, &scratch, start, length, out.baseAddress.map { $0 + start })
                }
                start += length
            }
        }
        return result
    }

    private func shifted(_ input: [Float], hertz: Float, sign: Double = 1, absolute: Bool = false, mix: Float = 1, applyMix: Bool = false) -> [Float] {
        let count = input.count
        let hilbert = transform(input, precision: 0)
        var checkpoints = [Double](repeating: 0, count: Int(bake.dsp.shiftCheckpointCount(count)))
        bake.dsp.shiftCheckpoints(signal(hertz), absolute, Self.rate, count, &checkpoints)
        var result = [Float](repeating: 0, count: count)
        input.withUnsafeBufferPointer { buffer in
            var audio = bake.dsp.AudioInput()
            audio.channelCount = 1
            audio.frames = count
            audio.channels.0 = buffer.baseAddress
            bake.dsp.shiftRender(audio, 0, hilbert, signal(hertz), absolute, sign, Self.rate, checkpoints, 0, count, &result, signal(mix), applyMix)
        }
        return result
    }

    /// The strongest frequency of the middle of a signal, from a Hann-windowed FFT of 65,536 frames.
    private func dominantFrequency(_ input: [Float]) -> Double {
        let size = 65_536
        let start = input.count / 2 - size / 2
        var real = (0..<size).map { Double(input[start + $0]) * (0.5 - 0.5 * cos(2 * Double.pi * Double($0) / Double(size))) }
        var imaginary = [Double](repeating: 0, count: size)
        var cosines = [Double](repeating: 0, count: size / 2)
        var sines = [Double](repeating: 0, count: size / 2)
        bake.dsp.fftTwiddles(size, &cosines, &sines)
        bake.dsp.fft(&real, &imaginary, size, cosines, sines)
        var best = 1
        var bestPower = 0.0
        for bin in 1..<(size / 2) {
            let power = real[bin] * real[bin] + imaginary[bin] * imaginary[bin]
            if power > bestPower { bestPower = power; best = bin }
        }
        return Double(best) * Self.rate / Double(size)
    }

    @Test func theHilbertTransformOfASineIsMinusACosine() {
        let input = tone(1_000)
        let result = transform(input, precision: 0)
        var worst = 0.0
        for index in (input.count / 4)..<(input.count * 3 / 4) {
            let expected = -0.5 * cos(2 * Double.pi * 1_000 * Double(index) / Self.rate)
            worst = max(worst, abs(Double(result[index]) - expected))
        }
        #expect(worst < 1e-4)
    }

    @Test func shiftingUpMovesEveryFrequencyUpByTheSameAmount() {
        let result = shifted(tone(1_000), hertz: 300)
        #expect(abs(dominantFrequency(result) - 1_300) < 2)
    }

    @Test func aNegativeShiftMovesItDown() {
        let result = shifted(tone(1_000), hertz: -300)
        #expect(abs(dominantFrequency(result) - 700) < 2)
    }

    @Test func theUpAndDownSidebandsUseTheMagnitude() {
        let up = shifted(tone(1_000), hertz: -300, sign: 1, absolute: true)
        let down = shifted(tone(1_000), hertz: -300, sign: -1, absolute: true)
        #expect(abs(dominantFrequency(up) - 1_300) < 2)
        #expect(abs(dominantFrequency(down) - 700) < 2)
    }

    @Test func theLevelIsKept() {
        let result = shifted(tone(1_000), hertz: 300)
        let middle = result[(result.count / 4)..<(result.count * 3 / 4)]
        let peak = middle.map { abs($0) }.max() ?? 0
        #expect(abs(peak - 0.5) < 0.01)
    }

    @Test func zeroShiftGivesTheInputBack() {
        let input = tone(1_000)
        let result = shifted(input, hertz: 0)
        var worst: Float = 0
        for index in 0..<input.count { worst = max(worst, abs(result[index] - input[index])) }
        #expect(worst < 1e-6)
    }

    @Test func mixZeroIsTheDrySignal() {
        let input = tone(1_000)
        let result = shifted(input, hertz: 300, mix: 0, applyMix: true)
        #expect(result == input)
    }

    @Test func anyChunkSizeGivesTheSameBits() {
        let input = tone(1_000, seconds: 1)
        let whole = shifted(input, hertz: 123.4)
        let hilbert = transform(input, precision: 0)
        let count = input.count
        var checkpoints = [Double](repeating: 0, count: Int(bake.dsp.shiftCheckpointCount(count)))
        bake.dsp.shiftCheckpoints(signal(123.4), false, Self.rate, count, &checkpoints)
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
                    bake.dsp.shiftRender(audio, 0, hilbert, signal(123.4), false, 1, Self.rate, checkpoints, start, length, out.baseAddress.map { $0 + start }, signal(1), false)
                }
                start += length
            }
        }
        #expect(whole == chunked)
    }

    @Test func theCatalogPutsItInTheEffectsGroupWithUpAndDownOutputs() {
        let definition = NodeCatalog.definition(for: .frequencyShifter)
        #expect(NodeKind.frequencyShifter.category == .effects)
        #expect(definition.pins.contains { $0.id == "up" && $0.direction == .output })
        #expect(definition.pins.contains { $0.id == "down" && $0.direction == .output })
        #expect(definition.lengthRule == .sameAsInput("in"))
        #expect(!NodeCatalog.isCausal(Node(kind: .frequencyShifter, parameters: [:])))
    }
}
