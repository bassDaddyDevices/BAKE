import Foundation

/// The check every node makes before it allocates scratch that grows with the file or a setting (whole-file buffers, delay
/// tables, partial tables). The plan's own buffers are checked once up front (`plan.peakMemoryBytes`); this covers what a node
/// adds on top, so an extreme setting on a long file stops with `insufficientMemory` and a byte count instead of the whole
/// machine running out of memory halfway through a bake.
enum NodeMemory {
    /// The most one node may add: half of this Mac's memory.
    static var limit: Int { Int(ProcessInfo.processInfo.physicalMemory / 2) }

    static func require(bytes: Int) throws {
        guard bytes < limit else { throw RenderError.insufficientMemory(requiredBytes: bytes) }
    }
}
