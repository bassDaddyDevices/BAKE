import BakeDSP
import BakeGraph

/// Math node: a mono control signal from `a`, `b`, the operator, and Scale.
final class MathProcessor: StepProcessor {
    private let op: bake.dsp.MathOperator
    private let operatorIndex: bake.dsp.ParameterSignal
    private let scale: bake.dsp.ParameterSignal
    private let minimum: bake.dsp.ParameterSignal
    private let maximum: bake.dsp.ParameterSignal
    private let a: bake.dsp.ControlInput
    private let b: bake.dsp.ControlInput
    private let output: UnsafeMutableBufferPointer<Float>

    init(step: RenderStep, pool: BufferPool) throws {
        guard let binding = step.outputs["out"] else { throw RenderError.unsupportedNode(step.kind) }
        var name = "add"
        if case .choice(let value)? = step.parameters["operator"] { name = value }
        switch name {
        case "subtract": op = .subtract
        case "multiply": op = .multiply
        case "divide": op = .divide
        case "abs": op = .absolute
        case "invert": op = .invert
        case "modulo": op = .modulo
        default: op = .add
        }
        scale = bake.dsp.ParameterSignal("scale", of: step, pool: pool)
        operatorIndex = bake.dsp.ParameterSignal("operator", of: step, pool: pool)
        minimum = bake.dsp.ParameterSignal("clampMin", of: step, pool: pool)
        maximum = bake.dsp.ParameterSignal("clampMax", of: step, pool: pool)
        a = bake.dsp.ControlInput("a", of: step, pool: pool, unwired: 0)
        b = bake.dsp.ControlInput("b", of: step, pool: pool, unwired: 0)
        output = pool.channel(0, of: binding)
    }

    func process(frames: Range<Int>) async throws {
        guard let base = output.baseAddress else { return }
        bake.dsp.renderMath(op, operatorIndex, a, b, scale, minimum, maximum, base + frames.lowerBound, frames.lowerBound, frames.count)
    }

    func finish() throws -> PendingOutput? { nil }

    func discard() {}
}
