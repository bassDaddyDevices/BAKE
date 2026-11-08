import Foundation
import Testing
@testable import BakeGraph
@testable import BakeRender

struct RenderEngineTests {
    /// Writes `samples` as the source, builds Audio → Print, and returns a ready render request.
    private func audioToPrint(
        _ samples: [[Float]],
        sourceRate: Double = 48_000,
        audio: [ParameterID: ParameterValue] = [:],
        print: [ParameterID: ParameterValue] = ["bitDepth": .choice("32f")],
        in directory: URL
    ) throws -> (request: RenderRequest, printNode: NodeID) {
        let source = directory.appendingPathComponent("source.wav")
        try TestAudio.write(samples, to: source, sampleRate: sourceRate)
        let output = directory.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        var graph = TestProject()
        let audioNode = graph.add(.audio, audio, asset: sourceAsset)
        let printNode = graph.add(.print, print)
        graph.connect(audioNode, to: printNode)
        let urls = [sourceAsset: source]
        let plan = try compile(graph.project, assetURLs: urls)
        return (RenderRequest(plan: plan, assetURLs: urls, outputDirectory: output, chunkFrames: 4_096), printNode)
    }

    private func files(in directory: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
    }

    @Test(arguments: [1, 2])
    func passThroughIsBitExact(channels: Int) async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        // Mono matters: AVAudioFile returns partial reads for some files, which once truncated sources.
        let input = TestAudio.samples(frames: 48_000, channels: channels)
        let (request, printNode) = try audioToPrint(input, in: directory)

        let result = try await RenderEngine.render(request)

        let written = try #require(result.outputs[printNode])
        #expect(written.lastPathComponent == "bake.wav")
        let decoded = try TestAudio.read(written)
        #expect(decoded.sampleRate == 48_000)
        #expect(decoded.samples == input)
    }

    @Test(arguments: [("16", 16, false), ("24", 24, false), ("32f", 32, true)])
    func writesTheRequestedBitDepth(choice: String, bits: Int, isFloat: Bool) async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (request, printNode) = try audioToPrint(
            TestAudio.samples(frames: 1_000, channels: 1), print: ["bitDepth": .choice(choice)], in: directory
        )

        let written = try #require(try await RenderEngine.render(request).outputs[printNode])

        let decoded = try TestAudio.read(written)
        #expect(decoded.bitDepth == bits)
        #expect(decoded.isFloat == isFloat)
    }

    @Test func sourcesAreResampledToThePlannedLength() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = TestAudio.samples(frames: 44_100, channels: 1)
        let (request, printNode) = try audioToPrint(input, sourceRate: 44_100, in: directory)

        let written = try #require(try await RenderEngine.render(request).outputs[printNode])

        let decoded = try TestAudio.read(written)
        #expect(decoded.sampleRate == 48_000)
        #expect(decoded.samples[0].count == 48_000)
        #expect(abs(TestAudio.rms(decoded.samples[0]) - TestAudio.rms(input[0])) < 0.01)
    }

    @Test func cropLoopAndGainShapeTheSource() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let ramp = [(0..<1_000).map { Float($0) / 1_000 }]
        let (request, printNode) = try audioToPrint(
            ramp,
            audio: ["cropStart": .number(0.25), "cropEnd": .number(0.75), "loopCount": .number(2), "gain": .number(20 * log10(0.5))],
            in: directory
        )

        let written = try #require(try await RenderEngine.render(request).outputs[printNode])

        let once = (250..<750).map { Float($0) / 1_000 * 0.5 }
        let expected = once + once
        let decoded = try TestAudio.read(written)
        #expect(decoded.samples[0].count == expected.count)
        #expect(zip(decoded.samples[0], expected).allSatisfy { abs($0 - $1) < 1e-6 })
    }

    /// Two Bake nodes into one folder: the first keeps the plain name, the next takes `-2`.
    @Test func multiplePrintsNeverShareAName() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.wav")
        try TestAudio.write(TestAudio.samples(frames: 1_000, channels: 1), to: source, sampleRate: 48_000)
        let output = directory.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        var graph = TestProject()
        let audio = graph.add(.audio, asset: sourceAsset)
        let first = graph.add(.print)
        let second = graph.add(.print)
        graph.connect(audio, to: first)
        graph.connect(audio, to: second)
        let urls = [sourceAsset: source]
        let request = RenderRequest(plan: try compile(graph.project, assetURLs: urls), assetURLs: urls, outputDirectory: output)

        let result = try await RenderEngine.render(request)

        #expect(Set(result.outputs.values.map(\.lastPathComponent)) == ["bake.wav", "bake-2.wav"])
        #expect(try files(in: output) == ["bake-2.wav", "bake.wav"])
    }

    @Test func previewsReplaceTheirFile() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.wav")
        try TestAudio.write(TestAudio.samples(frames: 1_000, channels: 1), to: source, sampleRate: 48_000)
        let output = directory.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var graph = TestProject()
        let audio = graph.add(.audio, asset: sourceAsset)
        let preview = graph.add(.preview)
        graph.connect(audio, to: preview)
        let urls = [sourceAsset: source]
        let request = RenderRequest(plan: try compile(graph.project, assetURLs: urls), assetURLs: urls, outputDirectory: output)

        _ = try await RenderEngine.render(request)
        let second = try await RenderEngine.render(request)

        #expect(second.outputs[preview]?.lastPathComponent == "preview-\(preview.rawValue.uuidString).wav")
        #expect(try files(in: output).count == 1)
    }

    @Test func bakingAgainSavesANewVersion() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (request, print) = try audioToPrint(TestAudio.samples(frames: 1_000, channels: 1), in: directory)

        let first = try await RenderEngine.render(request)
        let second = try await RenderEngine.render(request)

        #expect(first.outputs[print]?.lastPathComponent == "bake.wav")
        #expect(second.outputs[print]?.lastPathComponent == "bake-2.wav")
        #expect(try files(in: request.outputDirectory) == ["bake-2.wav", "bake.wav"])
    }

    @Test func overwriteReplacesTheFile() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.wav")
        try TestAudio.write(TestAudio.samples(frames: 1_000, channels: 1), to: source, sampleRate: 48_000)
        let output = directory.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var graph = TestProject()
        let audio = graph.add(.audio, asset: sourceAsset)
        let print = graph.add(.print, ["prefix": .text("loop"), "versions": .choice("overwrite")])
        graph.connect(audio, to: print)
        let urls = [sourceAsset: source]
        let request = RenderRequest(plan: try compile(graph.project, assetURLs: urls), assetURLs: urls, outputDirectory: output)

        _ = try await RenderEngine.render(request)
        _ = try await RenderEngine.render(request)

        #expect(try files(in: output) == ["loop.wav"])
    }

    @Test func printsCanWriteToTheirOwnFolders() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.wav")
        try TestAudio.write(TestAudio.samples(frames: 1_000, channels: 1), to: source, sampleRate: 48_000)
        let shared = directory.appendingPathComponent("shared", isDirectory: true)
        let own = directory.appendingPathComponent("own", isDirectory: true)
        for folder in [shared, own] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        var graph = TestProject()
        let audio = graph.add(.audio, asset: sourceAsset)
        let first = graph.add(.print)
        let second = graph.add(.print)
        graph.connect(audio, to: first)
        graph.connect(audio, to: second)
        let urls = [sourceAsset: source]
        let request = RenderRequest(
            plan: try compile(graph.project, assetURLs: urls), assetURLs: urls,
            outputDirectory: shared, outputDirectories: [second: own]
        )

        _ = try await RenderEngine.render(request)

        #expect(try files(in: shared) == ["bake.wav"])
        #expect(try files(in: own) == ["bake.wav"])
    }

    @Test func missingAssetURLsFailBeforeWritingAnything() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var (request, _) = try audioToPrint(TestAudio.samples(frames: 1_000, channels: 1), in: directory)
        request.assetURLs = [:]

        await #expect(throws: RenderError.missingAssetURL(sourceAsset)) {
            try await RenderEngine.render(request)
        }
        #expect(try files(in: request.outputDirectory).isEmpty)
    }
}
