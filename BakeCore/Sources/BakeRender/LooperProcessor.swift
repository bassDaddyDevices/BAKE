import BakeDSP
import BakeGraph

/// Looper on the CPU engine. In Once mode the pass layout comes from `LooperPlan`, the same function
/// that set the node's length; in Repeat mode each bang starts a loop. Every channel snaps to the
/// first channel's zero crossings so they loop together.
final class LooperProcessor: StepProcessor {
    private var states: [bake.dsp.LooperState]
    private let repeats: Bool
    private let timing: bake.dsp.LooperRepeat
    private let trigger: bake.dsp.ControlInput
    private let plan: LooperPlan.Layout
    private let passLengths: [Int64]
    private let controls: bake.dsp.LooperControls
    private let inputs: [UnsafeMutableBufferPointer<Float>]
    private let outputs: [UnsafeMutableBufferPointer<Float>]

    init(step: RenderStep, sampleRate: Double, pool: BufferPool) throws {
        guard let input = step.inputs["in"], let output = step.outputs["out"] else {
            throw RenderError.unsupportedNode(step.kind)
        }
        plan = LooperPlan.layout(inputFrames: input.shape.frames, parameters: step.parameters, sampleRate: sampleRate)
        passLengths = plan.passLengths.map(Int64.init)
        inputs = (0..<input.shape.channels).map { pool.channel($0, of: input) }
        outputs = (0..<output.shape.channels).map { pool.channel($0, of: output) }
        var controls = bake.dsp.LooperControls()
        controls.scrub = bake.dsp.ParameterSignal("scrub", of: step, pool: pool)
        controls.direction = bake.dsp.ParameterSignal("direction", of: step, pool: pool)
        controls.pitch = bake.dsp.ParameterSignal("pitch", of: step, pool: pool)
        controls.pitchDrift = bake.dsp.ParameterSignal("pitchDrift", of: step, pool: pool)
        controls.decay = bake.dsp.ParameterSignal("decay", of: step, pool: pool)
        controls.crossfade = bake.dsp.ParameterSignal("crossfade", of: step, pool: pool)
        controls.sampleRate = sampleRate
        var snap = "on"
        if case .choice(let value)? = step.parameters["snap"] { snap = value }
        controls.snap = snap == "on"
        if let first = inputs.first {
            controls.snapSource = UnsafePointer(first.baseAddress)
            controls.snapFrames = first.count
        }
        self.controls = controls
        repeats = step.parameters["mode"] == .choice("repeat")
        var timing = bake.dsp.LooperRepeat()
        timing.every = bake.dsp.ParameterSignal("every", of: step, pool: pool)
        timing.length = bake.dsp.ParameterSignal("length", of: step, pool: pool)
        timing.passes = bake.dsp.ParameterSignal("passes", of: step, pool: pool)
        timing.shrink = bake.dsp.ParameterSignal("shrink", of: step, pool: pool)
        self.timing = timing
        trigger = bake.dsp.ControlInput("trigger", of: step, pool: pool)
        states = Array(repeating: bake.dsp.LooperState(), count: outputs.count)
    }

    func process(frames: Range<Int>) async throws {
        if repeats {
            for channel in outputs.indices where channel < inputs.count {
                guard let destination = outputs[channel].baseAddress else { continue }
                bake.dsp.renderLooperRepeat(
                    &states[channel], timing, controls, trigger, inputs[channel].baseAddress, inputs[channel].count,
                    destination + frames.lowerBound, frames.lowerBound, frames.count
                )
            }
            return
        }
        passLengths.withUnsafeBufferPointer { lengths in
            var layout = bake.dsp.LooperLayout()
            layout.passLengths = lengths.baseAddress
            layout.passCount = Int32(lengths.count)
            layout.regionStart = Double(plan.regionStart)
            layout.regionLength = Double(plan.regionLength)
            layout.introFrames = Double(plan.intro)
            for channel in outputs.indices where channel < inputs.count {
                guard let destination = outputs[channel].baseAddress else { continue }
                bake.dsp.renderLooper(
                    &states[channel], layout, controls, inputs[channel].baseAddress, inputs[channel].count,
                    destination + frames.lowerBound, frames.lowerBound, frames.count
                )
            }
        }
    }

    func finish() throws -> PendingOutput? { nil }

    func discard() {}
}
