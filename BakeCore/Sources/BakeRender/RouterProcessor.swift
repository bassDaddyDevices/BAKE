import BakeDSP
import BakeGraph

/// For Each Splitter and Spectral Sorter: every output is a copy of the input. Which outputs a batch's pass
/// goes down is decided before it renders (`BatchRun.offPins`).
final class RouterProcessor: StepProcessor {
    private let input: bake.dsp.AudioInput
    private let outputs: [[UnsafeMutableBufferPointer<Float>]]

    init(step: RenderStep, pool: BufferPool) throws {
        input = bake.dsp.AudioInput("in", of: step, pool: pool)
        outputs = step.outputs.keys.sorted().compactMap { pin in
            step.outputs[pin].map { binding in (0..<binding.shape.channels).map { pool.channel($0, of: binding) } }
        }
    }

    func process(frames: Range<Int>) async throws {
        for output in outputs {
            for (channel, buffer) in output.enumerated() {
                guard let destination = buffer.baseAddress else { continue }
                bake.dsp.copyChannel(input, channel, destination + frames.lowerBound, frames.lowerBound, frames.count)
            }
        }
    }

    func finish() throws -> PendingOutput? { nil }

    func discard() {}
}
