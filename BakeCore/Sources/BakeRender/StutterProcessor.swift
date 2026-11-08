import BakeDSP
import BakeGraph

/// Stutter on the CPU engine. Every channel keeps its own state from the same seed, so all channels
/// burst together; in stereo the kernel pans each repeat between them.
final class StutterProcessor: StepProcessor {
    private var states: [bake.dsp.StutterState]
    private let controls: bake.dsp.StutterControls
    private let trigger: bake.dsp.ControlInput
    private let inputs: [UnsafeMutableBufferPointer<Float>]
    private let outputs: [UnsafeMutableBufferPointer<Float>]

    init(step: RenderStep, sampleRate: Double, pool: BufferPool) throws {
        guard let input = step.inputs["in"], let output = step.outputs["out"] else {
            throw RenderError.unsupportedNode(step.kind)
        }
        func signal(_ id: ParameterID) -> bake.dsp.ParameterSignal { bake.dsp.ParameterSignal(id, of: step, pool: pool) }
        var controls = bake.dsp.StutterControls()
        controls.every = signal("every")
        controls.chance = signal("chance")
        controls.size = signal("size")
        controls.repeats = signal("repeats")
        controls.capture = signal("capture")
        controls.shrink = signal("shrink")
        controls.gate = signal("gate")
        controls.decay = signal("decay")
        controls.pitch = signal("pitch")
        controls.pitchDrift = signal("pitchDrift")
        controls.pan = signal("pan")
        controls.panDrift = signal("panDrift")
        controls.reverse = signal("reverse")
        controls.jitter = signal("jitter")
        controls.smooth = signal("smooth")
        controls.mix = signal("mix")
        controls.sampleRate = sampleRate
        controls.seed = UInt32(step.parameters["seed"]?.numberValue ?? 0)
        self.controls = controls
        trigger = bake.dsp.ControlInput("trigger", of: step, pool: pool)
        inputs = (0..<input.shape.channels).map { pool.channel($0, of: input) }
        outputs = (0..<output.shape.channels).map { pool.channel($0, of: output) }
        states = Array(repeating: bake.dsp.StutterState(), count: outputs.count)
    }

    func process(frames: Range<Int>) async throws {
        for channel in outputs.indices where channel < inputs.count {
            guard let destination = outputs[channel].baseAddress else { continue }
            bake.dsp.renderStutter(
                &states[channel], controls, trigger, Int32(channel), Int32(outputs.count),
                inputs[channel].baseAddress, inputs[channel].count, destination + frames.lowerBound,
                frames.lowerBound, frames.count
            )
        }
    }

    func finish() throws -> PendingOutput? { nil }

    func discard() {}
}
