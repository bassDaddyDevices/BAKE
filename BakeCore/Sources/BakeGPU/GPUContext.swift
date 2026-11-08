import Foundation
import Metal

public enum GPUError: Error, Equatable, Sendable {
    case noDevice
    case missingShaderLibrary
    case missingKernel(String)
    case allocationFailed(bytes: Int)
    case commandFailed
}

/// BAKE's GPU engine: one Metal device, command queue, and pipelines compiled once in `init`.
/// Create one per app run and reuse it for every bake.
///
/// `@unchecked Sendable`: every property is immutable after `init`, and Metal devices, command
/// queues, and pipeline states are safe to use from multiple threads.
public final class GPUContext: @unchecked Sendable {
    public let device: any MTLDevice
    private let queue: any MTLCommandQueue
    private let pipelines: [String: any MTLComputePipelineState]

    /// Every kernel in the package's shaders, compiled once here.
    static let kernelNames = ["scaleInPlace", "resonatorBands", "resonatorMix", "resonatorBandsBlocked", "resonatorMixGained", "residualExplosion", "residualExplosionUp", "residualExplosionDown", "fractalMask", "resynthesisSines", "otftEnvelope", "otftSmooth"]

    public init() throws(GPUError) {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw .noDevice
        }
        let library: any MTLLibrary
        do {
            library = try device.makeDefaultLibrary(bundle: .module)
        } catch {
            throw .missingShaderLibrary
        }
        var pipelines: [String: any MTLComputePipelineState] = [:]
        for name in Self.kernelNames {
            guard let function = library.makeFunction(name: name),
                  let pipeline = try? device.makeComputePipelineState(function: function) else {
                throw .missingKernel(name)
            }
            pipelines[name] = pipeline
        }
        self.device = device
        self.queue = queue
        self.pipelines = pipelines
    }

    /// A compiled pipeline. Every name in `kernelNames` is guaranteed present after `init`.
    func pipeline(_ name: String) -> any MTLComputePipelineState {
        guard let pipeline = pipelines[name] else { preconditionFailure("Unknown kernel \(name)") }
        return pipeline
    }

    func makeCommandBuffer() throws(GPUError) -> any MTLCommandBuffer {
        guard let commandBuffer = queue.makeCommandBuffer() else { throw .commandFailed }
        return commandBuffer
    }

    /// A zeroed buffer in unified memory. The CPU sees it through `contents()` (bound to `Float`)
    /// and the GPU through the buffer itself — the same bytes, so nothing is ever copied.
    public func makeSharedBuffer(floatCount: Int) throws(GPUError) -> any MTLBuffer {
        let count = max(floatCount, 1)
        let length = count * MemoryLayout<Float>.stride
        guard length <= device.maxBufferLength,
              let buffer = device.makeBuffer(length: length, options: .storageModeShared) else {
            throw .allocationFailed(bytes: length)
        }
        buffer.contents().bindMemory(to: Float.self, capacity: count).initialize(repeating: 0, count: count)
        return buffer
    }

    /// Multiplies `count` floats, starting `offset` floats into `buffer`, in place on the GPU.
    public func scale(_ buffer: any MTLBuffer, offset: Int = 0, count: Int, by factor: Float) async throws(GPUError) {
        guard count > 0 else { return }
        let commandBuffer = try makeCommandBuffer()
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw .commandFailed
        }
        let scalePipeline = pipeline("scaleInPlace")
        var sampleCount = UInt32(count)
        var factor = factor
        encoder.setComputePipelineState(scalePipeline)
        encoder.setBuffer(buffer, offset: offset * MemoryLayout<Float>.stride, index: 0)
        encoder.setBytes(&sampleCount, length: MemoryLayout<UInt32>.size, index: 1)
        encoder.setBytes(&factor, length: MemoryLayout<Float>.size, index: 2)
        // Dispatch exactly the work size; Metal sizes the last threadgroup to fit.
        let width = min(scalePipeline.maxTotalThreadsPerThreadgroup, count)
        encoder.dispatchThreads(
            MTLSize(width: count, height: 1, depth: 1),
            threadsPerThreadgroup: MTLSize(width: width, height: 1, depth: 1)
        )
        encoder.endEncoding()
        try await run(commandBuffer)
    }

    /// Commits and waits for completion without blocking a thread.
    func run(_ commandBuffer: any MTLCommandBuffer) async throws(GPUError) {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            commandBuffer.addCompletedHandler { _ in continuation.resume() }
            commandBuffer.commit()
        }
        if commandBuffer.status == .error {
            throw .commandFailed
        }
    }
}
