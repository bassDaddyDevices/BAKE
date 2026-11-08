import BakeGPU
import BakeGraph
import Metal

/// Owns one render's planned buffers: one shared `MTLBuffer` per slot, in Apple Silicon unified memory.
///
/// The CPU engine works on `channel(_:of:)` pointers and the GPU engine on `metalBuffer(for:)` —
/// the same bytes, so audio is never copied between engines.
/// Layout is planar: channel `c` of a binding occupies floats `[c × frames, (c + 1) × frames)` of its slot.
/// Pointers are valid only while the pool is alive; processors never outlive the render.
final class BufferPool {
    private let buffers: [any MTLBuffer]

    init(capacities: [Int], gpu: GPUContext) throws(GPUError) {
        var buffers: [any MTLBuffer] = []
        for capacity in capacities {
            buffers.append(try gpu.makeSharedBuffer(floatCount: capacity))
        }
        self.buffers = buffers
    }

    /// CPU view: one channel of a bound signal.
    func channel(_ channel: Int, of binding: BufferBinding) -> UnsafeMutableBufferPointer<Float> {
        precondition(channel < binding.shape.channels, "Channel \(channel) out of range")
        let base = buffers[binding.slot].contents().assumingMemoryBound(to: Float.self)
        return UnsafeMutableBufferPointer(start: base + offset(ofChannel: channel, in: binding), count: binding.shape.frames)
    }

    /// GPU view: the Metal buffer behind a binding's slot.
    func metalBuffer(for binding: BufferBinding) -> any MTLBuffer {
        buffers[binding.slot]
    }

    /// Where a channel starts within its slot, in floats.
    func offset(ofChannel channel: Int, in binding: BufferBinding) -> Int {
        channel * binding.shape.frames
    }
}
