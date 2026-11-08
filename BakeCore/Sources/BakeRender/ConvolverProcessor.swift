import BakeDSP
import BakeGraph
import Foundation

/// Convolver node. The whole input and impulse response exist before the node renders, so on the first chunk it builds
/// the impulse response (trim, reverse, stretch, normalise, pre-delay), then the spectra of every input window and
/// impulse partition. After that each output block is computed independently from those spectra, across all cores, so
/// the output is the same at any chunk size or core count.
final class ConvolverProcessor: StepProcessor {
    private let inputs: [UnsafeMutableBufferPointer<Float>]
    private let sources: [UnsafeMutableBufferPointer<Float>]
    private let outputs: [UnsafeMutableBufferPointer<Float>]
    private let mix: bake.dsp.ParameterSignal
    private let workers: Int
    private let impulseFrames: Int
    private let inputWindows: Int
    private let partitions: Int
    private let trimFrames: Int
    private let preDelayFrames: Int
    private let stretch: Double
    private let reverse: Bool
    private let normalize: Bool
    /// Per input channel: every window's spectrum. Per impulse channel: every partition's.
    private let inputSpectra: [UnsafeMutablePointer<Float>]
    private let impulseSpectra: [UnsafeMutablePointer<Float>]
    /// For each output channel, the (input channel, impulse channel) pairs it sums.
    private let pairs: [[(input: Int, impulse: Int)]]
    private let scratch: [UnsafeMutablePointer<Double>]
    private let blocks: [UnsafeMutablePointer<Float>]
    private var prepared = false

    init(step: RenderStep, sampleRate: Double, pool: BufferPool, workers: Int = Parallel.coreCount) throws {
        guard let input = step.inputs["in"], let output = step.outputs["out"] else {
            throw RenderError.unsupportedNode(step.kind)
        }
        inputs = (0..<input.shape.channels).map { pool.channel($0, of: input) }
        // Unwired `ir`: the input convolves with itself.
        let impulseBinding = step.inputs["ir"]
        sources = impulseBinding.map { binding in (0..<binding.shape.channels).map { pool.channel($0, of: binding) } } ?? inputs
        outputs = (0..<output.shape.channels).map { pool.channel($0, of: output) }
        mix = bake.dsp.ParameterSignal("mix", of: step, pool: pool)
        self.workers = max(workers, 1)
        normalize = step.parameters["normalize"] != .choice("off")
        reverse = step.parameters["reverse"] == .choice("on")
        stretch = ConvolverPlan.stretch(step.parameters)
        let rawFrames = sources.first?.count ?? 0
        trimFrames = ConvolverPlan.trimmedFrames(raw: rawFrames, parameters: step.parameters, sampleRate: sampleRate) < rawFrames
            ? ConvolverPlan.trimmedFrames(raw: rawFrames, parameters: step.parameters, sampleRate: sampleRate) : 0
        preDelayFrames = ConvolverPlan.preDelayFrames(step.parameters, sampleRate: sampleRate)
        impulseFrames = ConvolverPlan.impulseFrames(raw: rawFrames, parameters: step.parameters, sampleRate: sampleRate)
        inputWindows = Int(bake.dsp.convolverInputBlockCount(inputs.first?.count ?? 0))
        partitions = Int(bake.dsp.convolverPartitionCount(impulseFrames))

        let trueStereo = ConvolverPlan.usesTrueStereo(
            step.parameters, impulseChannels: sources.count, impulseIsWired: impulseBinding != nil
        ) && outputs.count == 2
        let inputCount = inputs.count, impulseCount = sources.count
        pairs = (0..<outputs.count).map { channel in
            if trueStereo {
                return [(0, channel), (min(1, inputCount - 1), 2 + channel)]
            }
            let inputChannel = inputCount == 1 ? 0 : min(channel, inputCount - 1)
            let impulseChannel = impulseCount == 1 ? 0 : min(channel, impulseCount - 1)
            return [(inputChannel, impulseChannel)]
        }

        let spectrumFloats = Int(bake.dsp.convolverSpectrumFloats)
        let floats = (inputs.count * inputWindows + sources.count * partitions) * spectrumFloats
        try NodeMemory.require(bytes: floats * MemoryLayout<Float>.stride + sources.count * impulseFrames * MemoryLayout<Float>.stride)
        func allocate(_ count: Int) -> UnsafeMutablePointer<Float> {
            let buffer = UnsafeMutablePointer<Float>.allocate(capacity: max(count, 1))
            buffer.initialize(repeating: 0, count: max(count, 1))
            return buffer
        }
        let windowFloats = inputWindows * spectrumFloats, partitionFloats = partitions * spectrumFloats
        inputSpectra = (0..<inputCount).map { _ in allocate(windowFloats) }
        impulseSpectra = (0..<impulseCount).map { _ in allocate(partitionFloats) }
        let scratchDoubles = Int(bake.dsp.convolverScratchDoubles())
        scratch = (0..<self.workers).map { _ in
            let buffer = UnsafeMutablePointer<Double>.allocate(capacity: scratchDoubles)
            buffer.initialize(repeating: 0, count: scratchDoubles)
            bake.dsp.convolverPrepareScratch(buffer)
            return buffer
        }
        blocks = (0..<self.workers).map { _ in allocate(Int(bake.dsp.convolverBlock)) }
    }

    deinit {
        for buffer in inputSpectra + impulseSpectra + blocks { buffer.deallocate() }
        for buffer in scratch { buffer.deallocate() }
    }

    /// The impulse response, then every spectrum, built once across all cores.
    private func prepare() {
        let channels = sources.count
        let prepared = (0..<channels).map { _ -> UnsafeMutablePointer<Float> in
            let buffer = UnsafeMutablePointer<Float>.allocate(capacity: max(impulseFrames, 1))
            buffer.initialize(repeating: 0, count: max(impulseFrames, 1))
            return buffer
        }
        defer { for buffer in prepared { buffer.deallocate() } }
        let sourcePointers: [UnsafePointer<Float>?] = sources.map { buffer in buffer.baseAddress.map { UnsafePointer($0) } }
        let outputPointers: [UnsafeMutablePointer<Float>?] = prepared
        sourcePointers.withUnsafeBufferPointer { source in
            outputPointers.withUnsafeBufferPointer { destination in
                bake.dsp.convolverPrepareImpulse(
                    source.baseAddress, Int32(channels), sources.first?.count ?? 0, trimFrames, reverse, stretch,
                    normalize, preDelayFrames, destination.baseAddress, impulseFrames
                )
            }
        }
        let spectrumFloats = Int(bake.dsp.convolverSpectrumFloats)
        let inputTasks = inputs.count * inputWindows
        let total = inputTasks + channels * partitions
        let groups = min(workers, max(total, 1))
        let share = (total + groups - 1) / groups
        Parallel.forEach(groups, workers: workers) { group in
            for task in min(group * share, total)..<min((group + 1) * share, total) {
                if task < inputTasks {
                    let channel = task / inputWindows, window = task % inputWindows
                    guard let base = inputs[channel].baseAddress else { continue }
                    bake.dsp.convolverInputSpectrum(
                        base, inputs[channel].count, window, scratch[group], inputSpectra[channel] + window * spectrumFloats
                    )
                } else {
                    let index = task - inputTasks
                    let channel = index / partitions, partition = index % partitions
                    bake.dsp.convolverImpulseSpectrum(
                        prepared[channel], impulseFrames, partition, scratch[group], impulseSpectra[channel] + partition * spectrumFloats
                    )
                }
            }
        }
    }

    func process(frames: Range<Int>) async throws {
        if !prepared {
            prepared = true
            prepare()
        }
        let block = Int(bake.dsp.convolverBlock)
        let firstBlock = frames.lowerBound / block
        let lastBlock = (frames.upperBound - 1) / block
        let blockCount = lastBlock - firstBlock + 1
        let total = outputs.count * blockCount
        let groups = min(workers, max(total, 1))
        let share = (total + groups - 1) / groups
        Parallel.forEach(groups, workers: workers) { group in
            for task in min(group * share, total)..<min((group + 1) * share, total) {
                let channel = task / blockCount
                let index = firstBlock + task % blockCount
                let pairInputs: [UnsafePointer<Float>?] = pairs[channel].map { UnsafePointer(inputSpectra[$0.input]) }
                let pairImpulses: [UnsafePointer<Float>?] = pairs[channel].map { UnsafePointer(impulseSpectra[$0.impulse]) }
                pairInputs.withUnsafeBufferPointer { inputPointers in
                    pairImpulses.withUnsafeBufferPointer { impulsePointers in
                        bake.dsp.convolverRenderBlock(
                            inputPointers.baseAddress, impulsePointers.baseAddress, pairs[channel].count, inputWindows, partitions,
                            index, scratch[group], blocks[group]
                        )
                    }
                }
                guard let destination = outputs[channel].baseAddress else { continue }
                let dry = dryChannel(for: channel)
                let start = max(frames.lowerBound, index * block), end = min(frames.upperBound, (index + 1) * block)
                for frame in start..<end {
                    let wet = blocks[group][frame - index * block]
                    let amount = min(max(mix.valueAt(frame), 0), 1)
                    var value = wet
                    if amount < 1 {
                        let source: Float = dry.map { buffer in frame < buffer.count ? buffer[frame] : 0 } ?? 0
                        value = amount == 0 ? source : source * (1 - amount) + wet * amount
                    }
                    destination[frame] = value.isFinite ? value : 0
                }
            }
        }
    }

    /// The input channel heard as the dry signal on an output channel (a mono input spreads to every channel).
    private func dryChannel(for channel: Int) -> UnsafeMutableBufferPointer<Float>? {
        if inputs.count == 1 { return inputs[0] }
        return channel < inputs.count ? inputs[channel] : nil
    }

    func finish() throws -> PendingOutput? { nil }

    func discard() {}
}
