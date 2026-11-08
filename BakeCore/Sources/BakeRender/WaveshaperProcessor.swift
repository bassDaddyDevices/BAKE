import BakeDSP
import BakeGraph

/// Waveshaper node on the CPU engine. Stateless per chunk; reads the whole input channel so the
/// oversampling filter sees across chunk boundaries. Pieces run across the cores (bit-identical at any count).
final class WaveshaperProcessor: StepProcessor {
    private let curve: bake.dsp.WaveshaperCurve
    private let curveIndex: bake.dsp.ParameterSignal
    private let oversampling: Int32
    private let intensity: bake.dsp.ParameterSignal
    private let bias: bake.dsp.ParameterSignal
    private let mix: bake.dsp.ParameterSignal
    private let inputs: [UnsafeMutableBufferPointer<Float>]
    private let outputs: [UnsafeMutableBufferPointer<Float>]
    private let plan: PiecePlan

    init(step: RenderStep, pool: BufferPool, maxChunkFrames: Int, workers: Int = Parallel.coreCount) throws {
        guard let input = step.inputs["in"], let output = step.outputs["out"] else {
            throw RenderError.unsupportedNode(step.kind)
        }
        // A document without these settings is an older one: plain tanh at the sample rate.
        var curveName = "tanh"
        if case .choice(let value)? = step.parameters["curve"] { curveName = value }
        curve = Self.curve(named: curveName)
        curveIndex = bake.dsp.ParameterSignal("curve", of: step, pool: pool)
        var factor = "1"
        if case .choice(let value)? = step.parameters["oversampling"] { factor = value }
        oversampling = Int32(factor) ?? 1
        intensity = bake.dsp.ParameterSignal("intensity", of: step, pool: pool)
        bias = bake.dsp.ParameterSignal("bias", of: step, pool: pool)
        mix = bake.dsp.ParameterSignal("mix", of: step, pool: pool)
        inputs = (0..<input.shape.channels).map { pool.channel($0, of: input) }
        outputs = (0..<output.shape.channels).map { pool.channel($0, of: output) }
        let levels = oversampling
        plan = PiecePlan(channels: output.shape.channels, maxChunkFrames: maxChunkFrames, workers: workers) {
            bake.dsp.waveshaperScratchFloats(levels, $0)
        }
    }

    static func curve(named name: String) -> bake.dsp.WaveshaperCurve {
        switch name {
        case "arctan": .arctan
        case "softsign": .softsign
        case "sine": .sine
        case "cubic": .cubic
        case "hardClip": .hardClip
        case "asymmetric": .asymmetric
        case "chebyshev": .chebyshev
        default: .tanh
        }
    }

    func process(frames: Range<Int>) async throws {
        plan.run(channels: outputs.count, frames: frames) { channel, piece, work in
            guard let source = inputs[channel].baseAddress, let destination = outputs[channel].baseAddress else { return }
            bake.dsp.renderWaveshaperCurve(
                curve, curveIndex, oversampling, intensity, bias, mix, source, inputs[channel].count,
                destination + piece.lowerBound, piece.lowerBound, piece.count, work
            )
        }
    }

    func finish() throws -> PendingOutput? { nil }

    func discard() {}
}
