import Foundation

/// A finished file waiting to be moved into place once the whole render succeeds.
struct PendingOutput {
    let temporaryURL: URL
    let finalURL: URL
}

/// Renders one plan step on either engine. The render engine calls `process` with consecutive
/// chunks covering the step's frames, then `finish`; or `discard` if the render stops early.
/// `process` is async so GPU steps can await their command buffers without blocking a thread.
protocol StepProcessor: AnyObject {
    func process(frames: Range<Int>) async throws
    func finish() throws -> PendingOutput?
    /// Removes anything partially written. Must not throw.
    func discard()
}
