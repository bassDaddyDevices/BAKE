import BakeDSP
import BakeGraph

/// Step FX on the CPU engine. The pattern is parsed once; every channel keeps its own state from the
/// same seed, so all channels play the same steps.
final class StepFXProcessor: StepProcessor {
    private var states: [bake.dsp.StepFXState]
    private let controls: bake.dsp.StepFXControls
    private let pattern: [Int32]
    private let stepQuarters: [Double]
    private let clock: bake.dsp.ControlInput
    private let inputs: [UnsafeMutableBufferPointer<Float>]
    private let outputs: [UnsafeMutableBufferPointer<Float>]

    init(step: RenderStep, sampleRate: Double, pool: BufferPool) throws {
        guard let input = step.inputs["in"], let output = step.outputs["out"] else {
            throw RenderError.unsupportedNode(step.kind)
        }
        var text = ""
        if case .text(let value)? = step.parameters["pattern"] { text = value }
        let steps = Int((step.parameters["steps"]?.numberValue ?? 16).rounded())
        pattern = StepFXPattern.effects(text, steps: steps).map { Int32($0.rawValue) }
        stepQuarters = StepFXPattern.stepLengths.map { BeatRepeatNotes.quarterNotes($0) ?? 0.25 }
        func signal(_ id: ParameterID) -> bake.dsp.ParameterSignal { bake.dsp.ParameterSignal(id, of: step, pool: pool) }
        var controls = bake.dsp.StepFXControls()
        controls.tempo = signal("tempo")
        controls.step = signal("step")
        controls.rotate = signal("rotate")
        controls.chance = signal("chance")
        controls.variation = signal("variation")
        controls.stutterSize = signal("stutterSize")
        controls.speed = signal("speed")
        controls.curve = signal("curve")
        controls.gate = signal("gate")
        controls.smooth = signal("smooth")
        controls.mix = signal("mix")
        controls.sampleRate = sampleRate
        controls.seed = UInt32(step.parameters["seed"]?.numberValue ?? 0)
        self.controls = controls
        clock = bake.dsp.ControlInput("clock", of: step, pool: pool)
        inputs = (0..<input.shape.channels).map { pool.channel($0, of: input) }
        outputs = (0..<output.shape.channels).map { pool.channel($0, of: output) }
        states = Array(repeating: bake.dsp.StepFXState(), count: outputs.count)
    }

    func process(frames: Range<Int>) async throws {
        pattern.withUnsafeBufferPointer { cells in
            stepQuarters.withUnsafeBufferPointer { quarters in
                var controls = self.controls
                controls.pattern = cells.baseAddress
                controls.steps = Int32(cells.count)
                controls.stepQuarters = quarters.baseAddress
                controls.stepCount = Int32(quarters.count)
                for channel in outputs.indices where channel < inputs.count {
                    guard let destination = outputs[channel].baseAddress else { continue }
                    bake.dsp.renderStepFX(
                        &states[channel], controls, clock, inputs[channel].baseAddress, inputs[channel].count,
                        destination + frames.lowerBound, frames.lowerBound, frames.count
                    )
                }
            }
        }
    }

    func finish() throws -> PendingOutput? { nil }

    func discard() {}
}
