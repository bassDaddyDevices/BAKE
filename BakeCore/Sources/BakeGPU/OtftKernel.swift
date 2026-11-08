import Foundation
import Metal

/// What a frame asks of every unit; mirrors `OtftFrameParams` in OtftCompressor.metal (eight floats).
public struct OtftGPUFrame: Equatable, Sendable {
    public var downThreshold: Float
    public var downSlope: Float
    public var upThreshold: Float
    public var upSlope: Float
    public var maxBoost: Float
    public var attackMs: Float
    public var releaseMs: Float
    public var padding: Float = 0

    public init(
        downThreshold: Float, downSlope: Float, upThreshold: Float, upSlope: Float, maxBoost: Float,
        attackMs: Float, releaseMs: Float
    ) {
        self.downThreshold = downThreshold
        self.downSlope = downSlope
        self.upThreshold = upThreshold
        self.upSlope = upSlope
        self.maxBoost = maxBoost
        self.attackMs = attackMs
        self.releaseMs = releaseMs
    }
}

/// Mirrors `OtftUniforms` in OtftCompressor.metal.
struct OtftGPUUniforms {
    var frames: UInt32
    var units: UInt32
    var hopMilliseconds: Float
    var kneeDb: Float
    var anticipating: UInt32
    var smoothFrames: UInt32
}

/// The OTFT Compressor's follower and gain computer on the GPU: one thread per unit (bin or group), each looping over
/// every frame, the case the GPU is best at. It does the same arithmetic as `otftGainColumns` on the CPU, in floats, so the
/// two agree to a few thousandths of a dB rather than bit for bit.
public final class OtftKernel {
    private let gpu: GPUContext
    private let frameCapacity: Int
    private let unitCapacity: Int
    private let frameTable: any MTLBuffer
    private let timeScaleTable: any MTLBuffer
    private let offsetTable: any MTLBuffer

    public init(gpu: GPUContext, maxFrames: Int, maxUnits: Int) throws(GPUError) {
        precondition(maxFrames > 0 && maxUnits > 0)
        precondition(maxFrames <= Int(UInt32.max) && maxUnits <= Int(UInt32.max))
        self.gpu = gpu
        frameCapacity = maxFrames
        unitCapacity = maxUnits
        let (tableBytes, overflow) = maxFrames.multipliedReportingOverflow(by: MemoryLayout<OtftGPUFrame>.stride)
        guard !overflow, tableBytes <= gpu.device.maxBufferLength,
              let table = gpu.device.makeBuffer(length: tableBytes, options: .storageModeShared) else {
            throw .allocationFailed(bytes: overflow ? Int.max : tableBytes)
        }
        frameTable = table
        timeScaleTable = try gpu.makeSharedBuffer(floatCount: maxUnits)
        offsetTable = try gpu.makeSharedBuffer(floatCount: maxUnits)
    }

    /// Runs the follower over `surface` (frame-major `frames.count × units` levels in dB, in place: gains out), then
    /// the time smoothing when `smoothFrames` is above 0. Returns the buffer that holds the gains: `surface` itself, or
    /// `scratch` when smoothing ran (which must then be the same size as `surface`).
    public func run(
        surface: any MTLBuffer, scratch: (any MTLBuffer)?, frames: [OtftGPUFrame], units: Int,
        timeScale: [Float], offsetDb: [Float], hopMilliseconds: Float, kneeDb: Float, anticipating: Bool,
        smoothFrames: Int
    ) async throws(GPUError) -> any MTLBuffer {
        precondition(!frames.isEmpty && frames.count <= frameCapacity)
        precondition(units > 0 && units <= unitCapacity && timeScale.count == units && offsetDb.count == units)
        precondition(surface.length >= frames.count * units * MemoryLayout<Float>.stride)
        precondition(smoothFrames == 0 || (scratch?.length ?? 0) >= frames.count * units * MemoryLayout<Float>.stride)
        frames.withUnsafeBufferPointer { source in
            frameTable.contents().bindMemory(to: OtftGPUFrame.self, capacity: frameCapacity)
                .update(from: source.baseAddress!, count: source.count)
        }
        timeScale.withUnsafeBufferPointer { source in
            timeScaleTable.contents().bindMemory(to: Float.self, capacity: unitCapacity)
                .update(from: source.baseAddress!, count: source.count)
        }
        offsetDb.withUnsafeBufferPointer { source in
            offsetTable.contents().bindMemory(to: Float.self, capacity: unitCapacity)
                .update(from: source.baseAddress!, count: source.count)
        }
        var uniforms = OtftGPUUniforms(
            frames: UInt32(frames.count), units: UInt32(units), hopMilliseconds: hopMilliseconds, kneeDb: kneeDb,
            anticipating: anticipating ? 1 : 0, smoothFrames: UInt32(max(smoothFrames, 0))
        )
        let commandBuffer = try gpu.makeCommandBuffer()
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { throw .commandFailed }
        let envelope = gpu.pipeline("otftEnvelope")
        encoder.setComputePipelineState(envelope)
        encoder.setBuffer(surface, offset: 0, index: 0)
        encoder.setBuffer(frameTable, offset: 0, index: 1)
        encoder.setBytes(&uniforms, length: MemoryLayout<OtftGPUUniforms>.size, index: 2)
        encoder.setBuffer(timeScaleTable, offset: 0, index: 3)
        encoder.setBuffer(offsetTable, offset: 0, index: 4)
        encoder.dispatchThreads(
            MTLSize(width: units, height: 1, depth: 1),
            threadsPerThreadgroup: MTLSize(width: min(envelope.maxTotalThreadsPerThreadgroup, units), height: 1, depth: 1)
        )
        var result = surface
        if smoothFrames > 0, let scratch {
            let smooth = gpu.pipeline("otftSmooth")
            encoder.setComputePipelineState(smooth)
            encoder.setBuffer(surface, offset: 0, index: 0)
            encoder.setBuffer(scratch, offset: 0, index: 1)
            encoder.setBytes(&uniforms, length: MemoryLayout<OtftGPUUniforms>.size, index: 2)
            encoder.dispatchThreads(
                MTLSize(width: units, height: 1, depth: 1),
                threadsPerThreadgroup: MTLSize(width: min(smooth.maxTotalThreadsPerThreadgroup, units), height: 1, depth: 1)
            )
            result = scratch
        }
        encoder.endEncoding()
        try await gpu.run(commandBuffer)
        return result
    }
}
