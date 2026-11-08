import BakeDSP
import Foundation
import Testing
@testable import BakeGraph
@testable import BakeRender

/// What each node produced in a bake (waveform envelope and spectrogram), gathered from the
/// render's own buffers.
struct NodeSummaryTests {
    private func run(
        in directory: URL, frames: Int = 3_200, channels: Int = 2, chunk: Int = 65_536, collect: Bool = true,
        source: [[Float]]? = nil, build: (inout TestProject, NodeID) -> PinRef
    ) async throws -> (summaries: [PinRef: NodeSummary], graph: TestProject, audio: NodeID, last: NodeID) {
        let file = directory.appendingPathComponent("source.wav")
        try TestAudio.write(source ?? TestAudio.samples(frames: frames, channels: channels), to: file, sampleRate: 48_000)
        let output = directory.appendingPathComponent("out-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var graph = TestProject()
        let audio = graph.add(.audio, asset: sourceAsset)
        let tap = build(&graph, audio)
        let last = tap.node
        let print = graph.add(.print, ["bitDepth": .choice("32f")])
        graph.project.edges.append(Edge(from: tap, to: PinRef(node: print, pin: "in")))
        let urls = [sourceAsset: file]
        let request = RenderRequest(
            plan: try compile(graph.project, assetURLs: urls), assetURLs: urls, outputDirectory: output,
            chunkFrames: chunk, collectSummaries: collect
        )
        return (try await RenderEngine.render(request).summaries, graph, audio, last)
    }

    private func reversed(in directory: URL, chunk: Int = 65_536, collect: Bool = true) async throws -> (summaries: [PinRef: NodeSummary], graph: TestProject, audio: NodeID, last: NodeID) {
        try await run(in: directory, chunk: chunk, collect: collect) { graph, audio in
            let reverse = graph.add(.reverse)
            graph.connect(audio, to: reverse)
            return PinRef(node: reverse, pin: "out")
        }
    }

    @Test func summariesAreOnlyGatheredWhenAsked() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(try await reversed(in: directory, collect: false).summaries.isEmpty)
        #expect(try await reversed(in: directory, collect: true).summaries.count == 2)   // Audio and Reverse; Bake has no output
    }

    @Test func eachNodeSummarisesWhatItProduced() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let result = try await reversed(in: directory)

        let audio = try #require(result.summaries[PinRef(node: result.audio, pin: "out")])
        #expect(audio.frames == 3_200 && audio.channels == 2 && audio.sampleRate == 48_000 && !audio.isControl)
        #expect(audio.minimums.count == 160 && audio.maximums.count == 160 && audio.rms.count == 160)
        #expect(audio.spectrogram?.columns == 160 && audio.spectrogram?.rows == 48)
        let source = TestAudio.samples(frames: 3_200, channels: 2)
        let expectedPeak = source.flatMap { $0 }.map { abs($0) }.max() ?? 0
        #expect(abs(audio.peak - expectedPeak) < 1e-6)
    }

    @Test func aReversedNodeSummaryIsTheOriginalsBackwards() async throws {
        // 3200 frames is exactly 160 slices of 20, so slices line up with the reversal.
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let result = try await reversed(in: directory)

        let audio = try #require(result.summaries[PinRef(node: result.audio, pin: "out")])
        let reverse = try #require(result.summaries[PinRef(node: result.last, pin: "out")])
        // Reverse mixes as dry + (wet − dry) · 1, which can differ from the sample by a rounding error.
        #expect(zip(reverse.maximums, audio.maximums.reversed()).allSatisfy { abs($0 - $1) < 2e-6 })
        #expect(zip(reverse.minimums, audio.minimums.reversed()).allSatisfy { abs($0 - $1) < 2e-6 })
        #expect(abs(reverse.peak - audio.peak) < 2e-6)
    }

    @Test func summariesDontDependOnChunkSize() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let whole = try await reversed(in: directory, chunk: 65_536)
        let chunked = try await reversed(in: directory, chunk: 777)
        #expect(whole.summaries == chunked.summaries)
    }

    @Test func aToneLightsItsOwnBandInTheSpectrogram() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let tone = [sine(frequency: 1_000, frames: 48_000, amplitude: 0.5)]
        let result = try await run(in: directory, source: tone) { graph, audio in
            let gain = graph.add(.gainVCA)
            graph.connect(audio, to: gain)
            return PinRef(node: gain, pin: "out")
        }

        let summary = try #require(result.summaries[PinRef(node: result.last, pin: "out")])
        let spectrogram = try #require(summary.spectrogram)
        #expect(summary.channels == 1)
        // Row of 1 kHz on the 30 Hz – 20 kHz log axis (48 rows).
        let expectedRow = Int(floor(48 * log(1_000.0 / 30.0) / log(20_000.0 / 30.0)))
        let middle = (0..<spectrogram.rows).map { Int(spectrogram.values[$0 * spectrogram.columns + spectrogram.columns / 2]) }
        #expect(middle.firstIndex(of: middle.max() ?? 0) == expectedRow)
        // −6 dBFS reads about (−6.02 + 90) / 90 × 255 ≈ 238.
        #expect(abs(middle[expectedRow] - 238) <= 6)
    }

    /// Owner report: Clock and Envelope cards showed nothing useful. A control summary now carries
    /// the first seconds in detail, so single bangs show; audio summaries don't carry it.
    @Test func aControlSummaryKeepsItsFirstSecondsInDetail() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("source.wav")
        try TestAudio.write([sine(frequency: 440, frames: 48_000 * 6)], to: file, sampleRate: 48_000)
        let output = directory.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var graph = TestProject()
        let audio = graph.add(.audio, asset: sourceAsset)
        let clock = graph.add(.clock, ["bpm": .number(120), "division": .choice("1/4"), "gateLength": .number(1)])
        let filters = graph.add(.filters)
        let print = graph.add(.print, ["bitDepth": .choice("32f")])
        let filterIndex = try #require(graph.project.nodes.firstIndex { $0.id == filters })
        graph.project.nodes[filterIndex].setModulated("cutoff", true)
        graph.connect(audio, to: filters)
        graph.connect(clock, to: filters, "mod.cutoff")
        graph.connect(filters, to: print)
        let urls = [sourceAsset: file]
        let request = RenderRequest(plan: try compile(graph.project, assetURLs: urls), assetURLs: urls, outputDirectory: output, collectSummaries: true)

        let summaries = try await RenderEngine.render(request).summaries

        // 1 % gates (240 frames) every 0.5 s: each starts every 125 points (4 ms each) and spans two.
        let detail = try #require(summaries[PinRef(node: clock, pin: "out")]).detail
        #expect(detail.count == 1_000)
        let rises = detail.indices.filter { detail[$0] > 0.5 && ($0 == 0 || detail[$0 - 1] <= 0.5) }
        #expect(rises == [0, 125, 250, 375, 500, 625, 750, 875])
        #expect(detail.filter { $0 > 0.5 }.count == 16)
        #expect(try #require(summaries[PinRef(node: filters, pin: "out")]).detail.isEmpty)
    }

    @Test func aControlSignalHasNoSpectrogramAndSwingsBothWays() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("source.wav")
        try TestAudio.write([sine(frequency: 440, frames: 48_000)], to: file, sampleRate: 48_000)
        let output = directory.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var graph = TestProject()
        let audio = graph.add(.audio, asset: sourceAsset)
        let lfo = graph.add(.lfo, ["rate": .number(2)])
        let filters = graph.add(.filters, ["cutoff": .number(900)])
        let print = graph.add(.print, ["bitDepth": .choice("32f")])
        let filterIndex = try #require(graph.project.nodes.firstIndex { $0.id == filters })
        graph.project.nodes[filterIndex].setModulated("cutoff", true)
        graph.connect(audio, to: filters)
        graph.connect(lfo, to: filters, "mod.cutoff")
        graph.connect(filters, to: print)
        let urls = [sourceAsset: file]
        let request = RenderRequest(plan: try compile(graph.project, assetURLs: urls), assetURLs: urls, outputDirectory: output, collectSummaries: true)

        let summaries = try await RenderEngine.render(request).summaries

        let control = try #require(summaries[PinRef(node: lfo, pin: "out")])
        #expect(control.isControl && control.channels == 1 && control.frames == 48_000)
        #expect(control.spectrogram == nil)
        #expect((control.maximums.max() ?? 0) > 0.9 && (control.minimums.min() ?? 0) < -0.9)
        #expect(try #require(summaries[PinRef(node: filters, pin: "out")]).spectrogram != nil)
    }

    @Test func aMultiOutputNodeIsSummarisedPerOutputPin() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let result = try await run(in: directory) { graph, audio in
            let splitter = graph.add(.channelSplitter)
            graph.connect(audio, to: splitter)
            return PinRef(node: splitter, pin: "out1")
        }
        // Only the outputs a plan uses have buffers; out1 is the one the Bake node reads.
        let first = try #require(result.summaries[PinRef(node: result.last, pin: "out1")])
        #expect(first.channels == 1 && first.frames == 3_200)
    }
}
