import BakeDSP
import BakeGraph

/// Distortion node on the CPU engine. Stateless per chunk; reads the whole input channel. Each chunk is cut
/// into pieces per channel that run across the cores: the kernel is stateless, so every piece gives the same
/// bits whatever the thread count (`ParallelTests` proves it).
final class DistortionProcessor: StepProcessor {
    private let mode: bake.dsp.DistortionMode
    private let modeIndex: bake.dsp.ParameterSignal
    private let oversampling: Int32
    private let drive: bake.dsp.ParameterSignal
    private let ceiling: bake.dsp.ParameterSignal
    private let mix: bake.dsp.ParameterSignal
    private let inputs: [UnsafeMutableBufferPointer<Float>]
    private let outputs: [UnsafeMutableBufferPointer<Float>]
    private let plan: PiecePlan

    init(step: RenderStep, pool: BufferPool, maxChunkFrames: Int, workers: Int = Parallel.coreCount) throws {
        guard let input = step.inputs["in"], let output = step.outputs["out"] else {
            throw RenderError.unsupportedNode(step.kind)
        }
        var modeName = "soft"
        if case .choice(let value)? = step.parameters["mode"] { modeName = value }
        mode = modeName == "hard" ? .hard : .soft
        modeIndex = bake.dsp.ParameterSignal("mode", of: step, pool: pool)
        var factor = "8"
        if case .choice(let value)? = step.parameters["oversampling"] { factor = value }
        oversampling = Int32(factor) ?? 8
        drive = bake.dsp.ParameterSignal("drive", of: step, pool: pool)
        ceiling = bake.dsp.ParameterSignal("ceiling", of: step, pool: pool)
        mix = bake.dsp.ParameterSignal("mix", of: step, pool: pool)
        inputs = (0..<input.shape.channels).map { pool.channel($0, of: input) }
        outputs = (0..<output.shape.channels).map { pool.channel($0, of: output) }
        let levels = oversampling
        plan = PiecePlan(channels: output.shape.channels, maxChunkFrames: maxChunkFrames, workers: workers) {
            bake.dsp.distortionScratchFloats(levels, $0)
        }
    }

    func process(frames: Range<Int>) async throws {
        plan.run(channels: outputs.count, frames: frames) { channel, piece, work in
            guard let source = inputs[channel].baseAddress, let destination = outputs[channel].baseAddress else { return }
            bake.dsp.renderDistortion(
                mode, modeIndex, oversampling, drive, ceiling, mix, source, inputs[channel].count,
                destination + piece.lowerBound, piece.lowerBound, piece.count, work
            )
        }
    }

    func finish() throws -> PendingOutput? { nil }

    func discard() {}
}
