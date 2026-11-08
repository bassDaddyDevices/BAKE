import BakeDSP
import BakeGraph

/// Gain/VCA node on the CPU engine; the optional amount pin drives all audio channels.
final class GainVCAProcessor: StepProcessor {
    private let mode: bake.dsp.GainMode
    private let gain: bake.dsp.ParameterSignal
    private let inputs: [UnsafeMutableBufferPointer<Float>]
    private let amount: bake.dsp.ControlInput
    private let outputs: [UnsafeMutableBufferPointer<Float>]

    init(step: RenderStep, pool: BufferPool) throws {
        guard let input = step.inputs["in"], let output = step.outputs["out"] else {
            throw RenderError.unsupportedNode(step.kind)
        }
        var modeName = "vca"
        if case .choice(let value)? = step.parameters["mode"] { modeName = value }
        mode = modeName == "ringMod" ? .ringMod : .vca
        gain = bake.dsp.ParameterSignal("gain", of: step, pool: pool)
        inputs = (0..<input.shape.channels).map { pool.channel($0, of: input) }
        outputs = (0..<output.shape.channels).map { pool.channel($0, of: output) }
        amount = bake.dsp.ControlInput("amount", of: step, pool: pool)
    }

    func process(frames: Range<Int>) async throws {
        for channel in outputs.indices {
            guard let source = inputs[channel].baseAddress, let destination = outputs[channel].baseAddress else { continue }
            bake.dsp.renderGainVCA(
                mode, gain, source + frames.lowerBound, amount,
                destination + frames.lowerBound, frames.lowerBound, frames.count
            )
        }
    }

    func finish() throws -> PendingOutput? { nil }

    func discard() {}
}
