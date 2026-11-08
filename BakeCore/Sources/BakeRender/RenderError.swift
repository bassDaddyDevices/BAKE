import BakeGraph
import Foundation

/// Why a render couldn't start or finish. Cancellation surfaces as `CancellationError` instead.
public enum RenderError: Error, Equatable, Sendable {
    /// The file is missing, unreadable, or not audio.
    case unreadableAsset(URL)
    /// The plan uses an asset the request has no URL for.
    case missingAssetURL(AssetID)
    /// This node kind has no renderer yet.
    case unsupportedNode(NodeKind)
    /// The step has modulation inputs, which arrive with the DSP kernels in M3.
    case unsupportedModulation(NodeID)
    /// The Metal GPU engine couldn't start (no device, or shaders missing from the build).
    case gpuUnavailable
    /// The plan's buffers wouldn't fit in this Mac's memory.
    case insufficientMemory(requiredBytes: Int)
    case writeFailed(URL)
}
