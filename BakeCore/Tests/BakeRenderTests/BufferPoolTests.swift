import BakeDSP
import Metal
import Testing
@testable import BakeGPU
@testable import BakeGraph
@testable import BakeRender

struct BufferPoolTests {
    @Test func newBuffersAreSilent() throws {
        let pool = try BufferPool(capacities: [8], gpu: GPUContext())
        let binding = BufferBinding(slot: 0, shape: SignalShape(frames: 8, channels: 1))
        #expect(pool.channel(0, of: binding).allSatisfy { $0 == 0 })
    }

    @Test func channelsArePlanarAndContiguous() throws {
        let pool = try BufferPool(capacities: [8], gpu: GPUContext())
        let binding = BufferBinding(slot: 0, shape: SignalShape(frames: 4, channels: 2))
        let left = pool.channel(0, of: binding)
        let right = pool.channel(1, of: binding)
        #expect(try #require(left.baseAddress) + 4 == right.baseAddress)

        left.update(repeating: 1)
        right.update(repeating: 2)
        #expect(Array(left) == [1, 1, 1, 1])
        #expect(Array(right) == [2, 2, 2, 2])
    }

    @Test func slotsAreSeparateMemory() throws {
        let pool = try BufferPool(capacities: [4, 4], gpu: GPUContext())
        let first = pool.channel(0, of: BufferBinding(slot: 0, shape: SignalShape(frames: 4, channels: 1)))
        let second = pool.channel(0, of: BufferBinding(slot: 1, shape: SignalShape(frames: 4, channels: 1)))
        first.update(repeating: 7)
        #expect(second.allSatisfy { $0 == 0 })
    }

    @Test func cppAndMetalWorkOnTheSameMemory() async throws {
        let gpu = try GPUContext()
        let pool = try BufferPool(capacities: [8], gpu: gpu)
        let binding = BufferBinding(slot: 0, shape: SignalShape(frames: 4, channels: 2))
        let right = pool.channel(1, of: binding)
        right.update(repeating: 1)

        // The CPU engine (C++) writes through the pool pointer…
        bake.dsp.applyGain(try #require(right.baseAddress), right.count, 3)
        // …the GPU engine (Metal) transforms the same bytes in place…
        try await gpu.scale(pool.metalBuffer(for: binding), offset: pool.offset(ofChannel: 1, in: binding), count: right.count, by: 2)
        // …and Swift reads the result. No copies anywhere.
        #expect(Array(right) == [6, 6, 6, 6])

        let metalBytes = pool.metalBuffer(for: binding).contents() + 4 * MemoryLayout<Float>.stride
        #expect(UnsafeMutableRawPointer(try #require(right.baseAddress)) == metalBytes)
    }
}
