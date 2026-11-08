import BakeDSP
import BakeGraph

/// Compressor / expander / gate node. The whole file is analysed on the first chunk (level per channel, link, the gain
/// curve with look-ahead, and with Auto Makeup a loudness match); after that each chunk is a stateless application
/// of those curves, so the output is the same at any chunk size or core count. With Stereo Mid/Side the two channels
/// are turned into mid and side first, each compressed by its own curve, and turned back.
final class CompressorProcessor: StepProcessor {
    /// What the node reads: the input as it is, or its mid/side copy.
    private let sourceInput: bake.dsp.AudioInput
    private let input: bake.dsp.AudioInput
    private let detector: bake.dsp.AudioInput
    private let midSide: Bool
    private let highPass: Double
    private let lowPass: Double
    private var arrays: [UnsafeMutablePointer<Float>] = []
    private let outputs: [UnsafeMutableBufferPointer<Float>]
    private let settings: bake.dsp.DynamicsSettings
    private let makeup: bake.dsp.ParameterSignal
    private let mix: bake.dsp.ParameterSignal
    private let rms: Bool
    private let rmsWindow: Double
    private let link: Double
    private let autoMakeup: Bool
    private let sampleRate: Double
    private let workers: Int
    private let frames: Int
    private var curves: [UnsafeMutablePointer<Float>] = []
    private var extraMakeup = 0.0
    private var prepared = false

    init(step: RenderStep, sampleRate: Double, pool: BufferPool, workers: Int = Parallel.coreCount) throws {
        guard let output = step.outputs["out"] else { throw RenderError.unsupportedNode(step.kind) }
        let original = bake.dsp.AudioInput("in", of: step, pool: pool)
        let sidechain = bake.dsp.AudioInput("sidechain", of: step, pool: pool)
        outputs = (0..<output.shape.channels).map { pool.channel($0, of: output) }
        frames = original.frames
        sourceInput = original
        highPass = step.parameters["scHighPass"]?.numberValue ?? 0
        lowPass = step.parameters["scLowPass"]?.numberValue ?? 0
        midSide = step.parameters["stereoMode"] == .choice("midSide") && original.channelCount == 2 && outputs.count == 2
        if midSide {
            var made: [UnsafeMutablePointer<Float>] = []
            func convert(_ source: bake.dsp.AudioInput) -> bake.dsp.AudioInput {
                let mid = UnsafeMutablePointer<Float>.allocate(capacity: max(source.frames, 1))
                let side = UnsafeMutablePointer<Float>.allocate(capacity: max(source.frames, 1))
                made.append(mid)
                made.append(side)
                let stereo = source.channelCount > 1
                for frame in 0..<source.frames {
                    let left = source.sample(0, frame)
                    let right = stereo ? source.sample(1, frame) : left
                    mid[frame] = (left + right) * 0.5
                    side[frame] = stereo ? (left - right) * 0.5 : 0
                }
                return Self.audio([UnsafePointer(mid), UnsafePointer(side)], frames: source.frames)
            }
            input = convert(original)
            detector = sidechain.isWired() ? convert(sidechain) : input
            arrays = made
        } else {
            input = original
            detector = sidechain.isWired() ? sidechain : original
        }
        var config = bake.dsp.DynamicsSettings()
        switch step.parameters["mode"] {
        case .choice("expander")?: config.mode = .expander
        case .choice("gate")?: config.mode = .gate
        default: config.mode = .compressor
        }
        config.threshold = bake.dsp.ParameterSignal("threshold", of: step, pool: pool)
        config.ratio = bake.dsp.ParameterSignal("ratio", of: step, pool: pool)
        config.kneeDb = step.parameters["knee"]?.numberValue ?? 6
        config.attackMs = step.parameters["attack"]?.numberValue ?? 5
        config.releaseMs = step.parameters["release"]?.numberValue ?? 120
        config.holdMs = step.parameters["hold"]?.numberValue ?? 0
        config.hysteresisDb = step.parameters["hysteresis"]?.numberValue ?? 3
        config.rangeDb = step.parameters["range"]?.numberValue ?? 60
        config.sampleRate = sampleRate
        settings = config
        makeup = bake.dsp.ParameterSignal("makeup", of: step, pool: pool)
        mix = bake.dsp.ParameterSignal("mix", of: step, pool: pool)
        rms = step.parameters["detector"] != .choice("peak")
        rmsWindow = step.parameters["rmsWindow"]?.numberValue ?? 20
        link = step.parameters["link"]?.numberValue ?? 1
        autoMakeup = step.parameters["autoMakeup"] == .choice("on")
        self.sampleRate = sampleRate
        self.workers = max(workers, 1)
        // Level curves (one per channel) plus gain curves (one when linked fully, else one per channel).
        let channels = max(outputs.count, 1)
        let filterScratch = (highPass > 0 || lowPass > 0) ? self.workers * frames : 0
        let copies = midSide ? frames * (sidechain.isWired() ? 4 : 2) : 0
        try NodeMemory.require(bytes: (frames * channels * 2 + filterScratch + copies) * MemoryLayout<Float>.stride)
    }

    deinit {
        for curve in curves { curve.deallocate() }
        for array in arrays { array.deallocate() }
    }

    /// An `AudioInput` over planar channels that outlive it.
    private static func audio(_ pointers: [UnsafePointer<Float>], frames: Int) -> bake.dsp.AudioInput {
        var audio = bake.dsp.AudioInput()
        audio.channelCount = pointers.count
        audio.frames = frames
        withUnsafeMutableBytes(of: &audio.channels) { raw in
            let slots = raw.bindMemory(to: UnsafePointer<Float>?.self)
            for (index, pointer) in pointers.enumerated() where index < slots.count { slots[index] = pointer }
        }
        return audio
    }

    private func analyze() {
        guard frames > 0, !outputs.isEmpty else { return }
        let channels = outputs.count
        let frames = frames, detector = detector, input = input, settings = settings
        let rms = rms, window = rmsWindow, rate = sampleRate
        let highPass = highPass, lowPass = lowPass
        let levels = (0..<channels).map { _ in UnsafeMutablePointer<Float>.allocate(capacity: frames) }
        defer { for level in levels { level.deallocate() } }
        Parallel.forEach(channels, workers: workers) { channel in
            if highPass > 0 || lowPass > 0 {
                let scratch = UnsafeMutablePointer<Float>.allocate(capacity: frames)
                defer { scratch.deallocate() }
                bake.dsp.dynamicsLevelsFiltered(detector, Int32(channel), highPass, lowPass, rms, window, rate, frames, levels[channel], scratch)
            } else {
                bake.dsp.dynamicsLevels(detector, Int32(channel), rms, window, rate, frames, levels[channel])
            }
        }
        let optionalLevels = UnsafeMutablePointer<UnsafeMutablePointer<Float>?>.allocate(capacity: channels)
        defer { optionalLevels.deallocate() }
        for channel in 0..<channels { optionalLevels[channel] = levels[channel] }
        bake.dsp.dynamicsLink(optionalLevels, Int32(channels), frames, link)
        let curveCount = link >= 1 ? 1 : channels
        curves = (0..<curveCount).map { _ in UnsafeMutablePointer<Float>.allocate(capacity: frames) }
        let curves = curves
        Parallel.forEach(curveCount, workers: workers) { index in
            bake.dsp.dynamicsGainCurve(levels[index], frames, settings, curves[index])
        }
        guard autoMakeup else { return }
        if midSide {
            // The gain acts on mid and side, so the loudness of what comes out has to be measured on left and right.
            renderChunks(0..<frames, extra: 0)
            let measured = Self.audio(outputs.compactMap { $0.baseAddress.map { UnsafePointer($0) } }, frames: frames)
            let before = bake.dsp.dynamicsLoudness(sourceInput, nil, 0, rate)
            let after = bake.dsp.dynamicsLoudness(measured, nil, 0, rate)
            if before > -999, after > -999 { extraMakeup = min(max(before - after, -24), 36) }
            return
        }
        let curvePointers = UnsafeMutablePointer<UnsafePointer<Float>?>.allocate(capacity: curveCount)
        defer { curvePointers.deallocate() }
        for index in 0..<curveCount { curvePointers[index] = UnsafePointer(curves[index]) }
        var measured = [Double](repeating: -1000, count: 2)
        measured.withUnsafeMutableBufferPointer { buffer in
            let results = buffer
            Parallel.forEach(2, workers: workers) { which in
                results[which] = which == 0
                    ? bake.dsp.dynamicsLoudness(input, nil, 0, rate)
                    : bake.dsp.dynamicsLoudness(input, curvePointers, Int32(curveCount), rate)
            }
        }
        if measured[0] > -999, measured[1] > -999 {
            extraMakeup = min(max(measured[0] - measured[1], -24), 36)
        }
    }

    /// Output samples `range` of every channel, written straight into the output buffers.
    private func renderChunks(_ range: Range<Int>, extra: Double) {
        let curvePointers = UnsafeMutablePointer<UnsafePointer<Float>?>.allocate(capacity: max(curves.count, 1))
        defer { curvePointers.deallocate() }
        for index in curves.indices { curvePointers[index] = UnsafePointer(curves[index]) }
        let curveArgument = curves.isEmpty ? nil : UnsafePointer(curvePointers)
        if midSide {
            let mid = UnsafeMutablePointer<Float>.allocate(capacity: max(range.count, 1))
            let side = UnsafeMutablePointer<Float>.allocate(capacity: max(range.count, 1))
            defer { mid.deallocate(); side.deallocate() }
            let temporary = UnsafeMutablePointer<UnsafeMutablePointer<Float>?>.allocate(capacity: 2)
            defer { temporary.deallocate() }
            temporary[0] = mid
            temporary[1] = side
            bake.dsp.dynamicsRender(
                input, curveArgument, Int32(curves.count), makeup, extra, mix, temporary, 2, range.lowerBound, range.count
            )
            if let left = outputs[0].baseAddress, let right = outputs[1].baseAddress {
                for i in 0..<range.count {
                    left[range.lowerBound + i] = mid[i] + side[i]
                    right[range.lowerBound + i] = mid[i] - side[i]
                }
            }
            return
        }
        let outputPointers = UnsafeMutablePointer<UnsafeMutablePointer<Float>?>.allocate(capacity: max(outputs.count, 1))
        defer { outputPointers.deallocate() }
        for channel in outputs.indices { outputPointers[channel] = outputs[channel].baseAddress.map { $0 + range.lowerBound } }
        bake.dsp.dynamicsRender(
            input, curveArgument, Int32(curves.count), makeup, extra, mix, outputPointers, Int32(outputs.count),
            range.lowerBound, range.count
        )
    }

    func process(frames range: Range<Int>) async throws {
        if !prepared {
            prepared = true
            analyze()
        }
        renderChunks(range, extra: extraMakeup)
    }

    func finish() throws -> PendingOutput? { nil }

    func discard() {}
}
