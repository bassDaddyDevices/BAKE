import BakeDSP
import Foundation
import Testing
@testable import BakeGraph
@testable import BakeRender

/// The card plots (BakeGraph's `TransferCurves` and `FrequencyResponse`) must show what the real
/// kernels do, so each is checked against the kernel it draws.
struct PlotMathTests {
    @Test func waveshaperCurvesMatchTheKernel() {
        let names = TransferCurves.waveshaperCurves
        let curves: [bake.dsp.WaveshaperCurve] = [.tanh, .arctan, .softsign, .sine, .cubic, .hardClip, .asymmetric, .chebyshev]
        #expect(names.count == curves.count)
        for (name, curve) in zip(names, curves) {
            for intensity in [0.0, 0.3, 0.8, 1.0] {
                for bias in [-1.0, -0.3, 0.0, 0.6] {
                    for step in -10...10 {
                        let x = Double(step) / 10
                        let kernel = Double(bake.dsp.waveshaperTransfer(curve, Float(x), Float(intensity), Float(bias)))
                        let plot = TransferCurves.waveshaper(curve: name, x: x, intensity: intensity, bias: bias)
                        #expect(abs(kernel - plot) < 2e-4, "\(name) drive \(intensity) bias \(bias) x \(x): \(kernel) vs \(plot)")
                    }
                }
            }
        }
    }

    @Test func wavefolderShapesMatchTheKernel() {
        let shapes: [(String, bake.dsp.WavefolderShape)] = [("triangle", .triangle), ("sine", .sine)]
        // Up to 4 stages at Fold ≤ 0.8: more gain than that is chaotic, so Float and Double drift apart.
        for (name, shape) in shapes {
            for fold in [0.0, 0.35, 0.8] {
                for symmetry in [-0.7, 0.0, 0.5] {
                    for stages in [1, 2, 4] {
                        for saturation in [0.0, 0.6] {
                            for step in -10...10 {
                                let x = Double(step) / 10
                                let kernel = Double(bake.dsp.wavefolderTransfer(shape, Float(x), Float(fold), Float(symmetry), Int32(stages), Float(saturation)))
                                let plot = TransferCurves.wavefolder(shape: name, x: x, fold: fold, symmetry: symmetry, stages: stages, saturation: saturation)
                                #expect(abs(kernel - plot) < 5e-3, "\(name) fold \(fold) x \(x): \(kernel) vs \(plot)")
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: Known answers (also checked against the C++ kernels' measured gain)

    @Test func aLowpassIsThreeDecibelsDownAtItsCutoff() {
        let atCutoff = FrequencyResponse.filterDecibels(type: "lowpass", cutoff: 1_000, q: 0.7071067811865476, sections: 1, at: 1_000)
        #expect(abs(atCutoff + 3.0103) < 1e-3)
        let two = FrequencyResponse.filterDecibels(type: "lowpass", cutoff: 1_000, q: 0.7071067811865476, sections: 2, at: 1_000)
        #expect(abs(two + 6.0206) < 1e-3)
        #expect(abs(FrequencyResponse.filterDecibels(type: "lowpass", cutoff: 1_000, q: 0.7071067811865476, sections: 1, at: 10)) < 1e-3)
        #expect(abs(FrequencyResponse.filterDecibels(type: "lowpass", cutoff: 1_000, q: 0.7071067811865476, sections: 1, at: 10_000) + 42.7383) < 1e-2)
    }

    @Test func eachFilterTypeHasItsShape() {
        func gain(_ type: String, _ hz: Double) -> Double {
            FrequencyResponse.filterDecibels(type: type, cutoff: 1_000, q: 1, sections: 1, at: hz)
        }
        #expect(gain("highpass", 50) < -20 && gain("highpass", 15_000) > -1)
        #expect(gain("bandpass", 1_000) > -0.1 && gain("bandpass", 50) < -15)
        #expect(gain("notch", 1_000) < -40 && gain("notch", 100) > -1)
    }

    @Test func thePhaserWithNoMixIsFlatAndSweepMovesTheNotches() {
        for hz in [60.0, 700.0, 5_000.0] {
            #expect(abs(FrequencyResponse.phaserDecibels(center: 700, width: 2, stages: 4, feedback: 0.2, mix: 0, at: hz)) < 1e-6)
        }
        #expect(abs(FrequencyResponse.phaserDecibels(center: 700, width: 2, stages: 4, feedback: 0.2, mix: 0.5, at: 700) - 1.0233) < 1e-2)
        #expect(abs(FrequencyResponse.phaserDecibels(center: 700, width: 2, stages: 4, feedback: 0.2, mix: 0.5, at: 50) - 0.3257) < 1e-2)
        #expect(abs(FrequencyResponse.phaserDecibels(center: 700, width: 2, stages: 4, feedback: 0.2, mix: 0.5, sweepOctaves: 0.5, at: 700) + 2.1256) < 1e-2)
        // Half-mixed, a notch appears where the stages turn the wet signal upside down, and it moves with the sweep.
        func deepest(_ sweep: Double) -> Double {
            stride(from: 40.0, through: 10_000, by: 20).min {
                FrequencyResponse.phaserDecibels(center: 700, width: 2, stages: 4, feedback: 0, mix: 0.5, sweepOctaves: sweep, at: $0) <
                    FrequencyResponse.phaserDecibels(center: 700, width: 2, stages: 4, feedback: 0, mix: 0.5, sweepOctaves: sweep, at: $1)
            } ?? 0
        }
        #expect(deepest(1) > deepest(0) * 1.5)
    }

    @Test func theSweepFollowsTheKernelsLFO() {
        #expect(FrequencyResponse.phaserSweepOctaves(depth: 1, width: 2, rate: 1, at: 0) == 0)
        #expect(abs(FrequencyResponse.phaserSweepOctaves(depth: 1, width: 2, rate: 1, at: 0.25) - 1) < 1e-12)   // +width/2
        #expect(abs(FrequencyResponse.phaserSweepOctaves(depth: 0.5, width: 4, rate: 0.5, at: 1.5) + 1) < 1e-12)
        #expect(FrequencyResponse.phaserSweepOctaves(depth: 0, width: 4, rate: 1, at: 0.25) == 0)
    }

    // MARK: Against the real kernels

    private func measuredDecibels(_ input: [Float], _ output: [Float]) -> Double {
        var inEnergy = 0.0, outEnergy = 0.0
        for index in input.count / 2..<input.count {
            inEnergy += Double(input[index]) * Double(input[index])
            outEnergy += Double(output[index]) * Double(output[index])
        }
        return 10 * log10(outEnergy / inEnergy)
    }

    @Test func filterResponseMatchesTheRealFilter() {
        let types: [(String, bake.dsp.FilterType)] = [("lowpass", .lowpass), ("highpass", .highpass), ("bandpass", .bandpass), ("notch", .notch)]
        for (name, type) in types {
            for sections in [1, 2, 8] {
                for hz in [120.0, 700.0, 1_000.0, 2_500.0, 9_000.0] {
                    let expected = FrequencyResponse.filterDecibels(type: name, cutoff: 1_000, q: 4, sections: sections, at: hz)
                    guard expected > -80 else { continue }
                    let input = sine(frequency: hz, frames: 48_000, amplitude: 0.4)
                    var output = [Float](repeating: 0, count: input.count)
                    var state = bake.dsp.FilterState()
                    input.withUnsafeBufferPointer { source in
                        output.withUnsafeMutableBufferPointer { destination in
                            bake.dsp.renderFilter(
                                &state, type, Int32(sections), signal(1_000, 20, 20_000), signal(4, 0.1, 20), signal(0, 0, 24), 48_000,
                                source.baseAddress!, destination.baseAddress!, 0, input.count
                            )
                        }
                    }
                    #expect(abs(measuredDecibels(input, output) - expected) < 0.1, "\(name) x\(sections) at \(hz) Hz")
                }
            }
        }
    }

    @Test func phaserResponseMatchesTheRealPhaser() {
        for stages in [2, 4, 24, 64] {
            for feedback in [-0.8, 0.0, 0.6] {
                for mix in [0.5, 1.0] {
                    for hz in [150.0, 900.0, 5_000.0] {
                        let expected = FrequencyResponse.phaserDecibels(center: 700, width: 2, stages: stages, feedback: feedback, mix: mix, at: hz)
                        let input = sine(frequency: hz, frames: 96_000, amplitude: 0.3)
                        var output = [Float](repeating: 0, count: input.count)
                        var state = bake.dsp.PhaserState()
                        input.withUnsafeBufferPointer { source in
                            output.withUnsafeMutableBufferPointer { destination in
                                bake.dsp.renderPhaser(
                                    &state, .mono, Int32(stages), signal(700, 80, 8_000), signal(2, 0.25, 4), signal(0.3, 0.05, 5), signal(0, 0, 1),
                                    signal(Float(feedback), -0.95, 0.95), signal(Float(mix), 0, 1), 48_000, 0.25,
                                    source.baseAddress!, destination.baseAddress!, 0, input.count
                                )
                            }
                        }
                        #expect(abs(measuredDecibels(input, output) - expected) < 0.2, "x\(stages) fb \(feedback) mix \(mix) at \(hz) Hz")
                    }
                }
            }
        }
    }
}
