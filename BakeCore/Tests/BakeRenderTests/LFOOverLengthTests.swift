import Foundation
import Testing
@testable import BakeGraph
@testable import BakeRender

/// LFO Sync › Over Length: Cycles whole cycles across everything the LFO feeds, whatever its length.
/// Heard through a Gain/VCA on a constant input, whose output is (LFO + 1) / 2.
struct LFOOverLengthTests {
    private func render(frames: Int, lfo: [ParameterID: ParameterValue], modulated: [ParameterID] = [],
                        modulator: [ParameterID: ParameterValue]? = nil, chunkFrames: Int = 65_536) async throws -> [Float] {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("ones.wav")
        try TestAudio.write([[Float](repeating: 1, count: frames)], to: source, sampleRate: 48_000)
        var graph = TestProject()
        let audio = graph.add(.audio, asset: sourceAsset)
        let vca = graph.add(.gainVCA)
        let node = graph.add(.lfo, lfo.merging(["sync": .choice("overLength")]) { $1 }, modulated: modulated)
        let bake = graph.add(.print, ["bitDepth": .choice("32f")])
        graph.connect(audio, to: vca)
        graph.connect(node, to: vca, "amount")
        graph.connect(vca, to: bake)
        if let modulator {
            let second = graph.add(.lfo, modulator)
            graph.connect(second, to: node, "mod.cycles")
        }
        let output = directory.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let urls = [sourceAsset: source]
        let request = RenderRequest(plan: try compile(graph.project, assetURLs: urls), assetURLs: urls,
                                    outputDirectory: output, chunkFrames: chunkFrames)
        return try TestAudio.read(try #require(try await RenderEngine.render(request).outputs[bake])).samples[0]
    }

    private func upwardCrossings(_ samples: [Float]) -> Int {
        zip(samples, samples.dropFirst()).filter { $0 < 0.5 && $1 >= 0.5 }.count
    }

    @Test(arguments: [2_048, 48_000, 480_000])
    func cyclesSpanTheWholeLengthAtAnyLength(frames: Int) async throws {
        // A sine starts at 0 (0.5 here) rising, so its upward crossings are at the start of each cycle.
        let four = try await render(frames: frames, lfo: ["shape": .choice("sine"), "cycles": .number(4), "phase": .number(90)])
        #expect(upwardCrossings(four) == 4)
        // The LFO saw rises from 0 to +1, jumps to −1 at mid-cycle and climbs back: one cycle over the
        // length jumps exactly once, at the middle frame.
        let saw = try await render(frames: frames, lfo: ["shape": .choice("saw"), "cycles": .number(1)])
        #expect(abs(saw[0] - 0.5) < 1e-6)
        let jumps = zip(saw.indices, zip(saw, saw.dropFirst())).filter { $0.1.0 - $0.1.1 > 0.5 }.map(\.0)
        #expect(jumps.count == 1)
        #expect(abs((jumps.first ?? 0) - frames / 2) <= 1)
    }

    @Test func rateIsIgnoredOverLength() async throws {
        let slow = try await render(frames: 2_048, lfo: ["rate": .number(0.01), "cycles": .number(2)])
        let fast = try await render(frames: 2_048, lfo: ["rate": .number(100), "cycles": .number(2)])
        #expect(slow == fast)
    }

    @Test func modulatedCyclesChangeTheOutputAndChunksDontMatter() async throws {
        let plain = try await render(frames: 48_000, lfo: ["cycles": .number(4)])
        let moved = try await render(frames: 48_000, lfo: ["cycles": .number(4)], modulated: ["cycles"], modulator: ["rate": .number(0.5)])
        #expect(plain != moved)
        let chunked = try await render(frames: 48_000, lfo: ["cycles": .number(4)], modulated: ["cycles"], modulator: ["rate": .number(0.5)], chunkFrames: 777)
        #expect(chunked == moved)
    }

    @Test func overLengthIsAnAddedOptionSoSavedSyncValuesKeepTheirIndex() throws {
        let sync = try #require(NodeCatalog.definition(for: .lfo).parameter("sync"))
        #expect(sync.kind == .choice(options: ["free", "clock", "overLength"], defaultValue: "free"))
        let cycles = try #require(NodeCatalog.definition(for: .lfo).parameter("cycles"))
        #expect(cycles.isModulatable && cycles.shownWhen == ParameterCondition("sync", in: ["overLength"]))
    }
}
