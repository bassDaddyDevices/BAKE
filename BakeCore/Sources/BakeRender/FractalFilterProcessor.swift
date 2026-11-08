import BakeDSP
import BakeGPU
import BakeGraph
import Metal

/// Fractal Filter uses the Metal spectral mask with the reference CPU STFT.
final class FractalFilterProcessor: StepProcessor {
    private let kernel: FractalFilterKernel
    private let sampleRate: Double
    private let fftSize: Int
    private let layout: bake.dsp.StftLayout
    private let inputChannels: [UnsafeMutableBufferPointer<Float>]
    private let outputChannels: [UnsafeMutableBufferPointer<Float>]
    private let inputFrames: Int
    private let mixSignal: bake.dsp.ParameterSignal
    private let phase: bake.dsp.ParameterSignal
    private let seed: UInt32
    private let iterations: bake.dsp.ParameterSignal
    private let warp: bake.dsp.ParameterSignal
    private let bias: bake.dsp.ParameterSignal
    private let q: bake.dsp.ParameterSignal
    private let pattern: bake.dsp.ParameterSignal
    private let frameCapacity: Int
    private let window: UnsafeMutablePointer<Double>
    private let stftScratch: UnsafeMutablePointer<Double>
    private let spectra: UnsafeMutablePointer<Float>
    private let rows: UnsafeMutablePointer<Float>
    private let masks: UnsafeMutablePointer<Float>
    private let phases: UnsafeMutablePointer<UInt32>
    private let outputChunk: UnsafeMutablePointer<Float>
    private let chunkCapacity: Int
    private var frameTable: [FractalMaskFrame] = []

    init(step: RenderStep, sampleRate: Double, gpu: GPUContext, pool: BufferPool, maxChunkFrames: Int) throws {
        guard let input = step.inputs["in"], let output = step.outputs["out"] else {
            throw RenderError.unsupportedNode(step.kind)
        }
        self.sampleRate = sampleRate
        inputFrames = input.shape.frames
        chunkCapacity = min(max(maxChunkFrames, 1), input.shape.frames)
        func choice(_ id: ParameterID, _ fallback: String) -> String {
            if case .choice(let value)? = step.parameters[id] { value } else { fallback }
        }
        fftSize = Int(choice("fftSize", "4096")) ?? 4_096
        layout = bake.dsp.StftLayout(fftSize: Int32(fftSize), hop: Int32(fftSize / 4))
        let bins = fftSize / 2 + 1
        iterations = bake.dsp.ParameterSignal("iterations", of: step, pool: pool)
        warp = bake.dsp.ParameterSignal("warp", of: step, pool: pool)
        bias = bake.dsp.ParameterSignal("bias", of: step, pool: pool)
        q = bake.dsp.ParameterSignal("q", of: step, pool: pool)
        mixSignal = bake.dsp.ParameterSignal("mix", of: step, pool: pool)
        pattern = bake.dsp.ParameterSignal("pattern", of: step, pool: pool)
        phase = bake.dsp.ParameterSignal("phaseMode", of: step, pool: pool)
        seed = UInt32(max(0, Int((step.parameters["seed"]?.numberValue ?? 1).rounded())))
        inputChannels = (0..<input.shape.channels).map { pool.channel($0, of: input) }
        outputChannels = (0..<output.shape.channels).map { pool.channel($0, of: output) }

        let rowsNeeded = max(Int(bake.dsp.fractalFilterMaxRows(layout, chunkCapacity)), 1)
        frameCapacity = rowsNeeded
        window = .allocate(capacity: fftSize)
        stftScratch = .allocate(capacity: max(Int(bake.dsp.stftScratchDoubles(layout)), 1))
        spectra = .allocate(capacity: max(Int(bake.dsp.stftSpectrumFloats(layout, rowsNeeded)), 1))
        rows = .allocate(capacity: max(Int(bake.dsp.stftRowFloats(layout, rowsNeeded)), 1))
        masks = .allocate(capacity: rowsNeeded * bins)
        phases = .allocate(capacity: rowsNeeded)
        outputChunk = .allocate(capacity: max(chunkCapacity, 1))
        window.initialize(repeating: 0, count: fftSize)
        bake.dsp.stftWindow(layout, window)
        stftScratch.initialize(repeating: 0, count: max(Int(bake.dsp.stftScratchDoubles(layout)), 1))
        spectra.initialize(repeating: 0, count: max(Int(bake.dsp.stftSpectrumFloats(layout, rowsNeeded)), 1))
        rows.initialize(repeating: 0, count: max(Int(bake.dsp.stftRowFloats(layout, rowsNeeded)), 1))
        masks.initialize(repeating: 0, count: rowsNeeded * bins)
        phases.initialize(repeating: 0, count: rowsNeeded)
        outputChunk.initialize(repeating: 0, count: max(chunkCapacity, 1))
        frameTable.reserveCapacity(rowsNeeded)
        do {
            kernel = try FractalFilterKernel(
                gpu: gpu, maxFrames: rowsNeeded, maxBins: bins, sampleRate: sampleRate, fftSize: fftSize
            )
        } catch {
            throw RenderError.gpuUnavailable
        }
    }

    deinit {
        window.deallocate()
        stftScratch.deallocate()
        spectra.deallocate()
        rows.deallocate()
        masks.deallocate()
        phases.deallocate()
        outputChunk.deallocate()
    }

    private func pattern(at frame: Int) -> FractalMaskPattern {
        let index = min(max(Int(pattern.valueAt(frame).rounded()), 0), 3)
        return FractalMaskPattern(rawValue: UInt32(index)) ?? .cantor
    }

    func process(frames: Range<Int>) async throws {
        guard !frames.isEmpty else { return }
        let covered = bake.dsp.stftFramesCovering(layout, inputFrames, frames.lowerBound, frames.count)
        let firstFrame = Int(covered.first)
        let frameCount = Int(covered.count)
        guard frameCount > 0 && frameCount <= frameCapacity else { throw RenderError.gpuUnavailable }
        let bins = fftSize / 2 + 1
        frameTable.removeAll(keepingCapacity: true)
        for row in 0..<frameCount {
            let center = min(max(Int(bake.dsp.stftFrameCenter(layout, firstFrame + row)), 0), max(inputFrames - 1, 0))
            frameTable.append(FractalMaskFrame(
                iterations: Int(iterations.valueAt(center).rounded()),
                warp: Double(warp.valueAt(center)),
                center: Double(0.5 + 0.5 * bias.valueAt(center)),
                q: Double(q.valueAt(center)), pattern: pattern(at: center)
            ))
            phases[row] = UInt32(min(max(Int(phase.valueAt(center).rounded()), 0), 2))
        }
        let gpuOutput: any MTLBuffer
        do {
            gpuOutput = try await kernel.run(
                frames: frameTable, binRange: 0..<bins, totalBins: bins, sampleRate: sampleRate, fftSize: fftSize
            )
        } catch {
            throw RenderError.gpuUnavailable
        }
        let gpuMasks = gpuOutput.contents().assumingMemoryBound(to: Float.self)
        for row in 0..<frameCount {
            masks.advanced(by: row * bins).update(from: gpuMasks + row * bins, count: bins)
        }
        for channel in outputChannels.indices {
            let input = inputChannels[min(channel, inputChannels.count - 1)]
            guard let source = input.baseAddress, let destination = outputChannels[channel].baseAddress else { continue }
            if (0..<frames.count).allSatisfy({ mixSignal.valueAt(frames.lowerBound + $0) == 0 }) {
                destination.advanced(by: frames.lowerBound).update(from: source.advanced(by: frames.lowerBound), count: frames.count)
                continue
            }
            bake.dsp.fractalFilterProcessChannel(
                layout, window, source, inputFrames, frames.lowerBound, frames.count,
                firstFrame, frameCount, masks, phases, seed, spectra, rows, stftScratch, outputChunk
            )
            for offset in 0..<frames.count {
                let dry = source[frames.lowerBound + offset]
                let amount = Float(mixSignal.valueAt(frames.lowerBound + offset))
                destination[frames.lowerBound + offset] = amount == 0 ? dry : dry * (1 - amount) + outputChunk[offset] * amount
            }
        }
    }

    func finish() throws -> PendingOutput? { nil }

    func discard() {}
}
