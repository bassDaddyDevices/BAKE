import BakeDSP
import BakeGraph

/// Generator node: noise colours, dust, velvet, an impulse train or silence, one independent stream per channel.
final class GeneratorProcessor: StepProcessor {
    private var states: [bake.dsp.GeneratorState]
    private let settings: bake.dsp.GeneratorSettings
    private let level: bake.dsp.ParameterSignal
    private let density: bake.dsp.ParameterSignal
    private let sampleRate: Double
    private let outputs: [UnsafeMutableBufferPointer<Float>]

    init(step: RenderStep, sampleRate: Double, pool: BufferPool) throws {
        guard let binding = step.outputs["out"] else { throw RenderError.unsupportedNode(step.kind) }
        var settings = bake.dsp.GeneratorSettings()
        var typeName = "white"
        if case .choice(let value)? = step.parameters["type"] { typeName = value }
        settings.type = switch typeName {
        case "pink": .pink
        case "brown": .brown
        case "blue": .blue
        case "violet": .violet
        case "dust": .dust
        case "velvet": .velvet
        case "impulse": .impulse
        case "silence": .silence
        default: .white
        }
        settings.seed = UInt32(step.parameters["seed"]?.numberValue ?? 0)
        self.settings = settings
        level = bake.dsp.ParameterSignal("level", of: step, pool: pool)
        density = bake.dsp.ParameterSignal("density", of: step, pool: pool)
        self.sampleRate = sampleRate
        outputs = (0..<binding.shape.channels).map { pool.channel($0, of: binding) }
        states = Array(repeating: bake.dsp.GeneratorState(), count: outputs.count)
    }

    func process(frames: Range<Int>) async throws {
        for channel in outputs.indices {
            guard let base = outputs[channel].baseAddress else { continue }
            bake.dsp.renderGenerator(
                &states[channel], settings, Int32(channel), level, density, sampleRate, base + frames.lowerBound, frames.lowerBound, frames.count
            )
        }
    }

    func finish() throws -> PendingOutput? { nil }

    func discard() {}
}
