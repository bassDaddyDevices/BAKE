import Foundation
import Testing
@testable import BakeGraph
@testable import BakeRender

/// Pins the exact output of the shipped Adaptive Clipping, so the lookahead ceiling and the frame-range multicore path can never change what a saved patch already sounds like (D-019).
///
/// Same recording rule as `ReduxGoldenTests`: set `expected` to `[:]`, run once, paste the literal
/// the failure prints. Hashes come from the Mac that records them (libm differs across platforms).
/// `legacySettings` is applied to every case; it names the old behaviour of any setting added later.
@Suite(.serialized)
struct AdaptiveClippingGoldenTests {
    private static let legacySettings: [String: ParameterValue] = [:]

    /// Quiet sustained tone with loud decaying kicks every quarter second, so the ceiling has to rise and fall.
    private static func kicks(frames: Int, channels: Int) -> [[Float]] {
        var result: [[Float]] = []
        for channel in 0..<channels {
            let pitch: Double = channel == 0 ? 70.0 : 82.0
            var samples = [Float](repeating: 0, count: frames)
            for n in 0..<frames {
                let t: Double = Double(n) / 48_000
                let beat: Double = (t * 4).truncatingRemainder(dividingBy: 1) / 4
                let kick: Double = 0.95 * exp(-25.0 * beat) * sin(2.0 * Double.pi * pitch * beat * 6.0 + 3.0 * beat)
                let bed: Double = 0.06 * sin(2.0 * Double.pi * 440.0 * t)
                samples[n] = Float(kick + bed)
            }
            result.append(samples)
        }
        return result
    }

    private static let cases: [(name: String, parameters: [String: ParameterValue], noisy: Bool)] = [
        ("default", [:], false),
        ("hardKnee", ["knee": .choice("hard")], false),
        ("deep", ["threshold": .number(-18), "makeup": .number(6)], false),
        ("shallow", ["threshold": .number(-1)], false),
        ("fastRelease", ["release": .number(5), "knee": .choice("hard")], false),
        ("slowRelease", ["release": .number(1_000)], false),
        ("halfMix", ["mix": .number(0.5), "threshold": .number(-12)], false),
        ("highFloor", ["floor": .number(-20), "threshold": .number(-24)], false),
        ("noOversampling", ["oversampling": .choice("1"), "knee": .choice("hard")], false),
        ("twoTimes", ["oversampling": .choice("2")], false),
        ("sixteenTimes", ["oversampling": .choice("16"), "threshold": .number(-9)], false),
        ("noise", ["threshold": .number(-6), "release": .number(40)], true),
    ]

    private static let expected: [String: String] = [
        "default": "ff1c8835ce289cb1",
        "hardKnee": "cbcdb26eaac3f565",
        "deep": "196fd42fe81eafbb",
        "shallow": "c50a87b35e563633",
        "fastRelease": "bfecfaf6c5ba5404",
        "slowRelease": "d6ca807294a24f65",
        "halfMix": "9c291688c7ca65fd",
        "highFloor": "d004d565493551e2",
        "noOversampling": "1a44097f4461b3f0",
        "twoTimes": "699e11e426b36f94",
        "sixteenTimes": "229860bdf98ffd37",
        "noise": "80d02781d1684e53",
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
        var merged = NodeCatalog.defaultParameters(for: .adaptiveClipping)
        for (id, value) in Self.legacySettings { merged[id] = value }
        for (id, value) in parameters { merged[id] = value }
        let node = graph.add(.adaptiveClipping, merged)
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

    @Test func shippedAdaptiveClippingKeepsItsExactOutput() async throws {
        let samples = TestAudio.samples(frames: 24_000, channels: 2)
        let kickSamples = Self.kicks(frames: 24_000, channels: 2)
        var found: [(String, String)] = []
        for item in Self.cases {
            let output = try await render(item.parameters, item.noisy ? samples : kickSamples)
            #expect(output.count == 2 && output.allSatisfy { $0.count == 24_000 && $0.allSatisfy { $0.isFinite } }, "\(item.name)")
            found.append((item.name, Self.hash(output)))
        }
        let wrong = found.filter { Self.expected[$0.0] != $0.1 }.map(\.0)
        let literal = found.map { "        \"\($0.0)\": \"\($0.1)\"," }.joined(separator: "\n")
        #expect(wrong.isEmpty, "Unrecorded or changed: \(wrong). Current hashes, to record:\n[\n\(literal)\n]")
    }
}
