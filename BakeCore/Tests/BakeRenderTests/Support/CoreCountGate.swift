@testable import BakeRender

/// `Parallel.overrideCoreCount` is process-wide, and Swift Testing runs suites at the same time, so two tests
/// that override it (or one that asserts what it reads back) can trample each other. Every test that touches
/// the override takes this first: `await CoreCountGate.shared.acquire()` … `defer { CoreCountGate.shared.releaseSoon() }`.
actor CoreCountGate {
    static let shared = CoreCountGate()

    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if !busy {
            busy = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty {
            busy = false
        } else {
            waiters.removeFirst().resume()
        }
    }

    /// For `defer`, which can't await. Whoever acquires next waits until this has run.
    nonisolated func releaseSoon() {
        Task { await release() }
    }
}
