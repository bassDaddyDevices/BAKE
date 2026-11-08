import BakeDSP
import BakeGraph
import Foundation

/// Reverb node on the CPU engine. Each channel is its own feedback delay network; every buffer is indexed by absolute
/// frame, so a chunk needs nothing from the one before it but the buffers and each line's damping memory. A stereo pair
/// is rendered together when Width isn't 1 (the pair's wet signals are mixed); otherwise channels run across the cores.
final class ReverbProcessor: StepProcessor {
    private let input: bake.dsp.AudioInput
    private let controls: bake.dsp.ReverbControls
    private let outputs: [UnsafeMutableBufferPointer<Float>]
    private let lengths: [UnsafeMutablePointer<UInt32>]
    private let gains: [UnsafeMutablePointer<Double>]
    private let storage: [UnsafeMutablePointer<Float>]
    private let filters: [UnsafeMutablePointer<Double>]
    private let lengthPointers: UnsafeMutablePointer<UnsafePointer<UInt32>?>
    private let gainPointers: UnsafeMutablePointer<UnsafePointer<Double>?>
    private let storagePointers: UnsafeMutablePointer<UnsafeMutablePointer<Float>?>
    private let filterPointers: UnsafeMutablePointer<UnsafeMutablePointer<Double>?>
    private let chunkOutputs: UnsafeMutablePointer<UnsafeMutablePointer<Float>?>
    private let coupled: Bool
    private let workers: Int

    init(step: RenderStep, sampleRate: Double, pool: BufferPool, workers: Int = Parallel.coreCount) throws {
        guard let source = step.inputs["in"], let output = step.outputs["out"] else {
            throw RenderError.unsupportedNode(step.kind)
        }
        input = bake.dsp.AudioInput("in", of: step, pool: pool)
        outputs = (0..<output.shape.channels).map { pool.channel($0, of: output) }
        let channels = outputs.count
        var controls = bake.dsp.ReverbControls()
        controls.mix = bake.dsp.ParameterSignal("mix", of: step, pool: pool)
        controls.width = step.parameters["width"]?.numberValue ?? 1
        controls.diffusion = step.parameters["diffusion"]?.numberValue ?? 0.7
        controls.damping = step.parameters["damping"]?.numberValue ?? 0.3
        let decay = step.parameters["decay"]?.numberValue ?? 3
        controls.decaySeconds = decay
        var lineCount = 64
        if case .choice(let value)? = step.parameters["lines"], let parsed = Int(value) { lineCount = max(parsed, 1) }
        controls.lines = lineCount
        controls.preDelayFrames = max(Int(((step.parameters["preDelay"]?.numberValue ?? 0) * 0.001 * sampleRate).rounded()), 0)
        controls.sampleRate = sampleRate
        let size = step.parameters["size"]?.numberValue ?? 1
        controls.size = size

        // Pass 2 settings; each default leaves the old arithmetic untouched.
        let early = step.parameters["early"]?.numberValue ?? 0
        if early > 0 {
            controls.earlyLevel = early
            controls.earlyFrames = Int(bake.dsp.reverbEarlyFrames(size, sampleRate))
        }
        let modulation = step.parameters["modulation"]?.numberValue ?? 0
        var margin = 0
        if modulation > 0 {
            margin = Int((modulation * 0.001 * sampleRate).rounded(.up)) + 8
            controls.modulationDepth = modulation
            controls.modulationMargin = margin
        }
        controls.lowDecayScale = step.parameters["lowDecay"]?.numberValue ?? 1
        controls.highDecayScale = step.parameters["highDecay"]?.numberValue ?? 1
        controls.crossoverHz = step.parameters["crossover"]?.numberValue ?? 800
        let extraFloats = lineCount * margin + controls.earlyFrames + 8

        // The last stretch of the tail fades out (up to half a second) so it never ends on a click.
        let total = outputs.first?.count ?? 0
        let tailFrames = max(total - source.shape.frames, 0)
        if tailFrames > 0 {
            let fade = min(Int(0.5 * sampleRate), tailFrames)
            controls.tailFadeStart = Double(total - fade)
            controls.tailFadeEnd = Double(total)
        }
        if case .choice("on")? = step.parameters["freeze"] {
            let start = ((step.parameters["freezeStart"]?.numberValue ?? 1) * sampleRate).rounded()
            if start < Double(total) {
                controls.freezeFrame = start
                controls.freezeFade = 0.05 * sampleRate
            }
        }
        self.controls = controls

        var floatCount = 0
        var lengthBuffers: [UnsafeMutablePointer<UInt32>] = []
        var gainBuffers: [UnsafeMutablePointer<Double>] = []
        for channel in 0..<channels {
            let lengthBuffer = UnsafeMutablePointer<UInt32>.allocate(capacity: lineCount)
            let gainBuffer = UnsafeMutablePointer<Double>.allocate(capacity: lineCount)
            bake.dsp.reverbDesign(size, decay, lineCount, Int32(channel), sampleRate, lengthBuffer, gainBuffer)
            floatCount += Int(bake.dsp.reverbStorageFloats(lengthBuffer, lineCount, controls.preDelayFrames, sampleRate)) + extraFloats
            lengthBuffers.append(lengthBuffer)
            gainBuffers.append(gainBuffer)
        }
        lengths = lengthBuffers
        gains = gainBuffers
        try NodeMemory.require(bytes: floatCount * MemoryLayout<Float>.stride + channels * 2 * lineCount * MemoryLayout<Double>.stride)
        storage = (0..<channels).map { channel in
            let count = Int(bake.dsp.reverbStorageFloats(lengthBuffers[channel], lineCount, controls.preDelayFrames, sampleRate)) + extraFloats
            let buffer = UnsafeMutablePointer<Float>.allocate(capacity: max(count, 1))
            buffer.initialize(repeating: 0, count: max(count, 1))
            return buffer
        }
        filters = (0..<channels).map { _ in
            let buffer = UnsafeMutablePointer<Double>.allocate(capacity: 2 * lineCount)
            buffer.initialize(repeating: 0, count: 2 * lineCount)
            return buffer
        }
        lengthPointers = .allocate(capacity: max(channels, 1))
        gainPointers = .allocate(capacity: max(channels, 1))
        storagePointers = .allocate(capacity: max(channels, 1))
        filterPointers = .allocate(capacity: max(channels, 1))
        chunkOutputs = .allocate(capacity: max(channels, 1))
        for channel in 0..<channels {
            lengthPointers[channel] = UnsafePointer(lengthBuffers[channel])
            gainPointers[channel] = UnsafePointer(gainBuffers[channel])
            storagePointers[channel] = storage[channel]
            filterPointers[channel] = filters[channel]
            chunkOutputs[channel] = nil
        }
        coupled = controls.width != 1 && channels >= 2
        self.workers = max(workers, 1)
    }

    deinit {
        for buffer in lengths { buffer.deallocate() }
        for buffer in gains { buffer.deallocate() }
        for buffer in storage { buffer.deallocate() }
        for buffer in filters { buffer.deallocate() }
        lengthPointers.deallocate()
        gainPointers.deallocate()
        storagePointers.deallocate()
        filterPointers.deallocate()
        chunkOutputs.deallocate()
    }

    func process(frames: Range<Int>) async throws {
        for channel in outputs.indices {
            chunkOutputs[channel] = outputs[channel].baseAddress.map { $0 + frames.lowerBound }
        }
        let channels = outputs.count
        let groupSize = coupled ? 2 : 1
        let groups = (channels + groupSize - 1) / groupSize
        Parallel.forEach(groups, workers: workers) { group in
            let first = group * groupSize
            let count = min(groupSize, channels - first)
            // A lone channel left over from pairing has nothing to be coupled to, so its width stays as built.
            var settings = controls
            if count < 2 { settings.width = 1 }
            bake.dsp.renderReverb(
                lengthPointers + first, gainPointers + first, storagePointers + first, filterPointers + first,
                chunkOutputs + first, Int32(count), Int32(first), input, settings, frames.lowerBound, frames.count
            )
        }
    }

    func finish() throws -> PendingOutput? { nil }

    func discard() {}
}
