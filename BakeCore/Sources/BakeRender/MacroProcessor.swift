import BakeDSP
import BakeGraph

/// One labelled control generator with up to eight independently shaped outputs.
final class MacroProcessor: StepProcessor {
    private struct Output {
        let curve: bake.dsp.MacroCurve
        let curveIndex: bake.dsp.ParameterSignal
        let depth: bake.dsp.ParameterSignal
        let minimum: bake.dsp.ParameterSignal
        let maximum: bake.dsp.ParameterSignal
        let buffer: UnsafeMutableBufferPointer<Float>
    }

    private let value: bake.dsp.ParameterSignal
    private let outputs: [Output]

    init(step: RenderStep, pool: BufferPool) throws {
        value = bake.dsp.ParameterSignal("value", of: step, pool: pool)
        let outputCount: Int
        if case .choice(let choice)? = step.parameters["outputs"] {
            outputCount = Int(choice) ?? 1
        } else {
            outputCount = 1
        }
        outputs = try (1...outputCount).map { index in
            guard let binding = step.outputs["out\(index)"] else { throw RenderError.unsupportedNode(step.kind) }
            let curveSignal = bake.dsp.ParameterSignal("curve\(index)", of: step, pool: pool)
            let curveName: String
            if case .choice(let choice)? = step.parameters["curve\(index)"] { curveName = choice } else { curveName = "linear" }
            let curve: bake.dsp.MacroCurve = switch curveName {
            case "exponential": .exponential
            case "logarithmic": .logarithmic
            default: .linear
            }
            return Output(
                curve: curve,
                curveIndex: curveSignal,
                depth: bake.dsp.ParameterSignal("depth\(index)", of: step, pool: pool),
                minimum: bake.dsp.ParameterSignal("min\(index)", of: step, pool: pool),
                maximum: bake.dsp.ParameterSignal("max\(index)", of: step, pool: pool),
                buffer: pool.channel(0, of: binding)
            )
        }
    }

    func process(frames: Range<Int>) async throws {
        for output in outputs {
            guard let base = output.buffer.baseAddress else { continue }
            bake.dsp.renderMacro(value, output.curve, output.curveIndex, output.depth, output.minimum, output.maximum,
                                 base + frames.lowerBound, frames.lowerBound, frames.count)
        }
    }

    func finish() throws -> PendingOutput? { nil }

    func discard() {}
}
