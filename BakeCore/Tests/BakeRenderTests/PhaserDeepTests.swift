import BakeDSP
import Foundation
import Testing
@testable import BakeGraph
@testable import BakeRender

/// Direction, up to 512 stages and the retriggered sweep. What saved Phasers sound like is pinned in `PhaserGoldenTests`.
@Suite(.serialized)
struct PhaserDeepTests {
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
        var merged = NodeCatalog.defaultParameters(for: .phaser)
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

    /// Short noise bursts, identical each time, in silence.
    private func bursts(at positions: [Int], frames: Int, channels: Int = 1) -> [[Float]] {
        (0..<channels).map { _ in
            var samples = [Float](repeating: 0, count: frames)
            for position in positions {
                var state: UInt32 = 12_345
                for offset in 0..<1_500 {
                    state = state &* 1_664_525 &+ 1_013_904_223
                    samples[position + offset] = (Float(state >> 8) / 8_388_608 - 1) * 0.5 * (1 - Float(offset) / 1_500)
                }
            }
            return samples
        }
    }

    private func impulse(at position: Int, frames: Int) -> [[Float]] {
        var samples = [Float](repeating: 0, count: frames)
        samples[position] = 1
        return [samples]
    }

    private func rms(_ values: ArraySlice<Float>) -> Double {
        sqrt(values.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(max(values.count, 1)))
    }

    private let steady: [String: ParameterValue] = [
        "depth": .number(0), "feedback": .number(0), "mix": .number(1), "stages": .choice("8"),
    ]

    // MARK: Determinism

    @Test(arguments: [
        ["direction": ParameterValue.choice("backward"), "stages": .choice("24"), "feedback": .number(0.4)],
        ["direction": .choice("zeroPhase"), "stages": .choice("512"), "feedback": .number(0.5)],
        ["stages": .choice("128"), "depth": .number(1), "rate": .number(2)],
        ["direction": .choice("zeroPhase"), "retrigger": .choice("transients"), "rate": .number(3), "stages": .choice("12")],
    ])
    func identicalOnAnyCoreCountAndChunking(parameters: [String: ParameterValue]) async throws {
        let samples = bursts(at: [3_000, 9_000, 15_000], frames: 20_000, channels: 4)
        let one = try await render(parameters, samples, workers: 1)
        #expect(one.count == 4 && one.allSatisfy { $0.count == 20_000 && $0.allSatisfy { $0.isFinite } })
        #expect(one[0] != samples[0])
        #expect(try await render(parameters, samples, workers: 8) == one)
        #expect(try await render(parameters, samples, workers: 8, chunk: 777) == one)
    }

    // MARK: Direction

    @Test func forwardOnlyRingsAfterAnImpulseAndBackwardOnlyBefore() async throws {
        let input = impulse(at: 4_000, frames: 8_000)
        // 128 stages puts forward on the deep kernel too.
        let forward = try await render(steady.merging(["direction": .choice("forward"), "stages": .choice("128")]) { $1 }, input)[0]
        let backward = try await render(steady.merging(["direction": .choice("backward")]) { $1 }, input)[0]
        #expect(forward[0..<4_000].allSatisfy { $0 == 0 })
        #expect(forward[4_001..<8_000].contains { abs($0) > 1e-3 })
        #expect(backward[4_001..<8_000].allSatisfy { $0 == 0 })
        #expect(backward[0..<4_000].contains { abs($0) > 1e-3 })
    }

    /// Averaging the forward and backward runs is the real part of the chain's response: an impulse comes out
    /// symmetric around itself, with no time smear in either direction.
    @Test func zeroPhaseIsSymmetricAroundAnImpulse() async throws {
        let output = try await render(steady.merging(["direction": .choice("zeroPhase")]) { $1 }, impulse(at: 4_000, frames: 8_000))[0]
        #expect(output[1_000..<4_000].contains { abs($0) > 1e-3 })
        for k in 1...3_000 {
            #expect(abs(output[4_000 + k] - output[4_000 - k]) < 1e-5, "k = \(k)")
        }
    }

    @Test func theDeepChainKeepsUnityGain() async throws {
        let input = TestAudio.samples(frames: 60_000, channels: 1)
        let output = try await render(steady.merging(["stages": .choice("512"), "center": .number(2_000)]) { $1 }, input)[0]
        let ratio = rms(output[25_000..<55_000]) / rms(input[0][25_000..<55_000])
        #expect(abs(ratio - 1) < 0.05, "\(ratio)")
        #expect(output.allSatisfy { $0.isFinite })
    }

    // MARK: Retrigger

    @Test func transientsAreFoundWhereTheBurstsStart() {
        let input = bursts(at: [10_000, 70_000], frames: 120_000)[0]
        var onsets = [Int32](repeating: 0, count: bake.dsp.phaserTransientCapacity(input.count, 48_000))
        let found = input.withUnsafeBufferPointer { samples in
            var pointer: UnsafePointer<Float>? = samples.baseAddress
            return onsets.withUnsafeMutableBufferPointer { storage in
                withUnsafePointer(to: &pointer) { channels in
                    bake.dsp.detectPhaserTransients(channels, 1, input.count, 48_000, 0.5, storage.baseAddress, storage.count)
                }
            }
        }
        #expect(found == 2, "found \(found)")
        if found == 2 {
            #expect(abs(Int(onsets[0]) - 10_000) < 200 && abs(Int(onsets[1]) - 70_000) < 200, "\(onsets[0]) \(onsets[1])")
        }
    }

    @Test func retriggerGivesEveryHitTheSameSweep() async throws {
        let input = bursts(at: [10_000, 70_000], frames: 120_000)
        let parameters: [String: ParameterValue] = [
            "rate": .number(0.2), "depth": .number(1), "feedback": .number(0), "mix": .number(1), "stages": .choice("4"), "width": .number(3),
        ]
        func difference(_ output: [Float]) -> Float {
            zip(output[10_000..<13_000], output[70_000..<73_000]).map { abs($0 - $1) }.max() ?? 0
        }
        let free = try await render(parameters, input)[0]
        let anchored = try await render(parameters.merging(["retrigger": .choice("transients")]) { $1 }, input)[0]
        #expect(difference(free) > 0.01, "free-running: \(difference(free))")
        #expect(difference(anchored) < 2e-3, "retriggered: \(difference(anchored))")
    }
}
