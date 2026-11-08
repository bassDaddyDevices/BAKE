import BakeDSP
import BakeGraph

/// LFO node on the CPU engine: writes a mono control signal into its pool buffer.
final class LFOProcessor: StepProcessor {
    private var state = bake.dsp.LFOState()
    private let shape: bake.dsp.LFOShape
    private let shapeIndex: bake.dsp.ParameterSignal
    private let rate: bake.dsp.ParameterSignal
    private let depth: bake.dsp.ParameterSignal
    /// Modulating Phase is phase modulation; unmodulated, the knob only sets where the cycle starts.
    private let phase: bake.dsp.ParameterSignal
    private let reset: bake.dsp.ControlInput
    private let sampleRate: Double
    private let output: UnsafeMutableBufferPointer<Float>

    init(step: RenderStep, sampleRate: Double, pool: BufferPool) throws {
        guard let binding = step.outputs["out"] else { throw RenderError.unsupportedNode(step.kind) }
        var shapeName = "sine"
        if case .choice(let value)? = step.parameters["shape"] { shapeName = value }
        shape = switch shapeName {
        case "triangle": .triangle
        case "saw": .saw
        case "square": .square
        case "sampleAndHold": .sampleAndHold
        default: .sine
        }
        depth = bake.dsp.ParameterSignal("depth", of: step, pool: pool)
        state.phase = (step.parameters["phase"]?.numberValue ?? 0) / 360
        state.resetPhase = state.phase
        phase = bake.dsp.ParameterSignal("phase", of: step, pool: pool)
        shapeIndex = bake.dsp.ParameterSignal("shape", of: step, pool: pool)
        if case .choice("clock")? = step.parameters["sync"] { state.clockSync = true }
        if case .choice(let cycles)? = step.parameters["cyclesPerBang"] {
            state.cyclesPerBang = switch cycles {
            case "1/4": 0.25
            case "1/2": 0.5
            default: Double(cycles) ?? 1
            }
        }
        state.random = UInt32(step.parameters["seed"]?.numberValue ?? 0)
        reset = bake.dsp.ControlInput("reset", of: step, pool: pool, unwired: 0)
        // The kernel advances `rate / sampleRate` cycles per frame. Over Length passes Cycles as the
        // rate and the LFO's own length in frames as the "sample rate": Cycles cycles across it exactly.
        if case .choice("overLength")? = step.parameters["sync"] {
            rate = bake.dsp.ParameterSignal("cycles", of: step, pool: pool)
            self.sampleRate = Double(max(step.shape.frames, 1))
        } else {
            rate = bake.dsp.ParameterSignal("rate", of: step, pool: pool)
            self.sampleRate = sampleRate
        }
        output = pool.channel(0, of: binding)
    }

    func process(frames: Range<Int>) async throws {
        guard let base = output.baseAddress else { return }
        bake.dsp.renderLFO(&state, shape, shapeIndex, rate, depth, phase, reset, sampleRate, base + frames.lowerBound, frames.lowerBound, frames.count)
    }

    func finish() throws -> PendingOutput? { nil }

    func discard() {}
}
