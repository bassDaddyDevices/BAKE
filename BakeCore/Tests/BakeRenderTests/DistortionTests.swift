import BakeDSP
import Foundation
import Testing

struct DistortionTests {
    private func distort(
        _ input: [Float], _ mode: bake.dsp.DistortionMode, oversampling: Int32,
        drive: Float, ceiling: Float = 0, mix: Float = 1, chunk: Int? = nil
    ) -> [Float] {
        let maxCount = chunk ?? input.count
        var scratch = [Float](repeating: 0, count: bake.dsp.distortionScratchFloats(oversampling, maxCount))
        var output = [Float](repeating: 0, count: input.count)
        let driveSignal = signal(drive, 0, 48)
        let ceilingSignal = signal(ceiling, -24, 0)
        let mixSignal = signal(mix, 0, 1)
        input.withUnsafeBufferPointer { inputPointer in
            output.withUnsafeMutableBufferPointer { outputPointer in
                scratch.withUnsafeMutableBufferPointer { scratchPointer in
                    var start = 0
                    while start < input.count {
                        let count = min(maxCount, input.count - start)
                        bake.dsp.renderDistortion(
                            mode, oversampling, driveSignal, ceilingSignal, mixSignal,
                            inputPointer.baseAddress!, input.count,
                            outputPointer.baseAddress! + start, start, count, scratchPointer.baseAddress!
                        )
                        start += count
                    }
                }
            }
        }
        return output
    }

    /// Hann-windowed Goertzel power.
    private func power(of signal: [Float], at frequency: Double) -> Double {
        let w = 2 * Double.pi * frequency / 48_000
        var s1 = 0.0
        var s2 = 0.0
        for (index, sample) in signal.enumerated() {
            let hann = 0.5 - 0.5 * cos(2 * Double.pi * Double(index) / Double(signal.count - 1))
            let s = Double(sample) * hann + 2 * cos(w) * s1 - s2
            s2 = s1
            s1 = s
        }
        return s1 * s1 + s2 * s2 - 2 * cos(w) * s1 * s2
    }

    @Test func cleanSignalsPassThroughTheOversampler() {
        // Hard mode at 0 dB drive and a 0 dB ceiling never clips a 0.5 sine.
        let input = sine(frequency: 1_000, frames: 4_800)
        let output = distort(input, .hard, oversampling: 8, drive: 0)
        let worst = (64..<(4_800 - 64)).map { abs(output[$0] - input[$0]) }.max() ?? 0
        #expect(worst < 1e-3)
    }

    @Test func hardClippingRespectsTheCeiling() {
        let output = distort(sine(frequency: 500, frames: 4_800, amplitude: 0.9), .hard, oversampling: 1, drive: 24, ceiling: -6)
        #expect(output.allSatisfy { abs($0) <= 0.5012 })
        #expect(output.contains { abs($0) > 0.5 })
    }

    @Test func mixBlendsDryAndWet() {
        let input = sine(frequency: 500, frames: 4_800, amplitude: 0.9)
        let dry = distort(input, .soft, oversampling: 1, drive: 24, mix: 0)
        #expect(dry == input)
    }

    @Test func oversamplingSuppressesAliasing() {
        // A driven 9 kHz sine makes a 27 kHz harmonic, which aliases to 21 kHz without oversampling.
        let input = sine(frequency: 9_000, frames: 24_000, amplitude: 0.9)
        func aliasLevel(_ factor: Int32) -> Double {
            let output = distort(input, .soft, oversampling: factor, drive: 24)
            return 10 * log10(power(of: output, at: 21_000) / power(of: output, at: 9_000))
        }
        let plain = aliasLevel(1)
        let oversampled = aliasLevel(8)
        #expect(oversampled < plain - 30, "1×: \(plain) dB, 8×: \(oversampled) dB")
        #expect(oversampled < -60)
    }

    @Test func chunkingDoesNotChangeTheResult() {
        let input = TestAudio.samples(frames: 6_000, channels: 1)[0]
        let whole = distort(input, .soft, oversampling: 4, drive: 18, ceiling: -3, mix: 0.7)
        let chunked = distort(input, .soft, oversampling: 4, drive: 18, ceiling: -3, mix: 0.7, chunk: 613)
        #expect(chunked == whole)
    }
}
