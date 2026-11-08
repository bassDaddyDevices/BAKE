import Foundation
import Testing
@testable import BakeGraph
@testable import BakeRender

/// Pins the exact output of every shipped Redux mode, so the linear-phase anti-alias, shaped dither and
/// fractional bit depth can never change what a saved patch already sounds like (D-019).
///
/// Same recording rule as `OversamplingGoldenTests`: set `expected` to `[:]`, run once, paste the literal
/// the failure prints. Hashes come from the Mac that records them (libm differs across platforms).
/// `legacySettings` is applied to every case; it names the old behaviour of any setting added later.
@Suite(.serialized)
struct ReduxGoldenTests {
    private static let legacySettings: [String: ParameterValue] = [
        "bitSteps": .choice("whole"), "antiAlias": .choice("biquad"),
    ]

    private static let cases: [(name: String, parameters: [String: ParameterValue])] = [
        ("classic/default", [:]),
        ("classic/4bit-div6-hold", ["reduxMode": .choice("classic"), "bitDepth": .number(4), "rateDivider": .number(6)]),
        ("classic/4bit-div6-linear-tpdf", [
            "reduxMode": .choice("classic"), "bitDepth": .number(4), "rateDivider": .number(6),
            "mode": .choice("linear"), "dither": .choice("triangular"),
        ]),
        ("classic/12bit-mix50", ["reduxMode": .choice("classic"), "bitDepth": .number(12), "mix": .number(0.5)]),
        ("bitReduction/3bit", ["reduxMode": .choice("bitReduction"), "bitDepth": .number(3)]),
        ("bitReduction/3bit-tpdf", ["reduxMode": .choice("bitReduction"), "bitDepth": .number(3), "dither": .choice("triangular")]),
        ("bitReduction/1bit", ["reduxMode": .choice("bitReduction"), "bitDepth": .number(1)]),
        ("downsampling/div8-hold", ["reduxMode": .choice("downsampling"), "rateDivider": .number(8)]),
        ("downsampling/div12-linear", ["reduxMode": .choice("downsampling"), "rateDivider": .number(12), "mode": .choice("linear")]),
        ("downsampling/div256", ["reduxMode": .choice("downsampling"), "rateDivider": .number(256)]),
        ("sampleAndHold/div5", ["reduxMode": .choice("sampleAndHold"), "rateDivider": .number(5)]),
        ("bitwise/xor", ["reduxMode": .choice("bitwise"), "bitDepth": .number(8), "bitwiseOperator": .choice("xor"), "mask": .number(21_845)]),
        ("bitwise/and", ["reduxMode": .choice("bitwise"), "bitDepth": .number(10), "bitwiseOperator": .choice("and"), "mask": .number(1_000)]),
        ("bitwise/or", ["reduxMode": .choice("bitwise"), "bitDepth": .number(6), "bitwiseOperator": .choice("or"), "mask": .number(7)]),
    ]

    private static let expected: [String: String] = [
        "classic/default": "4a816bec03bee7c2",
        "classic/4bit-div6-hold": "852aaf5a7db76d30",
        "classic/4bit-div6-linear-tpdf": "37ddac64c3d1114f",
        "classic/12bit-mix50": "dc9d16edd22ab70e",
        "bitReduction/3bit": "4215bbf99aee2175",
        "bitReduction/3bit-tpdf": "84a11757d14586fc",
        "bitReduction/1bit": "31c7b452e33a0d28",
        "downsampling/div8-hold": "8ad04b3945fc08f7",
        "downsampling/div12-linear": "9ed0e0d377fda1c4",
        "downsampling/div256": "57c5798b5571fbd7",
        "sampleAndHold/div5": "864dcb0cdbfb941b",
        "bitwise/xor": "e75027b7bfba78cc",
        "bitwise/and": "bdaa9b4bee8f681d",
        "bitwise/or": "b106364bd12eb74c",
    ]

    private func render(_ parameters: [String: ParameterValue], _ samples: [[Float]], workers: Int? = nil, chunk: Int = 65_536) async throws -> [[Float]] {
        await CoreCountGate.shared.acquire()
        Parallel.overrideCoreCount(workers)
        defer {
            Parallel.overrideCoreCount(nil)
            CoreCountGate.shared.releaseSoon()
        }
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.wav")
        try TestAudio.write(samples, to: source, sampleRate: 48_000)
        let output = directory.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var graph = TestProject()
        let audio = graph.add(.audio, asset: sourceAsset)
        var merged = NodeCatalog.defaultParameters(for: .redux)
        for (id, value) in Self.legacySettings { merged[id] = value }
        for (id, value) in parameters { merged[id] = value }
        let node = graph.add(.redux, merged)
        let print = graph.add(.print, ["bitDepth": .choice("32f")])
        graph.connect(audio, to: node)
        graph.connect(node, to: print)
        let urls = [sourceAsset: source]
        let request = RenderRequest(
            plan: try compile(graph.project, assetURLs: urls), assetURLs: urls, outputDirectory: output, chunkFrames: chunk
        )
        return try TestAudio.read(try #require(try await RenderEngine.render(request).outputs[print])).samples
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

    @Test func shippedModesKeepTheirExactOutput() async throws {
        let samples = TestAudio.samples(frames: 20_000, channels: 2)
        var found: [(String, String)] = []
        for item in Self.cases {
            let output = try await render(item.parameters, samples)
            #expect(output.count == 2 && output.allSatisfy { $0.count == 20_000 && $0.allSatisfy { $0.isFinite } }, "\(item.name)")
            found.append((item.name, Self.hash(output)))
        }
        let wrong = found.filter { Self.expected[$0.0] != $0.1 }.map(\.0)
        let literal = found.map { "        \"\($0.0)\": \"\($0.1)\"," }.joined(separator: "\n")
        #expect(wrong.isEmpty, "Unrecorded or changed: \(wrong). Current hashes, to record:\n[\n\(literal)\n]")
    }
}
