import BakeDSP
import BakeGPU
import BakeGraph
import Metal

/// Resonator node on the GPU engine. Reads and writes pool buffers directly — no copies.
final class ResonatorProcessor: StepProcessor {
    private let kernel: ResonatorKernel
    private let input: any MTLBuffer
    private let inputStride: Int
    private let output: any MTLBuffer
    private let outputStride: Int

    init(step: RenderStep, sampleRate: Double, gpu: GPUContext, pool: BufferPool) throws {
        guard let inputBinding = step.inputs["in"], let outputBinding = step.outputs["out"] else {
            throw RenderError.unsupportedNode(step.kind)
        }
        func number(_ id: ParameterID, _ fallback: Double) -> Double {
            step.parameters[id]?.numberValue ?? fallback
        }
        let settings = ResonatorSettings(
            rootHz: number("root", 110),
            fineCents: number("fine", 0),
            decaySeconds: number("decay", 2),
            inharmonicity: number("inharmonicity", 0),
            bands: Int(number("bands", 64).rounded()),
            damping: number("damping", 0.2),
            saturation: number("saturation", 0),
            mix: number("mix", 0.5)
        )
        // Root, Fine, Decay, Inharmonicity and Mix can be modulated: then the GPU retunes every 64 frames.
        // Unmodulated controls keep their exact knob values.
        let signals = ["root", "fine", "decay", "inharmonicity", "mix"].map { bake.dsp.ParameterSignal($0, of: step, pool: pool) }
        var modulation: ResonatorModulation?
        if signals.contains(where: { $0.modulation != nil }) {
            func value(_ index: Int, _ exact: Double, _ frame: Int) -> Double {
                signals[index].modulation == nil ? exact : Double(signals[index].valueAt(frame))
            }
            modulation = ResonatorModulation { frame in
                var moved = settings
                moved.rootHz = value(0, settings.rootHz, frame)
                moved.fineCents = value(1, settings.fineCents, frame)
                moved.decaySeconds = max(value(2, settings.decaySeconds, frame), 0.01)
                moved.inharmonicity = value(3, settings.inharmonicity, frame)
                moved.mix = value(4, settings.mix, frame)
                return moved
            }
        }
        do {
            kernel = try ResonatorKernel(
                gpu: gpu, settings: settings, sampleRate: sampleRate, channels: outputBinding.shape.channels, modulation: modulation
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
