import BakeDSP
import BakeGraph
import Foundation

/// Combinatorial Matrix: inputs A, B and C at their levels, aligned, and the sum scaled down to the
/// Ceiling if it would go above it. The offsets and the scale need the whole inputs, so they're worked
/// out on the first chunk; every chunk then reads the same numbers, whatever the split.
final class MatrixProcessor: StepProcessor {
    private let inputs: [bake.dsp.AudioInput]
    private let levels: [bake.dsp.ParameterSignal]
    private let outputs: [UnsafeMutableBufferPointer<Float>]
    private var pointers: [UnsafeMutablePointer<Float>?]
    private let frames: Int
    private let align: bake.dsp.MatrixAlign
    private let range: Int
    private let ceiling: Double
    private let seed: UInt64
    private let combination: UInt64
    private var offsets: [Int]?
    private var scale = 1.0

    init(step: RenderStep, sampleRate: Double, pool: BufferPool) throws {
        guard let output = step.outputs["out"] else { throw RenderError.unsupportedNode(step.kind) }
        inputs = ["a", "b", "c"].map { bake.dsp.AudioInput(PinID($0), of: step, pool: pool) }
        levels = ["levelA", "levelB", "levelC"].map { bake.dsp.ParameterSignal(ParameterID($0), of: step, pool: pool) }
        outputs = (0..<output.shape.channels).map { pool.channel($0, of: output) }
        pointers = Array(repeating: nil, count: outputs.count)
        frames = output.shape.frames
        let parameters = step.parameters
        align = switch parameters["align"] {
        case .choice("start")?: .start
        case .choice("random")?: .random
        default: .peak
        }
        range = Int(((parameters["alignRange"]?.numberValue ?? 50) * 0.001 * sampleRate).rounded())
        ceiling = pow(10, (parameters["ceiling"]?.numberValue ?? -0.3) / 20)
        seed = UInt64(max(0, parameters["seed"]?.numberValue ?? 1))
        combination = UInt64(max(0, parameters["combination"]?.numberValue ?? 0))
    }

    func process(frames range: Range<Int>) async throws {
        let offsets = self.offsets ?? prepare()
        for channel in outputs.indices {
            pointers[channel] = outputs[channel].baseAddress.map { $0 + range.lowerBound }
        }
        inputs.withUnsafeBufferPointer { inputs in
            levels.withUnsafeBufferPointer { levels in
                offsets.withUnsafeBufferPointer { offsets in
                    pointers.withUnsafeBufferPointer { outputs in
                        bake.dsp.matrixRender(
                            inputs.baseAddress, levels.baseAddress, offsets.baseAddress, inputs.count, scale,
                            outputs.baseAddress, outputs.count, range.lowerBound, range.count
                        )
                    }
                }
            }
        }
    }

    /// The layers' offsets and the scale that keeps the sum under the Ceiling.
    private func prepare() -> [Int] {
        var offsets = [Int](repeating: 0, count: inputs.count)
        inputs.withUnsafeBufferPointer { inputs in
            bake.dsp.matrixOffsets(inputs.baseAddress, inputs.count, align, range, seed, combination, &offsets)
        }
        let peak = inputs.withUnsafeBufferPointer { inputs in
            levels.withUnsafeBufferPointer { levels in
                bake.dsp.matrixPeak(inputs.baseAddress, levels.baseAddress, offsets, inputs.count, outputs.count, frames)
            }
        }
        scale = peak > ceiling ? ceiling / peak : 1
        self.offsets = offsets
        return offsets
    }

    func finish() throws -> PendingOutput? { nil }

    func discard() {}
}
