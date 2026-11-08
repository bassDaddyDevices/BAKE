import Foundation
import Testing
@testable import BakeGraph
@testable import BakeRender

/// Pins the exact output of the shipped Vocoder, so running its frames and channels across the cores can never change what
/// a saved patch already sounds like (D-019).
///
/// Same recording rule as `ReduxGoldenTests`: set `expected` to `[:]`, run once, paste the literal the failure prints.
/// Hashes come from the Mac that records them (libm differs across platforms).
@Suite(.serialized)
struct VocoderGoldenTests {
    private static let modulatorAsset = AssetID(testUUID(9_410))
    private static let frames = 30_000

    private static let cases: [(name: String, parameters: [String: ParameterValue])] = [
        ("default", [:]),
        ("bands16", ["bands": .number(16)]),
        ("bands64", ["bands": .number(64)]),
        ("bands256", ["bands": .number(256)]),
        ("linear", ["spacing": .choice("linear")]),
        ("bark", ["spacing": .choice("bark"), "bands": .number(24)]),
        ("mel", ["spacing": .choice("mel"), "bands": .number(48)]),
        ("fast", ["attack": .number(1), "release": .number(5)]),
        ("slow", ["attack": .number(500), "release": .number(2_000)]),
        ("shiftUp", ["formantShift": .number(7)]),
        ("shiftDown", ["formantShift": .number(-12)]),
        ("halfMix", ["mix": .number(0.4)]),
        ("noSibilance", ["sibilance": .number(0)]),
        ("fullSibilance", ["sibilance": .number(1)]),
    ]

    private static let expected: [String: String] = [
        "default": "b02dee6116963287",
        "bands16": "991321a6e43f56b1",
        "bands64": "127ea15da951193d",
        "bands256": "a05d255b93ee84db",
        "linear": "ff3f6c224b330430",
        "bark": "da0b91d2430dac17",
        "mel": "36ca02ce732bdedc",
        "fast": "441c22f5eef22e79",
        "slow": "c9ea2336f54a3c31",
        "shiftUp": "8b9db0b6be162c49",
        "shiftDown": "1df82c39cb8cdf18",
        "halfMix": "b9f9ab30dea67332",
        "noSibilance": "ca8b51b0b8cbe71d",
        "fullSibilance": "b1ac3085bc6dec90",
    ]

    /// A tonal carrier and a speech-like modulator: a few formants swelling in turn.
    private static func carrier() -> [[Float]] {
        (0..<2).map { channel in
            let base: Double = channel == 0 ? 110.0 : 164.8
            var samples = [Float](repeating: 0, count: frames)
            for n in 0..<frames {
                let t: Double = Double(n) / 48_000
                var sum: Double = 0
                for h in 1...12 {
                    sum += sin(2.0 * Double.pi * base * Double(h) * t) / Double(h)
                }
                samples[n] = Float(0.3 * sum)
            }
            return samples
        }
    }

    private static func modulator() -> [Float] {
        var state: UInt32 = 77
        var samples = [Float](repeating: 0, count: frames)
        for n in 0..<frames {
            state = state &* 1_664_525 &+ 1_013_904_223
            let noise: Double = Double(state >> 8) / 8_388_608 - 1
            let t: Double = Double(n) / 48_000
            let swell: Double = 0.5 + 0.5 * sin(2.0 * Double.pi * 3.0 * t)
            let formant: Double = sin(2.0 * Double.pi * (400.0 + 600.0 * swell) * t)
            samples[n] = Float(0.4 * swell * (0.6 * formant + 0.4 * noise))
        }
        return samples
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
        let carrierURL = directory.appendingPathComponent("carrier.wav")
        try TestAudio.write(Self.carrier(), to: carrierURL, sampleRate: 48_000)
        patch.assets[sourceAsset] = carrierURL
        let modulatorURL = directory.appendingPathComponent("modulator.wav")
        try TestAudio.write([Self.modulator()], to: modulatorURL, sampleRate: 48_000)
        patch.assets[Self.modulatorAsset] = modulatorURL
        let carrier = patch.graph.add(.audio, asset: sourceAsset)
        let modulator = patch.graph.add(.audio, asset: Self.modulatorAsset)
        var merged = NodeCatalog.defaultParameters(for: .vocoder)
        for (id, value) in parameters { merged[id] = value }
        let vocoder = patch.graph.add(.vocoder, merged)
        patch.wire(carrier, "out", to: vocoder, "carrier")
        patch.wire(modulator, "out", to: vocoder, "modulator")
        patch.bake("out", from: vocoder)
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

    @Test func shippedVocoderKeepsItsExactOutput() async throws {
        var found: [(String, String)] = []
        for item in Self.cases {
            let output = try await render(item.parameters)
            #expect(output.count == 2 && output.allSatisfy { $0.count == Self.frames && $0.allSatisfy { $0.isFinite } }, "\(item.name)")
            found.append((item.name, Self.hash(output)))
        }
        let wrong = found.filter { Self.expected[$0.0] != $0.1 }.map(\.0)
        let literal = found.map { "        \"\($0.0)\": \"\($0.1)\"," }.joined(separator: "\n")
        #expect(wrong.isEmpty, "Unrecorded or changed: \(wrong). Current hashes, to record:\n[\n\(literal)\n]")
    }

    /// Any core count and any chunk size must give the recorded bits: the cores only change who computes what.
    @Test func everyCoreCountAndChunkSizeGivesTheRecordedOutput() async throws {
        let names: Set<String> = ["default", "bands256", "bark", "shiftUp", "fullSibilance"]
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
