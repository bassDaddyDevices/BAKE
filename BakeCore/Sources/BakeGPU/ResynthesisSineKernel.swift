import Foundation
import Metal

/// Mirrors `ResynthesisSineUniforms` in ResynthesisSines.metal.
struct ResynthesisSineUniforms {
    var count: UInt32
    var start: Int32
    var firstCentre: Int32
    var hop: Int32
    var firstHop: Int32
    var hopCount: Int32
    var lastHop: Int32
    var slots: UInt32
}

/// The GPU oscillator bank of Spectral Resynthesis: sums the sine partials of a render range, one thread per sample.
/// The CPU writes each hop's partial entries (`resynthesisSineParams`, BakeDSP) straight into `entries`, then `render` sums
/// them. Each sample is computed alone from its hop's entries, in slot order, so splitting a render into chunks never
/// changes a bit. Floats only: it matches the CPU's double-precision bank to a fraction of a bit of 24, not bit for bit.
public final class ResynthesisSineKernel {
    /// Floats per partial entry; mirrors `sineEntryFloats` in BakeDSP/Resynthesis.h.
    public static let entryFloats = 8

    private let gpu: GPUContext
    public let slots: Int
    public let maxFrames: Int
    public let maxHops: Int
    private let entryBuffer: any MTLBuffer
    private let countBuffer: any MTLBuffer
    private let outputBuffer: any MTLBuffer

    /// Bytes `init` needs for these sizes, so a caller can refuse a render that cannot fit before starting it.
    public static func bytes(slots: Int, maxFrames: Int, hop: Int) -> Int {
        let hops = maxFrames / max(hop, 1) + 3
        return (hops * slots * entryFloats + maxFrames) * MemoryLayout<Float>.stride + hops * MemoryLayout<UInt32>.stride
    }

    public init(gpu: GPUContext, slots: Int, maxFrames: Int, hop: Int) throws(GPUError) {
        self.gpu = gpu
        self.slots = slots
        self.maxFrames = max(maxFrames, 1)
        maxHops = self.maxFrames / max(hop, 1) + 3
        entryBuffer = try gpu.makeSharedBuffer(floatCount: maxHops * slots * Self.entryFloats)
        outputBuffer = try gpu.makeSharedBuffer(floatCount: self.maxFrames)
        let length = maxHops * MemoryLayout<UInt32>.stride
        guard let counts = gpu.device.makeBuffer(length: length, options: .storageModeShared) else {
            throw .allocationFailed(bytes: length)
        }
        counts.contents().bindMemory(to: UInt32.self, capacity: maxHops).initialize(repeating: 0, count: maxHops)
        countBuffer = counts
    }

    /// Region `index`'s entries (`slots * entryFloats` floats): the CPU fills them before `render`.
    public func entries(region index: Int) -> UnsafeMutablePointer<Float> {
        entryBuffer.contents().bindMemory(to: Float.self, capacity: maxHops * slots * Self.entryFloats)
            + index * slots * Self.entryFloats
    }

    /// Where the CPU writes region `index`'s active-entry count.
    public func count(region index: Int) -> UnsafeMutablePointer<UInt32> {
        countBuffer.contents().bindMemory(to: UInt32.self, capacity: maxHops) + index
    }

    /// The summed sines of the last `render`, `count` floats.
    public var output: UnsafePointer<Float> {
        UnsafePointer(outputBuffer.contents().bindMemory(to: Float.self, capacity: maxFrames))
    }

    /// Sums samples `start … + count` from `hopCount` regions that begin at hop `firstHop`.
    public func render(
        start: Int, count: Int, firstCentre: Int, hop: Int, firstHop: Int, hopCount: Int, lastHop: Int
    ) async throws(GPUError) {
        guard count > 0, count <= maxFrames, hopCount <= maxHops else { return }
        var uniforms = ResynthesisSineUniforms(
            count: UInt32(count), start: Int32(start), firstCentre: Int32(firstCentre), hop: Int32(hop),
            firstHop: Int32(firstHop), hopCount: Int32(hopCount), lastHop: Int32(lastHop), slots: UInt32(slots)
        )
        let pipeline = gpu.pipeline("resynthesisSines")
        let commandBuffer = try gpu.makeCommandBuffer()
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { throw .commandFailed }
        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(entryBuffer, offset: 0, index: 0)
        encoder.setBuffer(countBuffer, offset: 0, index: 1)
        encoder.setBuffer(outputBuffer, offset: 0, index: 2)
        encoder.setBytes(&uniforms, length: MemoryLayout<ResynthesisSineUniforms>.size, index: 3)
        encoder.dispatchThreads(
            MTLSize(width: count, height: 1, depth: 1),
            threadsPerThreadgroup: MTLSize(width: min(pipeline.maxTotalThreadsPerThreadgroup, count), height: 1, depth: 1)
        )
        encoder.endEncoding()
        try await gpu.run(commandBuffer)
    }
}
