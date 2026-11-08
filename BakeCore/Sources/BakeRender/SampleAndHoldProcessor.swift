import BakeDSP
import BakeGraph

/// Sample & Hold node: a signal (control, else audio) sampled on each bang, or at Rate, and held as a control signal.
final class SampleAndHoldProcessor: StepProcessor {
    private var state = bake.dsp.SampleAndHoldState()
    private let mode: bake.dsp.SampleAndHoldMode
    private let audio: bake.dsp.AudioInput
    private let signal: bake.dsp.ControlInput
    private let trigger: bake.dsp.ControlInput
    private let rate: bake.dsp.ParameterSignal
    private let glide: bake.dsp.ParameterSignal
    private let sampleRate: Double
    private let output: UnsafeMutableBufferPointer<Float>

    init(step: RenderStep, sampleRate: Double, pool: BufferPool) throws {
        guard let binding = step.outputs["out"] else { throw RenderError.unsupportedNode(step.kind) }
        var modeName = "hold"
        if case .choice(let value)? = step.parameters["mode"] { modeName = value }
        mode = modeName == "trackAndHold" ? .trackAndHold : .hold
        audio = bake.dsp.AudioInput("in", of: step, pool: pool)
        signal = bake.dsp.ControlInput("signal", of: step, pool: pool, unwired: 0)
        trigger = bake.dsp.ControlInput("trigger", of: step, pool: pool, unwired: 0)
        rate = bake.dsp.ParameterSignal("rate", of: step, pool: pool)
        glide = bake.dsp.ParameterSignal("glide", of: step, pool: pool)
        self.sampleRate = sampleRate
        output = pool.channel(0, of: binding)
    }

    func process(frames: Range<Int>) async throws {
        guard let base = output.baseAddress else { return }
        bake.dsp.renderSampleAndHold(
            &state, mode, audio, signal, trigger, rate, glide, sampleRate, base + frames.lowerBound, frames.lowerBound, frames.count
        )
    }

    func finish() throws -> PendingOutput? { nil }

    func discard() {}
}
