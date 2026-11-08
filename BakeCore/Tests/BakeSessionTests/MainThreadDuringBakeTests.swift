import BakeGraph
import Foundation
import Testing
@testable import BakeSession

/// NFR-1: the canvas stays interactive during a bake, no main-thread stall over one frame. Bakes a
/// minute of stereo through the session (as the Bake button does) while the main actor ticks every
/// 4 ms, and measures how late the latest tick arrives. Other main-actor tests would add their own
/// stalls, so it runs alone: `BAKE_LONG_TESTS=1 swift test --filter MainThreadDuringBakeTests`.
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["BAKE_LONG_TESTS"] != nil))
struct MainThreadDuringBakeTests {
    private let access = PlainFileAccess()
    /// One frame at 60 Hz.
    private static let frame: Duration = .microseconds(16_667)

    @Test func aBakeNeverHoldsTheMainThreadForAFrame() async throws {
        let folder = try makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appending(path: "source.wav")
        try writeSine(to: source, seconds: 60)
        let output = folder.appending(path: "out", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        var project = ProjectFile()
        let audio = project.addNode(.audio, at: CanvasPoint())
        let stretch = project.addNode(.stretch, at: CanvasPoint())
        let lfo = project.addNode(.lfo, at: CanvasPoint())
        let filters = project.addNode(.filters, at: CanvasPoint())
        let distortion = project.addNode(.distortion, at: CanvasPoint())
        let bake = project.addNode(.print, at: CanvasPoint())
        project.assignAudio(path: source.path(percentEncoded: false), bookmark: try access.bookmark(for: source, writable: false), to: audio)
        project.setModulated("cutoff", of: filters, true)
        try project.connect(from: PinRef(node: audio, pin: "out"), to: PinRef(node: stretch, pin: "in"))
        try project.connect(from: PinRef(node: stretch, pin: "out"), to: PinRef(node: filters, pin: "in"))
        try project.connect(from: PinRef(node: lfo, pin: "out"), to: PinRef(node: filters, pin: "mod.cutoff"))
        try project.connect(from: PinRef(node: filters, pin: "out"), to: PinRef(node: distortion, pin: "in"))
        try project.connect(from: PinRef(node: distortion, pin: "out"), to: PinRef(node: bake, pin: "in"))
        project.settings.printFolder = FileReference(
            lastKnownPath: output.path(percentEncoded: false), bookmark: try access.bookmark(for: output, writable: true)
        )

        let session = BakeSession(access: access)
        let clock = ContinuousClock()
        let tick: Duration = .milliseconds(4)
        var worst: Duration = .zero
        var ticks = 0
        session.bake(project)
        while session.isBaking {
            let start = clock.now
            try await Task.sleep(for: tick)
            worst = max(worst, clock.now - start - tick)
            ticks += 1
        }
        await session.waitUntilFinished()
        guard case .finished = session.state else {
            Issue.record("expected a finished bake, got \(session.state)")
            return
        }
        print("NFR-1: \(ticks) ticks during the bake, worst \(worst.formatted(.units(allowed: [.milliseconds], fractionalPart: .show(length: 1)))) late")
        #expect(ticks > 100)
        #expect(worst < Self.frame)
    }
}
