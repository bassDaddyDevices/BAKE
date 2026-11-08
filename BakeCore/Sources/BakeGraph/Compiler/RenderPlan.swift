/// Where a pin's signal lives during a render.
public struct BufferBinding: Hashable, Sendable {
    /// Index into `RenderPlan.bufferCapacities`.
    public let slot: Int
    public let shape: SignalShape
}

/// One node's work in a render.
public struct RenderStep: Hashable, Sendable {
    public let node: NodeID
    public let kind: NodeKind
    /// Every parameter, defaults filled in and clamped.
    public let parameters: [ParameterID: ParameterValue]
    /// Page 2 trim for each modulated parameter (−1…+1, default +1).
    public let modulationTrims: [ParameterID: Double]
    public let assetID: AssetID?
    /// Frames and channels this node renders.
    public let shape: SignalShape
    public let inputs: [PinID: BufferBinding]
    public let outputs: [PinID: BufferBinding]
}

/// A feedback loop's steps (contiguous in `RenderPlan.steps`), which the engine renders together:
/// every step for one block, then every step for the next. A block is at most the loop's delay, so
/// the Feedback step only ever reads returned audio that's already written.
public struct RenderLoop: Hashable, Sendable {
    public let steps: Range<Int>
    public let blockFrames: Int
}

/// An immutable, ordered render recipe. Safe to hand to a background task.
public struct RenderPlan: Hashable, Sendable {
    public let sampleRate: Double
    public let steps: [RenderStep]
    /// Size of each pooled buffer, in Float samples (frames × channels).
    public let bufferCapacities: [Int]
    /// Feedback loops; empty for a patch without one.
    public internal(set) var loops: [RenderLoop] = []

    /// Memory the pooled buffers need at once, for warnings before a bake.
    public var peakMemoryBytes: Int {
        bufferCapacities.reduce(0, +) * MemoryLayout<Float>.size
    }
}
