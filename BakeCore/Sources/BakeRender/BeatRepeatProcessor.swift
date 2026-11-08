import BakeDSP
import BakeGraph

/// Beat Repeat on the CPU engine. Every channel keeps its own state from the same seed, so all
/// channels make the same choices and repeat together.
final class BeatRepeatProcessor: StepProcessor {
    private var states: [bake.dsp.BeatRepeatState]
    private let mode: bake.dsp.BeatRepeatMode
    private let controls: bake.dsp.BeatRepeatControls
    private let gridQuarters: [Double]
    private let intervalQuarters: [Double]
    private let trigger: bake.dsp.ControlInput
    private let inputs: [UnsafeMutableBufferPointer<Float>]
    private let outputs: [UnsafeMutableBufferPointer<Float>]

    init(step: RenderStep, sampleRate: Double, pool: BufferPool) throws {
        guard let input = step.inputs["in"], let output = step.outputs["out"] else {
            throw RenderError.unsupportedNode(step.kind)
        }
        var modeName = "insert"
        if case .choice(let value)? = step.parameters["mode"] { modeName = value }
        mode = switch modeName {
        case "mix": .mix
        case "gate": .gate
        default: .insert
        }
        func signal(_ id: ParameterID) -> bake.dsp.ParameterSignal { bake.dsp.ParameterSignal(id, of: step, pool: pool) }
        var controls = bake.dsp.BeatRepeatControls()
        controls.tempo = signal("tempo")
        controls.interval = signal("interval")
        controls.offset = signal("offset")
        controls.chance = signal("chance")
        controls.gate = signal("gate")
        controls.grid = signal("grid")
        controls.capture = signal("capture")
        controls.variation = signal("variation")
        controls.accelerate = signal("accelerate")
        controls.pitch = signal("pitch")
        controls.pitchDrift = signal("pitchDrift")
        controls.decay = signal("decay")
        controls.smooth = signal("smooth")
        controls.sampleRate = sampleRate
        controls.seed = UInt32(step.parameters["seed"]?.numberValue ?? 0)
        self.controls = controls
        // The kernel indexes these with the (modulated) Grid and Interval choices.
        gridQuarters = BeatRepeatNotes.grids.map { BeatRepeatNotes.quarterNotes($0) ?? 0.25 }
        intervalQuarters = BeatRepeatNotes.intervals.map { BeatRepeatNotes.quarterNotes($0) ?? 4 }
        trigger = bake.dsp.ControlInput("trigger", of: step, pool: pool)
        inputs = (0..<input.shape.channels).map { pool.channel($0, of: input) }
        outputs = (0..<output.shape.channels).map { pool.channel($0, of: output) }
        states = Array(repeating: bake.dsp.BeatRepeatState(), count: outputs.count)
    }

    func process(frames: Range<Int>) async throws {
        gridQuarters.withUnsafeBufferPointer { grids in
            intervalQuarters.withUnsafeBufferPointer { intervals in
                var controls = self.controls
                controls.gridQuarters = grids.baseAddress
                controls.gridCount = Int32(grids.count)
                controls.intervalQuarters = intervals.baseAddress
                controls.intervalCount = Int32(intervals.count)
                for channel in outputs.indices where channel < inputs.count {
                    guard let destination = outputs[channel].baseAddress else { continue }
                    bake.dsp.renderBeatRepeat(
                        &states[channel], mode, controls, trigger,
                        inputs[channel].baseAddress, inputs[channel].count, destination + frames.lowerBound,
                        frames.lowerBound, frames.count
                    )
                }
            }
        }
    }

    func finish() throws -> PendingOutput? { nil }

    func discard() {}
}
