import BakeDSP
import BakeGPU
import Foundation
import Testing
@testable import BakeGraph
@testable import BakeRender

/// The remaining card pictures (Distortion, Redux, Envelope, Quantizer, Flanger) must show what the
/// real kernels do, so each plot is checked against the kernel it draws.
struct MorePlotMathTests {
    @Test func theDistortionCurveMatchesTheKernel() {
        let modes: [(String, bake.dsp.DistortionMode)] = [("soft", .soft), ("hard", .hard)]
        for (name, mode) in modes {
            for drive: Float in [0, 12, 36] {
                for ceiling: Float in [0, -12] {
                    for step in -10...10 {
                        var input = Float(step) / 10
                        var output: Float = 0
                        var scratch = [Float](repeating: 0, count: bake.dsp.distortionScratchFloats(1, 1) + 1)
                        bake.dsp.renderDistortion(
                            mode, 1, signal(drive, 0, 48), signal(ceiling, -24, 0), signal(1, 0, 1), &input, 1, &output, 0, 1, &scratch
                        )
                        let plot = DistortionPlot.transfer(mode: name, x: Double(input), driveDecibels: Double(drive), ceilingDecibels: Double(ceiling))
                        #expect(abs(Double(output) - plot) < 1e-5, "\(name) \(drive) dB, ceiling \(ceiling) dB, x \(input)")
                    }
                }
            }
        }
    }

    @Test func theDerivativeDistortionCycleMatchesTheKernel() {
        let plot = DerivativeDistortionPlot.cycle(slopeDrive: 42, curveDrive: 30, edge: 0.5, splay: 0.3)
        let cycle = DerivativeDistortionPlot.samplesPerCycle
        let input = (0..<(4 * cycle)).map { Float(sin(2 * Double.pi * 1_000 * Double($0) / 48_000)) }
        var controls = bake.dsp.DerivativeDistortionControls()
        controls.slopeDrive = signal(42, 0, 72)
        controls.curveDrive = signal(30, 0, 72)
        controls.edge = signal(0.5, -1, 1)
        controls.splay = signal(0.3, -1, 1)
        controls.output = signal(0, -24, 24)
        controls.mix = signal(1, 0, 1)
        controls.sampleRate = 48_000
        controls.oversampling = 1
        var state = bake.dsp.DerivativeDistortionState()
        var output = [Float](repeating: 0, count: input.count)
        var scratch: [Float] = [0]
        var history: [Float] = [0]
        bake.dsp.renderDerivativeDistortion(&state, controls, input, input.count, &output, 0, input.count, &scratch, &history)
        #expect(plot.input.count == cycle)
        #expect(zip(plot.input, input[(3 * cycle)...]).allSatisfy { $0 == Double($1) })
        #expect(zip(plot.output, output[(3 * cycle)...]).allSatisfy { abs($0 - Double($1)) < 1e-4 })
    }

    @Test func theResidualTraceMatchesTheFormula() {
        for mode in ["collapse", "sparsify"] {
            for severity in [0.0, 0.4, 1] {
                for body in [0.0, 1] {
                    let trace = ResidualExplosionPlot.trace(mode: mode, severity: severity, residualGain: 24, body: body)
                    // The kernel's mapping (ResidualExplosionKernel.swift) and formula (ResidualExplosion.metal), in doubles.
                    let levels = pow(2, 15 - 15 * severity)
                    let threshold = pow(10, (-72 + 66 * severity) / 20)
                    let gain = pow(10, 24.0 / 20)
                    #expect(trace.input.count == trace.output.count)
                    for (x, y) in zip(trace.input, trace.output) {
                        let simplified = mode == "sparsify" ? (abs(x) < threshold ? 0 : x) : (x * levels).rounded() / levels
                        #expect(abs(y - (body * simplified + tanh(gain * (x - simplified)))) < 1e-9, "\(mode) \(severity) \(body)")
                    }
                }
            }
        }
    }

    @Test func theReduxTraceMatchesTheKernel() {
        let samples = 128
        let input = (0..<samples).map { Float(sin(2 * Double.pi * 2 * Double($0) / Double(samples)) * 0.9) }
        for bits in [2, 4, 8] {
            for divider in [1, 3, 8] {
                for linear in [false, true] {
                    var state = bake.dsp.ReduxState()
                    var output = [Float](repeating: 0, count: samples)
                    input.withUnsafeBufferPointer { source in
                        output.withUnsafeMutableBufferPointer { destination in
                            bake.dsp.renderRedux(
                                &state, .classic, linear ? .linear : .sampleAndHold, .off, .bitXor, 21_845,
                                signal(Float(bits), 1, 32), signal(Float(divider), 1, 256),
                                signal(1, 0, 1), source.baseAddress!, destination.baseAddress!, 0, samples, 0, 48_000
                            )
                        }
                    }
                    let trace = ReduxPlot.trace(mode: "classic", bits: bits, divider: divider, linear: linear, mask: 21_845, operatorName: "xor", samples: samples)
                    #expect(zip(output, trace.output).allSatisfy { abs(Double($0) - $1) < 1e-6 }, "\(bits) bits ÷\(divider) \(linear ? "linear" : "hold")")
                }
            }
        }
    }

    @Test func theEnvelopeCurveMatchesTheKernel() {
        // 1 kHz sample rate so every stage is a whole number of frames. The gate is held for the plot's own
        // sustain (a quarter of the rest, 225 ms here) and the kernel's first output is one frame into the attack.
        let sampleRate = 1_000.0
        for shape in ["linear", "exponential"] {
            let curve = EnvelopePlot.curve(attack: 0.2, decay: 0.3, sustain: 0.6, release: 0.4, timeScale: 1, shape: shape, points: 1_126)
            #expect(abs(curve.duration - 1.125) < 1e-12)
            let frames = 1_125
            var gate = [Float](repeating: 1, count: frames)
            for index in 725..<frames { gate[index] = 0 }
            var output = [Float](repeating: 0, count: frames)
            var state = bake.dsp.EnvelopeState()
            gate.withUnsafeBufferPointer { gatePointer in
                output.withUnsafeMutableBufferPointer { destination in
                    var trigger = bake.dsp.ControlInput()
                    trigger.samples = gatePointer.baseAddress
                    trigger.frames = gatePointer.count
                    bake.dsp.renderEnvelope(
                        &state, shape == "linear" ? .linear : .exponential, .off, .classic, signal(0.2, 0.001, 10), signal(0.3, 0.001, 10),
                        signal(0.6, 0, 1), signal(0.4, 0.001, 10), signal(1, 0.1, 10), trigger, sampleRate, destination.baseAddress!, 0, frames
                    )
                }
            }
            for index in 0..<frames {
                #expect(abs(Double(output[index]) - curve.levels[index + 1]) < 1e-5, "\(shape) frame \(index)")
            }
        }
    }

    @Test func theQuantizerStairsMatchTheKernel() {
        let scales: [(String, bake.dsp.QuantizerScale)] = [("chromatic", .chromatic), ("major", .major), ("minor", .minor), ("pentatonic", .pentatonic)]
        for (name, scale) in scales {
            for root in [0, 2, 9] {
                for step in -40...40 {
                    let input = Float(step) / 40
                    var output: Float = 0
                    var state = bake.dsp.QuantizerState()
                    var control = bake.dsp.ControlInput()
                    withUnsafePointer(to: input) { pointer in
                        control.samples = pointer
                        control.frames = 1
                        bake.dsp.renderQuantizer(&state, scale, Int32(root), 0, control, &output, 0, 1)
                    }
                    #expect(abs(Double(output) - QuantizerPlot.quantize(scale: name, root: root, x: Double(input))) < 1e-6, "\(name) root \(root) x \(input)")
                }
            }
        }
    }

    @Test func theFlangerResponseMatchesTheRealFlanger() {
        // Fractional delays and both feedback signs; up to 2.5 kHz, and away from deep nulls where both read "silent".
        for delay in [0.37, 4.37, 9.113] {
            for (feedback, negative) in [(0.0, false), (0.5, false), (0.5, true)] {
                for hz in [120.0, 440.0, 1_000.0, 2_500.0] {
                    let expected = FrequencyResponse.flangerDecibels(
                        delayMilliseconds: delay, depth: 0, lfo: 0, feedback: feedback, negativeFeedback: negative, damping: 0.2, mix: 1, at: hz
                    )
                    guard expected > -30 else { continue }
                    let input = sine(frequency: hz, frames: 96_000, amplitude: 0.3)
                    var output = [Float](repeating: 0, count: input.count)
                    let lineFrames = 4_096
                    var line = [Float](repeating: 0, count: lineFrames)
                    var state = bake.dsp.FlangerState()
                    input.withUnsafeBufferPointer { source in
                        output.withUnsafeMutableBufferPointer { destination in
                            bake.dsp.renderFlanger(
                                &state, signal(Float(delay), 0.1, 15), signal(0.25, 0.05, 5), signal(0, 0, 1), signal(Float(feedback), 0, 0.95), signal(1, 0, 1),
                                negative ? .negative : .positive, .cubic, 0.2, 48_000, &line, lineFrames,
                                source.baseAddress!, destination.baseAddress!, 0, input.count
                            )
                        }
                    }
                    var inEnergy = 0.0, outEnergy = 0.0
                    for index in input.count / 2..<input.count {
                        inEnergy += Double(input[index]) * Double(input[index])
                        outEnergy += Double(output[index]) * Double(output[index])
                    }
                    #expect(abs(10 * log10(outEnergy / inEnergy) - expected) < 0.05, "\(delay) ms fb \(feedback)\(negative ? "−" : "") at \(hz) Hz")
                }
            }
        }
    }

    @Test func theMathCurveMatchesTheKernel() {
        let operators: [(String, bake.dsp.MathOperator)] = [
            ("add", .add), ("subtract", .subtract), ("multiply", .multiply), ("divide", .divide),
            ("abs", .absolute), ("invert", .invert), ("modulo", .modulo),
        ]
        let aValues = (-10...10).map { Float($0) / 10 }
        for (name, op) in operators {
            for (b, scale, low, high) in [(Float(0.5), Float(1), Float(-16), Float(16)), (-0.3, 2.5, -1, 1), (0, -4, -16, 16)] {
                var output = [Float](repeating: 0, count: aValues.count)
                let bValues = [Float](repeating: b, count: aValues.count)
                aValues.withUnsafeBufferPointer { aPointer in
                    bValues.withUnsafeBufferPointer { bPointer in
                        output.withUnsafeMutableBufferPointer { destination in
                            var inputA = bake.dsp.ControlInput(), inputB = bake.dsp.ControlInput()
                            inputA.samples = aPointer.baseAddress
                            inputA.frames = aPointer.count
                            inputB.samples = bPointer.baseAddress
                            inputB.frames = bPointer.count
                            bake.dsp.renderMath(op, inputA, inputB, scale, low, high, destination.baseAddress!, 0, aValues.count)
                        }
                    }
                }
                for (index, a) in aValues.enumerated() {
                    let plot = MathPlot.apply(operatorName: name, a: Double(a), b: Double(b), scale: Double(scale), minimum: Double(low), maximum: Double(high))
                    #expect(abs(Double(output[index]) - plot) < 1e-5, "\(name) a \(a) b \(b) scale \(scale)")
                }
            }
        }
    }
}

/// The GPU's oversampling filter must be the CPU's, so oversampled nodes sound alike on both engines.
struct OversamplingFilterParityTests {
    @Test(arguments: [2, 4, 8, 16, 32, 64, 128, 256])
    func gpuTapsMatchTheCPU(factor: Int) {
        var cpu = [Float](repeating: 0, count: 64 * factor + 1)
        bake.dsp.oversampling.designTaps(Int32(factor), &cpu)
        let gpu = OversamplingFilter.taps(factor: factor)
        #expect(gpu.count == cpu.count)
        #expect(zip(gpu, cpu).allSatisfy { abs($0 - $1) < 1e-7 })
    }
}
