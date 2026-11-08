import BakeDSP
import BakeGraph

/// Half Time on the CPU engine. Each channel keeps its own time map and reads the whole input
/// channel, so the windows of every channel jump together.
final class HalfTimeProcessor: StepProcessor {
    private var states: [bake.dsp.HalfTimeState]
    private let mode: bake.dsp.HalfTimeMode
    private let speed: bake.dsp.ParameterSignal
    private let mix: bake.dsp.ParameterSignal
    private let windowFrames: Double
    private let smoothFrames: Double
    private let grainFrames: Int32
    private let modulation: bake.dsp.HalfTimeModulation
    private let sync: bake.dsp.ControlInput
    private let inputs: [UnsafeMutableBufferPointer<Float>]
    private let outputs: [UnsafeMutableBufferPointer<Float>]

    init(step: RenderStep, sampleRate: Double, pool: BufferPool) throws {
        guard let input = step.inputs["in"], let output = step.outputs["out"] else {
            throw RenderError.unsupportedNode(step.kind)
        }
        var modeName = "repitch"
        if case .choice(let value)? = step.parameters["mode"] { modeName = value }
        mode = modeName == "granular" ? .granular : .repitch
        speed = bake.dsp.ParameterSignal("speed", of: step, pool: pool)
        mix = bake.dsp.ParameterSignal("mix", of: step, pool: pool)
        windowFrames = (step.parameters["window"]?.numberValue ?? 500) / 1_000 * sampleRate
        smoothFrames = (step.parameters["smooth"]?.numberValue ?? 5) / 1_000 * sampleRate
        grainFrames = Int32(((step.parameters["grain"]?.numberValue ?? 40) / 1_000 * sampleRate).rounded())
        var modulation = bake.dsp.HalfTimeModulation()
        modulation.window = bake.dsp.ParameterSignal("window", of: step, pool: pool)
        modulation.smooth = bake.dsp.ParameterSignal("smooth", of: step, pool: pool)
        modulation.grain = bake.dsp.ParameterSignal("grain", of: step, pool: pool)
        modulation.sampleRate = sampleRate
        self.modulation = modulation
        sync = bake.dsp.ControlInput("sync", of: step, pool: pool)
        inputs = (0..<input.shape.channels).map { pool.channel($0, of: input) }
        outputs = (0..<output.shape.channels).map { pool.channel($0, of: output) }
        states = Array(repeating: bake.dsp.HalfTimeState(), count: outputs.count)
    }

    func process(frames: Range<Int>) async throws {
        for channel in outputs.indices where channel < inputs.count {
            guard let destination = outputs[channel].baseAddress else { continue }
            bake.dsp.renderHalfTime(
                &states[channel], mode, speed, mix, windowFrames, smoothFrames, grainFrames, modulation, sync,
                inputs[channel].baseAddress, inputs[channel].count, destination + frames.lowerBound,
                frames.lowerBound, frames.count
            )
        }
    }

    func finish() throws -> PendingOutput? { nil }

    func discard() {}
}
