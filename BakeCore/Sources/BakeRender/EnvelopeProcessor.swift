import BakeDSP
import BakeGraph

/// Envelope node: writes a mono control signal sized to the longest consumer.
final class EnvelopeProcessor: StepProcessor {
    private var state = bake.dsp.EnvelopeState()
    private let curve: bake.dsp.EnvelopeCurve
    private let loop: bake.dsp.EnvelopeLoop
    private let mode: bake.dsp.EnvelopeTriggerMode
    private let attack: bake.dsp.ParameterSignal
    private let decay: bake.dsp.ParameterSignal
    private let sustain: bake.dsp.ParameterSignal
    private let release: bake.dsp.ParameterSignal
    private let timeScale: bake.dsp.ParameterSignal
    private let trigger: bake.dsp.ControlInput
    /// Set in Repeat mode: an unwired envelope fires every Every ms.
    private let every: bake.dsp.ParameterSignal?
    private let sampleRate: Double
    private let output: UnsafeMutableBufferPointer<Float>

    init(step: RenderStep, sampleRate: Double, pool: BufferPool) throws {
        guard let binding = step.outputs["out"] else {
            throw RenderError.unsupportedNode(step.kind)
        }
        var curveName = "exponential"
        if case .choice(let value)? = step.parameters["curve"] { curveName = value }
        curve = curveName == "linear" ? .linear : .exponential
        var loopName = "off"
        if case .choice(let value)? = step.parameters["loop"] { loopName = value }
        loop = loopName == "attackDecay" ? .attackDecay : .off
        var modeName = "oneShot"
        if case .choice(let value)? = step.parameters["triggerMode"] { modeName = value }
        mode = switch modeName {
        case "gate": .gate
        case "classic": .classic
        default: .oneShot
        }
        attack = bake.dsp.ParameterSignal("attack", of: step, pool: pool)
        decay = bake.dsp.ParameterSignal("decay", of: step, pool: pool)
        sustain = bake.dsp.ParameterSignal("sustain", of: step, pool: pool)
        release = bake.dsp.ParameterSignal("release", of: step, pool: pool)
        timeScale = bake.dsp.ParameterSignal("timeScale", of: step, pool: pool)
        trigger = bake.dsp.ControlInput("trigger", of: step, pool: pool, unwired: 0)
        every = step.parameters["repeat"] == .choice("once") ? nil : bake.dsp.ParameterSignal("every", of: step, pool: pool)
        self.sampleRate = sampleRate
        output = pool.channel(0, of: binding)
    }

    func process(frames: Range<Int>) async throws {
        guard let base = output.baseAddress else { return }
        if var every {
            bake.dsp.renderEnvelope(
                &state, curve, loop, mode, attack, decay, sustain, release, timeScale, trigger, &every,
                sampleRate, base + frames.lowerBound, frames.lowerBound, frames.count
            )
        } else {
            bake.dsp.renderEnvelope(
                &state, curve, loop, mode, attack, decay, sustain, release, timeScale, trigger,
                sampleRate, base + frames.lowerBound, frames.lowerBound, frames.count
            )
        }
    }

    func finish() throws -> PendingOutput? { nil }

    func discard() {}
}
