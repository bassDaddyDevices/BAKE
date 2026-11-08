import BakeDSP
import BakeGraph

/// Converts the loudest input channel into a mono, smoothed control envelope.
final class EnvelopeFollowerProcessor: StepProcessor {
    private var state = bake.dsp.EnvelopeFollowerState()
    private let detection: bake.dsp.EnvelopeFollowerDetection
    private let input: bake.dsp.AudioInput
    private let attack: bake.dsp.ParameterSignal
    private let release: bake.dsp.ParameterSignal
    private let gain: bake.dsp.ParameterSignal
    private let sampleRate: Double
    private let output: UnsafeMutableBufferPointer<Float>

    init(step: RenderStep, sampleRate: Double, pool: BufferPool) throws {
        guard let binding = step.outputs["out"] else {
            throw RenderError.unsupportedNode(step.kind)
        }
        detection = step.parameters["detection"] == .choice("rms") ? .rms : .peak
        input = bake.dsp.AudioInput("in", of: step, pool: pool)
        attack = bake.dsp.ParameterSignal("attack", of: step, pool: pool)
        release = bake.dsp.ParameterSignal("release", of: step, pool: pool)
        gain = bake.dsp.ParameterSignal("gain", of: step, pool: pool)
        self.sampleRate = sampleRate
        output = pool.channel(0, of: binding)
    }

    func process(frames: Range<Int>) async throws {
        guard let base = output.baseAddress else { return }
        bake.dsp.renderEnvelopeFollower(
            &state, detection, input, attack, release, gain, sampleRate,
            base + frames.lowerBound, frames.lowerBound, frames.count
        )
    }

    func finish() throws -> PendingOutput? { nil }

    func discard() {}
}
