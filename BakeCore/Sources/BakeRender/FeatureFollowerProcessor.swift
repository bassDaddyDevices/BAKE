import BakeDSP
import BakeGraph

/// Feature Follower node. The whole file is analysed on the first chunk (STFT frames across all cores, or one serial
/// K-weighted pass for loudness, then normalize and zero-phase smooth); after that each chunk is a stateless
/// interpolation of that series, so the output is the same at any chunk size or core count.
final class FeatureFollowerProcessor: StepProcessor {
    private let settings: bake.dsp.FeatureSettings
    private let shape: bake.dsp.FeatureShape
    private let input: bake.dsp.AudioInput
    private let output: UnsafeMutableBufferPointer<Float>
    private let sampleRate: Double
    private let workers: Int
    private var series: [Double] = []
    private var prepared = false

    init(step: RenderStep, sampleRate: Double, pool: BufferPool, workers: Int = Parallel.coreCount) throws {
        guard let out = step.outputs["out"] else { throw RenderError.unsupportedNode(step.kind) }
        output = pool.channel(0, of: out)
        input = bake.dsp.AudioInput("in", of: step, pool: pool)
        var settings = bake.dsp.FeatureSettings()
        switch step.parameters["feature"] {
        case .choice("flatness")?: settings.feature = .flatness
        case .choice("flux")?: settings.feature = .flux
        case .choice("rolloff")?: settings.feature = .rolloff
        case .choice("bandwidth")?: settings.feature = .bandwidth
        case .choice("zeroCrossing")?: settings.feature = .zeroCrossing
        case .choice("crest")?: settings.feature = .crest
        case .choice("loudness")?: settings.feature = .loudness
        default: settings.feature = .centroid
        }
        settings.lowCut = step.parameters["lowCut"]?.numberValue ?? 20
        settings.highCut = step.parameters["highCut"]?.numberValue ?? 20_000
        settings.sampleRate = sampleRate
        self.settings = settings
        var shape = bake.dsp.FeatureShape()
        shape.autoRange = step.parameters["range"] != .choice("manual")
        shape.minimum = step.parameters["minimum"]?.numberValue ?? 0
        shape.maximum = step.parameters["maximum"]?.numberValue ?? 1
        shape.smoothMilliseconds = step.parameters["smooth"]?.numberValue ?? 50
        shape.sampleRate = sampleRate
        self.shape = shape
        self.sampleRate = sampleRate
        self.workers = max(workers, 1)
        let hops = Int(bake.dsp.featureHopCount(input.frames, sampleRate))
        try NodeMemory.require(bytes: hops * MemoryLayout<Double>.stride * 3)
    }

    private func analyze() {
        guard input.frames > 0 else { return }
        let hops = Int(bake.dsp.featureHopCount(input.frames, sampleRate))
        var values = [Double](repeating: 0, count: hops)
        let input = input, settings = settings
        values.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            if settings.feature == .loudness {
                bake.dsp.featureLoudness(input, settings, hops, base)
            } else {
                let pieces = min(workers, max(hops / 64, 1))
                let perPiece = (hops + pieces - 1) / pieces
                let scratchDoubles = max(Int(bake.dsp.featureScratchDoubles(sampleRate)), 1)
                Parallel.forEach(pieces, workers: workers) { piece in
                    let first = piece * perPiece
                    let count = min(perPiece, hops - first)
                    guard count > 0 else { return }
                    let scratch = UnsafeMutablePointer<Double>.allocate(capacity: scratchDoubles)
                    scratch.initialize(repeating: 0, count: scratchDoubles)
                    defer { scratch.deallocate() }
                    bake.dsp.featureFrames(input, settings, first, count, scratch, base)
                }
            }
            _ = bake.dsp.featureShape(base, hops, shape)
        }
        series = values
    }

    func process(frames: Range<Int>) async throws {
        if !prepared {
            prepared = true
            analyze()
        }
        let base = output.baseAddress.map { $0 + frames.lowerBound }
        series.withUnsafeBufferPointer { buffer in
            bake.dsp.featureRender(
                buffer.baseAddress, buffer.count, bake.dsp.featureHop(sampleRate), base, frames.lowerBound, frames.count
            )
        }
    }

    func finish() throws -> PendingOutput? { nil }

    func discard() {}
}
