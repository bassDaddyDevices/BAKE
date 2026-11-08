import Foundation
import Testing
@testable import BakeGraph
@testable import BakeRender

struct FeedbackTests {
    private func render(
        _ input: [Float],
        parameters: [ParameterID: ParameterValue] = [:],
        chunkFrames: Int = 65_536
    ) async throws -> [Float] {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("in.wav")
        try TestAudio.write([input], to: source, sampleRate: 48_000)
        let output = directory.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        var graph = TestProject()
        let audio = graph.add(.audio, asset: sourceAsset)
        let feedback = graph.add(.feedback, parameters)

        let bake = graph.add(.print, ["bitDepth": .choice("32f")])
        graph.connect(audio, to: feedback)
        graph.connect(feedback, to: bake)
        let urls = [sourceAsset: source]
        let request = RenderRequest(
            plan: try compile(graph.project, assetURLs: urls), assetURLs: urls,
            outputDirectory: output, chunkFrames: chunkFrames
        )
        return try TestAudio.read(try #require(try await RenderEngine.render(request).outputs[bake])).samples[0]
    }

    private func loopRender(
        _ input: [Float],
        parameters: [ParameterID: ParameterValue],
        chunkFrames: Int = 65_536,
        modulated: ParameterID? = nil
    ) async throws -> [Float] {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("in.wav")
        try TestAudio.write([input], to: source, sampleRate: 48_000)
        let output = directory.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        var graph = TestProject()
        let audio = graph.add(.audio, asset: sourceAsset)
        let feedback = graph.add(.feedback, parameters, modulated: modulated.map { [$0] } ?? [])

        let mixer = graph.add(.mixer)
        let bake = graph.add(.print, ["bitDepth": .choice("32f")])
        graph.connect(audio, to: feedback)
        graph.connect(feedback, to: mixer, "in1")
        graph.connect(mixer, to: feedback, "return")
        if let modulated {
            let lfo = graph.add(.lfo, ["rate": .number(2), "depth": .number(1), "shape": .choice("square")])
            graph.connect(lfo, to: feedback, "mod.\(modulated)")
        }
        graph.connect(feedback, to: bake)
        let urls = [sourceAsset: source]
        let plan = try compile(graph.project, assetURLs: urls)
        #expect(plan.loops.count == 1)
        let request = RenderRequest(plan: plan, assetURLs: urls, outputDirectory: output, chunkFrames: chunkFrames)
        return try TestAudio.read(try #require(try await RenderEngine.render(request).outputs[bake])).samples[0]
    }

    private func modulatedLoopRender(
        _ input: [Float],
        parameters: [ParameterID: ParameterValue],
        parameter: ParameterID
    ) async throws -> [Float] {
        try await loopRender(input, parameters: parameters, chunkFrames: 777, modulated: parameter)
    }

    @Test func feedbackWithoutReturnPassesInputThroughForThePlannedTail() async throws {
        let input = (0..<256).map { Float(sin(Double($0) * 0.17)) * 0.5 }
        let output = try await render(input, parameters: ["tail": .number(0.01)])
        #expect(output.count == input.count + 480)
        #expect(Array(output.prefix(input.count)) == input)
        #expect(output.suffix(480).allSatisfy { $0 == 0 })
    }

    @Test func saturatedFeedbackKeepsALoudSineFiniteAndBounded() async throws {
        let input = (0..<4_800).map { Float(sin(2 * Double.pi * 440 * Double($0) / 48_000)) * 4 }
        let output = try await loopRender(
            input,
            parameters: ["gain": .number(6), "delay": .number(1), "drive": .number(12), "tail": .number(0.02)]
        )
        #expect(output.allSatisfy { $0.isFinite })
        for frame in input.indices {
            #expect(abs(output[frame]) <= abs(input[frame]) + 1)
        }
    }

    @Test func everySaturationModeChangesTheLoopOutput() async throws {
        let input = (0..<4_800).map { Float(sin(2 * Double.pi * 997 * Double($0) / 48_000)) * 0.9 }
        var results: [[Float]] = []
        for mode in ["tanh", "tape", "hard", "crush"] {
            results.append(try await loopRender(
                input,
                parameters: ["gain": .number(6), "delay": .number(1), "drive": .number(18), "mode": .choice(mode), "tail": .number(0.01)]
            ))
        }
        for mode in results.indices.dropFirst() {
            #expect(results[mode] != results[0], "mode \(mode) differs from tanh")
        }
    }

    @Test func dampingControlsChangeAHighFrequencyEchoTrain() async throws {
        let input = (0..<2_400).map { Float(sin(2 * Double.pi * 8_000 * Double($0) / 48_000)) * 0.8 }
        let open = try await loopRender(
            input,
            parameters: ["gain": .number(-3), "delay": .number(1), "lowCut": .number(20), "highCut": .number(20_000), "tail": .number(0.03)]
        )
        let dark = try await loopRender(
            input,
            parameters: ["gain": .number(-3), "delay": .number(1), "lowCut": .number(20), "highCut": .number(1_000), "tail": .number(0.03)]
        )
        #expect(open != dark)
    }

    @Test func modulatableFeedbackControlsChangeTheLoopOutput() async throws {
        let input = (0..<9_600).map { Float(sin(2 * Double.pi * 2_300 * Double($0) / 48_000)) * 0.7 }
        let base: [ParameterID: ParameterValue] = [
            "gain": .number(-12), "delay": .number(2), "drive": .number(3),
            "mode": .choice("tanh"), "lowCut": .number(40), "highCut": .number(12_000), "tail": .number(0.02),
        ]
        for parameter in ["gain", "drive", "mode", "lowCut", "highCut"] {
            let baseline = try await loopRender(input, parameters: base)
            let modulated = try await modulatedLoopRender(input, parameters: base, parameter: parameter)
            #expect(modulated != baseline, "modulation for \\(parameter)")
            #expect(modulated.allSatisfy { $0.isFinite })
        }
    }

    @Test func feedbackLoopIsChunkInvariantWithDampingAndDrive() async throws {
        var seed: UInt64 = 17
        let noise = (0..<2_400).map { _ -> Float in
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Float(Int64(bitPattern: seed) >> 40) / Float(1 << 23) * 0.7
        }
        let parameters: [ParameterID: ParameterValue] = [
            "gain": .number(-3), "delay": .number(2.5), "drive": .number(9),
            "mode": .choice("tape"), "lowCut": .number(60), "highCut": .number(9_000), "tail": .number(0.05),
        ]
        let whole = try await loopRender(noise, parameters: parameters)
        #expect(try await loopRender(noise, parameters: parameters, chunkFrames: 777) == whole)
        #expect(try await loopRender(noise, parameters: parameters, chunkFrames: 1) == whole)
    }

    @Test func parameterExtremesStayFinite() async throws {
        let input = (0..<2_048).map { Float(sin(2 * Double.pi * 997 * Double($0) / 48_000)) * 3 }
        let configurations: [[ParameterID: ParameterValue]] = [
            ["gain": .number(-60), "delay": .number(0), "drive": .number(0), "mode": .choice("tanh"),
             "lowCut": .number(20), "highCut": .number(1_000), "tail": .number(0)],
            ["gain": .number(6), "delay": .number(1_000), "drive": .number(24), "mode": .choice("crush"),
             "lowCut": .number(2_000), "highCut": .number(20_000), "tail": .number(0.01)],
        ]
        for parameters in configurations {
            let output = try await loopRender(input, parameters: parameters)
            #expect(output.allSatisfy { $0.isFinite })
        }
    }

    @Test func identicalFeedbackRendersAreDeterministic() async throws {
        let input = (0..<2_048).map { Float(sin(Double($0) * 0.13)) * 0.7 }
        let parameters: [ParameterID: ParameterValue] = [
            "gain": .number(-3), "delay": .number(1.5), "drive": .number(4),
            "mode": .choice("crush"), "tail": .number(0.01),
        ]
        #expect(try await loopRender(input, parameters: parameters) == loopRender(input, parameters: parameters))
    }
}
