import BakeDSP
import BakeGPU
import BakeGraph
import Metal

/// Residual Explosion on the GPU engine. Reads and writes pool buffers directly — no copies.
final class ResidualExplosionProcessor: StepProcessor {
    private let kernel: ResidualExplosionKernel
    private let input: any MTLBuffer
    private let inputStride: Int
    private let output: any MTLBuffer
    private let outputStride: Int

    init(step: RenderStep, gpu: GPUContext, pool: BufferPool) throws {
        guard let inputBinding = step.inputs["in"], let outputBinding = step.outputs["out"] else {
            throw RenderError.unsupportedNode(step.kind)
        }
        func number(_ id: ParameterID, _ fallback: Double) -> Double {
            step.parameters[id]?.numberValue ?? fallback
        }
        var mode = ResidualExplosionMode.collapse
        if case .choice("sparsify")? = step.parameters["mode"] { mode = .sparsify }
        let settings = ResidualExplosionSettings(
            mode: mode, severity: number("severity", 0.5), residualGainDecibels: number("residualGain", 18),
            body: number("body", 1), mix: number("mix", 1)
        )
        // Any modulated control: the CPU fills a per-frame table. Unmodulated controls keep their exact knob values.
        let signals = ["mode", "severity", "residualGain", "body", "mix"].map { bake.dsp.ParameterSignal($0, of: step, pool: pool) }
        var modulation: ResidualExplosionModulation?
        if signals.contains(where: { $0.modulation != nil }) {
            func value(_ index: Int, _ exact: Double, _ frame: Int) -> Double {
                signals[index].modulation == nil ? exact : Double(signals[index].valueAt(frame))
            }
            modulation = ResidualExplosionModulation { frame in
                var moved = settings
                if signals[0].modulation != nil {
                    // A modulated choice moves by option index, nearest option.
                    moved.mode = value(0, 0, frame).rounded() >= 1 ? .sparsify : .collapse
                }
                moved.severity = value(1, settings.severity, frame)
                moved.residualGainDecibels = value(2, settings.residualGainDecibels, frame)
                moved.body = value(3, settings.body, frame)
                moved.mix = value(4, settings.mix, frame)
                return moved
            }
        }
        var factor = "8"
        if case .choice(let value)? = step.parameters["oversampling"] { factor = value }
        do {
            kernel = try ResidualExplosionKernel(
                gpu: gpu, settings: settings, channels: outputBinding.shape.channels,
                oversampling: Int(factor) ?? 8, modulation: modulation
            )
        } catch {
            throw RenderError.gpuUnavailable
        }
        input = pool.metalBuffer(for: inputBinding)
        inputStride = inputBinding.shape.frames
        output = pool.metalBuffer(for: outputBinding)
        outputStride = outputBinding.shape.frames
    }

    func process(frames: Range<Int>) async throws {
        do {
            try await kernel.process(
                input: input, inputChannelStride: inputStride,
                output: output, outputChannelStride: outputStride, frames: frames
            )
        } catch {
            throw RenderError.gpuUnavailable
        }
    }

    func finish() throws -> PendingOutput? { nil }

    func discard() {}
}
