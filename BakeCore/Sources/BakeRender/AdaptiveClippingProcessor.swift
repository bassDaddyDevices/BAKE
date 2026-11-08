import BakeDSP
import BakeGraph

/// Adaptive Clipping on the CPU engine. Each channel carries its envelope and oversampler history. With Lookahead, the
/// ceilings for every frame are built on the first chunk, after which clipping is stateless and runs across frame ranges
/// as well as channels.
final class AdaptiveClippingProcessor: StepProcessor {
    private let controls: bake.dsp.AdaptiveClippingControls
    private let inputs: [UnsafeMutableBufferPointer<Float>]
    private let outputs: [UnsafeMutableBufferPointer<Float>]
    /// One envelope state, oversampler history and scratch per channel, allocated once; channels run on separate threads.
    private let channelState: ChannelStates<bake.dsp.AdaptiveClippingState>
    private let workers: Int
    private let lookahead: Bool
    private let plan: PiecePlan?
    /// Lookahead: every channel's ceiling at every frame, built on the first chunk.
    private let ceilings: [UnsafeMutablePointer<Double>]
    private var prepared = false

    init(step: RenderStep, sampleRate: Double, pool: BufferPool, maxChunkFrames: Int, workers: Int = Parallel.coreCount) throws {
        guard let input = step.inputs["in"], let output = step.outputs["out"] else {
            throw RenderError.unsupportedNode(step.kind)
        }
        var controls = bake.dsp.AdaptiveClippingControls()
        controls.threshold = bake.dsp.ParameterSignal("threshold", of: step, pool: pool)
        controls.release = bake.dsp.ParameterSignal("release", of: step, pool: pool)
        controls.kneeIndex = bake.dsp.ParameterSignal("knee", of: step, pool: pool)
        controls.makeup = bake.dsp.ParameterSignal("makeup", of: step, pool: pool)
        controls.mix = bake.dsp.ParameterSignal("mix", of: step, pool: pool)
        controls.floor = bake.dsp.ParameterSignal("floor", of: step, pool: pool)
        if case .choice("hard")? = step.parameters["knee"] { controls.knee = .hard } else { controls.knee = .soft }
        var factor = "8"
        if case .choice(let value)? = step.parameters["oversampling"] { factor = value }
        controls.oversampling = Int32(factor) ?? 8
        controls.sampleRate = sampleRate
        // Documents without Lookahead are older ones: the causal ceiling.
        controls.lookaheadMilliseconds = max(step.parameters["lookahead"]?.numberValue ?? 0, 0)
        self.controls = controls
        inputs = (0..<input.shape.channels).map { pool.channel($0, of: input) }
        outputs = (0..<output.shape.channels).map { pool.channel($0, of: output) }
        self.workers = max(workers, 1)
        channelState = ChannelStates(
            channels: output.shape.channels, initial: bake.dsp.AdaptiveClippingState(),
            historyFloats: bake.dsp.adaptiveClippingHistoryFloats(controls.oversampling),
            scratchFloats: bake.dsp.adaptiveClippingScratchFloats(controls.oversampling, maxChunkFrames)
        )
        let ahead = controls.lookaheadMilliseconds > 0
        lookahead = ahead
        if ahead {
            let oversampling = controls.oversampling
            plan = PiecePlan(channels: output.shape.channels, maxChunkFrames: max(maxChunkFrames, 1), workers: workers) {
                Int(bake.dsp.adaptiveClippingScratchFloats(oversampling, $0))
            }
            let sourceFrames = inputs.map(\.count)
            try NodeMemory.require(bytes: sourceFrames.reduce(0, +) * MemoryLayout<Double>.stride)
            ceilings = (0..<output.shape.channels).map { channel in
                let frames = max(sourceFrames[min(channel, sourceFrames.count - 1)], 1)
                let buffer = UnsafeMutablePointer<Double>.allocate(capacity: frames)
                buffer.initialize(repeating: 0, count: frames)
                return buffer
            }
        } else {
            plan = nil
            ceilings = []
        }
    }

    deinit {
        for buffer in ceilings { buffer.deallocate() }
    }

    func process(frames: Range<Int>) async throws {
        if lookahead, let plan {
            if !prepared {
                prepared = true
                Parallel.forEach(outputs.count, workers: workers) { channel in
                    let source = inputs[min(channel, inputs.count - 1)]
                    guard let input = source.baseAddress else { return }
                    let doubles = Int(bake.dsp.adaptiveClippingCeilingScratchDoubles(source.count))
                    let scratch = UnsafeMutablePointer<Double>.allocate(capacity: max(doubles, 1))
                    scratch.initialize(repeating: 0, count: max(doubles, 1))
                    defer { scratch.deallocate() }
                    bake.dsp.buildAdaptiveClippingCeilings(controls, input, source.count, source.count, ceilings[channel], scratch)
                }
            }
            plan.run(channels: outputs.count, frames: frames) { channel, piece, work in
                let source = inputs[min(channel, inputs.count - 1)]
                guard let input = source.baseAddress, let destination = outputs[channel].baseAddress else { return }
                bake.dsp.renderAdaptiveClippingAhead(
                    controls, input, source.count, ceilings[channel], source.count,
                    destination + piece.lowerBound, piece.lowerBound, piece.count, work
                )
            }
            return
        }
        Parallel.forEach(outputs.count, workers: workers) { channel in
            let source = inputs[min(channel, inputs.count - 1)]
            guard let input = source.baseAddress, let destination = outputs[channel].baseAddress else { return }
            bake.dsp.renderAdaptiveClipping(
                &channelState.states[channel], controls, input, source.count,
                destination + frames.lowerBound, frames.lowerBound, frames.count,
                channelState.scratch[channel], channelState.histories[channel]
            )
        }
    }

    func finish() throws -> PendingOutput? { nil }

    func discard() {}
}
