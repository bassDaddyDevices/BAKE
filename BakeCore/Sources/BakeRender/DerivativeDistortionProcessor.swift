import BakeDSP
import BakeGraph

/// Derivative Distortion on the CPU engine. Each channel carries its own loop state and oversampler
/// history, so chunks must arrive in order (they do). Channels never share state, so they run in parallel with identical bits.
final class DerivativeDistortionProcessor: StepProcessor {
    private let controls: bake.dsp.DerivativeDistortionControls
    private let inputs: [UnsafeMutableBufferPointer<Float>]
    private let outputs: [UnsafeMutableBufferPointer<Float>]
    /// One loop state, oversampler history and scratch per channel, allocated once; channels run on separate threads.
    private let channelState: ChannelStates<bake.dsp.DerivativeDistortionState>
    private let workers: Int

    init(step: RenderStep, sampleRate: Double, pool: BufferPool, maxChunkFrames: Int, workers: Int = Parallel.coreCount) throws {
        guard let input = step.inputs["in"], let output = step.outputs["out"] else {
            throw RenderError.unsupportedNode(step.kind)
        }
        var controls = bake.dsp.DerivativeDistortionControls()
        controls.slopeDrive = bake.dsp.ParameterSignal("slopeDrive", of: step, pool: pool)
        controls.curveDrive = bake.dsp.ParameterSignal("curveDrive", of: step, pool: pool)
        controls.edge = bake.dsp.ParameterSignal("edge", of: step, pool: pool)
        controls.splay = bake.dsp.ParameterSignal("splay", of: step, pool: pool)
        controls.output = bake.dsp.ParameterSignal("output", of: step, pool: pool)
        controls.mix = bake.dsp.ParameterSignal("mix", of: step, pool: pool)
        controls.sampleRate = sampleRate
        var factor = "8"
        if case .choice(let value)? = step.parameters["oversampling"] { factor = value }
        controls.oversampling = Int32(factor) ?? 8
        self.controls = controls
        inputs = (0..<input.shape.channels).map { pool.channel($0, of: input) }
        outputs = (0..<output.shape.channels).map { pool.channel($0, of: output) }
        self.workers = max(workers, 1)
        channelState = ChannelStates(
            channels: output.shape.channels, initial: bake.dsp.DerivativeDistortionState(),
            historyFloats: bake.dsp.derivativeDistortionHistoryFloats(controls.oversampling),
            scratchFloats: bake.dsp.derivativeDistortionScratchFloats(controls.oversampling, maxChunkFrames)
        )
    }

    func process(frames: Range<Int>) async throws {
        Parallel.forEach(outputs.count, workers: workers) { channel in
            guard let source = inputs[channel].baseAddress, let destination = outputs[channel].baseAddress else { return }
            bake.dsp.renderDerivativeDistortion(
                &channelState.states[channel], controls, source, inputs[channel].count,
                destination + frames.lowerBound, frames.lowerBound, frames.count,
                channelState.scratch[channel], channelState.histories[channel]
            )
        }
    }

    func finish() throws -> PendingOutput? { nil }

    func discard() {}
}
