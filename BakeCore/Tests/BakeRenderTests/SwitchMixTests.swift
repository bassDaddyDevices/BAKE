import Foundation
import Testing
@testable import BakeGraph
@testable import BakeRender

/// The many-in/one-out Switch end to end. (`SwitchTests` covers the step kernel, `SwitchGoldenTests` the fan-out kind.)
@Suite(.serialized)
struct SwitchMixTests {
    private static let frames = 48_000

    private func near(_ a: Float, _ b: Float) -> Bool { abs(a - b) < 1e-4 }

    /// Inputs of constant value, one file per input (`frames` long unless a length is given), a Clock banging every
    /// `bangEvery` frames into Advance; returns the rendered output channels.
    private func render(
        inputs: [(channels: [Float], frames: Int)], bangEvery: Int, parameters: [String: ParameterValue] = [:],
        reset: Bool = false, chunk: Int = 4_096
    ) async throws -> [[Float]] {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var patch = Patch()
        var merged = NodeCatalog.defaultParameters(for: .stepSwitch)
        merged["inputs"] = .choice(String(max(inputs.count, 2)))
        merged["crossfade"] = .number(0)
        for (id, value) in parameters { merged[id] = value }
        let router = patch.graph.add(.stepSwitch, merged)
        for (index, input) in inputs.enumerated() {
            let url = directory.appendingPathComponent("in\(index + 1).wav")
            let samples = input.channels.map { [Float](repeating: $0, count: input.frames) }
            try TestAudio.write(samples, to: url, sampleRate: 48_000)
            let asset = AssetID(testUUID(9_600 + index))
            patch.assets[asset] = url
            let audio = patch.graph.add(.audio, asset: asset)
            patch.wire(audio, "out", to: router, "in\(index + 1)")
        }
        // 240 bpm quarter notes bang every 12,000 frames; scale from there.
        let clock = patch.graph.add(.clock, ["bpm": .number(240.0 * 12_000.0 / Double(bangEvery)), "division": .choice("1/4")])
        patch.wire(clock, "out", to: router, "advance")
        if reset {
            let slow = patch.graph.add(.clock, ["bpm": .number(240.0 * 12_000.0 / Double(bangEvery) / 3.0), "division": .choice("1/4")])
            patch.wire(slow, "out", to: router, "reset")
        }
        patch.bake("out", from: router)
        return try #require(try await patch.render(in: directory, chunkFrames: chunk)["out"])
    }

    @Test func eachBangMovesToTheNextInputAndWrapsAround() async throws {
        let output = try await render(
            inputs: [([0.2], Self.frames), ([0.4], Self.frames), ([0.6], Self.frames)], bangEvery: 12_000
        )
        #expect(output.count == 1 && output[0].count == Self.frames)
        let heard = [6_000, 18_000, 30_000, 42_000].map { output[0][$0] }
        #expect(zip(heard, [0.2, 0.4, 0.6, 0.2] as [Float]).allSatisfy { near($0, $1) }, "\(heard)")
    }

    @Test func theOutputIsAsLongAsTheLongestInputAndAShorterOneIsSilentPastItsEnd() async throws {
        // In 1 (0.5) is half as long as In 2 (1.0). The first bang plays In 1; the next bang is at 48,000: never.
        let output = try await render(inputs: [([0.5], 24_000), ([1.0], Self.frames)], bangEvery: 48_000)
        #expect(output[0].count == Self.frames)
        #expect(near(output[0][12_000], 0.5))
        #expect(output[0][30_000] == 0 && output[0][47_999] == 0)
        // With a bang at 24,000 In 2 takes over and plays to its end.
        let moved = try await render(inputs: [([0.5], 24_000), ([1.0], Self.frames)], bangEvery: 24_000)
        #expect(moved[0].count == Self.frames)
        #expect(near(moved[0][12_000], 0.5) && near(moved[0][30_000], 1.0) && near(moved[0][47_999], 1.0))
    }

    @Test func theOutputHasTheWidestInputsChannelsAndMonoFeedsEveryChannel() async throws {
        let output = try await render(inputs: [([0.5], Self.frames), ([0.25, 0.75], Self.frames)], bangEvery: 24_000)
        #expect(output.count == 2)
        #expect(near(output[0][12_000], 0.5) && near(output[1][12_000], 0.5))
        #expect(near(output[0][36_000], 0.25) && near(output[1][36_000], 0.75))
    }

    @Test func anUnwiredStepIsSilent() async throws {
        // Three steps but only In 1 and In 3 wired.
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var patch = Patch()
        let router = patch.graph.add(.stepSwitch, ["inputs": .choice("3"), "crossfade": .number(0)])
        for number in [1, 3] {
            let url = directory.appendingPathComponent("in\(number).wav")
            try TestAudio.write([[Float](repeating: 0.5, count: 36_000)], to: url, sampleRate: 48_000)
            let asset = AssetID(testUUID(9_700 + number))
            patch.assets[asset] = url
            patch.wire(patch.graph.add(.audio, asset: asset), "out", to: router, "in\(number)")
        }
        let clock = patch.graph.add(.clock, ["bpm": .number(240), "division": .choice("1/4")])
        patch.wire(clock, "out", to: router, "advance")
        patch.bake("out", from: router)
        let output = try #require(try await patch.render(in: directory)["out"])
        #expect(near(output[0][6_000], 0.5) && output[0][18_000] == 0 && near(output[0][30_000], 0.5))
    }

    @Test func anyChunkSizeGivesTheSameBits() async throws {
        let inputs: [(channels: [Float], frames: Int)] = [([0.2, 0.3], Self.frames), ([0.5], 30_000), ([0.9, 0.1], Self.frames)]
        let cases: [[String: ParameterValue]] = [
            ["crossfade": .number(12)],
            ["order": .choice("random"), "seed": .number(3), "crossfade": .number(5)],
            ["order": .choice("pingPong"), "crossfade": .number(30)],
        ]
        for parameters in cases {
            let reference = try await render(inputs: inputs, bangEvery: 7_000, parameters: parameters, reset: true, chunk: 65_536)
            for chunk in [777, 4_096] {
                let output = try await render(inputs: inputs, bangEvery: 7_000, parameters: parameters, reset: true, chunk: chunk)
                #expect(output == reference, "chunk \(chunk) \(parameters)")
            }
        }
    }

    @Test func theCatalogDescribesTheSwitch() {
        let definition = NodeCatalog.definition(for: .stepSwitch)
        #expect(definition.pins.map(\.id) == ["out", "advance", "reset"])
        let inputs = NodeCatalog.pins(of: Node(kind: .stepSwitch)).filter { $0.direction == .input && $0.signal == .audio }
        #expect(inputs.map(\.id) == ["in1", "in2", "in3", "in4"])
        #expect(definition.lengthRule == .longestInput)
        #expect(NodeKind.stepSwitch.category == .routing && !NodeKind.stepSwitch.isLegacy)
    }
}
