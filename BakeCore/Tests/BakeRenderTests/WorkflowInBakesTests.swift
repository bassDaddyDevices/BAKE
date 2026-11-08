import Foundation
import Testing
@testable import BakeGraph
@testable import BakeRender

/// Owner request (roadmap #27): every baked WAV carries the patch that made it.
struct WorkflowInBakesTests {
    private func render(workflow: Bool, bitDepth: String = "24", wavetable: String = "off", in directory: URL) async throws -> (URL, NodeID, ProjectFile) {
        let file = directory.appendingPathComponent("source.wav")
        try TestAudio.write(TestAudio.samples(frames: 20_000, channels: 2), to: file, sampleRate: 48_000)
        let output = directory.appendingPathComponent(workflow ? "with" : "without", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var graph = TestProject()
        let audio = graph.add(.audio, asset: sourceAsset)
        let filters = graph.add(.filters, NodeCatalog.defaultParameters(for: .filters))
        let print = graph.add(.print, ["bitDepth": .choice(bitDepth), "wavetable": .choice(wavetable)])
        graph.connect(audio, to: filters)
        graph.connect(filters, to: print)
        let urls = [sourceAsset: file]
        let request = RenderRequest(
            plan: try compile(graph.project, assetURLs: urls), assetURLs: urls, outputDirectory: output,
            chunkFrames: 777, workflow: workflow ? graph.project : nil
        )
        let url = try #require(try await RenderEngine.render(request).outputs[print])
        return (url, print, graph.project)
    }

    @Test func wavetableDeclarationDoesNotChangeBakedAudio() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (plain, _, _) = try await render(workflow: false, bitDepth: "32f", in: directory)
        let (declared, _, _) = try await render(workflow: false, bitDepth: "32f", wavetable: "2048", in: directory)
        #expect(try TestAudio.read(declared).samples == TestAudio.read(plain).samples)
        let chunks = try Data(contentsOf: declared)
        #expect(String(decoding: chunks, as: UTF8.self).contains("<!>2048 10000000 wavetable (bake)"))
        #expect(BakedWorkflow.read(fromWAV: declared) == nil)
    }

    @Test func aBakedWAVCarriesItsPatchAndStillReadsAsAudio() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (with, bake, project) = try await render(workflow: true, in: directory)
        let (without, _, _) = try await render(workflow: false, in: directory)

        let workflow = try #require(BakedWorkflow.read(fromWAV: with))
        #expect(workflow.bakeNode == bake && workflow.project == project)
        #expect(BakedWorkflow.read(fromWAV: without) == nil)
        // AVAudioFile reads it as before: the same samples, the same length.
        #expect(try TestAudio.read(with).samples == TestAudio.read(without).samples)
    }
}
