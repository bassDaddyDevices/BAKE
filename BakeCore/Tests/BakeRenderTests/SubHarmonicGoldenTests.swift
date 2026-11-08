import Foundation
import Testing
@testable import BakeGraph
@testable import BakeRender

/// Pins the exact output of the shipped Sub Harmonic, so the whole-file analysis mode can never change what a saved patch already sounds like (D-019).
///
/// Same recording rule as `ReduxGoldenTests`: set `expected` to `[:]`, run once, paste the literal
/// the failure prints. Hashes come from the Mac that records them (libm differs across platforms).
/// `legacySettings` is applied to every case; it names the old behaviour of any setting added later.
@Suite(.serialized)
struct SubHarmonicGoldenTests {
    private static let legacySettings: [String: ParameterValue] = [:]

    /// Bass notes with a second harmonic, in bursts with silence between, so crossings, envelope and release all move.
    private static func bass(frames: Int, channels: Int) -> [[Float]] {
        var result: [[Float]] = []
        for channel in 0..<channels {
            let note: Double = channel == 0 ? 110.0 : 116.5
            var samples = [Float](repeating: 0, count: frames)
            for n in 0..<frames {
                let t: Double = Double(n) / 48_000
                let beat: Double = (t * 4).truncatingRemainder(dividingBy: 1)
                let burst: Double = beat < 0.7 ? 1.0 : 0.0
                let decay: Double = exp(-3.0 * beat)
                let fundamental: Double = sin(2.0 * Double.pi * note * t)
                let second: Double = 0.35 * sin(4.0 * Double.pi * note * t + 0.6)
                samples[n] = Float(0.6 * burst * decay * (fundamental + second))
            }
            result.append(samples)
        }
        return result
    }

    private static let cases: [(name: String, parameters: [String: ParameterValue], noisy: Bool)] = [
        ("default", [:], false),
        ("sub1Only", ["sub1": .number(1), "sub2": .number(0)], false),
        ("sub2Only", ["sub1": .number(0), "sub2": .number(1)], false),
        ("bothSubs", ["sub1": .number(0.8), "sub2": .number(0.8), "dry": .number(0.5)], false),
        ("lowTone", ["tone": .number(60), "sub1": .number(0.9)], false),
        ("highTone", ["tone": .number(1_800), "sub1": .number(0.9), "sub2": .number(0.4)], false),
        ("fastRelease", ["release": .number(10), "sub1": .number(0.7)], false),
        ("slowRelease", ["release": .number(500), "sub1": .number(0.7), "sub2": .number(0.3)], false),
        ("lowTrack", ["track": .number(40), "sub2": .number(0.5)], false),
        ("highTrack", ["track": .number(400), "sub2": .number(0.5)], false),
        ("dryOff", ["dry": .number(0), "sub1": .number(1), "sub2": .number(0.5)], false),
        ("noise", ["sub1": .number(0.6), "sub2": .number(0.3)], true),
    ]

    private static let expected: [String: String] = [
        "default": "97383d36c8b44da9",
        "sub1Only": "d5f95b3a801ea0a5",
        "sub2Only": "ebf2ddbb954e7e0",
        "bothSubs": "30711c691441857b",
        "lowTone": "6951a99bf4672b0a",
        "highTone": "39d14a36428c0848",
        "fastRelease": "c45fa69f5cc18bc2",
        "slowRelease": "9f6bc33f2edd77a7",
        "lowTrack": "82fd18847e03a9ac",
        "highTrack": "efccddd9adf882f3",
        "dryOff": "1c796d78e1e9268d",
        "noise": "cac517cf94d053a4",
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
        var merged = NodeCatalog.defaultParameters(for: .subHarmonic)
        for (id, value) in Self.legacySettings { merged[id] = value }
        for (id, value) in parameters { merged[id] = value }
        let node = graph.add(.subHarmonic, merged)
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

    @Test func shippedSubHarmonicKeepsItsExactOutput() async throws {
        let samples = TestAudio.samples(frames: 24_000, channels: 2)
        let bassSamples = Self.bass(frames: 24_000, channels: 2)
        var found: [(String, String)] = []
        for item in Self.cases {
            let output = try await render(item.parameters, item.noisy ? samples : bassSamples)
            #expect(output.count == 2 && output.allSatisfy { $0.count == 24_000 && $0.allSatisfy { $0.isFinite } }, "\(item.name)")
            found.append((item.name, Self.hash(output)))
        }
        let wrong = found.filter { Self.expected[$0.0] != $0.1 }.map(\.0)
        let literal = found.map { "        \"\($0.0)\": \"\($0.1)\"," }.joined(separator: "\n")
        #expect(wrong.isEmpty, "Unrecorded or changed: \(wrong). Current hashes, to record:\n[\n\(literal)\n]")
    }
}
