import Foundation
import Testing
@testable import BakeGraph
@testable import BakeRender

/// Pins the exact output of the shipped Chorus, so the swarm path, the higher voice counts and Reach can never change what a saved patch already sounds like (D-019).
///
/// Same recording rule as `ReduxGoldenTests`: set `expected` to `[:]`, run once, paste the literal
/// the failure prints. Hashes come from the Mac that records them (libm differs across platforms).
/// `legacySettings` is applied to every case; it names the old behaviour of any setting added later.
@Suite(.serialized)
struct ChorusGoldenTests {
    private static let legacySettings: [String: ParameterValue] = [:]

    private static let cases: [(name: String, parameters: [String: ParameterValue])] = [
        ("default", [:]),
        ("twoVoices", ["voices": .choice("2"), "detune": .number(20), "mix": .number(0.7)]),
        ("sixVoices", ["voices": .choice("6"), "spread": .number(0.9), "driftRate": .number(0.8)]),
        ("eightMaxDetune", ["voices": .choice("8"), "detune": .number(30), "spread": .number(1), "mix": .number(1)]),
        ("fastDrift", ["driftRate": .number(2), "detune": .number(15), "mix": .number(0.6)]),
        ("slowDrift", ["driftRate": .number(0.05), "detune": .number(30), "voices": .choice("8")]),
        ("panZero", ["panSpread": .number(0), "voices": .choice("4")]),
        ("panFull", ["panSpread": .number(1), "voices": .choice("6")]),
        ("dryish", ["mix": .number(0.15), "spread": .number(0.2), "detune": .number(5)]),
    ]

    private static let expected: [String: String] = [
        "default": "647d779892fbdaca",
        "twoVoices": "86c59a9ed156b55b",
        "sixVoices": "e9352b2be5f93ee",
        "eightMaxDetune": "b696f9c2c4a33221",
        "fastDrift": "62072035710b9443",
        "slowDrift": "87339921ceb15abe",
        "panZero": "35904573cffb80e1",
        "panFull": "78024c73bd71721",
        "dryish": "6618138786ed3930",
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
        var merged = NodeCatalog.defaultParameters(for: .chorus)
        for (id, value) in Self.legacySettings { merged[id] = value }
        for (id, value) in parameters { merged[id] = value }
        let node = graph.add(.chorus, merged)
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

    @Test func shippedChorusKeepsItsExactOutput() async throws {
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
