import BakeDSP
import BakeGraph

/// Mixer: the sum of every wired input (`in1`…`inN`), then the master Gain.
final class MixerProcessor: StepProcessor {
    private let inputs: [bake.dsp.AudioInput]
    private let gain: bake.dsp.ParameterSignal
    private let outputs: [UnsafeMutableBufferPointer<Float>]
    private var pointers: [UnsafeMutablePointer<Float>?]

    init(step: RenderStep, pool: BufferPool) throws {
        guard let output = step.outputs["out"] else { throw RenderError.unsupportedNode(step.kind) }
        // Wired inputs in pin order, so the sum is the same however the document stores its edges.
        let wired = step.inputs.keys.compactMap { pin -> Int? in
            pin.hasPrefix("in") ? Int(pin.dropFirst(2)) : nil
        }.sorted()
        inputs = wired.map { bake.dsp.AudioInput("in\($0)", of: step, pool: pool) }
        gain = bake.dsp.ParameterSignal("gain", of: step, pool: pool)
        outputs = (0..<output.shape.channels).map { pool.channel($0, of: output) }
        pointers = Array(repeating: nil, count: outputs.count)
    }

    func process(frames: Range<Int>) async throws {
        for channel in outputs.indices {
            pointers[channel] = outputs[channel].baseAddress.map { $0 + frames.lowerBound }
        }
        inputs.withUnsafeBufferPointer { inputs in
            pointers.withUnsafeBufferPointer { outputs in
                guard let outputBase = outputs.baseAddress else { return }
                bake.dsp.mixInputs(
                    inputs.baseAddress, inputs.count, gain, outputBase, outputs.count, frames.lowerBound, frames.count
                )
            }
        }
    }

    func finish() throws -> PendingOutput? { nil }

    func discard() {}
}
