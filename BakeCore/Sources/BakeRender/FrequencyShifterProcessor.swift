import BakeDSP
import BakeGraph

/// Frequency Shifter node. The whole file's Hilbert transform is computed on the first chunk (independent FFT blocks
/// across all cores) and the shift's phase is checkpointed every 1,024 frames; after that each chunk is a stateless
/// rotation of the signal and its transform, so the output is the same at any chunk size or core count.
final class FrequencyShifterProcessor: StepProcessor {
    private let input: bake.dsp.AudioInput
    private let channels: Int
    private let outputs: [UnsafeMutableBufferPointer<Float>]
    private let ups: [UnsafeMutableBufferPointer<Float>]
    private let downs: [UnsafeMutableBufferPointer<Float>]
    private let shift: bake.dsp.ParameterSignal
    private let mix: bake.dsp.ParameterSignal
    private let precision: Int32
    private let sampleRate: Double
    private let frames: Int
    private let workers: Int
    private var transforms: [UnsafeMutablePointer<Float>] = []
    private var signedCheckpoints: [Double] = []
    private var absoluteCheckpoints: [Double] = []
    private var prepared = false

    init(step: RenderStep, sampleRate: Double, pool: BufferPool, workers: Int = Parallel.coreCount) throws {
        guard step.outputs["out"] != nil || step.outputs["up"] != nil || step.outputs["down"] != nil else {
            throw RenderError.unsupportedNode(step.kind)
        }
        input = bake.dsp.AudioInput("in", of: step, pool: pool)
        channels = Int(input.channelCount)
        outputs = step.outputs["out"].map { binding in (0..<binding.shape.channels).map { pool.channel($0, of: binding) } } ?? []
        ups = step.outputs["up"].map { binding in (0..<binding.shape.channels).map { pool.channel($0, of: binding) } } ?? []
        downs = step.outputs["down"].map { binding in (0..<binding.shape.channels).map { pool.channel($0, of: binding) } } ?? []
        shift = bake.dsp.ParameterSignal("shift", of: step, pool: pool)
        mix = bake.dsp.ParameterSignal("mix", of: step, pool: pool)
        switch step.parameters["precision"] {
        case .choice("standard")?: precision = 0
        case .choice("maximum")?: precision = 2
        default: precision = 1
        }
        self.sampleRate = sampleRate
        frames = input.frames
        self.workers = max(workers, 1)
        let tableBytes = Int(bake.dsp.hilbertTableDoubles(precision)) * MemoryLayout<Double>.stride
        let scratchBytes = Int(bake.dsp.hilbertScratchDoubles(precision)) * MemoryLayout<Double>.stride * self.workers
        let transformBytes = frames * MemoryLayout<Float>.stride * channels
        let checkpointBytes = Int(bake.dsp.shiftCheckpointCount(frames)) * MemoryLayout<Double>.stride * 2
        try NodeMemory.require(bytes: tableBytes + scratchBytes + transformBytes + checkpointBytes)
    }

    deinit { for transform in transforms { transform.deallocate() } }

    private func analyze() {
        guard frames > 0, channels > 0 else { return }
        let frames = frames, input = input, precision = precision, channels = channels
        let blockFrames = Int(bake.dsp.hilbertBlockFrames(precision))
        let blocksPerChannel = (frames + blockFrames - 1) / blockFrames
        transforms = (0..<channels).map { _ in
            let buffer = UnsafeMutablePointer<Float>.allocate(capacity: frames)
            buffer.initialize(repeating: 0, count: frames)
            return buffer
        }
        let transforms = transforms
        var tables = [Double](repeating: 0, count: Int(bake.dsp.hilbertTableDoubles(precision)))
        bake.dsp.hilbertDesign(precision, &tables)
        let scratchDoubles = Int(bake.dsp.hilbertScratchDoubles(precision))
        tables.withUnsafeBufferPointer { tableBuffer in
            let tableBase = tableBuffer.baseAddress
            Parallel.forEach(channels * blocksPerChannel, workers: workers) { task in
                let channel = task / blocksPerChannel
                let first = (task % blocksPerChannel) * blockFrames
                let count = min(blockFrames, frames - first)
                let scratch = UnsafeMutablePointer<Double>.allocate(capacity: scratchDoubles)
                defer { scratch.deallocate() }
                bake.dsp.hilbertBlock(input, channel, precision, tableBase, scratch, first, count, transforms[channel] + first)
            }
        }
        let count = Int(bake.dsp.shiftCheckpointCount(frames))
        signedCheckpoints = [Double](repeating: 0, count: count)
        bake.dsp.shiftCheckpoints(shift, false, sampleRate, frames, &signedCheckpoints)
        if !ups.isEmpty || !downs.isEmpty {
            absoluteCheckpoints = [Double](repeating: 0, count: count)
            bake.dsp.shiftCheckpoints(shift, true, sampleRate, frames, &absoluteCheckpoints)
        }
    }

    func process(frames range: Range<Int>) async throws {
        if !prepared {
            prepared = true
            analyze()
        }
        guard channels > 0 else { return }
        let input = input, shift = shift, mix = mix, rate = sampleRate
        let transforms = transforms
        let outputs = outputs, ups = ups, downs = downs
        let signedBase = signedCheckpoints, absoluteBase = absoluteCheckpoints
        signedBase.withUnsafeBufferPointer { signedBuffer in
            absoluteBase.withUnsafeBufferPointer { absoluteBuffer in
                Parallel.forEach(channels, workers: workers) { channel in
                    let transform = UnsafePointer(transforms[channel])
                    if channel < outputs.count, let base = outputs[channel].baseAddress {
                        bake.dsp.shiftRender(
                            input, channel, transform, shift, false, 1, rate, signedBuffer.baseAddress,
                            range.lowerBound, range.count, base + range.lowerBound, mix, true
                        )
                    }
                    if channel < ups.count, let base = ups[channel].baseAddress {
                        bake.dsp.shiftRender(
                            input, channel, transform, shift, true, 1, rate, absoluteBuffer.baseAddress,
                            range.lowerBound, range.count, base + range.lowerBound, mix, false
                        )
                    }
                    if channel < downs.count, let base = downs[channel].baseAddress {
                        bake.dsp.shiftRender(
                            input, channel, transform, shift, true, -1, rate, absoluteBuffer.baseAddress,
                            range.lowerBound, range.count, base + range.lowerBound, mix, false
                        )
                    }
                }
            }
        }
    }

    func finish() throws -> PendingOutput? { nil }

    func discard() {}
}
