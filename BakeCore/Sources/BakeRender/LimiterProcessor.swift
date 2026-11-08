import BakeDSP
import BakeGraph

/// Limiter node. The whole file is analysed on the first chunk (true peaks across all cores, then one serial solve of
/// the gain curve); after that each chunk is a stateless application of that curve, so the output is the same at any
/// chunk size or core count.
final class LimiterProcessor: StepProcessor {
    private let input: bake.dsp.AudioInput
    private let outputs: [UnsafeMutableBufferPointer<Float>]
    private let settings: bake.dsp.LimiterSettings
    private let gain: bake.dsp.ParameterSignal
    private let factor: Int
    private let frames: Int
    private let workers: Int
    private var curve: UnsafeMutablePointer<Float>?
    /// One curve per channel, used only when Link is below 1 and there is more than one channel.
    private var channelCurves: [UnsafeMutablePointer<Float>] = []
    private let link: Double
    private var prepared = false

    init(step: RenderStep, sampleRate: Double, pool: BufferPool, workers: Int = Parallel.coreCount) throws {
        guard let output = step.outputs["out"] else { throw RenderError.unsupportedNode(step.kind) }
        input = bake.dsp.AudioInput("in", of: step, pool: pool)
        outputs = (0..<output.shape.channels).map { pool.channel($0, of: output) }
        frames = input.frames
        var config = bake.dsp.LimiterSettings()
        config.ceilingDb = step.parameters["ceiling"]?.numberValue ?? -1
        config.lookaheadMs = step.parameters["lookahead"]?.numberValue ?? 5
        config.releaseMs = step.parameters["release"]?.numberValue ?? 100
        config.holdMs = max(step.parameters["hold"]?.numberValue ?? 0, 0)
        let linkValue = min(max(step.parameters["link"]?.numberValue ?? 1, 0), 1)
        link = linkValue
        config.sampleRate = sampleRate
        settings = config
        gain = bake.dsp.ParameterSignal("gain", of: step, pool: pool)
        if case .choice(let value)? = step.parameters["oversampling"], let parsed = Int(value) {
            factor = max(parsed, 1)
        } else {
            factor = 4
        }
        self.workers = max(workers, 1)
        // Peaks and the curve, plus what the solve keeps while it works (needed, early, widened, and a double prefix sum).
        let split = linkValue < 1 && output.shape.channels > 1
        try NodeMemory.require(bytes: frames * 28 * (split ? output.shape.channels + 1 : 1))
    }

    deinit {
        curve?.deallocate()
        for pointer in channelCurves { pointer.deallocate() }
    }

    private var separate: Bool { link < 1 && outputs.count > 1 }

    /// Link below 1: every channel is measured and solved on its own, then blended toward the largest need.
    private func analyzeSeparate() {
        let frames = frames, input = input, settings = settings, gain = gain, factor = factor
        let count = outputs.count
        let tapCount = Int(bake.dsp.limiterTapCount(Int32(factor)))
        var taps = [Float](repeating: 0, count: max(tapCount, 1))
        bake.dsp.limiterDesign(Int32(factor), &taps)
        let peaks = (0..<count).map { _ in UnsafeMutablePointer<Float>.allocate(capacity: frames) }
        defer { for pointer in peaks { pointer.deallocate() } }
        let pieces = min(workers * 4, max(frames / 4_096, 1))
        let perPiece = (frames + pieces - 1) / pieces
        taps.withUnsafeBufferPointer { tapBuffer in
            let tapBase = tapBuffer.baseAddress
            Parallel.forEach(pieces * count, workers: workers) { job in
                let channel = job % count
                let first = (job / count) * perPiece
                let length = min(perPiece, frames - first)
                guard length > 0 else { return }
                bake.dsp.limiterChannelPeaks(input, channel, Int32(factor), tapBase, first, length, peaks[channel] + first)
            }
        }
        let needs = (0..<count).map { _ in UnsafeMutablePointer<Float>.allocate(capacity: frames) }
        defer { for pointer in needs { pointer.deallocate() } }
        for channel in 0..<count {
            bake.dsp.limiterNeeded(peaks[channel], frames, gain, settings, needs[channel])
        }
        var optional = needs.map { Optional($0) }
        bake.dsp.limiterLink(&optional, Int32(count), frames, link)
        channelCurves = (0..<count).map { _ in
            let pointer = UnsafeMutablePointer<Float>.allocate(capacity: frames)
            pointer.initialize(repeating: 0, count: frames)
            return pointer
        }
        let curves = channelCurves
        Parallel.forEach(count, workers: workers) { channel in
            bake.dsp.limiterCurve(needs[channel], frames, settings, curves[channel])
        }
    }

    private func analyze() {
        guard frames > 0 else { return }
        if separate {
            analyzeSeparate()
            return
        }
        let frames = frames, input = input, settings = settings, gain = gain, factor = factor
        let peaks = UnsafeMutablePointer<Float>.allocate(capacity: frames)
        defer { peaks.deallocate() }
        let solved = UnsafeMutablePointer<Float>.allocate(capacity: frames)
        solved.initialize(repeating: 0, count: frames)
        curve = solved
        let tapCount = Int(bake.dsp.limiterTapCount(Int32(factor)))
        var taps = [Float](repeating: 0, count: max(tapCount, 1))
        bake.dsp.limiterDesign(Int32(factor), &taps)
        let pieces = min(workers * 4, max(frames / 4_096, 1))
        let perPiece = (frames + pieces - 1) / pieces
        taps.withUnsafeBufferPointer { tapBuffer in
            let tapBase = tapBuffer.baseAddress
            Parallel.forEach(pieces, workers: workers) { piece in
                let first = piece * perPiece
                let count = min(perPiece, frames - first)
                guard count > 0 else { return }
                bake.dsp.limiterPeaks(input, Int32(factor), tapBase, first, count, peaks + first)
            }
        }
        bake.dsp.limiterSolve(peaks, frames, gain, settings, solved)
    }

    func process(frames range: Range<Int>) async throws {
        if !prepared {
            prepared = true
            analyze()
        }
        let outputPointers = UnsafeMutablePointer<UnsafeMutablePointer<Float>?>.allocate(capacity: max(outputs.count, 1))
        defer { outputPointers.deallocate() }
        for channel in outputs.indices { outputPointers[channel] = outputs[channel].baseAddress.map { $0 + range.lowerBound } }
        if separate, channelCurves.count == outputs.count {
            for channel in outputs.indices {
                bake.dsp.limiterRenderChannel(input, channel, channelCurves[channel], gain, outputPointers[channel], range.lowerBound, range.count)
            }
            return
        }
        bake.dsp.limiterRender(input, curve, gain, outputPointers, Int32(outputs.count), range.lowerBound, range.count)
    }

    func finish() throws -> PendingOutput? { nil }

    func discard() {}
}
