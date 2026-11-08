import Foundation
import Testing
@testable import BakeGraph
@testable import BakeRender

/// Single Cycle's Oscillator mode (Frequency, Length) and Wavetable mode's Harmonic (owner request, 2026-10-27).
struct SingleCycleModesTests {
    private func render(_ parameters: [ParameterID: ParameterValue], modulated: [ParameterID] = [],
                        modulator: (pin: PinID, lfo: [ParameterID: ParameterValue])? = nil, chunkFrames: Int = 65_536) async throws -> [Float] {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var graph = TestProject()
        let cycle = graph.add(.singleCycle, parameters, modulated: modulated)
        let bake = graph.add(.print, ["bitDepth": .choice("32f")])
        graph.connect(cycle, to: bake)
        if let modulator {
            let lfo = graph.add(.lfo, modulator.lfo)
            graph.connect(lfo, to: cycle, modulator.pin)
        }
        let output = directory.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let request = RenderRequest(plan: try compile(graph.project, assetURLs: [:]), assetURLs: [:], outputDirectory: output, chunkFrames: chunkFrames)
        return try TestAudio.read(try #require(try await RenderEngine.render(request).outputs[bake])).samples[0]
    }

    /// The largest difference between `out` and `expected(frame)`.
    private func worstError(_ out: [Float], _ expected: (Int) -> Double) -> Double {
        var worst = 0.0
        for frame in out.indices {
            worst = max(worst, abs(Double(out[frame]) - expected(frame)))
        }
        return worst
    }

    @Test func oscillatorPlaysTheSineAtItsFrequencyForItsLength() async throws {
        let out = try await render(["mode": .choice("oscillator"), "shape": .choice("sine"), "frequency": .number(440), "length": .number(0.5)])
        #expect(out.count == 24_000)
        #expect(worstError(out) { frame in sin(2 * Double.pi * 440 * Double(frame) / 48_000) } < 1e-4)
    }

    @Test func oscillatorSawHasTheRightPitch() async throws {
        // A saw at 100 Hz wraps 100 times a second.
        let out = try await render(["mode": .choice("oscillator"), "shape": .choice("saw"), "frequency": .number(100), "length": .number(1)])
        let wraps = zip(out, out.dropFirst()).filter { $0 - $1 > 1 }.count
        #expect(abs(wraps - 100) <= 1)
    }

    @Test func oscillatorFrequencyIsModulatableAndChunkInvariant() async throws {
        let base: [ParameterID: ParameterValue] = ["mode": .choice("oscillator"), "frequency": .number(220), "length": .number(0.5)]
        let plain = try await render(base)
        let swept = try await render(base, modulated: ["frequency"], modulator: ("mod.frequency", ["rate": .number(2)]))
        #expect(plain != swept)
        let chunked = try await render(base, modulated: ["frequency"], modulator: ("mod.frequency", ["rate": .number(2)]), chunkFrames: 777)
        #expect(chunked == swept)
    }

    @Test func wavetableModeIsTheDefaultAndKeepsItsLength() async throws {
        let out = try await render(["cycles": .number(3), "frameSize": .choice("1024")])
        #expect(out.count == 3_072)
    }

    @Test func harmonicPutsWholeCyclesInEachFrame() async throws {
        let out = try await render(["shape": .choice("sine"), "harmonic": .number(3), "frameSize": .choice("2048"), "cycles": .number(2)])
        #expect(worstError(out) { frame in sin(2 * Double.pi * 3 * Double(frame % 2_048) / 2_048) } < 1e-6)
    }

    @Test func harmonicIsModulatablePerFrame() async throws {
        // An LFO saw steps Harmonic across 4 frames; frames differ but each stays seamless.
        let out = try await render(
            ["shape": .choice("sine"), "harmonic": .number(8), "frameSize": .choice("1024"), "cycles": .number(4)],
            modulated: ["harmonic"], modulator: ("mod.harmonic", ["shape": .choice("saw"), "rate": .number(48_000.0 / 4_096), "depth": .number(0.1)])
        )
        let frames = (0..<4).map { Array(out[$0 * 1_024..<($0 + 1) * 1_024]) }
        #expect(Set(frames.map { $0.prefix(32).map { ($0 * 1_000).rounded() } }).count > 1)
        // Seamless: the last sample of each frame leads into its first (a sine at whole cycles).
        for frame in frames { #expect(abs(frame[1_023] - frame[0]) < 0.1) }
    }
}
