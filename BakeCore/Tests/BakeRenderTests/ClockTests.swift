import BakeDSP
import Foundation
import Testing
@testable import BakeGraph
@testable import BakeRender

struct ClockTests {
    /// Renders a Clock kernel in the given chunk size (one call by default).
    private func render(division: Double, gate: Double = 0.1, frames: Int, chunk: Int? = nil) -> [Float] {
        var output = [Float](repeating: -1, count: frames)
        output.withUnsafeMutableBufferPointer { buffer in
            var start = 0
            while start < frames {
                let count = min(chunk ?? frames, frames - start)
                bake.dsp.renderClock(division, gate, buffer.baseAddress! + start, start, count)
                start += count
            }
        }
        return output
    }

    /// Frames where the signal rises above 0.5 (a bang starts).
    private func onsets(_ signal: [Float]) -> [Int] {
        signal.indices.filter { signal[$0] > 0.5 && ($0 == 0 || signal[$0 - 1] <= 0.5) }
    }

    @Test func quarterNotesAt120BPMBangEvery24000FramesFor10Percent() {
        let output = render(division: ClockDivision.frames("1/4", bpm: 120, sampleRate: 48_000), frames: 96_000)
        #expect(onsets(output) == [0, 24_000, 48_000, 72_000])
        #expect(output[2_399] == 1 && output[2_400] == 0 && output[23_999] == 0)
        #expect(output[0..<24_000].filter { $0 == 1 }.count == 2_400)
        #expect(output.allSatisfy { $0 == 0 || $0 == 1 })
    }

    @Test func dottedAndTripletDivisionsLandOnTheirFrames() {
        let dotted = render(division: ClockDivision.frames("1/8d", bpm: 120, sampleRate: 48_000), frames: 60_000)
        #expect(onsets(dotted) == [0, 18_000, 36_000, 54_000])
        let triplet = render(division: ClockDivision.frames("1/8t", bpm: 120, sampleRate: 48_000), frames: 30_000)
        #expect(onsets(triplet) == [0, 8_000, 16_000, 24_000])
    }

    @Test func fractionalDivisionsDoNotDrift() {
        let division = ClockDivision.frames("1/16", bpm: 97, sampleRate: 48_000)   // 7422.68… frames
        let output = render(division: division, frames: 48_000 * 60)
        let expected = (0..<Int((Double(48_000 * 60) / division).rounded(.up))).map { Int((Double($0) * division).rounded(.up)) }
        #expect(onsets(output) == expected)
    }

    @Test func chunksOf777MatchOneWholeRender() {
        let division = ClockDivision.frames("1/8t", bpm: 133, sampleRate: 48_000)
        #expect(render(division: division, gate: 0.37, frames: 100_000, chunk: 777) == render(division: division, gate: 0.37, frames: 100_000))
    }

    @Test func gateLengthSetsTheHighTime() {
        let output = render(division: 1_000, gate: 0.99, frames: 2_000)
        #expect(output[989] == 1 && output[990] == 0 && output[1_000] == 1)
    }

    // MARK: end to end

    /// Constant 0.5 audio → Gain/VCA (ring mod) whose Amount is `clocks` added by Math → Print.
    /// The output is non-zero exactly while some Clock is high.
    private func gated(_ clocks: [[ParameterID: ParameterValue]], frames: Int = 48_000, directory: URL) async throws -> [Float] {
        let audioFile = directory.appendingPathComponent("dc-\(UUID().uuidString).wav")
        try TestAudio.write([[Float](repeating: 0.5, count: frames)], to: audioFile, sampleRate: 48_000)
        let output = directory.appendingPathComponent("out-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var graph = TestProject()
        let audio = graph.add(.audio, asset: sourceAsset)
        let gain = graph.add(.gainVCA, ["mode": .choice("ringMod")])
        let print = graph.add(.print, ["bitDepth": .choice("32f")])
        graph.connect(audio, to: gain)
        if clocks.count == 1 {
            graph.connect(graph.add(.clock, clocks[0]), to: gain, "amount")
        } else {
            let math = graph.add(.math, ["operator": .choice("add")])
            graph.connect(graph.add(.clock, clocks[0]), to: math, "a")
            graph.connect(graph.add(.clock, clocks[1]), to: math, "b")
            graph.connect(math, to: gain, "amount")
        }
        graph.connect(gain, to: print)
        let urls = [sourceAsset: audioFile]
        let request = RenderRequest(plan: try compile(graph.project, assetURLs: urls), assetURLs: urls, outputDirectory: output)
        let written = try #require(try await RenderEngine.render(request).outputs[print])
        return try TestAudio.read(written).samples[0]
    }

    @Test func aClockGatesAudioOnItsDivisions() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = try await gated([["bpm": .number(240), "division": .choice("1/4"), "gateLength": .number(25)]], directory: directory)
        // 240 BPM quarter = 12000 frames; 25 % = 3000 frames high.
        let open = output.indices.filter { abs(output[$0]) > 1e-6 }
        let expected: [Int] = (0..<4).flatMap { (division: Int) -> [Int] in Array((division * 12_000)..<(division * 12_000 + 3_000)) }
        #expect(open == expected)
    }

    @Test func twoClocksRunIndependently() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = try await gated([
            ["bpm": .number(120), "division": .choice("1/4"), "gateLength": .number(1)],   // 0, 24000 (240 frames)
            ["bpm": .number(90), "division": .choice("1/4"), "gateLength": .number(1)],    // 0, 32000 (320 frames)
        ], directory: directory)
        let open = Set(output.indices.filter { abs(output[$0]) > 1e-6 })
        var expected = Set<Int>(0..<320)
        expected.formUnion(24_000..<24_240)
        expected.formUnion(32_000..<32_320)
        #expect(open == expected)
    }

    @Test func aClockResetsAnLFOEndToEnd() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let audioFile = directory.appendingPathComponent("dc.wav")
        try TestAudio.write([[Float](repeating: 0.5, count: 48_000)], to: audioFile, sampleRate: 48_000)
        let output = directory.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var graph = TestProject()
        let audio = graph.add(.audio, asset: sourceAsset)
        let clock = graph.add(.clock, ["bpm": .number(240), "division": .choice("1/4")])   // every 12000 frames
        let lfo = graph.add(.lfo, ["shape": .choice("saw"), "rate": .number(0.1)])
        let gain = graph.add(.gainVCA, ["mode": .choice("ringMod")])
        let print = graph.add(.print, ["bitDepth": .choice("32f")])
        graph.connect(clock, to: lfo, "reset")
        graph.connect(lfo, to: gain, "amount")
        graph.connect(audio, to: gain)
        graph.connect(gain, to: print)
        let urls = [sourceAsset: audioFile]
        let request = RenderRequest(plan: try compile(graph.project, assetURLs: urls), assetURLs: urls, outputDirectory: output)
        let samples = try TestAudio.read(try #require(try await RenderEngine.render(request).outputs[print])).samples[0]
        // The saw restarts at 0 on every bang; without the Clock it would be 0.05 at frame 12000.
        for onset in [12_000, 24_000, 36_000] {
            #expect(abs(samples[onset]) < 1e-6)
            #expect(abs(samples[onset - 1]) > 1e-3)
        }
    }

    @Test func aClockSyncedLFOFollowsTheClockEndToEnd() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let audioFile = directory.appendingPathComponent("dc.wav")
        try TestAudio.write([[Float](repeating: 0.5, count: 36_000)], to: audioFile, sampleRate: 48_000)
        let output = directory.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var graph = TestProject()
        let audio = graph.add(.audio, asset: sourceAsset)
        let clock = graph.add(.clock, ["bpm": .number(240), "division": .choice("1/4")])   // every 12000 frames
        let lfo = graph.add(.lfo, ["shape": .choice("saw"), "rate": .number(0.1), "sync": .choice("clock")])
        let gain = graph.add(.gainVCA, ["mode": .choice("ringMod")])
        let print = graph.add(.print, ["bitDepth": .choice("32f")])
        graph.connect(clock, to: lfo, "reset")
        graph.connect(lfo, to: gain, "amount")
        graph.connect(audio, to: gain)
        graph.connect(gain, to: print)
        let urls = [sourceAsset: audioFile]
        let request = RenderRequest(plan: try compile(graph.project, assetURLs: urls), assetURLs: urls, outputDirectory: output)
        let samples = try TestAudio.read(try #require(try await RenderEngine.render(request).outputs[print])).samples[0]
        // A quarter cycle into each locked division the saw is at 0.5 (× 0.5 audio); free at 0.1 Hz it would be ~0.03.
        #expect(abs(samples[15_000] - 0.25) < 1e-3)
        #expect(abs(samples[27_000] - 0.25) < 1e-3)
    }

    @Test func theClockIsAModulationSourceWithOneControlOutput() {
        let definition = NodeCatalog.definition(for: .clock)
        #expect(definition.pins.map(\.id) == ["out"] && definition.pins[0].signal == .control)
        #expect(definition.parameter("division")?.defaultValue == .choice("1/4"))
        #expect(definition.parameter("bpm")?.defaultValue == .number(120))
        #expect(definition.parameter("gateLength")?.defaultValue == .number(10))
    }
}
