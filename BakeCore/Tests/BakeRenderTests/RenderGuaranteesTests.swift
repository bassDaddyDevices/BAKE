import Foundation
import Synchronization
import Testing
@testable import BakeGraph
@testable import BakeRender

struct RenderGuaranteesTests {
    /// Audio → Print over a stereo source at `sourceRate`, writing into `directory/out`.
    private func request(
        frames: Int, sourceRate: Double, chunkFrames: Int, in directory: URL
    ) throws -> (request: RenderRequest, printNode: NodeID) {
        let source = directory.appendingPathComponent("source.wav")
        try TestAudio.write(TestAudio.samples(frames: frames, channels: 2), to: source, sampleRate: sourceRate)
        let output = directory.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        var graph = TestProject()
        let audio = graph.add(.audio, asset: sourceAsset)
        let print = graph.add(.print)
        graph.connect(audio, to: print)
        let urls = [sourceAsset: source]
        let plan = try compile(graph.project, assetURLs: urls)
        return (RenderRequest(plan: plan, assetURLs: urls, outputDirectory: output, chunkFrames: chunkFrames), print)
    }

    @Test func renderingTwiceIsByteIdentical() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        // 44.1 kHz source, so resampling is part of what must be deterministic.
        var (first, printNode) = try request(frames: 44_100, sourceRate: 44_100, chunkFrames: 4_096, in: directory)
        var second = first
        first.outputDirectory = directory.appendingPathComponent("a", isDirectory: true)
        second.outputDirectory = directory.appendingPathComponent("b", isDirectory: true)
        for folder in [first.outputDirectory, second.outputDirectory] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }

        let a = try #require(try await RenderEngine.render(first).outputs[printNode])
        let b = try #require(try await RenderEngine.render(second).outputs[printNode])

        #expect(try Data(contentsOf: a) == Data(contentsOf: b))
    }

    @Test func cancellingLeavesNoFilesBehind() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (request, _) = try request(frames: 48_000, sourceRate: 48_000, chunkFrames: 1_000, in: directory)

        await #expect(throws: CancellationError.self) {
            try await Task {
                try await RenderEngine.render(request) { progress in
                    // Cancel during the Print step, after its temporary file exists.
                    if progress.stepIndex == progress.stepCount - 1 {
                        withUnsafeCurrentTask { $0?.cancel() }
                    }
                }
            }.value
        }

        let leftovers = try FileManager.default.contentsOfDirectory(atPath: request.outputDirectory.path)
        #expect(leftovers.isEmpty, "left behind: \(leftovers)")
    }

    @Test func progressRisesSteadilyToOne() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (request, _) = try request(frames: 48_000, sourceRate: 48_000, chunkFrames: 4_096, in: directory)
        let reports = Mutex<[RenderProgress]>([])

        _ = try await RenderEngine.render(request) { progress in
            reports.withLock { $0.append(progress) }
        }

        let fractions = reports.withLock { $0.map(\.fraction) }
        #expect(!fractions.isEmpty)
        #expect(zip(fractions, fractions.dropFirst()).allSatisfy { $0 < $1 })
        #expect(fractions.last == 1)
        #expect(reports.withLock { $0.allSatisfy { $0.stepCount == 2 && (0..<2).contains($0.stepIndex) } })
    }
}
