import BakeDSP
import BakeGraph

/// The Pitch Follower on the CPU engine. The kernel's estimates live here for the whole render, because estimates made
/// for one chunk are read again by the next. Estimates are independent of each other, so each chunk's new ones are
/// analysed across all cores (one scratch per core); everything after that is cheap and serial.
final class PitchFollowerProcessor: StepProcessor {
    private var state = bake.dsp.PitchFollowerState()
    private let controls: bake.dsp.PitchFollowerControls
    private let input: bake.dsp.AudioInput
    private let estimateCount: Int
    private let estimates: UnsafeMutableBufferPointer<Float>
    private let scratch: UnsafeMutableBufferPointer<Double>
    private let workers: Int
    private let analysisScratch: [UnsafeMutablePointer<Double>]
    private let glideBuffer: UnsafeMutablePointer<Float>?
    private let pitch: UnsafeMutableBufferPointer<Float>?
    private let confidence: UnsafeMutableBufferPointer<Float>?

    init(step: RenderStep, sampleRate: Double, pool: BufferPool, workers: Int = Parallel.coreCount) throws {
        pitch = step.outputs["out"].map { pool.channel(0, of: $0) }
        confidence = step.outputs["confidence"].map { pool.channel(0, of: $0) }
        guard pitch != nil || confidence != nil else {
            throw RenderError.unsupportedNode(step.kind)
        }
        input = bake.dsp.AudioInput("in", of: step, pool: pool)
        var controls = bake.dsp.PitchFollowerControls()
        controls.minFreq = bake.dsp.ParameterSignal("minFreq", of: step, pool: pool)
        controls.maxFreq = bake.dsp.ParameterSignal("maxFreq", of: step, pool: pool)
        controls.glide = bake.dsp.ParameterSignal("glide", of: step, pool: pool)
        controls.threshold = bake.dsp.ParameterSignal("threshold", of: step, pool: pool)
        controls.output = bake.dsp.ParameterSignal("output", of: step, pool: pool)
        controls.unvoiced = bake.dsp.ParameterSignal("unvoiced", of: step, pool: pool)
        switch step.parameters["output"] {
        case .choice("linear")?: controls.fixedOutput = .linear
        case .choice("note")?: controls.fixedOutput = .note
        default: controls.fixedOutput = .log
        }
        switch step.parameters["unvoiced"] {
        case .choice("fallToMin")?: controls.fixedUnvoiced = .fallToMin
        case .choice("zero")?: controls.fixedUnvoiced = .zero
        default: controls.fixedUnvoiced = .hold
        }
        controls.sampleRate = sampleRate
        // Documents without these settings are older ones: the median, a causal Glide, an estimate every 5 ms.
        if case .choice("path")? = step.parameters["smoothing"] { controls.smoothing = .path }
        var hop = 5.0
        if case .choice(let value)? = step.parameters["resolution"], let milliseconds = Double(value), milliseconds > 0 { hop = milliseconds }
        controls.hopMilliseconds = hop
        let estimateBytes = Int(bake.dsp.pitchFollowerEstimateCount(input.frames, sampleRate, hop))
            * Int(bake.dsp.pitchFollowerFloatsPerEstimate()) * MemoryLayout<Float>.stride
        try NodeMemory.require(bytes: estimateBytes + input.frames * MemoryLayout<Float>.stride)
        var glide: UnsafeMutablePointer<Float>?
        if case .choice("zeroPhase")? = step.parameters["glidePhase"], input.frames > 0 {
            controls.glidePhase = .zeroPhase
            let buffer = UnsafeMutablePointer<Float>.allocate(capacity: input.frames)
            buffer.initialize(repeating: 0, count: input.frames)
            controls.glideBuffer = buffer
            controls.glideFrames = input.frames
            glide = buffer
        }
        glideBuffer = glide
        self.controls = controls
        self.workers = max(workers, 1)
        let scratchDoubles = max(Int(bake.dsp.pitchFollowerScratchDoubles(sampleRate)), 1)
        analysisScratch = (0..<max(workers, 1)).map { _ in
            let buffer = UnsafeMutablePointer<Double>.allocate(capacity: scratchDoubles)
            buffer.initialize(repeating: 0, count: scratchDoubles)
            bake.dsp.pitchFollowerPrepareScratch(sampleRate, buffer)
            return buffer
        }

        estimateCount = Int(bake.dsp.pitchFollowerEstimateCount(input.frames, sampleRate, hop))
        estimates = .allocate(capacity: max(estimateCount, 1) * Int(bake.dsp.pitchFollowerFloatsPerEstimate()))
        estimates.initialize(repeating: 0)
        scratch = .allocate(capacity: max(Int(bake.dsp.pitchFollowerScratchDoubles(sampleRate)), 1))
        scratch.initialize(repeating: 0)
    }

    deinit {
        estimates.deallocate()
        scratch.deallocate()
        for buffer in analysisScratch { buffer.deallocate() }
        glideBuffer?.deallocate()
    }

    func process(frames: Range<Int>) async throws {
        // The estimates this chunk still needs, split across the cores in consecutive pieces.
        let first = Int(state.analysed)
        let last = min(Int(bake.dsp.pitchFollowerEstimatesNeeded(state, controls, estimateCount, frames.lowerBound, frames.count)), estimateCount)
        if last > first, let base = estimates.baseAddress {
            let pieces = min(workers, last - first)
            let size = (last - first + pieces - 1) / pieces
            Parallel.forEach(pieces, workers: workers) { piece in
                let start = first + piece * size
                let end = min(start + size, last)
                guard start < end else { return }
                bake.dsp.pitchFollowerAnalyse(controls, input, base, start, end, analysisScratch[piece])
            }
            state.analysed = last
        }
        bake.dsp.renderPitchFollower(
            &state, controls, input, estimates.baseAddress, estimateCount, scratch.baseAddress,
            pitch?.baseAddress.map { $0 + frames.lowerBound }, confidence?.baseAddress.map { $0 + frames.lowerBound },
            frames.lowerBound, frames.count
        )
    }

    func finish() throws -> PendingOutput? { nil }

    func discard() {}
}
