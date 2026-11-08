import BakeDSP
import BakeGraph

/// Filters node on the CPU engine: a carried biquad cascade per channel (minimum phase), or a
/// linear-phase FIR that reads the whole channel (no delay, no phase shift). Channels share nothing, so
/// they run in parallel with identical bits on any core count.
final class FiltersProcessor: StepProcessor {
    private let channelState: ChannelStates<bake.dsp.FilterState>
    private let workers: Int
    private let type: bake.dsp.FilterType
    private let sections: Int32
    private let isLinearPhase: Bool
    private let taps: Int32
    private let cutoff: bake.dsp.ParameterSignal
    private let q: bake.dsp.ParameterSignal
    private let drive: bake.dsp.ParameterSignal
    private let typeIndex: bake.dsp.ParameterSignal
    private let sampleRate: Double
    private let inputs: [UnsafeMutableBufferPointer<Float>]
    private let outputs: [UnsafeMutableBufferPointer<Float>]
    /// One block per channel for the linear-phase FFTs, allocated once; never inside the processing loop.
    private let scratch: [UnsafeMutablePointer<Double>]

    init(step: RenderStep, sampleRate: Double, pool: BufferPool, workers: Int = Parallel.coreCount) throws {
        guard let input = step.inputs["in"], let output = step.outputs["out"] else {
            throw RenderError.unsupportedNode(step.kind)
        }
        var typeName = "lowpass"
        if case .choice(let value)? = step.parameters["type"] { typeName = value }
        type = switch typeName {
        case "highpass": .highpass
        case "bandpass": .bandpass
        case "notch": .notch
        default: .lowpass
        }
        var slope = "24"
        if case .choice(let value)? = step.parameters["slope"] { slope = value }
        sections = Int32((Int(slope) ?? 24) / 12)
        // A document without these settings is an older one: the biquad filter.
        var phaseName = "minimum"
        if case .choice(let value)? = step.parameters["phase"] { phaseName = value }
        isLinearPhase = phaseName == "linear"
        var tapName = "4097"
        if case .choice(let value)? = step.parameters["firTaps"] { tapName = value }
        taps = Int32(tapName) ?? 4_097
        cutoff = bake.dsp.ParameterSignal("cutoff", of: step, pool: pool)
        q = bake.dsp.ParameterSignal("q", of: step, pool: pool)
        drive = bake.dsp.ParameterSignal("drive", of: step, pool: pool)
        typeIndex = bake.dsp.ParameterSignal("type", of: step, pool: pool)
        self.sampleRate = sampleRate
        inputs = (0..<input.shape.channels).map { pool.channel($0, of: input) }
        outputs = (0..<output.shape.channels).map { pool.channel($0, of: output) }
        self.workers = max(workers, 1)
        channelState = ChannelStates(channels: outputs.count, initial: bake.dsp.FilterState(), historyFloats: 0, scratchFloats: 1)
        // A moving Type also needs the cross-faded (larger) linear-phase workspace.
        let moves = cutoff.modulation != nil || q.modulation != nil || typeIndex.modulation != nil
        let doubles = isLinearPhase ? max(bake.dsp.linearPhaseScratchDoubles(taps, moves), 1) : 1
        scratch = (0..<max(outputs.count, 1)).map { _ in
            let buffer = UnsafeMutablePointer<Double>.allocate(capacity: doubles)
            buffer.initialize(repeating: 0, count: doubles)
            return buffer
        }
    }

    deinit {
        for buffer in scratch { buffer.deallocate() }
    }

    func process(frames: Range<Int>) async throws {
        Parallel.forEach(outputs.count, workers: workers) { channel in
            guard let source = inputs[channel].baseAddress, let destination = outputs[channel].baseAddress else { return }
            if isLinearPhase {
                bake.dsp.renderLinearPhaseFilter(
                    type, typeIndex, taps, cutoff, q, drive, sampleRate, source, inputs[channel].count,
                    destination + frames.lowerBound, frames.lowerBound, frames.count, scratch[channel]
                )
            } else {
                bake.dsp.renderFilter(
                    &channelState.states[channel], type, typeIndex, sections, cutoff, q, drive, sampleRate,
                    source + frames.lowerBound, destination + frames.lowerBound, frames.lowerBound, frames.count
                )
            }
        }
    }

    func finish() throws -> PendingOutput? { nil }

    func discard() {}
}
