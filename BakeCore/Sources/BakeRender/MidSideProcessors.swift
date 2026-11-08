import BakeDSP
import BakeGraph

/// Mid/Side Encoder: `mid` = (L+R)/2 and `side` = (L−R)/2, both mono. A mono input is all Mid.
final class MidSideEncoderProcessor: StepProcessor {
    private let input: bake.dsp.AudioInput
    private let mid: UnsafeMutableBufferPointer<Float>?
    private let side: UnsafeMutableBufferPointer<Float>?

    init(step: RenderStep, pool: BufferPool) throws {
        input = bake.dsp.AudioInput("in", of: step, pool: pool)
        mid = step.outputs["mid"].map { pool.channel(0, of: $0) }
        side = step.outputs["side"].map { pool.channel(0, of: $0) }
    }

    func process(frames: Range<Int>) async throws {
        bake.dsp.encodeMidSide(
            input, mid?.baseAddress.map { $0 + frames.lowerBound }, side?.baseAddress.map { $0 + frames.lowerBound },
            frames.lowerBound, frames.count
        )
    }

    func finish() throws -> PendingOutput? { nil }

    func discard() {}
}

/// Mid/Side Decoder: stereo out, left = Mid + Side and right = Mid − Side.
final class MidSideDecoderProcessor: StepProcessor {
    private let mid: bake.dsp.AudioInput
    private let side: bake.dsp.AudioInput
    private let left: UnsafeMutableBufferPointer<Float>
    private let right: UnsafeMutableBufferPointer<Float>

    init(step: RenderStep, pool: BufferPool) throws {
        guard let output = step.outputs["out"], output.shape.channels == 2 else { throw RenderError.unsupportedNode(step.kind) }
        mid = bake.dsp.AudioInput("mid", of: step, pool: pool)
        side = bake.dsp.AudioInput("side", of: step, pool: pool)
        left = pool.channel(0, of: output)
        right = pool.channel(1, of: output)
    }

    func process(frames: Range<Int>) async throws {
        bake.dsp.decodeMidSide(
            mid, side, left.baseAddress.map { $0 + frames.lowerBound }, right.baseAddress.map { $0 + frames.lowerBound },
            frames.lowerBound, frames.count
        )
    }

    func finish() throws -> PendingOutput? { nil }

    func discard() {}
}
