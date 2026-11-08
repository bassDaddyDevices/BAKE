import BakeDSP
import BakeGraph

/// Switch: the kernel decides each frame's per-output gains once, then every wired output gets the
/// input scaled by its gain, channel by channel.
final class SwitchProcessor: StepProcessor {
    private var state = bake.dsp.SwitchState()
    private let order: bake.dsp.SwitchOrder
    private let outputCount: Int32
    private let pattern: [Int32]
    private let seed: UInt32
    private let fadeFrames: Double
    private let crossfade: bake.dsp.ParameterSignal
    private let sampleRate: Double
    private let advance: bake.dsp.ControlInput
    private let reset: bake.dsp.ControlInput
    private let inputs: [UnsafeMutableBufferPointer<Float>]
    /// Output index (0-based) → its channel buffers, for the outputs this plan uses.
    private let outputs: [(index: Int32, channels: [UnsafeMutableBufferPointer<Float>])]
    private var gains: [Float]

    init(step: RenderStep, sampleRate: Double, maxChunkFrames: Int, pool: BufferPool) throws {
        guard let input = step.inputs["in"] else { throw RenderError.unsupportedNode(step.kind) }
        var count = 4
        if case .choice(let value)? = step.parameters["outputs"] { count = Int(value) ?? 4 }
        outputCount = Int32(count)
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
        // Parsed once here; the kernel takes 0-based outputs.
        pattern = SwitchSteps.pattern(text, outputs: count).map(Int32.init)
        seed = UInt32(step.parameters["seed"]?.numberValue ?? 0)
        fadeFrames = (step.parameters["crossfade"]?.numberValue ?? 5) / 1_000 * sampleRate
        crossfade = bake.dsp.ParameterSignal("crossfade", of: step, pool: pool)
        self.sampleRate = sampleRate
        advance = bake.dsp.ControlInput("advance", of: step, pool: pool, unwired: 0)
        reset = bake.dsp.ControlInput("reset", of: step, pool: pool, unwired: 0)
        inputs = (0..<input.shape.channels).map { pool.channel($0, of: input) }
        outputs = step.outputs.compactMap { pin, binding in
            guard pin.hasPrefix("out"), let number = Int(pin.dropFirst(3)), (1...count).contains(number) else { return nil }
            return (Int32(number - 1), (0..<binding.shape.channels).map { pool.channel($0, of: binding) })
        }
        gains = [Float](repeating: 0, count: max(maxChunkFrames, 1) * count)
    }

    func process(frames: Range<Int>) async throws {
        pattern.withUnsafeBufferPointer { patternPointer in
            gains.withUnsafeMutableBufferPointer { gainPointer in
                guard let gainBase = gainPointer.baseAddress else { return }
                bake.dsp.renderSwitchGains(
                    &state, order, outputCount, patternPointer.baseAddress, Int32(pattern.count), seed, fadeFrames, crossfade, sampleRate,
                    advance, reset, gainBase, frames.lowerBound, frames.count
                )
                for output in outputs {
                    for (channel, destination) in output.channels.enumerated() where channel < inputs.count {
                        guard let source = inputs[channel].baseAddress, let target = destination.baseAddress else { continue }
                        bake.dsp.applySwitchGain(
                            gainBase, outputCount, output.index, source + frames.lowerBound, target + frames.lowerBound, frames.count
                        )
                    }
                }
            }
        }
    }

    func finish() throws -> PendingOutput? { nil }

    func discard() {}
}
