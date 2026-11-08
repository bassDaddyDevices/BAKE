import BakeDSP
import BakeGraph

/// Feedback node: `in` plus its delayed, filtered, driven and saturated return, on `out` and `send` alike.
final class FeedbackProcessor: StepProcessor {
    private let input: bake.dsp.AudioInput
    private let returned: bake.dsp.AudioInput
    /// Rendered into: `out`'s channels, or `send`'s when only Send is wired.
    private let outputs: [UnsafeMutableBufferPointer<Float>]
    /// The other output's channels when both are wired; a copy of `outputs`.
    private let copies: [UnsafeMutableBufferPointer<Float>]
    private var states: [bake.dsp.FeedbackState]
    private let gain: bake.dsp.ParameterSignal
    private let drive: bake.dsp.ParameterSignal
    private let modeIndex: bake.dsp.ParameterSignal
    private let fixedMode: bake.dsp.FeedbackMode
    private let lowCut: bake.dsp.ParameterSignal
    private let highCut: bake.dsp.ParameterSignal
    private let sampleRate: Double
    private let delayFrames: Int

    init(step: RenderStep, sampleRate: Double, pool: BufferPool) throws {
        guard let output = step.outputs["out"] ?? step.outputs["send"] else { throw RenderError.unsupportedNode(step.kind) }
        input = bake.dsp.AudioInput("in", of: step, pool: pool)
        returned = bake.dsp.AudioInput("return", of: step, pool: pool)
        outputs = (0..<output.shape.channels).map { pool.channel($0, of: output) }
        let copy = step.outputs["out"] == nil ? nil : step.outputs["send"]
        copies = copy.map { copy in (0..<copy.shape.channels).map { pool.channel($0, of: copy) } } ?? []
        states = Array(repeating: bake.dsp.FeedbackState(), count: output.shape.channels)
        gain = bake.dsp.ParameterSignal("gain", of: step, pool: pool)
        drive = bake.dsp.ParameterSignal("drive", of: step, pool: pool)
        modeIndex = bake.dsp.ParameterSignal("mode", of: step, pool: pool)
        switch step.parameters["mode"] {
        case .choice("tape"): fixedMode = .tape
        case .choice("hard"): fixedMode = .hard
        case .choice("crush"): fixedMode = .crush
        default: fixedMode = .tanh
        }
        lowCut = bake.dsp.ParameterSignal("lowCut", of: step, pool: pool)
        highCut = bake.dsp.ParameterSignal("highCut", of: step, pool: pool)
        self.sampleRate = sampleRate
        let milliseconds = step.parameters["delay"]?.numberValue ?? 10
        delayFrames = max(1, Int((milliseconds * 0.001 * sampleRate).rounded()))
    }

    func process(frames: Range<Int>) async throws {
        for channel in outputs.indices {
            guard let destination = outputs[channel].baseAddress else { continue }
            bake.dsp.renderFeedback(
                &states[channel], input, returned, Int32(channel), fixedMode, gain, drive, modeIndex,
                lowCut, highCut, sampleRate, Int32(delayFrames), destination + frames.lowerBound,
                Int32(frames.lowerBound), Int32(frames.count)
            )
            if channel < copies.count {
                for frame in frames { copies[channel][frame] = outputs[channel][frame] }
            }
        }
    }

    func finish() throws -> PendingOutput? { nil }

    func discard() {}
}
