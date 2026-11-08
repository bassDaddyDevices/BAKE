import BakeDSP
import BakeGraph

/// Tape Degrade on the CPU engine. Reads the whole input channel at moving positions; each channel
/// carries its wobble phases and tone filter, so channels run in parallel with identical bits on any core count.
final class TapeDegradeProcessor: StepProcessor {
    private let controls: bake.dsp.TapeDegradeControls
    private let inputs: [UnsafeMutableBufferPointer<Float>]
    private let outputs: [UnsafeMutableBufferPointer<Float>]
    private let channelState: ChannelStates<bake.dsp.TapeDegradeState>
    private let workers: Int

    init(step: RenderStep, sampleRate: Double, pool: BufferPool, workers: Int = Parallel.coreCount) throws {
        guard let input = step.inputs["in"], let output = step.outputs["out"] else {
            throw RenderError.unsupportedNode(step.kind)
        }
        var controls = bake.dsp.TapeDegradeControls()
        controls.wow = bake.dsp.ParameterSignal("wow", of: step, pool: pool)
        controls.flutter = bake.dsp.ParameterSignal("flutter", of: step, pool: pool)
        controls.saturation = bake.dsp.ParameterSignal("saturation", of: step, pool: pool)
        controls.tone = bake.dsp.ParameterSignal("tone", of: step, pool: pool)
        controls.mix = bake.dsp.ParameterSignal("mix", of: step, pool: pool)
        controls.wowRate = bake.dsp.ParameterSignal("wowRate", of: step, pool: pool)
        controls.flutterRate = bake.dsp.ParameterSignal("flutterRate", of: step, pool: pool)
        controls.hiss = bake.dsp.ParameterSignal("hiss", of: step, pool: pool)
        controls.dropouts = bake.dsp.ParameterSignal("dropouts", of: step, pool: pool)
        controls.seed = UInt64(max(step.parameters["seed"]?.numberValue ?? 1, 0).rounded())
        controls.sampleRate = sampleRate
        controls.channelCount = output.shape.channels
        self.controls = controls
        inputs = (0..<input.shape.channels).map { pool.channel($0, of: input) }
        outputs = (0..<output.shape.channels).map { pool.channel($0, of: output) }
        self.workers = max(workers, 1)
        channelState = ChannelStates(channels: outputs.count, initial: bake.dsp.TapeDegradeState(), historyFloats: 0, scratchFloats: 1)
    }

    func process(frames: Range<Int>) async throws {
        Parallel.forEach(outputs.count, workers: workers) { channel in
            let source = inputs[min(channel, inputs.count - 1)]
            guard let input = source.baseAddress, let destination = outputs[channel].baseAddress else { return }
            bake.dsp.renderTapeDegrade(
                &channelState.states[channel], controls, input, source.count, channel,
                destination + frames.lowerBound, frames.lowerBound, frames.count
            )
        }
    }

    func finish() throws -> PendingOutput? { nil }

    func discard() {}
}
