import BakeDSP
import Foundation
import Testing
@testable import BakeGraph
@testable import BakeRender

/// Parallel steps must give the same bits on any number of cores (PRD NFR-2). Serialized because
/// they change the process-wide core count.
@Suite(.serialized)
struct ParallelTests {
    @Test func forEachRunsEveryIndexExactlyOnce() {
        var hits = [Int](repeating: 0, count: 1_000)
        hits.withUnsafeMutableBufferPointer { buffer in
            let pointer = buffer
            Parallel.forEach(buffer.count, workers: 8) { pointer[$0] += 1 }
        }
        #expect(hits.allSatisfy { $0 == 1 })
    }

    @Test func forEachWithOneWorkerRunsInOrder() {
        var order: [Int] = []
        Parallel.forEach(5, workers: 1) { order.append($0) }
        #expect(order == [0, 1, 2, 3, 4])
    }

    @Test func piecesCoverTheRangeWithNoGapsOrOverlap() {
        for frames in [0..<0, 0..<1, 7..<4_103, 0..<10_000, 100..<65_636] {
            for size in [1, 777, 4_096, 8_192] {
                let pieces = Parallel.pieces(of: frames, size: size)
                #expect(pieces.allSatisfy { $0.count <= size && !$0.isEmpty })
                #expect(pieces.first?.lowerBound ?? frames.lowerBound == frames.lowerBound)
                #expect(pieces.last?.upperBound ?? frames.upperBound == frames.upperBound)
                #expect(zip(pieces, pieces.dropFirst()).allSatisfy { $0.upperBound == $1.lowerBound })
            }
        }
    }

    @Test func coreCountCanBeOverriddenAndRestored() async {
        await CoreCountGate.shared.acquire()
        defer { CoreCountGate.shared.releaseSoon() }
        Parallel.overrideCoreCount(nil)
        let natural = Parallel.coreCount
        Parallel.overrideCoreCount(3)
        #expect(Parallel.coreCount == 3)
        Parallel.overrideCoreCount(nil)
        #expect(Parallel.coreCount == natural)
    }

    /// Audio → `kind` (32x oversampling where it has one) → Bake, on `workers` cores.
    private func renderChain(_ kind: NodeKind, _ samples: [[Float]], workers: Int, chunk: Int = 65_536) async throws -> [[Float]] {
        await CoreCountGate.shared.acquire()
        Parallel.overrideCoreCount(workers)
        defer {
            Parallel.overrideCoreCount(nil)
            CoreCountGate.shared.releaseSoon()
        }
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.wav")
        try TestAudio.write(samples, to: source, sampleRate: 48_000)
        let output = directory.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var graph = TestProject()
        let audio = graph.add(.audio, asset: sourceAsset)
        var parameters = NodeCatalog.defaultParameters(for: kind)
        if parameters["oversampling"] != nil { parameters["oversampling"] = .choice("32") }
        let node = graph.add(kind, parameters)
        let print = graph.add(.print, ["bitDepth": .choice("32f")])
        graph.connect(audio, to: node)
        graph.connect(node, to: print)
        let urls = [sourceAsset: source]
        let request = RenderRequest(
            plan: try compile(graph.project, assetURLs: urls), assetURLs: urls, outputDirectory: output, chunkFrames: chunk
        )
        return try TestAudio.read(try #require(try await RenderEngine.render(request).outputs[print])).samples
    }

    /// Every parallel node must give the same bits on 1, 2 and 8 cores, and in 777-frame chunks.
    @Test(arguments: [NodeKind.distortion, .waveshaper, .wavefolder, .granularCloud, .derivativeDistortion, .adaptiveClipping])
    func nodeGivesTheSameBitsOnAnyNumberOfCores(kind: NodeKind) async throws {
        let samples = TestAudio.samples(frames: 60_000, channels: 2)
        let one = try await renderChain(kind, samples, workers: 1)
        #expect(one.count == 2 && one.allSatisfy { $0.count == 60_000 && $0.allSatisfy { $0.isFinite } })
        #expect(one[0] != samples[0])
        #expect(try await renderChain(kind, samples, workers: 2) == one)
        #expect(try await renderChain(kind, samples, workers: 8) == one)
        #expect(try await renderChain(kind, samples, workers: 8, chunk: 777) == one)
    }
}
