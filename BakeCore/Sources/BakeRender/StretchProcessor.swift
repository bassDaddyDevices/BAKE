import BakeDSP
import BakeGraph

/// Stretch node on the CPU engine. Owns a Signalsmith session (an opaque C++ handle) for one
/// render step and frees it on deinit.
final class StretchProcessor: StepProcessor {
    private let session: OpaquePointer
    private let pitch: bake.dsp.ParameterSignal
    private let cents: bake.dsp.ParameterSignal

    init(step: RenderStep, sampleRate: Double, pool: BufferPool) throws {
        guard let input = step.inputs["in"], let output = step.outputs["out"] else {
            throw RenderError.unsupportedNode(step.kind)
        }
        // Per-channel pointers into the pool; the session copies these arrays, not the audio.
        let inputs: [UnsafePointer<Float>?] = (0..<input.shape.channels).map {
            UnsafePointer(pool.channel($0, of: input).baseAddress)
        }
        let outputs: [UnsafeMutablePointer<Float>?] = (0..<output.shape.channels).map {
            pool.channel($0, of: output).baseAddress
        }
        var fftSize = "4096"
        if case .choice(let value)? = step.parameters["fftSize"] { fftSize = value }
        let handle = inputs.withUnsafeBufferPointer { inputArray in
            outputs.withUnsafeBufferPointer { outputArray in
                bake.dsp.createStretchSession(
                    Int32(output.shape.channels), sampleRate, Int32(fftSize) ?? 4_096,
                    inputArray.baseAddress, input.shape.frames, outputArray.baseAddress, output.shape.frames
                )
            }
        }
        guard let handle else { throw RenderError.unsupportedNode(step.kind) }
        session = handle
        pitch = bake.dsp.ParameterSignal("pitchSemitones", of: step, pool: pool)
        cents = bake.dsp.ParameterSignal("pitchCents", of: step, pool: pool)
    }

    deinit {
        bake.dsp.destroyStretchSession(session)
    }

    func process(frames: Range<Int>) async throws {
        bake.dsp.renderStretch(session, frames.upperBound, pitch, cents)
    }

    func finish() throws -> PendingOutput? { nil }

    func discard() {}
}
