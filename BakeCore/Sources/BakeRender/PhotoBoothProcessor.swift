import BakeDSP
import BakeGraph

/// Photo Booth outside a batch's passes (where it plays a chunk as Audio): it passes its input through. While a
/// bake captures it, its output's first channel carries its trigger instead (its grid's bangs when Trigger is
/// unwired), so a hidden Bake can record where the chunks start.
final class PhotoBoothProcessor: StepProcessor {
    private let input: bake.dsp.AudioInput
    private let trigger: bake.dsp.ControlInput
    private let outputs: [UnsafeMutableBufferPointer<Float>]
    private let capturing: Bool
    private let period: Double

    init(step: RenderStep, sampleRate: Double, pool: BufferPool) throws {
        guard let output = step.outputs["out"] else { throw RenderError.unsupportedNode(step.kind) }
        input = bake.dsp.AudioInput("in", of: step, pool: pool)
        trigger = bake.dsp.ControlInput("trigger", of: step, pool: pool)
        outputs = (0..<output.shape.channels).map { pool.channel($0, of: output) }
        capturing = step.parameters["capture"] == .choice("on")
        period = PhotoBoothChunks.period(step.parameters, sampleRate: sampleRate)
    }

    func process(frames: Range<Int>) async throws {
        for (channel, buffer) in outputs.enumerated() {
            guard let destination = buffer.baseAddress else { continue }
            guard capturing else {
                bake.dsp.copyChannel(input, channel, destination + frames.lowerBound, frames.lowerBound, frames.count)
                continue
            }
            for frame in frames {
                let value: Float = if channel > 0 {
                    0
                } else if trigger.isWired() {
                    trigger.valueAt(frame)
                } else {
                    PhotoBoothChunks.isGridBang(frame, period: period) ? 1 : 0
                }
                destination[frame] = value
            }
        }
    }

    func finish() throws -> PendingOutput? { nil }

    func discard() {}
}
