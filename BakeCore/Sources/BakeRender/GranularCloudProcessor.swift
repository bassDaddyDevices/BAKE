import BakeDSP
import BakeGraph

/// Granular Cloud on the CPU engine. Stateless: every chunk recomputes the grains that overlap it from
/// the whole input channel. Each grain's samples are summed in slot order whatever the piece, so frame-range
/// pieces run across the cores and give the same bits.
final class GranularCloudProcessor: StepProcessor {
    private let controls: bake.dsp.GranularCloudControls
    private let inputs: [UnsafeMutableBufferPointer<Float>]
    private let outputs: [UnsafeMutableBufferPointer<Float>]
    private let plan: PiecePlan

    init(step: RenderStep, sampleRate: Double, pool: BufferPool, maxChunkFrames: Int = 65_536, workers: Int = Parallel.coreCount) throws {
        guard let input = step.inputs["in"], let output = step.outputs["out"] else {
            throw RenderError.unsupportedNode(step.kind)
        }
        var controls = bake.dsp.GranularCloudControls()
        controls.size = bake.dsp.ParameterSignal("size", of: step, pool: pool)
        controls.density = bake.dsp.ParameterSignal("density", of: step, pool: pool)
        controls.spray = bake.dsp.ParameterSignal("spray", of: step, pool: pool)
        controls.pitchSpread = bake.dsp.ParameterSignal("pitchSpread", of: step, pool: pool)
        controls.mix = bake.dsp.ParameterSignal("mix", of: step, pool: pool)
        controls.pitch = bake.dsp.ParameterSignal("pitch", of: step, pool: pool)
        controls.reverse = bake.dsp.ParameterSignal("reverse", of: step, pool: pool)
        controls.stereoSpread = bake.dsp.ParameterSignal("stereoSpread", of: step, pool: pool)
        controls.seed = UInt64(max(step.parameters["seed"]?.numberValue ?? 1, 0).rounded())
        controls.sampleRate = sampleRate
        self.controls = controls
        inputs = (0..<input.shape.channels).map { pool.channel($0, of: input) }
        outputs = (0..<output.shape.channels).map { pool.channel($0, of: output) }
        plan = PiecePlan(channels: output.shape.channels, maxChunkFrames: maxChunkFrames, workers: workers)
    }

    func process(frames: Range<Int>) async throws {
        plan.run(channels: outputs.count, frames: frames) { channel, piece, _ in
            // A mono input feeds every output channel.
            let source = inputs[min(channel, inputs.count - 1)]
            guard let input = source.baseAddress, let destination = outputs[channel].baseAddress else { return }
            bake.dsp.renderGranularCloud(
                controls, input, source.count, channel, outputs.count,
                destination + piece.lowerBound, piece.lowerBound, piece.count
            )
        }
    }

    func finish() throws -> PendingOutput? { nil }

    func discard() {}
}
