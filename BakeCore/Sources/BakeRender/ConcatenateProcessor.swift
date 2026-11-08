import BakeDSP
import BakeGraph

/// Concatenate in a render: its wired inputs end to end in pin order (`JoinPlan`). In a batch it renders this
/// way in every pass too, and what it makes is captured; the passes are joined afterwards (`Concatenation`).
final class ConcatenateProcessor: StepProcessor {
    private let inputs: [bake.dsp.AudioInput]
    private let starts: [Int]
    private let holds: [Int]
    private let outputs: [UnsafeMutableBufferPointer<Float>]
    private var pointers: [UnsafeMutablePointer<Float>?]

    init(step: RenderStep, sampleRate: Double, pool: BufferPool) throws {
        guard let output = step.outputs["out"] else { throw RenderError.unsupportedNode(step.kind) }
        let wired = step.inputs.keys.compactMap { pin -> Int? in pin.hasPrefix("in") ? Int(pin.dropFirst(2)) : nil }.sorted()
        inputs = wired.map { bake.dsp.AudioInput(PinID("in\($0)"), of: step, pool: pool) }
        let plan = JoinPlan(lengths: inputs.map(\.frames), parameters: step.parameters, sampleRate: sampleRate)
        starts = plan.starts
        holds = plan.holds
        outputs = (0..<output.shape.channels).map { pool.channel($0, of: output) }
        pointers = Array(repeating: nil, count: outputs.count)
    }

    func process(frames: Range<Int>) async throws {
        for channel in outputs.indices {
            pointers[channel] = outputs[channel].baseAddress.map { $0 + frames.lowerBound }
        }
        inputs.withUnsafeBufferPointer { inputs in
            pointers.withUnsafeBufferPointer { outputs in
                bake.dsp.joinRender(
                    inputs.baseAddress, inputs.count, starts, holds, outputs.baseAddress, outputs.count,
                    frames.lowerBound, frames.count
                )
            }
        }
    }

    func finish() throws -> PendingOutput? { nil }

    func discard() {}
}
