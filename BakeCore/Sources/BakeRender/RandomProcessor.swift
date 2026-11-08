import BakeDSP
import BakeGraph

/// Random node: a mono control signal of seeded random steps, steady or walking, stepped or glided.
final class RandomProcessor: StepProcessor {
    private var state = bake.dsp.RandomState()
    private let settings: bake.dsp.RandomSettings
    private let rate: bake.dsp.ParameterSignal
    private let minimum: bake.dsp.ParameterSignal
    private let maximum: bake.dsp.ParameterSignal
    private let smooth: bake.dsp.ParameterSignal
    private let trigger: bake.dsp.ControlInput
    private let sampleRate: Double
    private let output: UnsafeMutableBufferPointer<Float>

    init(step: RenderStep, sampleRate: Double, pool: BufferPool) throws {
        guard let binding = step.outputs["out"] else { throw RenderError.unsupportedNode(step.kind) }
        var settings = bake.dsp.RandomSettings()
        var modeName = "random"
        if case .choice(let value)? = step.parameters["mode"] { modeName = value }
        settings.mode = modeName == "walk" ? .walk : .random
        var interpolationName = "stepped"
        if case .choice(let value)? = step.parameters["interpolation"] { interpolationName = value }
        settings.interpolation = switch interpolationName {
        case "linear": .linear
        case "cosine": .cosine
        case "cubic": .cubic
        default: .stepped
        }
        var distributionName = "uniform"
        if case .choice(let value)? = step.parameters["distribution"] { distributionName = value }
        settings.distribution = switch distributionName {
        case "gaussian": .gaussian
        case "coin": .coin
        default: .uniform
        }
        settings.seed = UInt32(step.parameters["seed"]?.numberValue ?? 0)
        settings.stepSize = Float(step.parameters["stepSize"]?.numberValue ?? 0.15)
        settings.glideFrames = (step.parameters["glide"]?.numberValue ?? 50) / 1_000 * sampleRate
        self.settings = settings
        rate = bake.dsp.ParameterSignal("rate", of: step, pool: pool)
        minimum = bake.dsp.ParameterSignal("min", of: step, pool: pool)
        maximum = bake.dsp.ParameterSignal("max", of: step, pool: pool)
        smooth = bake.dsp.ParameterSignal("smooth", of: step, pool: pool)
        trigger = bake.dsp.ControlInput("trigger", of: step, pool: pool, unwired: 0)
        self.sampleRate = sampleRate
        output = pool.channel(0, of: binding)
    }

    func process(frames: Range<Int>) async throws {
        guard let base = output.baseAddress else { return }
        bake.dsp.renderRandom(
            &state, settings, rate, minimum, maximum, smooth, trigger, sampleRate, base + frames.lowerBound, frames.lowerBound, frames.count
        )
    }

    func finish() throws -> PendingOutput? { nil }

    func discard() {}
}
