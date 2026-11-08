import BakeDSP
import Foundation
import Testing

struct FilterTests {
    /// Filters one channel, optionally with a cutoff modulation signal, in the given chunk size.
    private func filter(
        _ input: [Float], _ type: bake.dsp.FilterType, sections: Int32 = 1, cutoff: Float = 1_000, q: Float = 0.7071,
        cutoffModulation: [Float]? = nil, chunk: Int? = nil
    ) -> [Float] {
        var state = bake.dsp.FilterState()
        var output = [Float](repeating: 0, count: input.count)
        let modulation = cutoffModulation ?? []
        modulation.withUnsafeBufferPointer { modulationPointer in
            var cutoffSignal = signal(cutoff, 20, 20_000, scale: .exponential)
            if cutoffModulation != nil {
                cutoffSignal.modulation = modulationPointer.baseAddress
                cutoffSignal.modulationFrames = modulationPointer.count
            }
            let qSignal = signal(q, 0.1, 20)
            let driveSignal = signal(0, 0, 24)
            input.withUnsafeBufferPointer { inputPointer in
                output.withUnsafeMutableBufferPointer { outputPointer in
                    var start = 0
                    while start < input.count {
                        let count = min(chunk ?? input.count, input.count - start)
                        bake.dsp.renderFilter(
                            &state, type, sections, cutoffSignal, qSignal, driveSignal, 48_000,
                            inputPointer.baseAddress! + start, outputPointer.baseAddress! + start, start, count
                        )
                        start += count
                    }
                }
            }
        }
        return output
    }

    /// Steady-state gain in dB for a sine at `frequency` (measured over the second half).
    private func gain(_ type: bake.dsp.FilterType, sections: Int32 = 1, q: Float = 0.7071, at frequency: Double) -> Float {
        let input = sine(frequency: frequency, frames: 48_000)
        let output = filter(input, type, sections: sections, q: q)
        return decibels(TestAudio.rms(Array(output[24_000...])) / TestAudio.rms(Array(input[24_000...])))
    }

    @Test func lowpassIsMinusThreeDecibelsAtCutoff() {
        #expect(abs(gain(.lowpass, at: 1_000) + 3.01) < 0.2)
        #expect(abs(gain(.lowpass, at: 100)) < 0.2)
        #expect(gain(.lowpass, at: 10_000) < -35)
    }

    @Test func sectionsStackTheSlope() {
        #expect(abs(gain(.lowpass, sections: 2, at: 1_000) + 6.02) < 0.3)
        #expect(gain(.lowpass, sections: 2, at: 10_000) < -70)
    }

    @Test func highpassMirrorsLowpass() {
        #expect(abs(gain(.highpass, at: 1_000) + 3.01) < 0.2)
        #expect(abs(gain(.highpass, at: 10_000)) < 0.2)
        #expect(gain(.highpass, at: 100) < -35)
    }

    @Test func bandpassPeaksAtUnityAndNotchCuts() {
        #expect(abs(gain(.bandpass, q: 2, at: 1_000)) < 0.2)
        #expect(gain(.bandpass, q: 2, at: 250) < -10)
        #expect(gain(.notch, at: 1_000) < -40)
        #expect(abs(gain(.notch, at: 100)) < 0.3)
    }

    @Test func cutoffFollowsModulation() {
        // 3 kHz through a 24 dB low-pass at 200 Hz, then the LFO opens it to 5 kHz halfway.
        let input = sine(frequency: 3_000, frames: 48_000)
        let opened = Float(log(25.0) / log(1_000.0)) // 200 · 1000^a = 5000
        let modulation = (0..<48_000).map { $0 < 24_000 ? Float(0) : opened }
        let output = filter(input, .lowpass, sections: 2, cutoff: 200, cutoffModulation: modulation)
        let inputLevel = TestAudio.rms(Array(input[24_000...]))
        #expect(TestAudio.rms(Array(output[12_000..<24_000])) < 0.05 * inputLevel)
        #expect(TestAudio.rms(Array(output[36_000...])) > 0.7 * inputLevel)
    }

    @Test func chunkingDoesNotChangeTheResult() {
        let input = TestAudio.samples(frames: 20_000, channels: 1)[0]
        let modulation = (0..<20_000).map { Float(sin(Double($0) / 2_000)) * 0.3 }
        let whole = filter(input, .bandpass, sections: 4, q: 3, cutoffModulation: modulation)
        let chunked = filter(input, .bandpass, sections: 4, q: 3, cutoffModulation: modulation, chunk: 777)
        #expect(chunked == whole)
    }
}
