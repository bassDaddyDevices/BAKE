import BakeDSP
import BakeGraph

/// Flanger node on the CPU engine. Two read heads:
///
/// - `causal`: the original, a circular delay line per channel that only ever looks backwards.
/// - `throughZero`: the wet head reads the whole input and can pass through zero into its future, optionally
///   through a whole-channel all-pass chain (Dispersion) that bends the comb into a chirp.
///
/// Each channel carries only its LFO phase, damping memory and feedback history, so channels run in parallel
/// with identical bits on any core count.
final class FlangerProcessor: StepProcessor {
    private let channelState: ChannelStates<bake.dsp.FlangerState>
    private let workers: Int
    private let delay: bake.dsp.ParameterSignal
    private let rate: bake.dsp.ParameterSignal
    private let depth: bake.dsp.ParameterSignal
    private let feedback: bake.dsp.ParameterSignal
    private let mix: bake.dsp.ParameterSignal
    private let polarity: bake.dsp.FlangerPolarity
    private let interpolation: bake.dsp.FlangerInterpolation
    private let hfDamping: Double
    private let hfDampingSignal: bake.dsp.ParameterSignal
    private let sampleRate: Double
    private let delayLineFrames: Int
    private let inputs: [UnsafeMutableBufferPointer<Float>]
    private let outputs: [UnsafeMutableBufferPointer<Float>]
    private let throughZero: Bool
    private let controls: bake.dsp.FlangerThroughZero
    private let dispersionSections: Int32
    /// One whole-channel copy per channel, only when Dispersion is on; filled on the first chunk.
    private let dispersed: [UnsafeMutablePointer<Float>]
    private var prepared = false

    init(step: RenderStep, sampleRate: Double, pool: BufferPool, workers: Int = Parallel.coreCount) throws {
        guard let input = step.inputs["in"], let output = step.outputs["out"] else {
            throw RenderError.unsupportedNode(step.kind)
        }
        delay = bake.dsp.ParameterSignal("delay", of: step, pool: pool)
        rate = bake.dsp.ParameterSignal("rate", of: step, pool: pool)
        depth = bake.dsp.ParameterSignal("depth", of: step, pool: pool)
        feedback = bake.dsp.ParameterSignal("feedback", of: step, pool: pool)
        mix = bake.dsp.ParameterSignal("mix", of: step, pool: pool)
        var polarityName = "positive"
        if case .choice(let value)? = step.parameters["feedbackPolarity"] { polarityName = value }
        polarity = polarityName == "negative" ? .negative : .positive
        var interpolationName = "cubic"
        if case .choice(let value)? = step.parameters["interpolation"] { interpolationName = value }
        interpolation = interpolationName == "linear" ? .linear : .cubic
        hfDamping = step.parameters["hfDamping"]?.numberValue ?? 0.2
        hfDampingSignal = bake.dsp.ParameterSignal("hfDamping", of: step, pool: pool)
        self.sampleRate = sampleRate
        // Saved documents are migrated to `causal` (ProjectMigration), so this fallback only matters for a step built without it.
        var readHead = "causal"
        if case .choice(let value)? = step.parameters["readHead"] { readHead = value }
        throughZero = readHead == "throughZero"
        var wetName = "positive"
        if case .choice(let value)? = step.parameters["wetPolarity"] { wetName = value }
        dispersionSections = throughZero ? Int32(bake.dsp.flangerDispersionSections(step.parameters["dispersion"]?.numberValue ?? 0)) : 0
        // A causal Flanger from before the Delay range widened keeps its 15 ms line, so its output keeps its exact bits;
        // everything else reaches 50 ms.
        var isLegacy = false
        if case .choice(let value)? = step.parameters[LegacyModulationRanges.parameterID] { isLegacy = value == LegacyModulationRanges.legacy }
        let reachMs = throughZero || !isLegacy ? 50.0 : 15.0 // flangerThroughZeroMaxMs in Flanger.h
        delayLineFrames = throughZero
            ? bake.dsp.flangerHistoryFrames(sampleRate, reachMs)
            : Int((sampleRate * reachMs / 1_000).rounded(.up)) + 8
        var controls = bake.dsp.FlangerThroughZero()
        controls.delayMs = delay
        controls.rateHz = rate
        controls.depth = depth
        controls.feedback = feedback
        controls.mix = mix
        controls.hfDampingSignal = hfDampingSignal
        controls.feedbackPolarity = polarity
        controls.wetPolarity = wetName == "negative" ? .negative : .positive
        controls.interpolation = interpolation
        controls.hfDamping = hfDamping
        controls.sampleRate = sampleRate
        controls.lookaheadSamples = bake.dsp.flangerDispersionDelay(dispersionSections)
        self.controls = controls
        inputs = (0..<input.shape.channels).map { pool.channel($0, of: input) }
        outputs = (0..<output.shape.channels).map { pool.channel($0, of: output) }
        self.workers = max(workers, 1)
        channelState = ChannelStates(
            channels: output.shape.channels, initial: bake.dsp.FlangerState(), historyFloats: delayLineFrames, scratchFloats: 1
        )
        if dispersionSections > 0 {
            try NodeMemory.require(bytes: output.shape.channels * input.shape.frames * MemoryLayout<Float>.stride)
        }
        dispersed = dispersionSections > 0
            ? (0..<output.shape.channels).map { channel in
                let frames = channel < input.shape.channels ? pool.channel(channel, of: input).count : 0
                let buffer = UnsafeMutablePointer<Float>.allocate(capacity: max(frames, 1))
                buffer.initialize(repeating: 0, count: max(frames, 1))
                return buffer
            }
            : []
    }

    deinit {
        for buffer in dispersed { buffer.deallocate() }
    }

    func process(frames: Range<Int>) async throws {
        if dispersionSections > 0, !prepared {
            prepared = true
            // The all-pass chain is the same however the render is chunked: one pass over the whole channel.
            Parallel.forEach(outputs.count, workers: workers) { channel in
                guard let source = inputs[channel].baseAddress else { return }
                bake.dsp.renderFlangerDispersion(source, inputs[channel].count, dispersed[channel], dispersionSections)
            }
        }
        Parallel.forEach(outputs.count, workers: workers) { channel in
            guard let source = inputs[channel].baseAddress, let destination = outputs[channel].baseAddress else { return }
            if throughZero {
                let wet = dispersed.isEmpty ? UnsafePointer(source) : UnsafePointer(dispersed[channel])
                bake.dsp.renderFlangerThroughZero(
                    &channelState.states[channel], controls, source, wet, inputs[channel].count,
                    channelState.histories[channel], delayLineFrames,
                    destination + frames.lowerBound, frames.lowerBound, frames.count
                )
            } else {
                bake.dsp.renderFlanger(
                    &channelState.states[channel], delay, rate, depth, feedback, mix, polarity, interpolation, hfDamping, hfDampingSignal, sampleRate,
                    channelState.histories[channel], delayLineFrames, source + frames.lowerBound, destination + frames.lowerBound,
                    frames.lowerBound, frames.count
                )
            }
        }
    }

    func finish() throws -> PendingOutput? { nil }

    func discard() {}
}
