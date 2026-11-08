import Foundation
import Testing
@testable import BakeGraph
@testable import BakeRender

/// The GPU oscillator bank of Spectral Resynthesis (Engine GPU). It sums the sines in floats, so it cannot match the CPU's
/// doubles bit for bit; it must stay within -90 dB of them, and be the same for any chunk size and core count.
@Suite(.serialized)
struct ResynthesisGPUTests {
    private static let frames = 60_000

    /// A bass-like tone with vibrato and overtones plus a little noise, stereo.
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
                for h in 1...24 {
                    sum += sin(phase * Double(h)) / Double(h)
                }
                state = state &* 1_664_525 &+ 1_013_904_223
                let noise: Double = Double(state >> 8) / 8_388_608 - 1
                samples[n] = Float(0.3 * sum + 0.02 * noise)
            }
            return samples
        }
    }

    private func render(_ parameters: [String: ParameterValue], gpu: Bool, workers: Int? = nil, chunk: Int = 8_192) async throws -> [[Float]] {
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
        merged["engine"] = .choice(gpu ? "gpu" : "cpu")
        let node = patch.graph.add(.spectralResynthesis, merged)
        patch.wire(audio, "out", to: node, "in")
        patch.bake("out", from: node)
        return try #require(try await patch.render(in: directory, chunkFrames: chunk)["out"])
    }

    private static let cases: [(name: String, parameters: [String: ParameterValue])] = [
        ("default", [:]),
        ("sinesOnly", ["balance": .number(0)]),
        ("partials1024", ["partials": .number(1_024)]),
        ("partials4096", ["partials": .number(4_096), "fftSize": .choice("8192")]),
        ("odd", ["harmonics": .choice("odd")]),
        ("tilt", ["tilt": .number(6)]),
        ("smallFrames", ["fftSize": .choice("1024"), "partials": .number(256)]),
        ("pitchUp", ["pitch": .number(7)]),
        ("everything", ["pitch": .number(-5), "stretch": .number(0.75), "crystallize": .number(0.3), "phaseRandomize": .number(0.4)]),
    ]

    @Test func theGPUBankStaysWithinNinetyDecibelsOfTheCPU() async throws {
        var failures: [String] = []
        for item in Self.cases {
            let cpu = try await render(item.parameters, gpu: false)
            let gpu = try await render(item.parameters, gpu: true)
            #expect(cpu.count == gpu.count && zip(cpu, gpu).allSatisfy { $0.count == $1.count }, "\(item.name) shape")
            var peak: Float = 0
            var error: Float = 0
            for (a, b) in zip(cpu, gpu) {
                for (x, y) in zip(a, b) {
                    peak = max(peak, abs(x))
                    error = max(error, abs(x - y))
                    #expect(y.isFinite)
                }
            }
            let decibels = 20 * log10(Double(max(error, 1e-12)) / Double(max(peak, 1e-12)))
            if peak < 1e-4 || decibels > -90 { failures.append("\(item.name): peak \(peak), error \(decibels) dB") }
        }
        #expect(failures.isEmpty, "Outside -90 dB of the CPU: \(failures)")
    }

    @Test func theGPUBankGivesTheSameBitsAtAnyCoreCountAndChunkSize() async throws {
        for item in Self.cases.filter({ ["default", "partials1024", "odd", "pitchUp"].contains($0.name) }) {
            let reference = try await render(item.parameters, gpu: true, workers: 1, chunk: 8_192)
            for (workers, chunk) in [(2, 8_192), (8, 8_192), (8, 777), (4, 3_000)] {
                let other = try await render(item.parameters, gpu: true, workers: workers, chunk: chunk)
                #expect(other == reference, "\(item.name) workers \(workers) chunk \(chunk)")
            }
        }
    }

    @Test func engineIsASettingThatDefaultsToTheCPU() {
        let definition = NodeCatalog.definition(for: .spectralResynthesis)
        let defaults = NodeCatalog.defaultParameters(for: .spectralResynthesis)
        #expect(defaults["engine"] == .choice("cpu"))
        #expect(definition.parameters.contains { $0.id == "engine" })
        let partials = definition.parameter("partials")!
        #expect(NodeCatalog.resolve(.number(16_384), for: partials) == .number(16_384))
    }
}
