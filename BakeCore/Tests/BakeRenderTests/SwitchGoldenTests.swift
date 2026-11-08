import Foundation
import Testing
@testable import BakeGraph
@testable import BakeRender

/// Pins the exact output of the shipped fan-out Switch (one input, N outputs), so flipping the Switch to many-in/one-out
/// can never change what a saved patch already sounds like (D-019): saved Switches migrate to the legacy kind and must
/// keep these bits.
///
/// Same recording rule as `ReduxGoldenTests`: set `expected` to `[:]`, run once, paste the literal the failure prints.
/// Hashes come from the Mac that records them.
@Suite(.serialized)
struct SwitchGoldenTests {
    private static let kind: NodeKind = .stepSwitchFanOut
    private static let frames = 48_000

    private static let cases: [(name: String, parameters: [String: ParameterValue], reset: Bool)] = [
        ("default", [:], false),
        ("forwardHardCut", ["crossfade": .number(0)], false),
        ("forwardFade", ["crossfade": .number(12)], false),
        ("forwardLongFade", ["crossfade": .number(50)], false),
        ("pingPong", ["order": .choice("pingPong"), "crossfade": .number(5)], false),
        ("random", ["order": .choice("random"), "seed": .number(7)], false),
        ("randomOtherSeed", ["order": .choice("random"), "seed": .number(12_345), "outputs": .choice("8")], false),
        ("pattern", ["order": .choice("pattern"), "pattern": .text("1 1 3 2")], false),
        ("twoOutputs", ["outputs": .choice("2")], false),
        ("eightOutputs", ["outputs": .choice("8"), "crossfade": .number(2)], false),
        ("withReset", ["crossfade": .number(5)], true),
    ]

    private static let expected: [String: String] = [
        "default": "7c0ca81d2c540dfe",
        "forwardHardCut": "431e58405691c252",
        "forwardFade": "371998ad99522212",
        "forwardLongFade": "737ca4c9d922d7a",
        "pingPong": "e77c852036589506",
        "random": "75cca0af06dbcf06",
        "randomOtherSeed": "5367b3431d2b92ba",
        "pattern": "9dd25a3d88c44713",
        "twoOutputs": "7ccaa9edc491196",
        "eightOutputs": "7d865cac16d4820e",
        "withReset": "413f6b70ef3ba502",
    ]

    /// A stereo tonal source with a different pitch per channel.
    private static func source() -> [[Float]] {
        (0..<2).map { channel in
            let base: Double = channel == 0 ? 220 : 330
            return (0..<frames).map { n in
                let t: Double = Double(n) / 48_000
                return Float(0.5 * sin(2.0 * Double.pi * base * t) + 0.2 * sin(2.0 * Double.pi * base * 3.0 * t))
            }
        }
    }

    private func render(_ parameters: [String: ParameterValue], reset: Bool, workers: Int? = nil, chunk: Int = 4_096) async throws -> [[Float]] {
        await CoreCountGate.shared.acquire()
        Parallel.overrideCoreCount(workers)
        defer {
            Parallel.overrideCoreCount(nil)
            CoreCountGate.shared.releaseSoon()
        }
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var patch = Patch()
        let url = directory.appendingPathComponent("source.wav")
        try TestAudio.write(Self.source(), to: url, sampleRate: 48_000)
        patch.assets[sourceAsset] = url
        let audio = patch.graph.add(.audio, asset: sourceAsset)
        let clock = patch.graph.add(.clock, ["bpm": .number(480), "division": .choice("1/4")])      // a bang every 6000 frames
        var merged = NodeCatalog.defaultParameters(for: Self.kind)
        for (id, value) in parameters { merged[id] = value }
        let router = patch.graph.add(Self.kind, merged)
        patch.wire(audio, "out", to: router, "in")
        patch.wire(clock, "out", to: router, "advance")
        if reset {
            let slow = patch.graph.add(.clock, ["bpm": .number(100), "division": .choice("1/4")])
            patch.wire(slow, "out", to: router, "reset")
        }
        let count = Int(merged["outputs"].flatMap { if case .choice(let value) = $0 { value } else { nil } } ?? "4") ?? 4
        for number in 1...count { patch.bake("out\(number)", from: router, "out\(number)") }
        let rendered = try await patch.render(in: directory, chunkFrames: chunk)
        var channels: [[Float]] = []
        for number in 1...count { channels += try #require(rendered["out\(number)"]) }
        return channels
    }

    private static func hash(_ channels: [[Float]]) -> String {
        var value: UInt64 = 0xcbf29ce484222325
        for channel in channels {
            for sample in channel {
                var bits = sample.bitPattern
                for _ in 0..<4 {
                    value = (value ^ UInt64(bits & 0xff)) &* 0x100000001b3
                    bits >>= 8
                }
            }
        }
        return String(value, radix: 16)
    }

    @Test func shippedSwitchKeepsItsExactOutput() async throws {
        var found: [(String, String)] = []
        for item in Self.cases {
            let output = try await render(item.parameters, reset: item.reset)
            #expect(!output.isEmpty && output.allSatisfy { $0.count == Self.frames && $0.allSatisfy { $0.isFinite } }, "\(item.name)")
            found.append((item.name, Self.hash(output)))
        }
        let wrong = found.filter { Self.expected[$0.0] != $0.1 }.map(\.0)
        let literal = found.map { "        \"\($0.0)\": \"\($0.1)\"," }.joined(separator: "\n")
        #expect(wrong.isEmpty, "Unrecorded or changed: \(wrong). Current hashes, to record:\n[\n\(literal)\n]")
    }

    /// Any chunk size must give the recorded bits.
    @Test func everyChunkSizeGivesTheRecordedOutput() async throws {
        let names: Set<String> = ["forwardFade", "random", "withReset"]
        var wrong: [String] = []
        for item in Self.cases where names.contains(item.name) {
            for chunk in [777, 6_000, 65_536] {
                let output = try await render(item.parameters, reset: item.reset, chunk: chunk)
                if Self.hash(output) != Self.expected[item.name] { wrong.append("\(item.name) chunk \(chunk)") }
            }
        }
        #expect(wrong.isEmpty, "Differs from the recorded output: \(wrong)")
    }
}
