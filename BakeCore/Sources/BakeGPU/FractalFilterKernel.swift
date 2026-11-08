import Foundation
import Metal

/// The self-similar seed used by Fractal Filter's spectral mask.
public enum FractalMaskPattern: UInt32, CaseIterable, Sendable {
    case cantor = 0
    case mandelbrot = 1
    case julia = 2
    case koch = 3
}

/// Settings at one STFT frame; mirrors `FractalMaskFrame` in FractalFilter.metal.
public struct FractalMaskFrame: Equatable, Sendable {
    public let iterations: UInt32
    public let warp: Float
    public let center: Float
    public let q: Float
    /// The pattern's raw value: a Swift enum is one byte, and Metal reads a 4-byte `uint` here.
    public let pattern: UInt32

    public init(iterations: Int, warp: Double, center: Double, q: Double, pattern: FractalMaskPattern) {
        precondition(warp.isFinite && center.isFinite && q.isFinite)
        self.iterations = UInt32(min(max(iterations, 1), 16))
        self.warp = Float(min(max(warp, 0.1), 10))
        self.center = Float(min(max(center, 0), 1))
        self.q = Float(min(max(q, 0.1), 50))
        self.pattern = pattern.rawValue
    }
}

/// Mirrors `FractalMaskUniforms` in FractalFilter.metal.
struct FractalMaskUniforms {
    var frames: UInt32
    var bins: UInt32
    var binOffset: UInt32
    var binHz: Float
    var inverseLogSpan: Float
}

/// Generates the raw recursive spectral mask on the GPU, one thread per (frame, bin).
/// The returned shared buffer contains compact frame-major rows with `binRange.count` bins each.
public final class FractalFilterKernel {
    private let gpu: GPUContext
    private let frameCapacity: Int
    private let binCapacity: Int
    private let frameTable: any MTLBuffer
    private let output: any MTLBuffer
    private let positions: any MTLBuffer
    private let sampleRate: Double
    private let fftSize: Int

    public init(gpu: GPUContext, maxFrames: Int, maxBins: Int, sampleRate: Double, fftSize: Int) throws(GPUError) {
        precondition(maxFrames > 0 && maxBins > 0)
        precondition(maxFrames <= Int(UInt32.max) && maxBins <= Int(UInt32.max))
        self.gpu = gpu
        frameCapacity = maxFrames
        binCapacity = maxBins
        self.sampleRate = sampleRate
        self.fftSize = fftSize

        let (tableBytes, tableOverflow) = maxFrames.multipliedReportingOverflow(by: MemoryLayout<FractalMaskFrame>.stride)
        guard !tableOverflow, tableBytes <= gpu.device.maxBufferLength,
              let frameTable = gpu.device.makeBuffer(length: tableBytes, options: .storageModeShared) else {
            throw .allocationFailed(bytes: tableOverflow ? Int.max : tableBytes)
        }
        self.frameTable = frameTable
        frameTable.contents().bindMemory(to: FractalMaskFrame.self, capacity: maxFrames)
            .initialize(
                repeating: FractalMaskFrame(iterations: 1, warp: 1, center: 0.5, q: 1, pattern: .cantor),
                count: maxFrames
            )

        let (outputCount, overflow) = maxFrames.multipliedReportingOverflow(by: maxBins)
        guard !overflow, outputCount <= gpu.device.maxBufferLength / MemoryLayout<Float>.stride else {
            throw .allocationFailed(bytes: overflow ? Int.max : outputCount * MemoryLayout<Float>.stride)
        }
        output = try gpu.makeSharedBuffer(floatCount: outputCount)
        positions = try gpu.makeSharedBuffer(floatCount: maxBins)
        let positionPointer = positions.contents().bindMemory(to: Float.self, capacity: maxBins)
        for bin in 0..<maxBins {
            positionPointer[bin] = Self.position(bin: bin, sampleRate: sampleRate, fftSize: fftSize)
        }
    }

    /// Log-frequency position 0...1 of a bin: 20 Hz to Nyquist, in double, rounded once to Float.
    public static func position(bin: Int, sampleRate: Double, fftSize: Int) -> Float {
        guard bin > 0 else { return 0 }
        let frequency = Double(bin) * sampleRate / Double(fftSize)
        return Float(min(max(log2(frequency / 20) / log2(sampleRate * 0.5 / 20), 0), 1))
    }

    /// Writes `frames.count × binRange.count` raw mask values and returns the shared output buffer.
    /// The shared position table stores each absolute bin's log-frequency coordinate; `binRange`
    /// selects the absolute spectrum range for this dispatch.
    public func run(
        frames: [FractalMaskFrame], binRange: Range<Int>, totalBins: Int,
        sampleRate: Double, fftSize: Int
    ) async throws(GPUError) -> any MTLBuffer {
        let binCount = binRange.count
        precondition(!frames.isEmpty && frames.count <= frameCapacity && frames.count <= Int(UInt32.max))
        precondition(binRange.lowerBound >= 0 && binRange.upperBound <= totalBins)
        precondition(
            binCount > 0 && binCount <= binCapacity && totalBins > 0 &&
            totalBins <= binCapacity && totalBins <= Int(UInt32.max)
        )
        precondition(sampleRate == self.sampleRate && fftSize == self.fftSize)
        precondition(sampleRate.isFinite && sampleRate > 40 && fftSize > 0)

        let framePointer = frameTable.contents().bindMemory(to: FractalMaskFrame.self, capacity: frameCapacity)
        frames.withUnsafeBufferPointer { source in
            framePointer.update(from: source.baseAddress!, count: source.count)
        }

        let positionPointer = positions.contents().bindMemory(to: Float.self, capacity: binCapacity)
        for bin in 0..<totalBins {
            positionPointer[bin] = Self.position(bin: bin, sampleRate: sampleRate, fftSize: fftSize)
        }
        var uniforms = FractalMaskUniforms(
            frames: UInt32(frames.count), bins: UInt32(binCount), binOffset: UInt32(binRange.lowerBound),
            binHz: Float(sampleRate / Double(fftSize)),
            inverseLogSpan: Float(1 / (log2(sampleRate * 0.5) - log2(20)))
        )
        let commandBuffer = try gpu.makeCommandBuffer()
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { throw .commandFailed }
        let pipeline = gpu.pipeline("fractalMask")
        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(output, offset: 0, index: 0)
        encoder.setBuffer(frameTable, offset: 0, index: 1)
        encoder.setBytes(&uniforms, length: MemoryLayout<FractalMaskUniforms>.size, index: 2)
        encoder.setBuffer(positions, offset: 0, index: 3)
        encoder.dispatchThreads(
            MTLSize(width: binCount, height: frames.count, depth: 1),
            threadsPerThreadgroup: MTLSize(
                width: min(pipeline.maxTotalThreadsPerThreadgroup, binCount), height: 1, depth: 1
            )
        )
        encoder.endEncoding()
        try await gpu.run(commandBuffer)
        return output
    }
}
