import Foundation
import Testing
@testable import BakeGraph
@testable import BakeRender

/// Pins the exact output of the shipped Phaser, so the new directions, deeper stage counts and the transient
/// retrigger can never change what a saved patch already sounds like (D-019).
///
/// Same recording rule as `ReduxGoldenTests`: set `expected` to `[:]`, run once, paste the literal
/// the failure prints. Hashes come from the Mac that records them (libm differs across platforms).
/// `legacySettings` is applied to every case; it names the old behaviour of any setting added later.
@Suite(.serialized)
struct PhaserGoldenTests {
    private static let legacySettings: [String: ParameterValue] = [:]

    private static let cases: [(name: String, parameters: [String: ParameterValue])] = [
        ("default", [:]),
        ("twoStages", ["stages": .choice("2"), "feedback": .number(0.6), "mix": .number(0.5)]),
        ("eightStagesNegativeFeedback", ["stages": .choice("8"), "feedback": .number(-0.7), "rate": .number(0.8), "depth": .number(0.9)]),
        ("thirtySixWide", ["stages": .choice("36"), "width": .number(4), "depth": .number(1), "rate": .number(3), "mix": .number(1)]),
        ("sixtyFourStages", ["stages": .choice("64"), "center": .number(2_000), "feedback": .number(0.5), "mix": .number(0.5)]),
        ("stereoOffsetFull", ["stereoOffset": .number(1), "stages": .choice("12"), "feedback": .number(0.3)]),
        ("narrowAndSlow", ["width": .number(0.25), "rate": .number(0.05), "depth": .number(0.3), "stages": .choice("4"), "feedback": .number(0.9)]),
    ]

    private static let expected: [String: String] = [
        "default": "b819bc089d23710",
        "twoStages": "858a142d97e2d982",
        "eightStagesNegativeFeedback": "6896c3d94ab83974",
        "thirtySixWide": "d894190105b1d486",
        "sixtyFourStages": "1ea8dc597f550b21",
        "stereoOffsetFull": "1095475c2ab420a7",
        "narrowAndSlow": "e00d3e6762b8f420",
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
        var merged = NodeCatalog.defaultParameters(for: .phaser)
        for (id, value) in Self.legacySettings { merged[id] = value }
        for (id, value) in parameters { merged[id] = value }
        let node = graph.add(.phaser, merged)
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

    @Test func shippedPhaserKeepsItsExactOutput() async throws {
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
