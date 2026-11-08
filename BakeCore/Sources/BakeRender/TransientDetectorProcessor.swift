import BakeDSP
import BakeGraph

/// Transient Detector node. The whole file is analysed on the first chunk (detection frames across all cores, then one
/// serial pass that picks and places the onsets); after that each chunk is a stateless lookup into the onset list, so
/// the output is the same at any chunk size or core count.
final class TransientDetectorProcessor: StepProcessor {
    private let settings: bake.dsp.TransientSettings
    private let input: bake.dsp.AudioInput
    private let bang: UnsafeMutableBufferPointer<Float>?
    private let strength: UnsafeMutableBufferPointer<Float>?
    private let pulseFrames: Int
    private let sampleRate: Double
    private let workers: Int
    private var onsets: [Int] = []
    private var strengths: [Float] = []
    private var prepared = false

    init(step: RenderStep, sampleRate: Double, pool: BufferPool, workers: Int = Parallel.coreCount) throws {
        bang = step.outputs["out"].map { pool.channel(0, of: $0) }
        strength = step.outputs["strength"].map { pool.channel(0, of: $0) }
        guard bang != nil || strength != nil else { throw RenderError.unsupportedNode(step.kind) }
        input = bake.dsp.AudioInput("in", of: step, pool: pool)
        var settings = bake.dsp.TransientSettings()
        switch step.parameters["mode"] {
        case .choice("spectralFlux")?: settings.mode = .spectralFlux
        case .choice("highFrequency")?: settings.mode = .highFrequency
        default: settings.mode = .energy
        }
        settings.sensitivity = step.parameters["sensitivity"]?.numberValue ?? 0.5
        settings.minGapMilliseconds = step.parameters["minGap"]?.numberValue ?? 80
        settings.lowCut = step.parameters["lowCut"]?.numberValue ?? 20
        settings.highCut = step.parameters["highCut"]?.numberValue ?? 20_000
        settings.backTrack = step.parameters["backTrack"] != .choice("off")
        settings.sampleRate = sampleRate
        self.settings = settings
        self.sampleRate = sampleRate
        self.workers = max(workers, 1)
        pulseFrames = max(Int(((step.parameters["pulseLength"]?.numberValue ?? 5) * 0.001 * sampleRate).rounded()), 1)
        let hops = Int(bake.dsp.transientHopCount(input.frames, sampleRate))
        let capacity = Int(bake.dsp.transientMaxOnsets(input.frames, settings.minGapMilliseconds, sampleRate))
        try NodeMemory.require(bytes: hops * MemoryLayout<Double>.stride + capacity * (MemoryLayout<Int>.stride + MemoryLayout<Float>.stride))
    }

    private func analyze() {
        guard input.frames > 0 else { return }
        let hops = Int(bake.dsp.transientHopCount(input.frames, sampleRate))
        let detection = UnsafeMutablePointer<Double>.allocate(capacity: hops)
        detection.initialize(repeating: 0, count: hops)
        defer { detection.deallocate() }
        let pieces = min(workers, max(hops / 64, 1))
        let perPiece = (hops + pieces - 1) / pieces
        let scratchDoubles = max(Int(bake.dsp.transientScratchDoubles(sampleRate)), 1)
        let input = input, settings = settings
        Parallel.forEach(pieces, workers: workers) { piece in
            let first = piece * perPiece
            let count = min(perPiece, hops - first)
            guard count > 0 else { return }
            let scratch = UnsafeMutablePointer<Double>.allocate(capacity: scratchDoubles)
            scratch.initialize(repeating: 0, count: scratchDoubles)
            defer { scratch.deallocate() }
            bake.dsp.transientDetection(input, settings, first, count, scratch, detection)
        }
        let capacity = Int(bake.dsp.transientMaxOnsets(input.frames, settings.minGapMilliseconds, sampleRate))
        var foundOnsets = [Int](repeating: 0, count: capacity)
        var foundStrengths = [Float](repeating: 0, count: capacity)
        let count = foundOnsets.withUnsafeMutableBufferPointer { onsetBuffer in
            foundStrengths.withUnsafeMutableBufferPointer { strengthBuffer in
                Int(bake.dsp.transientPick(
                    input, settings, detection, hops, onsetBuffer.baseAddress, strengthBuffer.baseAddress, capacity
                ))
            }
        }
        onsets = Array(foundOnsets.prefix(count))
        strengths = Array(foundStrengths.prefix(count))
    }

    func process(frames: Range<Int>) async throws {
        if !prepared {
            prepared = true
            analyze()
        }
        let bangBase = bang?.baseAddress.map { $0 + frames.lowerBound }
        let strengthBase = strength?.baseAddress.map { $0 + frames.lowerBound }
        onsets.withUnsafeBufferPointer { onsetBuffer in
            strengths.withUnsafeBufferPointer { strengthBuffer in
                bake.dsp.transientRender(
                    onsetBuffer.baseAddress, strengthBuffer.baseAddress, onsetBuffer.count, pulseFrames,
                    bangBase, strengthBase, frames.lowerBound, frames.count
                )
            }
        }
    }

    func finish() throws -> PendingOutput? { nil }

    func discard() {}
}
