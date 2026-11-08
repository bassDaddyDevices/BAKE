import Foundation
import Testing
@testable import BakeGraph
@testable import BakeRender

/// Pins the exact output of the shipped Dual Filter, so zero-phase mode, per-sample coefficients, oversampled Drive and the longer slopes can never change what a saved patch already sounds like (D-019).
///
/// Same recording rule as `ReduxGoldenTests`: set `expected` to `[:]`, run once, paste the literal
/// the failure prints. Hashes come from the Mac that records them (libm differs across platforms).
/// `legacySettings` is applied to every case; it names the old behaviour of any setting added later.
@Suite(.serialized)
struct DualFilterGoldenTests {
    private static let legacySettings: [String: ParameterValue] = [:]

    private static let cases: [(name: String, parameters: [String: ParameterValue])] = [
        ("default", [:]),
        ("slope12", ["slope": .choice("12")]),
        ("slope48", ["slope": .choice("48"), "q": .number(4)]),
        ("slope96", ["slope": .choice("96"), "cutoff": .number(3_000)]),
        ("lowpassPair", ["betaType": .choice("lowpass"), "bandwidth": .number(2.5), "morph": .number(0.3)]),
        ("bandNotch", ["alphaType": .choice("bandpass"), "betaType": .choice("notch"), "q": .number(8), "morph": .number(0.7)]),
        ("lfoSine", ["lfoDepth": .number(0.6), "lfoRate": .number(6)]),
        ("lfoTriangleInPhase", ["lfoDepth": .number(0.8), "lfoRate": .number(3), "lfoShape": .choice("triangle"), "lfoPhase": .choice("inPhase")]),
        ("lfoSaw", ["lfoDepth": .number(1), "lfoRate": .number(12), "lfoShape": .choice("saw")]),
        ("lfoSquare", ["lfoDepth": .number(0.5), "lfoRate": .number(8), "lfoShape": .choice("square")]),
        ("lfoSampleAndHold", ["lfoDepth": .number(0.7), "lfoRate": .number(20), "lfoShape": .choice("sampleAndHold"), "seed": .number(42)]),
        ("driven", ["drive": .number(18), "q": .number(2)]),
        ("drivenWet", ["drive": .number(24), "mix": .number(0.5), "lfoDepth": .number(0.3)]),
        ("morphAlpha", ["morph": .number(0)]),
        ("morphBeta", ["morph": .number(1), "bandwidth": .number(3)]),
        ("highCutoff", ["cutoff": .number(18_000), "q": .number(12)]),
        ("lowCutoff", ["cutoff": .number(30), "q": .number(0.3)]),
    ]

    private static let expected: [String: String] = [
        "default": "bffafdf87b557d59",
        "slope12": "f706aff9a210be6e",
        "slope48": "226b16f7eb549d8",
        "slope96": "ceba993e4c4075d1",
        "lowpassPair": "1ffa3f08f5e772a1",
        "bandNotch": "3f1f219a9cc54428",
        "lfoSine": "96e56d691b8cb3ea",
        "lfoTriangleInPhase": "c698c933817069eb",
        "lfoSaw": "c01fb61acc96936f",
        "lfoSquare": "4fba9b7f66f4482",
        "lfoSampleAndHold": "6183e2f7140e29cc",
        "driven": "6f562b9c71b744b9",
        "drivenWet": "3d0f281fffabd390",
        "morphAlpha": "dbca308039cb4290",
        "morphBeta": "b21a396fb7abacd",
        "highCutoff": "4c9ead28198eba09",
        "lowCutoff": "88c44f5bbeb4b109",
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
        var merged = NodeCatalog.defaultParameters(for: .dualFilter)
        for (id, value) in Self.legacySettings { merged[id] = value }
        for (id, value) in parameters { merged[id] = value }
        let node = graph.add(.dualFilter, merged)
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

    @Test func shippedDualFilterKeepsItsExactOutput() async throws {
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
