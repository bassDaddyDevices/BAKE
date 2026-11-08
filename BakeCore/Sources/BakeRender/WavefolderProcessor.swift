import BakeDSP
import BakeGraph

/// Wavefolder node on the CPU engine. Stateless per chunk; reads the whole input channel so the
/// oversampling filter sees across chunk boundaries.
final class WavefolderProcessor: StepProcessor {
    private let shape: bake.dsp.WavefolderShape
    private let oversampling: Int32
    private let stages: Int32
    private let saturation: bake.dsp.ParameterSignal
    private let shapeIndex: bake.dsp.ParameterSignal
    private let fold: bake.dsp.ParameterSignal
    private let symmetry: bake.dsp.ParameterSignal
    private let mix: bake.dsp.ParameterSignal
    private let inputs: [UnsafeMutableBufferPointer<Float>]
    private let outputs: [UnsafeMutableBufferPointer<Float>]
    private let plan: PiecePlan

    init(step: RenderStep, pool: BufferPool, maxChunkFrames: Int, workers: Int = Parallel.coreCount) throws {
        guard let input = step.inputs["in"], let output = step.outputs["out"] else {
            throw RenderError.unsupportedNode(step.kind)
        }
        var stageName = "2"
        if case .choice(let value)? = step.parameters["stages"] { stageName = value }
        stages = Int32(stageName) ?? 2
        // A document without these settings is an older one: a triangle fold at the sample rate.
        var shapeName = "triangle"
        if case .choice(let value)? = step.parameters["foldShape"] { shapeName = value }
        shape = shapeName == "sine" ? .sine : .triangle
        var factor = "1"
        if case .choice(let value)? = step.parameters["oversampling"] { factor = value }
        oversampling = Int32(factor) ?? 1
        saturation = bake.dsp.ParameterSignal("saturation", of: step, pool: pool)
        shapeIndex = bake.dsp.ParameterSignal("foldShape", of: step, pool: pool)
        fold = bake.dsp.ParameterSignal("fold", of: step, pool: pool)
        symmetry = bake.dsp.ParameterSignal("symmetry", of: step, pool: pool)
        mix = bake.dsp.ParameterSignal("mix", of: step, pool: pool)
        inputs = (0..<input.shape.channels).map { pool.channel($0, of: input) }
        outputs = (0..<output.shape.channels).map { pool.channel($0, of: output) }
        let levels = oversampling
        plan = PiecePlan(channels: output.shape.channels, maxChunkFrames: maxChunkFrames, workers: workers) {
            bake.dsp.wavefolderScratchFloats(levels, $0)
        }
    }

    func process(frames: Range<Int>) async throws {
        plan.run(channels: outputs.count, frames: frames) { channel, piece, work in
            guard let source = inputs[channel].baseAddress, let destination = outputs[channel].baseAddress else { return }
            bake.dsp.renderWavefolderOversampled(
                shape, shapeIndex, oversampling, fold, symmetry, mix, stages, saturation, source, inputs[channel].count,
                destination + piece.lowerBound, piece.lowerBound, piece.count, work
            )
        }
    }

    func finish() throws -> PendingOutput? { nil }

    func discard() {}
}
