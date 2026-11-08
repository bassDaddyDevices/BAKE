import Foundation
import Testing
@testable import BakeGraph
@testable import BakeRender

/// Pins the exact output of the shipped Spectral Resynthesis, so running its channels and frame ranges across the cores can
/// never change what a saved patch already sounds like (D-019).
///
/// Same recording rule as `ReduxGoldenTests`: set `expected` to `[:]`, run once, paste the literal the failure prints.
/// Hashes come from the Mac that records them (libm differs across platforms).
@Suite(.serialized)
struct ResynthesisGoldenTests {
    private static let frames = 30_000

    private static let cases: [(name: String, parameters: [String: ParameterValue])] = [
        ("default", [:]),
        ("partials16", ["partials": .number(16)]),
        ("partials1024", ["partials": .number(1_024)]),
        ("fft1024", ["fftSize": .choice("1024")]),
        ("fft16384", ["fftSize": .choice("16384")]),
        ("odd", ["harmonics": .choice("odd")]),
        ("even", ["harmonics": .choice("even"), "hysteresis": .number(0.8)]),
        ("tightTracking", ["hysteresis": .number(0)]),
        ("tiltDown", ["tilt": .number(-6)]),
        ("tiltUp", ["tilt": .number(6)]),
        ("sinesOnly", ["balance": .number(0)]),
        ("noiseOnly", ["balance": .number(1)]),
        ("pitchUp", ["pitch": .number(7)]),
        ("stretched", ["stretch": .number(1.5)]),
        ("crystal", ["crystallize": .number(0.7)]),
        ("quantized", ["quantize": .number(1), "scale": .choice("major"), "root": .choice("2")]),
        ("randomPhase", ["phaseRandomize": .number(0.6), "seed": .number(3)]),
        ("everything", ["pitch": .number(-5), "stretch": .number(0.75), "crystallize": .number(0.3), "phaseRandomize": .number(0.4)]),
    ]

    private static let expected: [String: String] = [
        "default": "fc30328749786b74",
        "partials16": "2e5dcbfb39ac313d",
        "partials1024": "1c80a858351c7949",
        "fft1024": "8c64a12d68672f16",
        "fft16384": "223b20b68aac2e7",
        "odd": "e55765b4c6948712",
        "even": "86ed7914c10ed88d",
        "tightTracking": "f1a63ff51708fb7d",
        "tiltDown": "173125d54df835f5",
        "tiltUp": "e5b71e1768add47b",
        "sinesOnly": "202b75b7326b144a",
        "noiseOnly": "2c7eac95f6174bca",
        "pitchUp": "8c856f33976fbde4",
        "stretched": "6976dfbc04213018",
        "crystal": "cb07c513c0d91f63",
        "quantized": "642011572eee8be1",
        "randomPhase": "ac6dd1b166b7f47",
        "everything": "f1131331ec86af9d",
    ]

    /// A bass-like tone with vibrato, a few overtones and a little noise, in stereo.
    private static func source() -> [[Float]] {
        (0..<2).map { channel in
            let base: Double = channel == 0 ? 110.0 : 138.6
            var state: UInt32 = channel == 0 ? 5 : 11
            var phase: Double = 0
            var samples = [Float](repeating: 0, count: frames)
            for n in 0..<frames {
                let t: Double = Double(n) / 48_000
                let vibrato: Double = 1.0 + 0.01 * sin(2.0 * Double.pi * 5.0 * t)
                phase += 2.0 * Double.pi * base * vibrato / 48_000
                var sum: Double = 0
                for h in 1...6 {
                    sum += sin(phase * Double(h)) / Double(h)
                }
                state = state &* 1_664_525 &+ 1_013_904_223
                let noise: Double = Double(state >> 8) / 8_388_608 - 1
                samples[n] = Float(0.4 * sum + 0.02 * noise)
            }
            return samples
        }
    }

    private func render(_ parameters: [String: ParameterValue], workers: Int? = nil, chunk: Int = 4_096) async throws -> [[Float]] {
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
        var merged = NodeCatalog.defaultParameters(for: .spectralResynthesis)
        for (id, value) in parameters { merged[id] = value }
        let node = patch.graph.add(.spectralResynthesis, merged)
        patch.wire(audio, "out", to: node, "in")
        patch.bake("out", from: node)
        return try #require(try await patch.render(in: directory, chunkFrames: chunk)["out"])
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

    @Test func shippedResynthesisKeepsItsExactOutput() async throws {
        var found: [(String, String)] = []
        for item in Self.cases {
            let output = try await render(item.parameters)
            #expect(output.count == 2 && output.allSatisfy { !$0.isEmpty && $0.allSatisfy { $0.isFinite } }, "\(item.name)")
            found.append((item.name, Self.hash(output)))
        }
        let wrong = found.filter { Self.expected[$0.0] != $0.1 }.map(\.0)
        let literal = found.map { "        \"\($0.0)\": \"\($0.1)\"," }.joined(separator: "\n")
        #expect(wrong.isEmpty, "Unrecorded or changed: \(wrong). Current hashes, to record:\n[\n\(literal)\n]")
    }

    /// Any core count and any chunk size must give the recorded bits: the cores only change who computes what.
    @Test func everyCoreCountAndChunkSizeGivesTheRecordedOutput() async throws {
        let names: Set<String> = ["default", "partials1024", "odd", "pitchUp", "everything"]
        var wrong: [String] = []
        for item in Self.cases where names.contains(item.name) {
            for (workers, chunk) in [(1, 4_096), (2, 4_096), (8, 4_096), (8, 777)] {
                let output = try await render(item.parameters, workers: workers, chunk: chunk)
                if Self.hash(output) != Self.expected[item.name] { wrong.append("\(item.name) workers \(workers) chunk \(chunk)") }
            }
        }
        #expect(wrong.isEmpty, "Differs from the recorded output: \(wrong)")
    }
}
