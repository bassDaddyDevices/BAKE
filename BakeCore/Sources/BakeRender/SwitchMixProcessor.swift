import BakeDSP
import BakeGraph

/// Switch (many in, one out): the kernel decides each frame's per-input gains once, then the output is the sum of every
/// input times its gain. An input shorter than the node is silent past its end; a mono input feeds every channel.
final class SwitchMixProcessor: StepProcessor {
    private var state = bake.dsp.SwitchState()
    private let order: bake.dsp.SwitchOrder
    private let inputCount: Int32
    private let pattern: [Int32]
    private let seed: UInt32
    private let fadeFrames: Double
    private let crossfade: bake.dsp.ParameterSignal
    private let sampleRate: Double
    private let advance: bake.dsp.ControlInput
    private let reset: bake.dsp.ControlInput
    private let inputs: [bake.dsp.AudioInput]
    private let outputs: [UnsafeMutableBufferPointer<Float>]
    private var pointers: [UnsafeMutablePointer<Float>?]
    private var gains: [Float]

    init(step: RenderStep, sampleRate: Double, maxChunkFrames: Int, pool: BufferPool) throws {
        guard let output = step.outputs["out"] else { throw RenderError.unsupportedNode(step.kind) }
        var count = 4
        if case .choice(let value)? = step.parameters["inputs"] { count = Int(value) ?? 4 }
        inputCount = Int32(count)
        var orderName = "forward"
        if case .choice(let value)? = step.parameters["order"] { orderName = value }
        order = switch orderName {
        case "pingPong": .pingPong
        case "random": .random
        case "pattern": .pattern
        default: .forward
        }
        var text = ""
        if case .text(let value)? = step.parameters["pattern"] { text = value }
        // Parsed once here; the kernel takes 0-based inputs.
        pattern = SwitchSteps.pattern(text, outputs: count).map(Int32.init)
        seed = UInt32(step.parameters["seed"]?.numberValue ?? 0)
        fadeFrames = (step.parameters["crossfade"]?.numberValue ?? 5) / 1_000 * sampleRate
        crossfade = bake.dsp.ParameterSignal("crossfade", of: step, pool: pool)
        self.sampleRate = sampleRate
        advance = bake.dsp.ControlInput("advance", of: step, pool: pool, unwired: 0)
        reset = bake.dsp.ControlInput("reset", of: step, pool: pool, unwired: 0)
        // Every pin in order, wired or not: an unwired input is a silent step.
        inputs = (1...count).map { bake.dsp.AudioInput("in\($0)", of: step, pool: pool) }
        outputs = (0..<output.shape.channels).map { pool.channel($0, of: output) }
        pointers = Array(repeating: nil, count: outputs.count)
        gains = [Float](repeating: 0, count: max(maxChunkFrames, 1) * count)
    }

    func process(frames: Range<Int>) async throws {
        for channel in outputs.indices {
            pointers[channel] = outputs[channel].baseAddress.map { $0 + frames.lowerBound }
        }
        pattern.withUnsafeBufferPointer { patternPointer in
            gains.withUnsafeMutableBufferPointer { gainPointer in
                guard let gainBase = gainPointer.baseAddress else { return }
                bake.dsp.renderSwitchGains(
                    &state, order, inputCount, patternPointer.baseAddress, Int32(pattern.count), seed, fadeFrames, crossfade, sampleRate,
                    advance, reset, gainBase, frames.lowerBound, frames.count
                )
                inputs.withUnsafeBufferPointer { inputs in
                    pointers.withUnsafeBufferPointer { outputs in
                        guard let outputBase = outputs.baseAddress else { return }
                        bake.dsp.mixSwitchInputs(
                            inputs.baseAddress, inputs.count, gainBase, outputBase, outputs.count, frames.lowerBound, frames.count
                        )
                    }
                }
            }
        }
    }

    func finish() throws -> PendingOutput? { nil }

    func discard() {}
}
