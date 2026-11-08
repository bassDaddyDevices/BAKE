import BakeDSP
import BakeGraph

/// Vocoder: the modulator's band levels over time, imposed on the carrier (see BakeDSP/Vocoder.h).
/// The modulator is analysed when the first chunk arrives (its inputs are complete by then, the same as every other
/// node that looks ahead): the STFT band levels in pieces across the cores, then the followers in order. Every chunk
/// after that is independent, so frame-range pieces of every channel run across the cores and give the same bits.
final class VocoderProcessor: StepProcessor {
    private var settings = bake.dsp.VocoderSettings()
    private var modulation = bake.dsp.VocoderModulation()
    private let sampleRate: Double
    private let formantShift: bake.dsp.ParameterSignal
    private let mix: bake.dsp.ParameterSignal
    private let modulator: bake.dsp.AudioInput
    private let carriers: [UnsafeMutableBufferPointer<Float>]
    private let outputs: [UnsafeMutableBufferPointer<Float>]
    private let frameCount: Int

    // Allocated once, here; never in the processing loop.
    private let mono: UnsafeMutablePointer<Float>
    private let envelope: UnsafeMutablePointer<Float>
    private let envelopeCount: Int
    private let workers: Int
    private let scratchCount: Int
    /// One scratch and analysis work per worker, for the parallel analysis.
    private let analysisScratch: [UnsafeMutablePointer<Double>]
    private let analysisWork: [UnsafeMutablePointer<Float>]
    private let analysisWorkCount: Int
    /// Render pieces: each gets its work floats, then (16-byte aligned) its double scratch.
    private let plan: PiecePlan
    private var analysed = false

    init(step: RenderStep, sampleRate: Double, pool: BufferPool, maxChunkFrames: Int, workers: Int = Parallel.coreCount) throws {
        guard let carrier = step.inputs["carrier"], let output = step.outputs["out"] else {
            throw RenderError.unsupportedNode(step.kind)
        }
        self.sampleRate = sampleRate
        settings.bands = Int32((step.parameters["bands"]?.numberValue ?? 32).rounded())
        settings.attackMilliseconds = step.parameters["attack"]?.numberValue ?? 10
        settings.releaseMilliseconds = step.parameters["release"]?.numberValue ?? 80
        settings.sibilance = step.parameters["sibilance"]?.numberValue ?? 0.3
        modulation.attack = bake.dsp.ParameterSignal("attack", of: step, pool: pool)
        modulation.release = bake.dsp.ParameterSignal("release", of: step, pool: pool)
        modulation.sibilance = bake.dsp.ParameterSignal("sibilance", of: step, pool: pool)
        var spacing = "logarithmic"
        if case .choice(let value)? = step.parameters["spacing"] { spacing = value }
        switch spacing {
        case "linear": settings.spacing = .linear
        case "bark": settings.spacing = .bark
        case "mel": settings.spacing = .mel
        default: settings.spacing = .logarithmic
        }
        formantShift = bake.dsp.ParameterSignal("formantShift", of: step, pool: pool)
        mix = bake.dsp.ParameterSignal("mix", of: step, pool: pool)
        modulator = bake.dsp.AudioInput("modulator", of: step, pool: pool)
        carriers = (0..<carrier.shape.channels).map { pool.channel($0, of: carrier) }
        outputs = (0..<output.shape.channels).map { pool.channel($0, of: output) }
        frameCount = output.shape.frames

        let frames = max(frameCount, 1)
        // The mono modulator, the envelope, and the band levels held (in doubles) between the two analysis passes.
        try NodeMemory.require(
            bytes: frames * MemoryLayout<Float>.stride + Int(bake.dsp.vocoderEnvelopeFloats(settings, frameCount)) * MemoryLayout<Float>.stride
                + Int(bake.dsp.vocoderLevelDoubles(settings, frameCount)) * MemoryLayout<Double>.stride
        )
        mono = .allocate(capacity: frames)
        mono.initialize(repeating: 0, count: frames)
        envelopeCount = max(Int(bake.dsp.vocoderEnvelopeFloats(settings, frameCount)), 1)
        envelope = .allocate(capacity: envelopeCount)
        envelope.initialize(repeating: 0, count: envelopeCount)
        self.workers = max(workers, 1)
        scratchCount = max(Int(bake.dsp.vocoderScratchDoubles(settings)), 1)
        analysisWorkCount = max(Int(bake.dsp.vocoderAnalysisWorkFloats()), 1)
        let count = scratchCount
        let workCount = analysisWorkCount
        analysisScratch = (0..<max(workers, 1)).map { _ in
            let buffer = UnsafeMutablePointer<Double>.allocate(capacity: count)
            buffer.initialize(repeating: 0, count: count)
            return buffer
        }
        analysisWork = (0..<max(workers, 1)).map { _ in
            let buffer = UnsafeMutablePointer<Float>.allocate(capacity: workCount)
            buffer.initialize(repeating: 0, count: workCount)
            return buffer
        }
        let capturedSettings = settings
        plan = PiecePlan(channels: output.shape.channels, maxChunkFrames: max(maxChunkFrames, 1), workers: workers) { piece in
            // Work floats, rounded up to a multiple of 4 so the doubles after them are aligned, then the scratch.
            let work = (Int(bake.dsp.vocoderWorkFloats(piece)) + 3) / 4 * 4
            return work + 2 * Int(bake.dsp.vocoderScratchDoubles(capturedSettings)) + 4
        }
    }

    deinit {
        mono.deallocate()
        envelope.deallocate()
        for buffer in analysisScratch { buffer.deallocate() }
        for buffer in analysisWork { buffer.deallocate() }
    }

    func process(frames: Range<Int>) async throws {
        if !analysed {
            analyse()
            analysed = true
        }
        plan.run(channels: outputs.count, frames: frames) { channel, piece, floats in
            guard let source = carriers[min(channel, carriers.count - 1)].baseAddress,
                  let destination = outputs[channel].baseAddress else { return }
            let workFloats = (Int(bake.dsp.vocoderWorkFloats(piece.count)) + 3) / 4 * 4
            let scratch = UnsafeMutableRawPointer(floats + workFloats).assumingMemoryBound(to: Double.self)
            bake.dsp.vocoderRender(
                settings, modulation, sampleRate, formantShift, mix, source, mono, frameCount, envelope,
                destination + piece.lowerBound, piece.lowerBound, piece.count, scratch, floats
            )
        }
    }

    /// The modulator's envelope: band levels of the STFT frames in pieces across the cores, then the followers in order.
    private func analyse() {
        bake.dsp.vocoderMixModulator(modulator, frameCount, mono)
        let stftFrames = Int(bake.dsp.vocoderStftFrames(frameCount))
        let levelCount = max(Int(bake.dsp.vocoderLevelDoubles(settings, frameCount)), 1)
        let levels = UnsafeMutablePointer<Double>.allocate(capacity: levelCount)
        levels.initialize(repeating: 0, count: levelCount)
        defer { levels.deallocate() }
        let pieces = max(min(workers, stftFrames), 1)
        let size = (stftFrames + pieces - 1) / pieces
        Parallel.forEach(pieces, workers: workers) { piece in
            let first = piece * size
            let count = min(size, stftFrames - first)
            guard count > 0 else { return }
            bake.dsp.vocoderAnalyseLevels(
                settings, sampleRate, mono, frameCount, first, count, levels, analysisScratch[piece], analysisWork[piece]
            )
        }
        bake.dsp.vocoderSmoothLevels(settings, modulation, sampleRate, frameCount, levels, envelope)
    }

    func finish() throws -> PendingOutput? { nil }

    func discard() {}
}
