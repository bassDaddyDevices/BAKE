import BakeDSP
import BakeGPU
import BakeGraph
import Foundation

/// Spectral Resynthesis: each channel is taken apart into sine partials and a noise residual and rebuilt
/// (see BakeDSP/Resynthesis.h). The partials are found over the whole channel when the first chunk arrives
/// (its input is complete by then, as for every node that looks ahead), the channels across the cores; each chunk
/// after that is independent, so frame-range pieces of every channel run across the cores and give the same bits.
/// With any extra on (Pitch, Stretch, Quantize, Freeze, Crystallize, Phase Randomize) the table is rewritten
/// once after analysis and the transformed renderer runs; with none, the original renderer does.
/// Engine GPU sums the sine partials on the GPU instead (an oscillator bank, one thread per sample, up to 16,384
/// partials); the residual noise and the mix stay on the CPU. The GPU bank works in floats, so its bits differ
/// from the CPU engine's (a few millionths), but they are the same for any chunk size and core count.
final class ResynthesisProcessor: StepProcessor {
    private var settings = bake.dsp.ResynthesisSettings()
    private let sampleRate: Double
    private let tilt: bake.dsp.ParameterSignal
    private let balance: bake.dsp.ParameterSignal
    private let transform: bake.dsp.ResynthesisTransform
    private let transformed: Bool
    private let inputs: [UnsafeMutableBufferPointer<Float>]
    /// The second input's channels, when Mode uses it.
    private let bInputs: [UnsafeMutableBufferPointer<Float>]
    private let outputs: [UnsafeMutableBufferPointer<Float>]
    private let inputFrames: Int
    private let bFrames: Int
    private let outputFrames: Int

    // Allocated once, here; never in the processing loop.
    private let sourceTables: [UnsafeMutablePointer<Float>]
    /// B's analysed tables, one per output channel, when Mode uses B.
    private let bTables: [UnsafeMutablePointer<Float>]
    /// The rewritten tables and noise maps, only when transformed.
    private let tables: [UnsafeMutablePointer<Float>]
    private let noiseMaps: [UnsafeMutablePointer<Float>]
    /// Analysis and transform scratch and work, one set per channel so the channels can run at once.
    private let channelScratch: [UnsafeMutableRawPointer]
    private let channelWork: [UnsafeMutablePointer<Float>]
    private let workers: Int
    /// The GPU oscillator bank, only with Engine GPU, and each channel's summed sines for the chunk in hand.
    private let sineKernel: ResynthesisSineKernel?
    private let sines: [UnsafeMutablePointer<Float>]
    private let sineSlots: Int
    private let tableFrames: Int
    /// Render pieces: each gets its work floats, then (16-byte aligned) its raw scratch.
    private let plan: PiecePlan
    private var analysed = false

    init(
        step: RenderStep, sampleRate: Double, gpu: GPUContext, pool: BufferPool, maxChunkFrames: Int,
        workers: Int = Parallel.coreCount
    ) throws {
        guard let input = step.inputs["in"], let output = step.outputs["out"] else {
            throw RenderError.unsupportedNode(step.kind)
        }
        self.sampleRate = sampleRate
        func choice(_ id: ParameterID, _ fallback: String) -> String {
            if case .choice(let value)? = step.parameters[id] { value } else { fallback }
        }
        settings.partials = Int32((step.parameters["partials"]?.numberValue ?? 128).rounded())
        settings.hysteresis = step.parameters["hysteresis"]?.numberValue ?? 0.3
        settings.fftSize = Int32(choice("fftSize", "4096")) ?? 4_096
        switch choice("harmonics", "all") {
        case "odd": settings.parity = .odd
        case "even": settings.parity = .even
        default: settings.parity = .all
        }
        tilt = bake.dsp.ParameterSignal("tilt", of: step, pool: pool)
        balance = bake.dsp.ParameterSignal("balance", of: step, pool: pool)

        var transform = bake.dsp.ResynthesisTransform()
        transform.pitch = bake.dsp.ParameterSignal("pitch", of: step, pool: pool)
        transform.stretch = step.parameters["stretch"]?.numberValue ?? 1
        transform.crystallize = bake.dsp.ParameterSignal("crystallize", of: step, pool: pool)
        transform.quantize = bake.dsp.ParameterSignal("quantize", of: step, pool: pool)
        transform.scale = switch choice("scale", "chromatic") {
        case "major": .major
        case "minor": .minor
        case "pentatonic": .pentatonic
        default: .chromatic
        }
        transform.root = Int32(choice("root", "0")) ?? 0
        transform.glide = bake.dsp.ParameterSignal("glide", of: step, pool: pool)
        transform.freeze = bake.dsp.ControlInput("freeze", of: step, pool: pool)
        transform.decay = bake.dsp.ParameterSignal("decay", of: step, pool: pool)
        transform.phaseRandomize = bake.dsp.ParameterSignal("phaseRandomize", of: step, pool: pool)
        transform.seed = UInt32(step.parameters["seed"]?.numberValue ?? 0)
        // Mode only applies with something wired to B.
        let second = step.inputs["b"]
        let mode: bake.dsp.ResynthesisMode = switch choice("mode", "off") {
        case "cross": .cross
        case "morph": .morph
        case "splice": .splice
        case "swapNoise": .swapNoise
        default: .off
        }
        transform.mode = second == nil ? .off : mode
        transform.amount = bake.dsp.ParameterSignal("amount", of: step, pool: pool)
        transform.split = bake.dsp.ParameterSignal("split", of: step, pool: pool)
        self.transform = transform
        transformed = !bake.dsp.resynthesisTransformIsNeutral(transform)
        let usesB = second != nil && transform.mode != .off
        bInputs = usesB ? (0..<second!.shape.channels).map { pool.channel($0, of: second!) } : []
        bFrames = usesB ? second!.shape.frames : 0

        inputs = (0..<input.shape.channels).map { pool.channel($0, of: input) }
        outputs = (0..<output.shape.channels).map { pool.channel($0, of: output) }
        inputFrames = input.shape.frames
        outputFrames = output.shape.frames

        // The partial tables are the big allocation: 12 bytes per partial per frame, per channel (twice when transformed).
        let channelCount = output.shape.channels
        let sourceFloats = max(Int(bake.dsp.resynthesisTableFloats(settings, inputFrames)), 1)
        let outputFloats = transformed ? max(Int(bake.dsp.resynthesisOutputTableFloats(settings, transform, outputFrames)), 1) : 0
        let mapFloats = transformed ? max(Int(bake.dsp.resynthesisNoiseMapFloats(settings, outputFrames)), 1) : 0
        let bFloats = usesB ? max(Int(bake.dsp.resynthesisTableFloats(settings, bFrames)), 1) : 0
        let tableBytes = (sourceFloats + outputFloats + mapFloats + bFloats) * MemoryLayout<Float>.stride * channelCount
        guard tableBytes < Int(ProcessInfo.processInfo.physicalMemory / 2) else {
            throw RenderError.insufficientMemory(requiredBytes: tableBytes)
        }
        func allocate(_ floats: Int) -> UnsafeMutablePointer<Float> {
            let pointer = UnsafeMutablePointer<Float>.allocate(capacity: floats)
            pointer.initialize(repeating: 0, count: floats)
            return pointer
        }
        sourceTables = (0..<channelCount).map { _ in allocate(sourceFloats) }
        bTables = usesB ? (0..<channelCount).map { _ in allocate(bFloats) } : []
        tables = transformed ? (0..<channelCount).map { _ in allocate(outputFloats) } : []
        noiseMaps = transformed ? (0..<channelCount).map { _ in allocate(mapFloats) } : []
        let scratchBytes = max(
            Int(bake.dsp.resynthesisScratchBytes(settings, maxChunkFrames)),
            Int(bake.dsp.resynthesisTransformScratchBytes(settings)), 16
        )
        let workCount = max(
            Int(bake.dsp.resynthesisAnalysisWorkFloats(settings)),
            Int(bake.dsp.resynthesisRenderWorkFloats(settings, maxChunkFrames)), 1
        )
        channelScratch = (0..<channelCount).map { _ in
            let buffer = UnsafeMutableRawPointer.allocate(byteCount: scratchBytes, alignment: 16)
            buffer.initializeMemory(as: UInt8.self, repeating: 0, count: scratchBytes)
            return buffer
        }
        channelWork = (0..<channelCount).map { _ in allocate(workCount) }
        self.workers = max(workers, 1)
        // Engine GPU: one oscillator bank shared by the channels, which take turns.
        let partialCount = Int(bake.dsp.resynthesisPartialCount(settings))
        sineSlots = transformed && usesB ? Int(bake.dsp.resynthesisOutputSlots(settings, transform)) : partialCount
        tableFrames = transformed ? outputFrames : inputFrames
        if choice("engine", "cpu") == "gpu" {
            let hop = Int(bake.dsp.resynthesisLayout(settings).hop)
            let bankBytes = ResynthesisSineKernel.bytes(slots: sineSlots, maxFrames: max(maxChunkFrames, 1), hop: hop)
            guard bankBytes + tableBytes < Int(ProcessInfo.processInfo.physicalMemory / 2) else {
                throw RenderError.insufficientMemory(requiredBytes: bankBytes + tableBytes)
            }
            do {
                sineKernel = try ResynthesisSineKernel(gpu: gpu, slots: sineSlots, maxFrames: max(maxChunkFrames, 1), hop: hop)
            } catch {
                throw RenderError.gpuUnavailable
            }
            sines = (0..<channelCount).map { _ in allocate(max(maxChunkFrames, 1)) }
        } else {
            sineKernel = nil
            sines = []
        }
        let capturedSettings = settings
        plan = PiecePlan(channels: channelCount, maxChunkFrames: max(maxChunkFrames, 1), workers: workers) { piece in
            let work = (Int(bake.dsp.resynthesisRenderWorkFloats(capturedSettings, piece)) + 3) / 4 * 4
            let raw = (Int(bake.dsp.resynthesisScratchBytes(capturedSettings, piece)) + 15) / 16 * 4
            return work + raw + 4
        }
    }

    deinit {
        (sourceTables + bTables + tables + noiseMaps + channelWork + sines).forEach { $0.deallocate() }
        channelScratch.forEach { $0.deallocate() }
    }

    func process(frames: Range<Int>) async throws {
        if !analysed {
            Parallel.forEach(outputs.count, workers: workers) { channel in
                guard let source = inputs[min(channel, inputs.count - 1)].baseAddress else { return }
                let scratch = channelScratch[channel]
                let work = channelWork[channel]
                bake.dsp.resynthesisAnalyse(settings, sampleRate, source, inputFrames, sourceTables[channel], scratch, work)
                let bTable: UnsafeMutablePointer<Float>? = bTables.isEmpty ? nil : bTables[channel]
                if let bTable, let bSource = bInputs[min(channel, bInputs.count - 1)].baseAddress {
                    bake.dsp.resynthesisAnalyse(settings, sampleRate, bSource, bFrames, bTable, scratch, work)
                }
                if transformed {
                    bake.dsp.resynthesisTransformTable(
                        settings, sampleRate, transform, sourceTables[channel], inputFrames, bTable, bFrames,
                        tables[channel], outputFrames, noiseMaps[channel], scratch
                    )
                }
            }
            analysed = true
        }
        if let sineKernel {
            try await renderSines(sineKernel, frames: frames)
        }
        plan.run(channels: outputs.count, frames: frames) { channel, piece, floats in
            guard let source = inputs[min(channel, inputs.count - 1)].baseAddress,
                  let destination = outputs[channel].baseAddress else { return }
            let workFloats = (Int(bake.dsp.resynthesisRenderWorkFloats(settings, piece.count)) + 3) / 4 * 4
            let scratch = UnsafeMutableRawPointer(floats + workFloats)
            // With the GPU bank, this piece's slice of the channel's summed sines; nil makes the CPU sum them.
            let summed: UnsafePointer<Float>? = sineKernel == nil ? nil : UnsafePointer(sines[channel] + (piece.lowerBound - frames.lowerBound))
            if transformed {
                let bSource: UnsafeMutablePointer<Float>? = bInputs.isEmpty ? nil : bInputs[min(channel, bInputs.count - 1)].baseAddress
                bake.dsp.resynthesisRenderTransformedWithSines(
                    settings, sampleRate, transform, tilt, balance, source, inputFrames, sourceTables[channel],
                    bSource, bFrames, bTables.isEmpty ? nil : bTables[channel], tables[channel],
                    noiseMaps[channel], outputFrames, destination + piece.lowerBound, piece.lowerBound, piece.count,
                    UInt32(channel), scratch, floats, summed
                )
            } else {
                bake.dsp.resynthesisRenderWithSines(
                    settings, sampleRate, tilt, balance, source, inputFrames, sourceTables[channel],
                    destination + piece.lowerBound, piece.lowerBound, piece.count, UInt32(channel), scratch, floats, summed
                )
            }
        }
    }

    /// Every channel's sine sum for `frames`, from the GPU bank: the CPU writes each hop's partial entries across the cores,
    /// the GPU sums them, and the result is copied out so the next channel can reuse the bank.
    private func renderSines(_ kernel: ResynthesisSineKernel, frames: Range<Int>) async throws {
        var start = frames.lowerBound
        while start < frames.upperBound {
            let count = min(kernel.maxFrames, frames.upperBound - start)
            let hops = bake.dsp.resynthesisSineHops(settings, tableFrames, start, count)
            for channel in outputs.indices {
                let destination = sines[channel] + (start - frames.lowerBound)
                guard hops.count > 0 else {
                    destination.update(repeating: 0, count: count)
                    continue
                }
                let table: UnsafeMutablePointer<Float> = transformed ? tables[channel] : sourceTables[channel]
                Parallel.forEach(Int(hops.count), workers: workers) { hop in
                    bake.dsp.resynthesisSineParams(
                        settings, sampleRate, tilt, table, sineSlots, tableFrames, hops.first + CLongLong(hop),
                        kernel.entries(region: hop), kernel.count(region: hop)
                    )
                }
                do {
                    try await kernel.render(
                        start: start, count: count, firstCentre: Int(hops.firstCentre), hop: Int(hops.hop),
                        firstHop: Int(hops.first), hopCount: Int(hops.count), lastHop: Int(hops.lastHop)
                    )
                } catch {
                    throw RenderError.gpuUnavailable
                }
                destination.update(from: kernel.output, count: count)
            }
            start += count
        }
    }

    func finish() throws -> PendingOutput? { nil }

    func discard() {}
}
