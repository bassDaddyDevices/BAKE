import BakeDSP
import BakeGraph

/// Logic node: a mono 0/1 gate from `a`, `b`, the operator, and Threshold.
final class LogicProcessor: StepProcessor {
    private let op: bake.dsp.LogicOperator
    private var state = bake.dsp.LogicState()
    private let threshold: bake.dsp.ParameterSignal
    private let hysteresis: Float
    private let operatorIndex: bake.dsp.ParameterSignal
    private let hysteresisSignal: bake.dsp.ParameterSignal
    private let holdSeconds: bake.dsp.ParameterSignal
    private let sampleRate: Double
    private let holdFrames: Int
    private let a: bake.dsp.ControlInput
    private let b: bake.dsp.ControlInput
    private let output: UnsafeMutableBufferPointer<Float>

    init(step: RenderStep, sampleRate: Double, pool: BufferPool) throws {
        guard let binding = step.outputs["out"] else { throw RenderError.unsupportedNode(step.kind) }
        var name = "threshold"
        if case .choice(let value)? = step.parameters["operator"] { name = value }
        switch name {
        case "and": op = .andGate
        case "or": op = .orGate
        case "xor": op = .xorGate
        case "not": op = .notGate
        default: op = .threshold
        }
        threshold = bake.dsp.ParameterSignal("threshold", of: step, pool: pool)
        hysteresis = Float(step.parameters["hysteresis"]?.numberValue ?? 0)
        holdFrames = Int(((step.parameters["holdTime"]?.numberValue ?? 0) * sampleRate).rounded())
        hysteresisSignal = bake.dsp.ParameterSignal("hysteresis", of: step, pool: pool)
        holdSeconds = bake.dsp.ParameterSignal("holdTime", of: step, pool: pool)
        self.sampleRate = sampleRate
        operatorIndex = bake.dsp.ParameterSignal("operator", of: step, pool: pool)
        a = bake.dsp.ControlInput("a", of: step, pool: pool, unwired: 0)
        b = bake.dsp.ControlInput("b", of: step, pool: pool, unwired: 0)
        output = pool.channel(0, of: binding)
    }

    func process(frames: Range<Int>) async throws {
        guard let base = output.baseAddress else { return }
        bake.dsp.renderLogic(
            &state, op, operatorIndex, a, b, threshold, hysteresis, holdFrames, hysteresisSignal, holdSeconds, sampleRate,
            base + frames.lowerBound, frames.lowerBound, frames.count
        )
    }

    func finish() throws -> PendingOutput? { nil }

    func discard() {}
}
