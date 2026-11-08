import Foundation
import Testing
@testable import BakeGraph
@testable import BakeRender

/// PRD requirements the M6 audit found without a direct test (see wiki/guides/requirements-coverage).
struct RequirementsTests {
    private func bake(_ graph: TestProject, _ bake: NodeID, source: URL, chunk: Int = 65_536) async throws -> TestAudio.Decoded {
        let output = source.deletingLastPathComponent().appendingPathComponent("out-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let urls = [sourceAsset: source]
        let request = RenderRequest(plan: try compile(graph.project, assetURLs: urls), assetURLs: urls, outputDirectory: output, chunkFrames: chunk)
        return try TestAudio.read(try #require(try await RenderEngine.render(request).outputs[bake]))
    }

    /// FR-1: WAV, AIFF and CAF, mono or stereo, at common rates, import into an Audio node and bake at
    /// the project's rate.
    @Test(arguments: [("aiff", 44_100.0, 1), ("caf", 96_000.0, 2), ("wav", 22_050.0, 2), ("aif", 88_200.0, 1)])
    func everySupportedFileTypeImportsAndBakes(fileExtension: String, sampleRate: Double, channels: Int) async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.\(fileExtension)")
        let frames = Int(sampleRate / 10)
        try TestAudio.write(TestAudio.samples(frames: frames, channels: channels), to: source, sampleRate: sampleRate, bitDepth: 24, isFloat: false)
        #expect(try AssetInfoReader.info(for: source) == AssetInfo(frameCount: frames, channelCount: channels, sampleRate: sampleRate))

        var graph = TestProject()
        let audio = graph.add(.audio, asset: sourceAsset)
        let print = graph.add(.print, ["bitDepth": .choice("32f")])
        graph.connect(audio, to: print)
        let rendered = try await bake(graph, print, source: source)
        #expect(rendered.samples.count == channels)
        #expect(rendered.samples[0].count == Int((Double(frames) * graph.project.settings.sampleRate / sampleRate).rounded()))
        #expect(rendered.samples[0].contains { $0 != 0 })
    }

    /// FR-4: an LFO moves Stretch's pitch, Filters' cutoff and Distortion's drive, the same at any
    /// chunk size.
    @Test(arguments: [(NodeKind.stretch, "pitchSemitones"), (.filters, "cutoff"), (.distortion, "drive")])
    func anLFOModulatesEachV1Effect(kind: NodeKind, parameter: ParameterID) async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.wav")
        try TestAudio.write(TestAudio.samples(frames: 24_000, channels: 2), to: source, sampleRate: 48_000)

        func patch(modulated: Bool) -> (TestProject, NodeID) {
            var graph = TestProject()
            let audio = graph.add(.audio, asset: sourceAsset)
            let effect = graph.add(kind, [:], modulated: modulated ? [parameter] : [])
            let print = graph.add(.print, ["bitDepth": .choice("32f")])
            graph.connect(audio, to: effect)
            graph.connect(effect, to: print)
            if modulated {
                let lfo = graph.add(.lfo, ["rate": .number(4), "shape": .choice("triangle")])
                graph.connect(lfo, to: effect, NodeCatalog.modulationPinID(for: parameter))
            }
            return (graph, print)
        }
        let (plain, plainBake) = patch(modulated: false)
        let (moved, movedBake) = patch(modulated: true)
        let still = try await bake(plain, plainBake, source: source)
        let swept = try await bake(moved, movedBake, source: source)
        #expect(swept.samples != still.samples)
        #expect(try await bake(moved, movedBake, source: source, chunk: 777).samples == swept.samples)
    }
}
