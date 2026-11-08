import BakeDSP
import BakeGraph

/// Batch Conform: the Stretch engine at this pass's `ratio` and `shift`, plus Key Offset, with formants kept
/// or shifted. When there is nothing to do (ratio 1, no shift, Key Offset 0 and unmodulated) it copies its
/// input, so outside a batch it changes nothing.
final class ConformProcessor: StepProcessor {
    private let session: OpaquePointer?
    private let keyOffset: bake.dsp.ParameterSignal
    private let cents: Float
    private let input: bake.dsp.AudioInput
    private let outputs: [UnsafeMutableBufferPointer<Float>]

    init(step: RenderStep, sampleRate: Double, pool: BufferPool) throws {
        guard let inputBinding = step.inputs["in"], let output = step.outputs["out"] else { throw RenderError.unsupportedNode(step.kind) }
        input = bake.dsp.AudioInput("in", of: step, pool: pool)
        outputs = (0..<output.shape.channels).map { pool.channel($0, of: output) }
        keyOffset = bake.dsp.ParameterSignal("keyOffset", of: step, pool: pool)
        let ratio = step.parameters["ratio"]?.numberValue ?? 1
        let shift = step.parameters["shift"]?.numberValue ?? 0
        cents = Float(shift * 100)
        guard ratio != 1 || shift != 0 || keyOffset.modulation != nil || keyOffset.base != 0 else {
            session = nil
            return
        }
        let inputs: [UnsafePointer<Float>?] = (0..<inputBinding.shape.channels).map { UnsafePointer(pool.channel($0, of: inputBinding).baseAddress) }
        let outs: [UnsafeMutablePointer<Float>?] = outputs.map(\.baseAddress)
        var fftSize = "4096"
        if case .choice(let value)? = step.parameters["fftSize"] { fftSize = value }
        session = inputs.withUnsafeBufferPointer { inputArray in
            outs.withUnsafeBufferPointer { outputArray in
                bake.dsp.createStretchSession(
                    Int32(output.shape.channels), sampleRate, Int32(fftSize) ?? 4_096,
                    inputArray.baseAddress, inputBinding.shape.frames, outputArray.baseAddress, output.shape.frames
                )
            }
        }
        guard let session else { throw RenderError.unsupportedNode(step.kind) }
        bake.dsp.setStretchFormants(session, step.parameters["formants"] == .choice("preserve"))
    }

    deinit {
        if let session { bake.dsp.destroyStretchSession(session) }
    }

    func process(frames: Range<Int>) async throws {
        if let session {
            bake.dsp.renderStretch(session, frames.upperBound, keyOffset, cents)
            return
        }
        for (channel, buffer) in outputs.enumerated() {
            guard let destination = buffer.baseAddress else { continue }
            bake.dsp.copyChannel(input, channel, destination + frames.lowerBound, frames.lowerBound, frames.count)
        }
    }

    func finish() throws -> PendingOutput? { nil }

    func discard() {}
}
