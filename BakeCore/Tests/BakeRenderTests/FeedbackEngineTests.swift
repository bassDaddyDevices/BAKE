import Foundation
import Testing
@testable import BakeGraph
@testable import BakeRender

/// Spec §11 engine rules: a loop renders in lockstep blocks of at most its delay, so the Feedback node
/// hears exactly what came back one delay ago, at any chunk size.
struct FeedbackEngineTests {
    /// Audio → Feedback → Mixer (unity) → back into Return; Feedback → Bake.
    private func render(_ input: [Float], feedback parameters: [ParameterID: ParameterValue], chunkFrames: Int = 65_536) async throws -> [Float] {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("in.wav")
        try TestAudio.write([input], to: source, sampleRate: 48_000)
        var graph = TestProject()
        let audio = graph.add(.audio, asset: sourceAsset)
        let feedback = graph.add(.feedback, parameters)
        let mixer = graph.add(.mixer)
        let bake = graph.add(.print, ["bitDepth": .choice("32f")])
        graph.connect(audio, to: feedback)
        graph.connect(feedback, to: mixer, "in1")
        graph.connect(mixer, to: feedback, "return")
        graph.connect(feedback, to: bake)
        let output = directory.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let urls = [sourceAsset: source]
        let plan = try compile(graph.project, assetURLs: urls)
        #expect(plan.loops.count == 1)
        let request = RenderRequest(plan: plan, assetURLs: urls, outputDirectory: output, chunkFrames: chunkFrames)
        return try TestAudio.read(try #require(try await RenderEngine.render(request).outputs[bake])).samples[0]
    }

    @Test func anImpulseEchoesEveryDelayAtTheFeedbackGain() async throws {
        var impulse = [Float](repeating: 0, count: 4_800)
        impulse[0] = 1
        let parameters: [ParameterID: ParameterValue] = [
            "gain": .number(-6), "delay": .number(10), "tail": .number(0.1),
            "lowCut": .number(20), "highCut": .number(20_000),
        ]
        let out = try await render(impulse, feedback: parameters)
        // 0.1 s of input + 0.1 s of tail.
        #expect(out.count == 9_600)
        // Each echo is the last one at the Feedback gain, through tanh (Drive 0 saturates too).
        let gain = pow(10, -6.0 / 20)
        var echo = 1.0
        for (frame, value) in out.enumerated() {
            if frame % 480 == 0 {
                if frame > 0 { echo = tanh(gain * echo) }
                #expect(abs(Double(value) - echo) <= echo * 1e-5, "echo at \(frame)")
            } else {
                #expect(value == 0, "silence at \(frame)")
            }
        }
    }

    @Test func aOneSampleDelayStillWorks() async throws {
        var impulse = [Float](repeating: 0, count: 64)
        impulse[0] = 1
        let out = try await render(impulse, feedback: [
            "gain": .number(-6), "delay": .number(0), "tail": .number(0),
            "lowCut": .number(20), "highCut": .number(20_000),
        ])
        let gain = pow(10, -6.0 / 20)
        var echo = 1.0
        for frame in 0..<16 {
            if frame > 0 { echo = tanh(gain * echo) }
            #expect(abs(Double(out[frame]) - echo) < 1e-6)
        }
    }

    @Test func chunkSizeNeverChangesALoop() async throws {
        var seed: UInt64 = 9
        let noise = (0..<2_400).map { _ -> Float in
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Float(Int64(bitPattern: seed) >> 40) / Float(1 << 23) * 0.5
        }
        let parameters: [ParameterID: ParameterValue] = [
            "gain": .number(-3), "delay": .number(2.5), "tail": .number(0.05),
            "lowCut": .number(20), "highCut": .number(20_000),
        ]
        let whole = try await render(noise, feedback: parameters)
        for chunk in [1, 777] {
            #expect(try await render(noise, feedback: parameters, chunkFrames: chunk) == whole, "chunk \(chunk)")
        }
    }
}
