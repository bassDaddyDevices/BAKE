import BakeDSP
import BakeGPU
import BakeGraph
import Foundation
import Metal

/// OTFT Compressor node (see BakeDSP/OtftCompressor.h). The whole file is analysed when the first chunk arrives:
/// 1. the detector's STFT levels per unit (frame blocks across the cores), 2. every unit's follower and gain along time
/// (unit blocks across the cores, or one GPU thread per unit with Engine GPU), 3. with Auto Makeup, one render of the
/// whole file to measure its loudness. Every chunk after that is stateless: the covering frames are analysed, each bin
/// is multiplied by its gain, and the result is synthesised, so any chunk size or core count gives the same bits.
final class OtftCompressorProcessor: StepProcessor {
    private enum Link { case independent, linked, midSide }

    private let step: RenderStep
    private let sampleRate: Double
    private let workers: Int
    private let useGPU: Bool
    private let gpu: GPUContext
    private let inputs: [UnsafeMutableBufferPointer<Float>]
    private let detectorInputs: [UnsafeMutableBufferPointer<Float>]
    private let outputs: [UnsafeMutableBufferPointer<Float>]
    private let signalFrames: Int
    private let detectorFrames: Int
    private let layout: bake.dsp.StftLayout
    private let link: Link
    private let anticipating: Bool
    private let autoMakeup: Bool
    private let smoothFreq: Double
    private let smoothTime: Double
    private let timeTilt: Double
    private let kneeDb: Float
    private let requestedBands: Int
    private let curve: [bake.dsp.OtftCurvePoint]
    private let downThreshold: bake.dsp.ParameterSignal
    private let downRatio: bake.dsp.ParameterSignal
    private let upThreshold: bake.dsp.ParameterSignal
    private let upRatio: bake.dsp.ParameterSignal
    private let maxBoost: bake.dsp.ParameterSignal
    private let attack: bake.dsp.ParameterSignal
    private let release: bake.dsp.ParameterSignal
    private let mix: bake.dsp.ParameterSignal
    private let outputGain: bake.dsp.ParameterSignal
    private let inputAudio: bake.dsp.AudioInput

    // Built on the first chunk.
    private var prepared = false
    private var units = 0
    private var edges: [UInt32] = []
    private var lower: [UInt32] = []
    private var weight: [Float] = []
    private var window: [Double] = []
    private var surfaces: [UnsafeMutablePointer<Float>] = []
    private var gpuBuffers: [any MTLBuffer] = []
    private var signalArrays: [UnsafeMutablePointer<Float>] = []
    private var makeupDb = 0.0
    private let maxChunkFrames: Int

    /// Units of work for a render: which signal, which surface, which wet buffer.
    private struct RenderTask {
        var signal: UnsafePointer<Float>
        var surface: Int
    }

    static func parseCurve(_ text: String) -> [bake.dsp.OtftCurvePoint] {
        var points = text.split(whereSeparator: { $0 == " " || $0 == "," || $0 == "\n" || $0 == "\t" }).prefix(32).compactMap { token -> bake.dsp.OtftCurvePoint? in
            let parts = token.split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let hertz = Double(parts[0]), let decibels = Double(parts[1]),
                  hertz > 0, hertz.isFinite, decibels.isFinite else { return nil }
            var point = bake.dsp.OtftCurvePoint()
            point.hertz = Float(hertz)
            point.decibels = Float(decibels)
            return point
        }
        points.sort { $0.hertz < $1.hertz }
        return points
    }

    init(
        step: RenderStep, sampleRate: Double, gpu: GPUContext, pool: BufferPool, maxChunkFrames: Int,
        workers: Int = Parallel.coreCount
    ) throws {
        guard let source = step.inputs["in"], let output = step.outputs["out"] else {
            throw RenderError.unsupportedNode(step.kind)
        }
        self.step = step
        self.sampleRate = sampleRate
        self.gpu = gpu
        self.workers = max(workers, 1)
        self.maxChunkFrames = max(maxChunkFrames, 1)
        inputs = (0..<source.shape.channels).map { pool.channel($0, of: source) }
        let sidechain = step.inputs["sidechain"]
        detectorInputs = sidechain.map { binding in (0..<binding.shape.channels).map { pool.channel($0, of: binding) } } ?? inputs
        detectorFrames = sidechain?.shape.frames ?? source.shape.frames
        outputs = (0..<output.shape.channels).map { pool.channel($0, of: output) }
        signalFrames = source.shape.frames
        inputAudio = bake.dsp.AudioInput("in", of: step, pool: pool)
        var layout = bake.dsp.StftLayout()
        var size = 8192
        if case .choice(let value)? = step.parameters["fftSize"], let parsed = Int(value) { size = parsed }
        layout.fftSize = Int32(size)
        layout.hop = Int32(step.parameters["overlap"] == .choice("87.5") ? size / 8 : size / 4)
        self.layout = layout
        switch step.parameters["stereoLink"] {
        case .choice("independent")?: link = .independent
        case .choice("midSide")?: link = inputs.count == 2 ? .midSide : .independent
        default: link = .linked
        }
        anticipating = step.parameters["detector"] == .choice("anticipating")
        autoMakeup = step.parameters["autoMakeup"] == .choice("on")
        smoothFreq = step.parameters["smoothFreq"]?.numberValue ?? 0.3
        smoothTime = step.parameters["smoothTime"]?.numberValue ?? 0.3
        timeTilt = step.parameters["timeTilt"]?.numberValue ?? 0
        kneeDb = Float(step.parameters["knee"]?.numberValue ?? 6)
        if case .choice(let value)? = step.parameters["bands"], let parsed = Int(value) { requestedBands = parsed } else { requestedBands = 0 }
        var curveText = ""
        if case .text(let value)? = step.parameters["thresholdCurve"] { curveText = value }
        curve = Self.parseCurve(curveText)
        downThreshold = bake.dsp.ParameterSignal("downThreshold", of: step, pool: pool)
        downRatio = bake.dsp.ParameterSignal("downRatio", of: step, pool: pool)
        upThreshold = bake.dsp.ParameterSignal("upThreshold", of: step, pool: pool)
        upRatio = bake.dsp.ParameterSignal("upRatio", of: step, pool: pool)
        maxBoost = bake.dsp.ParameterSignal("maxBoost", of: step, pool: pool)
        attack = bake.dsp.ParameterSignal("attack", of: step, pool: pool)
        release = bake.dsp.ParameterSignal("release", of: step, pool: pool)
        mix = bake.dsp.ParameterSignal("mix", of: step, pool: pool)
        outputGain = bake.dsp.ParameterSignal("outputGain", of: step, pool: pool)
        useGPU = step.parameters["engine"] == .choice("gpu")

        // Memory: a surface per gain set (two with the GPU's smoothing), mid/side copies, and the wet chunks.
        let frameCount = Int(bake.dsp.stftFrameCount(layout, signalFrames))
        let unitCount = Int(bake.dsp.otftUnitCount(layout, requestedBands))
        let sets = link == .linked ? 1 : (link == .midSide ? 2 : max(inputs.count, 1))
        let surfaceBytes = frameCount * unitCount * MemoryLayout<Float>.stride * sets * (useGPU && smoothTime > 0 ? 2 : 1)
        let copyBytes = link == .midSide ? signalFrames * MemoryLayout<Float>.stride * (sidechain == nil ? 2 : 4) : 0
        let wetBytes = self.maxChunkFrames * MemoryLayout<Float>.stride * max(inputs.count, 2)
        try NodeMemory.require(bytes: surfaceBytes + copyBytes + wetBytes)
    }

    deinit {
        // With Engine GPU the surfaces belong to their Metal buffers; only the CPU engine allocates them.
        if !useGPU { for surface in surfaces { surface.deallocate() } }
        for array in signalArrays { array.deallocate() }
    }

    // MARK: Analysis

    private func prepare() async throws {
        let layout = layout
        let bins = Int(bake.dsp.stftBinCount(layout))
        let frameCount = Int(bake.dsp.stftFrameCount(layout, signalFrames))
        guard frameCount > 0, !inputs.isEmpty else { return }
        units = Int(bake.dsp.otftUnitCount(layout, requestedBands))
        edges = [UInt32](repeating: 0, count: units + 1 + max(requestedBands, 0))
        bake.dsp.otftUnitEdges(layout, requestedBands, &edges)
        edges = Array(edges.prefix(units + 1))
        lower = [UInt32](repeating: 0, count: bins)
        weight = [Float](repeating: 0, count: bins)
        bake.dsp.otftBinMap(layout, edges, units, &lower, &weight)
        window = [Double](repeating: 0, count: Int(layout.fftSize))
        bake.dsp.stftWindow(layout, &window)
        var timeScale = [Float](repeating: 1, count: units)
        var offsetDb = [Float](repeating: 0, count: units)
        bake.dsp.otftUnitTables(layout, sampleRate, edges, units, timeTilt, curve, curve.count, &timeScale, &offsetDb)
        var frameParams = [bake.dsp.OtftFrameParams](repeating: bake.dsp.OtftFrameParams(), count: frameCount)
        bake.dsp.otftFrameParams(
            layout, signalFrames, frameCount, downThreshold, downRatio, upThreshold, upRatio, maxBoost, attack, release,
            &frameParams
        )
        var envelope = bake.dsp.OtftEnvelope()
        let hopMs = 1000.0 * Double(layout.hop) / sampleRate
        envelope.hopMilliseconds = Float(hopMs)
        envelope.kneeDb = kneeDb
        envelope.anticipating = anticipating ? 1 : 0
        envelope.smoothFrames = UInt32((smoothTime * 100.0 / hopMs).rounded())

        // The signals the detector reads and the signals the gain is applied to, one pair per gain set.
        let (detectorSignals, _) = makeSignals()
        let sets = detectorSignals.count
        let surfaceFloats = frameCount * units
        surfaces = []
        gpuBuffers = []
        if useGPU {
            do {
                for _ in 0..<sets {
                    let buffer = try gpu.makeSharedBuffer(floatCount: surfaceFloats)
                    gpuBuffers.append(buffer)
                    surfaces.append(buffer.contents().bindMemory(to: Float.self, capacity: surfaceFloats))
                }
            } catch { throw RenderError.gpuUnavailable }
        } else {
            for _ in 0..<sets { surfaces.append(.allocate(capacity: surfaceFloats)) }
        }
        for surface in surfaces { surface.initialize(repeating: bake.dsp.otftFloorDb, count: surfaceFloats) }

        // 1. Levels: frame blocks across the cores, one pass per detector signal (linked ones take the loudest).
        let edges = edges, units = units, workers = workers, detectorFrames = detectorFrames
        for (set, group) in detectorSignals.enumerated() {
            for (index, signal) in group.enumerated() {
                let surface = surfaces[set]
                let combine = index > 0
                let blockFrames = 8
                let blocks = (frameCount + blockFrames - 1) / blockFrames
                Parallel.forEach(blocks, workers: workers) { block in
                    let first = block * blockFrames
                    let count = min(blockFrames, frameCount - first)
                    var spectrum = [Float](repeating: 0, count: count * bins * 2)
                    var scratch = [Double](repeating: 0, count: Int(bake.dsp.otftScratchDoubles(layout)))
                    bake.dsp.otftLevels(layout, signal, detectorFrames, first, count, edges, units, combine, surface, &spectrum, &scratch)
                }
            }
        }

        // 2. Gains: every unit's follower, in place.
        if useGPU {
            do {
                let kernel = try OtftKernel(gpu: gpu, maxFrames: frameCount, maxUnits: units)
                let gpuFrames = frameParams.map {
                    OtftGPUFrame(
                        downThreshold: $0.downThreshold, downSlope: $0.downSlope, upThreshold: $0.upThreshold,
                        upSlope: $0.upSlope, maxBoost: $0.maxBoost, attackMs: $0.attackMs, releaseMs: $0.releaseMs
                    )
                }
                let smoothing = Int(envelope.smoothFrames)
                for set in 0..<sets {
                    var scratch: (any MTLBuffer)?
                    if smoothing > 0 { scratch = try gpu.makeSharedBuffer(floatCount: surfaceFloats) }
                    let result = try await kernel.run(
                        surface: gpuBuffers[set], scratch: scratch, frames: gpuFrames, units: units, timeScale: timeScale,
                        offsetDb: offsetDb, hopMilliseconds: envelope.hopMilliseconds, kneeDb: kneeDb,
                        anticipating: anticipating, smoothFrames: smoothing
                    )
                    if result !== gpuBuffers[set] {
                        // Smoothing wrote into the scratch buffer; it becomes this set's surface.
                        gpuBuffers[set] = result
                        surfaces[set] = result.contents().bindMemory(to: Float.self, capacity: surfaceFloats)
                    }
                }
            } catch { throw RenderError.gpuUnavailable }
        } else {
            let unitBlock = 64
            let blocks = (units + unitBlock - 1) / unitBlock
            for set in 0..<sets {
                let surface = surfaces[set]
                let frameParams = frameParams, timeScale = timeScale, offsetDb = offsetDb, envelope = envelope
                Parallel.forEach(blocks, workers: workers) { block in
                    let first = block * unitBlock
                    let count = min(unitBlock, units - first)
                    var column = [Float](repeating: 0, count: frameCount)
                    bake.dsp.otftGainColumns(frameParams, frameCount, units, first, count, timeScale, offsetDb, envelope, surface, &column)
                }
            }
        }

        // 3. Auto Makeup: render the whole file as it will come out (without Output Gain) and match its loudness.
        if autoMakeup {
            renderAll(includeOutputGain: false, makeupDb: 0)
            var measured = bake.dsp.AudioInput()
            measured.channelCount = outputs.count
            measured.frames = signalFrames
            withUnsafeMutableBytes(of: &measured.channels) { raw in
                let slots = raw.bindMemory(to: UnsafePointer<Float>?.self)
                for (index, buffer) in outputs.enumerated() where index < slots.count {
                    slots[index] = buffer.baseAddress.map { UnsafePointer($0) }
                }
            }
            let before = bake.dsp.dynamicsLoudness(inputAudio, nil, 0, sampleRate)
            let after = bake.dsp.dynamicsLoudness(measured, nil, 0, sampleRate)
            if before > -999, after > -999 { makeupDb = min(max(before - after, -24), 36) }
        }
    }

    /// The detector signals per gain set and the signals the gain is applied to, building mid/side copies when needed.
    private func makeSignals() -> (detector: [[UnsafePointer<Float>]], applied: [UnsafePointer<Float>]) {
        func pointers(_ buffers: [UnsafeMutableBufferPointer<Float>]) -> [UnsafePointer<Float>] {
            buffers.compactMap { $0.baseAddress.map { UnsafePointer($0) } }
        }
        let applied = pointers(inputs)
        let detector = pointers(detectorInputs)
        switch link {
        case .independent:
            return (applied.indices.map { [detector[min($0, detector.count - 1)]] }, applied)
        case .linked:
            return ([detector], applied)
        case .midSide:
            func midSide(_ left: UnsafePointer<Float>, _ right: UnsafePointer<Float>?, frames: Int) -> [UnsafePointer<Float>] {
                let mid = UnsafeMutablePointer<Float>.allocate(capacity: max(frames, 1))
                let side = UnsafeMutablePointer<Float>.allocate(capacity: max(frames, 1))
                signalArrays.append(mid)
                signalArrays.append(side)
                for frame in 0..<frames {
                    let l = left[frame], r = right?[frame] ?? l
                    mid[frame] = (l + r) * 0.5
                    side[frame] = right == nil ? 0 : (l - r) * 0.5
                }
                return [UnsafePointer(mid), UnsafePointer(side)]
            }
            let appliedMS = midSide(applied[0], applied[1], frames: signalFrames)
            let detectorMS = detector.first == applied.first
                ? appliedMS : midSide(detector[0], detector.count > 1 ? detector[1] : nil, frames: detectorFrames)
            return ([[detectorMS[0]], [detectorMS[1]]], appliedMS)
        }
    }

    // MARK: Render

    /// The surfaces and signals one chunk renders from, once prepared.
    private func renderTasks() -> [RenderTask] {
        let (_, applied) = appliedSignals
        switch link {
        case .independent: return applied.indices.map { RenderTask(signal: applied[$0], surface: $0) }
        case .linked: return applied.map { RenderTask(signal: $0, surface: 0) }
        case .midSide: return applied.indices.map { RenderTask(signal: applied[$0], surface: $0) }
        }
    }

    private var appliedSignals: (detector: [[UnsafePointer<Float>]], applied: [UnsafePointer<Float>]) {
        let applied = inputs.compactMap { $0.baseAddress.map { UnsafePointer($0) } }
        if link == .midSide, signalArrays.count >= 2 {
            return ([], [UnsafePointer(signalArrays[0]), UnsafePointer(signalArrays[1])])
        }
        return ([], applied)
    }

    /// Renders output samples `range` of every channel into `destination[channel]` (offset by `range.lowerBound`).
    private func render(range: Range<Int>, includeOutputGain: Bool, makeupDb: Double, destination: [UnsafeMutablePointer<Float>]) {
        let tasks = renderTasks()
        guard !tasks.isEmpty, units > 0 else { return }
        let layout = layout, units = units, lower = lower, weight = weight, window = window
        let signalFrames = signalFrames, smoothFreq = smoothFreq
        let surfaces = surfaces
        let wet = tasks.map { _ in UnsafeMutablePointer<Float>.allocate(capacity: max(range.count, 1)) }
        defer { for buffer in wet { buffer.deallocate() } }
        // Pieces of the chunk across the cores: (task, piece).
        let minimumPiece = 16_384
        let pieces = max(min(workers, range.count / minimumPiece), 1)
        let pieceSize = (range.count + pieces - 1) / pieces
        Parallel.forEach(tasks.count * pieces, workers: workers) { index in
            let task = tasks[index / pieces]
            let piece = index % pieces
            let offset = piece * pieceSize
            let count = min(pieceSize, range.count - offset)
            guard count > 0 else { return }
            var floats = [Float](repeating: 0, count: Int(bake.dsp.otftRenderFloats(layout, count)))
            var scratch = [Double](repeating: 0, count: Int(bake.dsp.otftScratchDoubles(layout)))
            bake.dsp.otftRenderBlock(
                layout, window, task.signal, signalFrames, surfaces[task.surface], units, lower, weight, smoothFreq,
                range.lowerBound + offset, count, wet[index / pieces] + offset, &floats, &scratch
            )
        }
        let channels = destination.count
        let inputBuffers = inputs
        let combined = UnsafeMutablePointer<Float>.allocate(capacity: max(range.count, 1))
        defer { combined.deallocate() }
        for channel in 0..<channels {
            var source: UnsafePointer<Float> = UnsafePointer(wet[min(channel, wet.count - 1)])
            if link == .midSide, wet.count == 2 {
                let sign: Float = channel == 0 ? 1 : -1
                for i in 0..<range.count { combined[i] = wet[0][i] + sign * wet[1][i] }
                source = UnsafePointer(combined)
            }
            let dry = channel < inputBuffers.count ? inputBuffers[channel].baseAddress.map { UnsafePointer($0) } : nil
            bake.dsp.otftMixDown(
                mix, outputGain, makeupDb, includeOutputGain, dry, source, range.lowerBound, range.count, destination[channel]
            )
        }
    }

    /// The whole file in chunks of at most `maxChunkFrames`, straight into the output buffers.
    private func renderAll(includeOutputGain: Bool, makeupDb: Double) {
        var start = 0
        while start < signalFrames {
            let count = min(maxChunkFrames, signalFrames - start)
            let destination = outputs.map { $0.baseAddress.map { $0 + start } ?? UnsafeMutablePointer<Float>(bitPattern: 1)! }
            render(range: start..<(start + count), includeOutputGain: includeOutputGain, makeupDb: makeupDb, destination: destination)
            start += count
        }
    }

    func process(frames: Range<Int>) async throws {
        if !prepared {
            prepared = true
            try await prepare()
        }
        guard units > 0, !outputs.isEmpty else { return }
        let destination = outputs.map { $0.baseAddress.map { $0 + frames.lowerBound } ?? UnsafeMutablePointer<Float>(bitPattern: 1)! }
        render(range: frames, includeOutputGain: true, makeupDb: makeupDb, destination: destination)
    }

    func finish() throws -> PendingOutput? { nil }

    func discard() {}
}
