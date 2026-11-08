import BakeDSP
import BakeGraph

/// Reverse node on the CPU engine. Reads the entire input buffer and writes requested output frames.
final class ReverseProcessor: StepProcessor {
    private let mix: bake.dsp.ParameterSignal
    private let inputs: [UnsafeMutableBufferPointer<Float>]
    private let outputs: [UnsafeMutableBufferPointer<Float>]

    init(step: RenderStep, pool: BufferPool) throws {
        guard let input = step.inputs["in"], let output = step.outputs["out"] else {
            throw RenderError.unsupportedNode(step.kind)
        }
        mix = bake.dsp.ParameterSignal("mix", of: step, pool: pool)
        inputs = (0..<input.shape.channels).map { pool.channel($0, of: input) }
        outputs = (0..<output.shape.channels).map { pool.channel($0, of: output) }
    }

    func process(frames: Range<Int>) async throws {
        for channel in outputs.indices {
            guard let source = inputs[channel].baseAddress, let destination = outputs[channel].baseAddress else { continue }
            bake.dsp.renderReverse(
                source, inputs[channel].count, destination + frames.lowerBound,
                frames.lowerBound, frames.count, mix
            )
        }
    }

    func finish() throws -> PendingOutput? { nil }

    func discard() {}
}
