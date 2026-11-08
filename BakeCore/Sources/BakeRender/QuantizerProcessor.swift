import BakeDSP
import BakeGraph

/// Quantizer node: a mono control signal snapped to the notes of a scale.
final class QuantizerProcessor: StepProcessor {
    private var state = bake.dsp.QuantizerState()
    private let glideFrames: Double
    private let glideSeconds: bake.dsp.ParameterSignal
    private let sampleRate: Double
    private let scale: bake.dsp.QuantizerScale
    private let root: Int32
    private let scaleIndex: bake.dsp.ParameterSignal
    private let rootIndex: bake.dsp.ParameterSignal
    private let input: bake.dsp.ControlInput
    private let output: UnsafeMutableBufferPointer<Float>

    init(step: RenderStep, sampleRate: Double, pool: BufferPool) throws {
        guard let binding = step.outputs["out"] else { throw RenderError.unsupportedNode(step.kind) }
        var name = "chromatic"
        if case .choice(let value)? = step.parameters["scale"] { name = value }
        switch name {
        case "major": scale = .major
        case "minor": scale = .minor
        case "pentatonic": scale = .pentatonic
        default: scale = .chromatic
        }
        var rootName = "0"
        if case .choice(let value)? = step.parameters["root"] { rootName = value }
        root = Int32(rootName) ?? 0
        scaleIndex = bake.dsp.ParameterSignal("scale", of: step, pool: pool)
        rootIndex = bake.dsp.ParameterSignal("root", of: step, pool: pool)
        glideFrames = (step.parameters["glide"]?.numberValue ?? 0) * sampleRate
        glideSeconds = bake.dsp.ParameterSignal("glide", of: step, pool: pool)
        self.sampleRate = sampleRate
        input = bake.dsp.ControlInput("in", of: step, pool: pool, unwired: 0)
        output = pool.channel(0, of: binding)
    }

    func process(frames: Range<Int>) async throws {
        guard let base = output.baseAddress else { return }
        bake.dsp.renderQuantizer(
            &state, scale, scaleIndex, root, rootIndex, glideFrames, glideSeconds, sampleRate, input, base + frames.lowerBound, frames.lowerBound, frames.count
        )
    }

    func finish() throws -> PendingOutput? { nil }

    func discard() {}
}
