import BakeDSP
import Foundation
import Testing
@testable import BakeGraph

/// The linear-phase response drawn on the Filters card must match the kernel it describes.
struct LinearPhasePlotTests {
    private let sampleRate = 48_000.0

    private func kernelDecibels(_ type: bake.dsp.FilterType, cutoff: Double, q: Double, taps: Int32, at hertz: Double) -> Double {
        let count = Int(bake.dsp.linearPhaseTaps(taps))
        var window = [Double](repeating: 0, count: count)
        var kernel = [Double](repeating: 0, count: count)
        bake.dsp.kaiserWindow(taps, &window)
        bake.dsp.designLinearPhaseKernel(type, cutoff, q, taps, sampleRate, window, &kernel)
        let centre = (count - 1) / 2
        var real = 0.0, imaginary = 0.0
        for (index, tap) in kernel.enumerated() {
            let angle = -2 * Double.pi * hertz / sampleRate * Double(index - centre)
            real += tap * cos(angle)
            imaginary += tap * sin(angle)
        }
        return 20 * log10(max((real * real + imaginary * imaginary).squareRoot(), 1e-12))
    }

    @Test func theEdgeWidthIsTheKernelsOwn() {
        for taps: Int32 in [513, 4_097, 131_073] {
            #expect(abs(FrequencyResponse.linearPhaseTransitionHertz(taps: Int(taps)) - bake.dsp.linearPhaseTransitionHz(taps, sampleRate)) < 1e-9)
        }
    }

    @Test func theLowpassPlotMatchesTheKernelAwayFromTheEdge() {
        let edge = FrequencyResponse.linearPhaseTransitionHertz(taps: 4_097)
        for hertz in [100.0, 1_000.0, 3_500.0, 4_000.0, 4_000 + 2 * edge, 8_000.0, 15_000.0] {
            let plot = max(FrequencyResponse.linearPhaseDecibels(type: "lowpass", cutoff: 4_000, q: 0.707, taps: 4_097, at: hertz), -90)
            let kernel = max(kernelDecibels(.lowpass, cutoff: 4_000, q: 0.707, taps: 4_097, at: hertz), -90)
            #expect(abs(plot - kernel) < 0.2, "\(hertz) Hz: plot \(plot) dB, kernel \(kernel) dB")
        }
    }

    @Test func theOtherTypesMatchToo() {
        let cases: [(String, bake.dsp.FilterType)] = [("highpass", .highpass), ("bandpass", .bandpass), ("notch", .notch)]
        for (name, type) in cases {
            for hertz in [100.0, 1_000.0, 4_000.0, 10_000.0, 20_000.0] {
                let plot = max(FrequencyResponse.linearPhaseDecibels(type: name, cutoff: 4_000, q: 1, taps: 4_097, at: hertz), -90)
                let kernel = max(kernelDecibels(type, cutoff: 4_000, q: 1, taps: 4_097, at: hertz), -90)
                #expect(abs(plot - kernel) < 0.3, "\(name) \(hertz) Hz: plot \(plot) dB, kernel \(kernel) dB")
            }
        }
    }

    @Test func aLongerKernelDrawsASteeperEdge() {
        func drop(_ taps: Int) -> Double {
            FrequencyResponse.linearPhaseDecibels(type: "lowpass", cutoff: 4_000, q: 1, taps: taps, at: 4_000) -
                FrequencyResponse.linearPhaseDecibels(type: "lowpass", cutoff: 4_000, q: 1, taps: taps, at: 4_100)
        }
        #expect(drop(131_073) > drop(1_025) + 50)      // 100 Hz above the cutoff a long kernel is already at the floor
        #expect(FrequencyResponse.linearPhaseDecibels(type: "lowpass", cutoff: 4_000, q: 1, taps: 131_073, at: 4_010) < -100)
        #expect(FrequencyResponse.linearPhaseDecibels(type: "lowpass", cutoff: 4_000, q: 1, taps: 1_025, at: 4_010) > -20)
    }
}
