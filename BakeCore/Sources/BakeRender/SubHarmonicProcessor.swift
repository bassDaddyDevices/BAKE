import BakeDSP
import BakeGraph

/// Sub-Harmonic Synth on the CPU engine: one mono sub from the input's mono sum, added to every channel. The causal
/// analysis follows the input chunk by chunk; the whole-file analysis builds the sub for the entire file on the first
/// chunk (zero-phase filters, lookahead envelope). Channels are added on separate cores.
final class SubHarmonicProcessor: StepProcessor {
    private var state = bake.dsp.SubHarmonicState()
    private let controls: bake.dsp.SubHarmonicControls
    private let input: bake.dsp.AudioInput
    private let inputs: [UnsafeMutableBufferPointer<Float>]
    private let outputs: [UnsafeMutableBufferPointer<Float>]
    /// Allocated once; never inside the processing loop.
    private let sub: UnsafeMutablePointer<Float>
    private let wholeFile: Bool
    private let totalFrames: Int
    private let workers: Int
    /// Whole-file analysis: the sub for every frame, built on the first chunk.
    private let wholeSub: UnsafeMutablePointer<Float>?
    private var prepared = false

    init(step: RenderStep, sampleRate: Double, pool: BufferPool, maxChunkFrames: Int, workers: Int = Parallel.coreCount) throws {
        guard let inputBinding = step.inputs["in"], let outputBinding = step.outputs["out"] else {
            throw RenderError.unsupportedNode(step.kind)
        }
        var controls = bake.dsp.SubHarmonicControls()
        controls.sub1 = bake.dsp.ParameterSignal("sub1", of: step, pool: pool)
        controls.sub2 = bake.dsp.ParameterSignal("sub2", of: step, pool: pool)
        controls.tone = bake.dsp.ParameterSignal("tone", of: step, pool: pool)
        controls.dry = bake.dsp.ParameterSignal("dry", of: step, pool: pool)
        controls.track = bake.dsp.ParameterSignal("track", of: step, pool: pool)
        controls.release = bake.dsp.ParameterSignal("release", of: step, pool: pool)
        controls.sampleRate = sampleRate
        self.controls = controls
        input = bake.dsp.AudioInput("in", of: step, pool: pool)
        inputs = (0..<inputBinding.shape.channels).map { pool.channel($0, of: inputBinding) }
        outputs = (0..<outputBinding.shape.channels).map { pool.channel($0, of: outputBinding) }
        sub = UnsafeMutablePointer<Float>.allocate(capacity: max(maxChunkFrames, 1))
        sub.initialize(repeating: 0, count: max(maxChunkFrames, 1))
        // Documents without this setting are older ones: the causal analysis.
        var analysis = "causal"
        if case .choice(let value)? = step.parameters["analysis"] { analysis = value }
        wholeFile = analysis == "wholeFile"
        let frames = max(inputs.first?.count ?? 0, 1)
        totalFrames = frames
        self.workers = max(workers, 1)
        if wholeFile {
            // The whole-file sub signal, plus a channel's worth of analysis scratch per worker.
            try NodeMemory.require(
                bytes: frames * MemoryLayout<Float>.stride
                    + Int(bake.dsp.subHarmonicWholeFileScratchDoubles(frames)) * MemoryLayout<Double>.stride * max(workers, 1)
            )
            let buffer = UnsafeMutablePointer<Float>.allocate(capacity: frames)
            buffer.initialize(repeating: 0, count: frames)
            wholeSub = buffer
        } else {
            wholeSub = nil
        }
    }

    deinit {
        sub.deallocate()
        wholeSub?.deallocate()
    }

    func process(frames: Range<Int>) async throws {
        let subChunk: UnsafePointer<Float>
        if wholeFile, let wholeSub {
            if !prepared {
                prepared = true
                let doubles = Int(bake.dsp.subHarmonicWholeFileScratchDoubles(totalFrames))
                let scratch = UnsafeMutablePointer<Double>.allocate(capacity: max(doubles, 1))
                scratch.initialize(repeating: 0, count: max(doubles, 1))
                defer { scratch.deallocate() }
                bake.dsp.renderSubHarmonicWholeFile(controls, input, totalFrames, wholeSub, scratch)
            }
            subChunk = UnsafePointer(wholeSub + frames.lowerBound)
        } else {
            bake.dsp.renderSubHarmonic(&state, controls, input, sub, frames.lowerBound, frames.count)
            subChunk = UnsafePointer(sub)
        }
        Parallel.forEach(outputs.count, workers: workers) { channel in
            guard let destination = outputs[channel].baseAddress else { return }
            let source = inputs[min(channel, inputs.count - 1)]
            guard let dry = source.baseAddress else { return }
            bake.dsp.addSubHarmonic(controls, dry, source.count, subChunk, destination + frames.lowerBound, frames.lowerBound, frames.count)
        }
    }

    func finish() throws -> PendingOutput? { nil }

    func discard() {}
}
