import Foundation
import Testing
@testable import BakeGraph
@testable import BakeRender

/// A Bake's Clean Up, from its rules: trim to the first and last frame above the floor, raised-cosine
/// fades, Remove DC, peak to the target. Off, the file is what was rendered.
struct CleanUpTests {
    private let rate = 48_000.0

    /// 0.1 s silence, 0.2 s of a 1 kHz sine at `amplitude` (plus `dc` throughout), 0.1 s silence.
    private func signal(amplitude: Float = 0.25, dc: Float = 0) -> [Float] {
        (0..<Int(0.4 * rate)).map { frame in
            let inside = frame >= Int(0.1 * rate) && frame < Int(0.3 * rate)
            return dc + (inside ? amplitude * sin(2 * .pi * 1_000 * Float(frame) / Float(rate)) : 0)
        }
    }

    /// Audio → Bake (32-bit float) with these Bake settings; the baked samples.
    private func bake(_ input: [Float], _ settings: [ParameterID: ParameterValue]) async throws -> [Float] {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("in.wav")
        try TestAudio.write([input], to: source, sampleRate: rate)
        var graph = TestProject()
        let audio = graph.add(.audio, asset: sourceAsset)
        let bake = graph.add(.print, settings.merging(["bitDepth": .choice("32f")]) { $1 })
        graph.connect(audio, to: bake)
        let output = directory.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let urls = [sourceAsset: source]
        let plan = try compile(graph.project, assetURLs: urls)
        let result = try await RenderEngine.render(RenderRequest(plan: plan, assetURLs: urls, outputDirectory: output, chunkFrames: 777))
        let files = try FileManager.default.contentsOfDirectory(atPath: output.path(percentEncoded: false))
        #expect(files == ["bake.wav"], "no scratch file is left behind")
        return try TestAudio.read(try #require(result.outputs[bake])).samples[0]
    }

    private let on: [ParameterID: ParameterValue] = ["cleanUp": .choice("on")]

    @Test func cleanUpTrimsFadesAndNormalizes() async throws {
        let input = signal()
        let out = try await bake(input, on)
        // From the first to the last frame louder than −60 dBFS.
        let floor = Float(pow(10, -60.0 / 20))
        let first = try #require(input.firstIndex { abs($0) > floor })
        let last = try #require(input.lastIndex { abs($0) > floor })
        #expect(out.count == last - first + 1)
        #expect(out.first == 0 && out.last == 0)
        // The 2 ms (96-frame) raised cosine, on the source scaled to the target.
        let target = Float(pow(10, -0.1 / 20))
        let gain = target / (input.map(abs).max() ?? 1)
        for frame in [1, 24, 48, 95] {
            let expected = input[first + frame] * gain * CleanUp.fadeGain(frame, length: 96)
            #expect(abs(out[frame] - expected) < 1e-6, "fade-in frame \(frame)")
        }
        let peak = out.map(abs).max() ?? 0
        #expect(abs(20 * log10(Double(peak)) - -0.1) < 0.01)
    }

    @Test func removeDCCentresTheSignal() async throws {
        var settings = on
        settings["dcRemoval"] = .choice("on")
        settings["normalize"] = .choice("off")
        let input = signal(dc: 0.1)
        let out = try await bake(input, settings)
        // DC goes first, so the stretches that were only DC are silence and are trimmed like silence:
        // what's left is the sine, centred on 0.
        let sine = signal()
        let floor = Float(pow(10, -60.0 / 20))
        let mean = input.reduce(0, +) / Float(input.count)
        let first = try #require(input.firstIndex { abs($0 - mean) > floor })
        let last = try #require(input.lastIndex { abs($0 - mean) > floor })
        #expect(out.count == last - first + 1)
        #expect(out.count < sine.count)
        let middle = out[1_000..<(out.count - 1_000)]
        #expect(abs(middle.reduce(0, +) / Float(middle.count)) < 1e-3)
        #expect(abs((out.map(abs).max() ?? 0) - 0.25) < 0.01)
    }

    @Test func aFileNeverAboveTheFloorIsKeptWhole() async throws {
        let input = signal(amplitude: 0.0005)  // about −66 dBFS
        let out = try await bake(input, on)
        #expect(out == input)
    }

    @Test func cleanUpOffWritesExactlyWhatWasRendered() async throws {
        let input = signal()
        #expect(try await bake(input, [:]) == input)
        #expect(try await bake(input, ["cleanUp": .choice("off"), "dcRemoval": .choice("on")]) == input)
    }
}
