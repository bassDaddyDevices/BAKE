import BakeDSP
import BakeGraph

/// Dual Filter on the CPU engine; each channel carries both filter paths and the (shared-timing) LFO, and channels run
/// on separate cores. Drive can be oversampled (a stateless pass over each chunk before the filters), and Phase "zero"
/// filters each path forward and backward over the whole file on the first chunk.
final class DualFilterProcessor: StepProcessor {
    private let controls: bake.dsp.DualFilterControls
    private let inputs: [UnsafeMutableBufferPointer<Float>]
    private let outputs: [UnsafeMutableBufferPointer<Float>]
    private let channelState: ChannelStates<bake.dsp.DualFilterState>
    private let workers: Int
    private let oversampling: Int32
    private let zeroPhase: Bool
    private let totalFrames: Int
    /// Drive pass, when oversampled.
    private let plan: PiecePlan?
    private let maxChunkFrames: Int
    /// One buffer per channel: this chunk's driven frames (minimum phase) or the whole file's (zero phase).
    private let driven: [UnsafeMutablePointer<Float>]
    /// Zero phase: the whole filtered channel, built on the first chunk.
    private let zeroOutput: [UnsafeMutablePointer<Float>]
    private var prepared = false

    init(
        step: RenderStep, sampleRate: Double, pool: BufferPool,
        maxChunkFrames: Int = 65_536, workers: Int = Parallel.coreCount
    ) throws {
        guard let input = step.inputs["in"], let output = step.outputs["out"] else {
            throw RenderError.unsupportedNode(step.kind)
        }
        func choice(_ id: ParameterID, _ fallback: String) -> String {
            if case .choice(let value)? = step.parameters[id] { value } else { fallback }
        }
        func filterType(_ name: String) -> bake.dsp.FilterType {
            switch name {
            case "highpass": .highpass
            case "bandpass": .bandpass
            case "notch": .notch
            default: .lowpass
            }
        }
        var controls = bake.dsp.DualFilterControls()
        controls.cutoff = bake.dsp.ParameterSignal("cutoff", of: step, pool: pool)
        controls.q = bake.dsp.ParameterSignal("q", of: step, pool: pool)
        controls.bandwidth = bake.dsp.ParameterSignal("bandwidth", of: step, pool: pool)
        controls.morph = bake.dsp.ParameterSignal("morph", of: step, pool: pool)
        controls.lfoRate = bake.dsp.ParameterSignal("lfoRate", of: step, pool: pool)
        controls.lfoDepth = bake.dsp.ParameterSignal("lfoDepth", of: step, pool: pool)
        controls.drive = bake.dsp.ParameterSignal("drive", of: step, pool: pool)
        controls.mix = bake.dsp.ParameterSignal("mix", of: step, pool: pool)
        controls.alphaTypeIndex = bake.dsp.ParameterSignal("alphaType", of: step, pool: pool)
        controls.betaTypeIndex = bake.dsp.ParameterSignal("betaType", of: step, pool: pool)
        controls.lfoShapeIndex = bake.dsp.ParameterSignal("lfoShape", of: step, pool: pool)
        controls.lfoPhaseIndex = bake.dsp.ParameterSignal("lfoPhase", of: step, pool: pool)
        controls.alphaType = filterType(choice("alphaType", "lowpass"))
        controls.betaType = filterType(choice("betaType", "highpass"))
        controls.lfoShape = switch choice("lfoShape", "sine") {
        case "triangle": .triangle
        case "saw": .saw
        case "square": .square
        case "sampleAndHold": .sampleAndHold
        default: .sine
        }
        controls.inverted = choice("lfoPhase", "inverted") != "inPhase"
        controls.sections = (Int32(choice("slope", "24")) ?? 24) / 12
        // Documents without these settings are older ones: minimum phase, a coefficient step every 32 frames, Drive at 1x.
        controls.perSample = choice("coefficients", "block") == "perSample"
        controls.seed = UInt64(max(step.parameters["seed"]?.numberValue ?? 1, 0).rounded())
        controls.sampleRate = sampleRate
        self.controls = controls
        inputs = (0..<input.shape.channels).map { pool.channel($0, of: input) }
        outputs = (0..<output.shape.channels).map { pool.channel($0, of: output) }
        self.workers = max(workers, 1)
        self.maxChunkFrames = max(maxChunkFrames, 1)
        let factor = Int32(choice("oversampling", "1")) ?? 1
        oversampling = factor
        let zero = choice("phase", "minimum") == "zero"
        zeroPhase = zero
        let frames = max(inputs.first?.count ?? 0, 1)
        totalFrames = frames
        let channels = output.shape.channels
        channelState = ChannelStates(channels: channels, initial: bake.dsp.DualFilterState(), historyFloats: 1, scratchFloats: 1)
        func buffers(_ count: Int, _ floats: Int) -> [UnsafeMutablePointer<Float>] {
            (0..<count).map { _ in
                let buffer = UnsafeMutablePointer<Float>.allocate(capacity: max(floats, 1))
                buffer.initialize(repeating: 0, count: max(floats, 1))
                return buffer
            }
        }
        // Whole-file buffers (zero-phase), the driven rows, and each worker's zero-phase scratch (sized for per-sample coefficients).
        let wholeFileFloats = zero ? channels * frames * (factor > 1 ? 2 : 1) : (factor > 1 ? channels * max(maxChunkFrames, 1) : 0)
        let zeroScratchBytes = zero ? Int(bake.dsp.dualFilterZeroPhaseScratchDoubles(frames, true)) * MemoryLayout<Double>.stride * max(workers, 1) : 0
        try NodeMemory.require(bytes: wholeFileFloats * MemoryLayout<Float>.stride + zeroScratchBytes)
        if factor > 1 {
            plan = PiecePlan(channels: channels, maxChunkFrames: max(maxChunkFrames, 1), workers: workers) {
                Int(bake.dsp.dualFilterDriveScratchFloats(factor, $0))
            }
            driven = buffers(channels, zero ? frames : max(maxChunkFrames, 1))
        } else {
            plan = nil
            driven = []
        }
        zeroOutput = zero ? buffers(channels, frames) : []
    }

    deinit {
        for buffer in driven { buffer.deallocate() }
        for buffer in zeroOutput { buffer.deallocate() }
    }

    /// Drive at the oversampled rate for `block`, written so that frame `base` lands at index 0 of each channel's buffer.
    private func runDrive(block: Range<Int>, base: Int) {
        guard let plan else { return }
        plan.run(channels: outputs.count, frames: block) { channel, piece, work in
            let source = inputs[min(channel, inputs.count - 1)]
            guard let start = source.baseAddress else { return }
            bake.dsp.renderDualFilterDrive(
                controls, oversampling, start, source.count, driven[channel] + (piece.lowerBound - base),
                piece.lowerBound, piece.count, work
            )
        }
    }

    /// Zero phase: filters every channel's whole file at once.
    private func prepareZeroPhase() {
        if plan != nil {
            var start = 0
            while start < totalFrames {
                let end = min(start + maxChunkFrames, totalFrames)
                runDrive(block: start..<end, base: 0)
                start = end
            }
        }
        Parallel.forEach(outputs.count, workers: workers) { channel in
            let source = inputs[min(channel, inputs.count - 1)]
            guard let start = source.baseAddress else { return }
            let frames = source.count
            let doubles = Int(bake.dsp.dualFilterZeroPhaseScratchDoubles(frames, controls.perSample))
            let scratch = UnsafeMutablePointer<Double>.allocate(capacity: max(doubles, 1))
            scratch.initialize(repeating: 0, count: max(doubles, 1))
            defer { scratch.deallocate() }
            bake.dsp.renderDualFilterZeroPhase(
                controls, start, plan != nil ? UnsafePointer(driven[channel]) : nil, frames, zeroOutput[channel], scratch
            )
        }
    }

    func process(frames: Range<Int>) async throws {
        if zeroPhase {
            if !prepared {
                prepared = true
                prepareZeroPhase()
            }
            for channel in outputs.indices {
                guard let destination = outputs[channel].baseAddress else { continue }
                (destination + frames.lowerBound).update(from: zeroOutput[channel] + frames.lowerBound, count: frames.count)
            }
            return
        }
        runDrive(block: frames, base: frames.lowerBound)
        Parallel.forEach(outputs.count, workers: workers) { channel in
            guard let source = inputs[min(channel, inputs.count - 1)].baseAddress,
                  let destination = outputs[channel].baseAddress else { return }
            bake.dsp.renderDualFilterDriven(
                &channelState.states[channel], controls, source + frames.lowerBound, destination + frames.lowerBound,
                frames.lowerBound, frames.count, plan != nil ? UnsafePointer(driven[channel]) : nil
            )
        }
    }

    func finish() throws -> PendingOutput? { nil }

    func discard() {}
}
