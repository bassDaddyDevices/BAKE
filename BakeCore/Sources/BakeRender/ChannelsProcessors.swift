import BakeDSP
import BakeGraph

/// Channel Splitter: output `outN` (mono) carries channel N of the input.
final class ChannelSplitterProcessor: StepProcessor {
    private let input: bake.dsp.AudioInput
    /// Channel index → its mono output buffer, for the outputs this plan uses.
    private let outputs: [(channel: Int, buffer: UnsafeMutableBufferPointer<Float>)]

    init(step: RenderStep, pool: BufferPool) throws {
        input = bake.dsp.AudioInput("in", of: step, pool: pool)
        outputs = step.outputs.compactMap { pin, binding in
            guard pin.hasPrefix("out"), let number = Int(pin.dropFirst(3)), number >= 1 else { return nil }
            return (number - 1, pool.channel(0, of: binding))
        }
    }

    func process(frames: Range<Int>) async throws {
        for output in outputs {
            guard let destination = output.buffer.baseAddress else { continue }
            bake.dsp.copyChannel(input, output.channel, destination + frames.lowerBound, frames.lowerBound, frames.count)
        }
    }

    func finish() throws -> PendingOutput? { nil }

    func discard() {}
}

/// Channel Merger: the first channel of input `inN` becomes output channel N; unwired inputs are silent.
final class ChannelMergerProcessor: StepProcessor {
    private let inputs: [bake.dsp.AudioInput]
    private let outputs: [UnsafeMutableBufferPointer<Float>]

    init(step: RenderStep, pool: BufferPool) throws {
        guard let output = step.outputs["out"] else { throw RenderError.unsupportedNode(step.kind) }
        outputs = (0..<output.shape.channels).map { pool.channel($0, of: output) }
        inputs = (0..<output.shape.channels).map { bake.dsp.AudioInput("in\($0 + 1)", of: step, pool: pool) }
    }

    func process(frames: Range<Int>) async throws {
        for channel in outputs.indices {
            guard let destination = outputs[channel].baseAddress else { continue }
            bake.dsp.copyChannel(inputs[channel], 0, destination + frames.lowerBound, frames.lowerBound, frames.count)
        }
    }

    func finish() throws -> PendingOutput? { nil }

    func discard() {}
}
