import Foundation
import Testing
@testable import BakeGraph
@testable import BakeRender

/// The Dual Filter's upgrades: zero phase, per-sample coefficients, oversampled Drive, slopes to 384 dB/oct. Output must be
/// identical at any core count and chunk size; the defaults are pinned by `DualFilterGoldenTests`.
@Suite(.serialized)
struct DualFilterUpgradeTests {
    private func render(
        _ parameters: [String: ParameterValue], _ samples: [[Float]], workers: Int? = nil, chunk: Int = 65_536
    ) async throws -> [[Float]] {
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

    private func sine(_ frequency: Double, _ frames: Int) -> [Float] {
        (0..<frames).map { Float(0.5 * sin(2 * Double.pi * frequency * Double($0) / 48_000)) }
    }

    private func level(_ samples: ArraySlice<Float>) -> Float {
        20 * log10(max(sqrt(samples.reduce(0) { $0 + $1 * $1 } / Float(max(samples.count, 1))), 1e-12))
    }

    private static let configs: [(String, [String: ParameterValue])] = [
        ("zeroPhase", ["phase": .choice("zero"), "lfoDepth": .number(0.4), "lfoRate": .number(5)]),
        ("zeroPhaseDriven", ["phase": .choice("zero"), "drive": .number(12), "oversampling": .choice("4"), "coefficients": .choice("perSample")]),
        ("perSample", ["coefficients": .choice("perSample"), "lfoDepth": .number(0.8), "lfoRate": .number(30), "lfoShape": .choice("saw")]),
        ("oversampledDrive", ["drive": .number(24), "oversampling": .choice("16"), "q": .number(3)]),
        ("slope384", ["slope": .choice("384"), "cutoff": .number(2_000)]),
        ("sampleAndHoldZero", ["phase": .choice("zero"), "lfoShape": .choice("sampleAndHold"), "lfoDepth": .number(0.6), "lfoRate": .number(20), "seed": .number(7)]),
    ]

    @Test func identicalAtAnyCoreCountAndChunkSize() async throws {
        let samples = TestAudio.samples(frames: 12_000, channels: 2)
        for (name, parameters) in Self.configs {
            let reference = try await render(parameters, samples, workers: 1)
            #expect(reference.allSatisfy { $0.count == 12_000 && $0.allSatisfy { $0.isFinite } }, "\(name)")
            for workers in [2, 8] {
                #expect(try await render(parameters, samples, workers: workers) == reference, "\(name) workers \(workers)")
            }
            #expect(try await render(parameters, samples, workers: 4, chunk: 777) == reference, "\(name) chunk 777")
        }
    }

    /// A lowpass leaves a sine in phase only when it is zero phase.
    @Test func zeroPhaseHasNoPhaseShift() async throws {
        let input = sine(300, 24_000)
        let base: [String: ParameterValue] = ["cutoff": .number(300), "bandwidth": .number(0), "morph": .number(0), "slope": .choice("12")]
        func correlation(_ output: [Float]) -> Float {
            var dot: Float = 0, a: Float = 0, b: Float = 0
            for i in 8_000..<16_000 {
                dot += input[i] * output[i]
                a += input[i] * input[i]
                b += output[i] * output[i]
            }
            return dot / max((a * b).squareRoot(), 1e-12)
        }
        let minimum = try await render(base, [input])
        var zero = base
        zero["phase"] = .choice("zero")
        let zeroPhase = try await render(zero, [input])
        #expect(correlation(zeroPhase[0]) > 0.999, "zero phase should stay in phase")
        #expect(correlation(minimum[0]) < 0.9, "a minimum-phase lowpass at its cutoff lags by 90 degrees")
    }

    /// With nothing moving, per-sample coefficients are the same constants as block ones.
    @Test func perSampleEqualsBlockWhenNothingMoves() async throws {
        let samples = TestAudio.samples(frames: 12_000, channels: 2)
        let block = try await render([:], samples)
        let exact = try await render(["coefficients": .choice("perSample")], samples)
        #expect(block == exact)
        let moving: [String: ParameterValue] = ["lfoDepth": .number(0.9), "lfoRate": .number(40), "lfoShape": .choice("saw")]
        var movingExact = moving
        movingExact["coefficients"] = .choice("perSample")
        #expect(try await render(moving, samples) != render(movingExact, samples))
    }

    @Test func oversampledDriveChangesTheSaturatedSound() async throws {
        let input = sine(5_000, 12_000)
        let plain = try await render(["drive": .number(24), "mix": .number(1)], [input])
        let oversampled = try await render(["drive": .number(24), "oversampling": .choice("16")], [input])
        #expect(plain != oversampled)
        // With no drive the pass is a transparent round trip for low frequencies.
        let low = sine(200, 12_000)
        let clean = try await render([:], [low])
        let through = try await render(["oversampling": .choice("8")], [low])
        let worst = zip(clean[0], through[0]).map { abs($0 - $1) }.max() ?? 1
        #expect(worst < 0.02, "worst difference \(worst)")
    }

    @Test func longerSlopesAttenuateMore() async throws {
        let input = sine(1_000, 24_000)
        let base: [String: ParameterValue] = ["cutoff": .number(500), "bandwidth": .number(0), "morph": .number(0)]
        var gentle = base, steep = base
        gentle["slope"] = .choice("24")
        steep["slope"] = .choice("384")
        let a = try await render(gentle, [input])
        let b = try await render(steep, [input])
        #expect(level(b[0][12_000...]) < level(a[0][12_000...]) - 20)
    }

    @Test func catalogOffersTheUpgradesOffByDefault() throws {
        let definition = NodeCatalog.definition(for: .dualFilter)
        func options(_ id: String) throws -> [String] {
            let parameter = try #require(definition.parameters.first { $0.id == id })
            guard case .choice(let options, _) = parameter.kind else {
                Issue.record("\(id) should be a choice")
                return []
            }
            return options
        }
        #expect(try options("slope").last == "384")
        #expect(try options("oversampling").last == "256")
        let defaults = NodeCatalog.defaultParameters(for: .dualFilter)
        #expect(defaults["phase"] == .choice("minimum"))
        #expect(defaults["coefficients"] == .choice("block"))
        #expect(defaults["oversampling"] == .choice("1"))
    }
}
