import Foundation
import os

/// Runs independent pieces of one step's work across the CPU cores.
///
/// BAKE renders offline, so nothing limits a node to one thread. The rule that keeps renders
/// deterministic (PRD NFR-2): only split work whose pieces **write disjoint output and read shared,
/// finished input**, so every piece gives the same bits whatever the thread count or order.
/// Stateless kernels (chunk-invariant ones) split by frame range; stateful ones split by channel.
enum Parallel {
    /// Pieces shorter than this aren't worth a thread; it also bounds scratch memory per piece.
    static let minimumPieceFrames = 4_096

    private static let overridden = OSAllocatedUnfairLock<Int?>(initialState: nil)

    /// Threads a step may use: every core, unless a test (or `overrideCoreCount`) says otherwise.
    static var coreCount: Int {
        overridden.withLock { $0 } ?? max(ProcessInfo.processInfo.activeProcessorCount, 1)
    }

    /// Forces `coreCount` (pass nil to restore). For tests that prove results don't depend on it.
    static func overrideCoreCount(_ count: Int?) {
        overridden.withLock { $0 = count.map { max($0, 1) } }
    }

    /// Calls `body(0) … body(count − 1)` and returns when all have finished. Runs on several threads
    /// unless `workers` is 1 (or there is only one piece), in which case it runs in order on this one.
    static func forEach(_ count: Int, workers: Int = coreCount, _ body: (Int) -> Void) {
        guard count > 0 else { return }
        if count == 1 || workers <= 1 {
            for index in 0..<count { body(index) }
            return
        }
        withoutActuallyEscaping(body) { escapable in
            let job = Job(escapable)
            DispatchQueue.concurrentPerform(iterations: count) { job.body($0) }
        }
    }

    /// `frames` cut into consecutive ranges of at most `size` frames (the last may be shorter).
    static func pieces(of frames: Range<Int>, size: Int) -> [Range<Int>] {
        guard !frames.isEmpty, size > 0 else { return [] }
        return stride(from: frames.lowerBound, to: frames.upperBound, by: size).map {
            $0..<min($0 + size, frames.upperBound)
        }
    }

    /// Holds the body for `concurrentPerform`. Safe because `forEach` waits for every iteration
    /// before returning, and the pieces it runs write disjoint memory (see the rule above).
    private final class Job: @unchecked Sendable {
        let body: (Int) -> Void
        init(_ body: @escaping (Int) -> Void) { self.body = body }
    }
}

/// A step's parallel layout: frames cut into pieces per channel, each with its own scratch, allocated once.
/// For stateless kernels (a piece's output depends only on the input and the frame range).
final class PiecePlan {
    let workers: Int
    let pieceFrames: Int
    let pieceCount: Int
    private let scratch: [UnsafeMutablePointer<Float>]

    init(channels: Int, maxChunkFrames: Int, workers: Int = Parallel.coreCount, scratchFloats: (Int) -> Int = { _ in 1 }) {
        let cores = max(workers, 1)
        let piece = max(Parallel.minimumPieceFrames, (maxChunkFrames + cores - 1) / cores)
        let pieces = max((maxChunkFrames + piece - 1) / piece, 1)
        let floats = max(scratchFloats(piece), 1)
        self.workers = cores
        pieceFrames = piece
        pieceCount = pieces
        scratch = (0..<(max(channels, 1) * pieces)).map { _ in
            let buffer = UnsafeMutablePointer<Float>.allocate(capacity: floats)
            buffer.initialize(repeating: 0, count: floats)
            return buffer
        }
    }

    deinit {
        for buffer in scratch { buffer.deallocate() }
    }

    /// Runs `body(channel, piece, scratch)` for every channel × piece of `frames`, across the cores.
    func run(channels: Int, frames: Range<Int>, _ body: (Int, Range<Int>, UnsafeMutablePointer<Float>) -> Void) {
        let pieces = Parallel.pieces(of: frames, size: pieceFrames)
        precondition(pieces.count <= pieceCount, "a chunk is never longer than maxChunkFrames")
        let used = pieces.count
        guard used > 0 else { return }
        Parallel.forEach(channels * used, workers: workers) { task in
            let channel = task / used
            let slot = task % used
            body(channel, pieces[slot], scratch[channel * pieceCount + slot])
        }
    }
}

/// Per-channel state for stateful kernels: each channel owns its loop state, oversampler history and
/// scratch, so channels run on separate threads without sharing anything. Chunks still arrive in order.
final class ChannelStates<State> {
    let states: UnsafeMutablePointer<State>
    let histories: [UnsafeMutablePointer<Float>]
    let scratch: [UnsafeMutablePointer<Float>]
    private let count: Int

    init(channels: Int, initial: State, historyFloats: Int, scratchFloats: Int) {
        count = max(channels, 1)
        states = UnsafeMutablePointer<State>.allocate(capacity: count)
        states.initialize(repeating: initial, count: count)
        func make(_ floats: Int, _ count: Int) -> [UnsafeMutablePointer<Float>] {
            (0..<count).map { _ in
                let buffer = UnsafeMutablePointer<Float>.allocate(capacity: max(floats, 1))
                buffer.initialize(repeating: 0, count: max(floats, 1))
                return buffer
            }
        }
        histories = make(historyFloats, count)
        scratch = make(scratchFloats, count)
    }

    deinit {
        states.deinitialize(count: count)
        states.deallocate()
        for buffer in histories { buffer.deallocate() }
        for buffer in scratch { buffer.deallocate() }
    }
}
