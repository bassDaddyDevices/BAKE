import Foundation
import Testing
@testable import BakeGraph
@testable import BakeRender

/// Combinatorial Matrix's layering, alignment and Ceiling, from known answers.
struct MatrixTests {
    /// `signals` on A, B, C (in order) into a Matrix with `parameters`, rendered at `chunkFrames`.
    private func layer(
        _ signals: [[Float]], _ parameters: [ParameterID: ParameterValue] = [:], chunkFrames: Int = 4_096
    ) async throws -> [Float] {
        let folder = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        var patch = Patch()
        let matrix = patch.graph.add(.combinatorialMatrix, parameters)
        for (index, signal) in signals.enumerated() {
            let asset = AssetID(testUUID(8_000 + index))
            let url = folder.appending(path: "layer \(index).wav")
            try TestAudio.write([signal], to: url, sampleRate: 48_000)
            patch.assets[asset] = url
            let audio = patch.graph.add(.audio, asset: asset)
            patch.wire(audio, "out", to: matrix, PinID(["a", "b", "c"][index]))
        }
        patch.bake("layered", from: matrix)
        return try #require(try await patch.render(in: folder, chunkFrames: chunkFrames)["layered"]?.first)
    }

    private func click(at frame: Int, frames: Int, level: Float = 0.5) -> [Float] {
        var signal = [Float](repeating: 0, count: frames)
        signal[frame] = level
        return signal
    }

    private let ramp: [Float] = (0..<3_000).map { Float($0 % 100) / 400 }
    private let wave: [Float] = (0..<5_000).map { Float(sin(Double($0) * 0.01)) * 0.2 }

    @Test func startIsThePlainSumAtTheLevelsAsLongAsTheLongestInput() async throws {
        let out = try await layer([ramp, wave], ["align": .choice("start"), "levelA": .number(-6), "levelB": .number(6)])
        #expect(out.count == 5_000)
        let a = Float(pow(10, -6.0 / 20)), b = Float(pow(10, 6.0 / 20))
        for i in 0..<5_000 {
            let expected = (i < ramp.count ? ramp[i] * a : 0) + wave[i] * b
            #expect(abs(out[i] - expected) < 1e-6)
        }
    }

    @Test func peakLinesUpTheLoudestSamplesWithinTheAlignRange() async throws {
        // 10 ms apart at 48 kHz: A moves 480 frames later, and the two clicks become one.
        let out = try await layer([click(at: 100, frames: 2_000), click(at: 580, frames: 2_000)], ["align": .choice("peak")])
        #expect(out.count == 2_000 + 2_400)
        #expect(abs(out[580] - 1.0 * Float(pow(10, -0.3 / 20))) < 1e-5)  // 1.0 is over the Ceiling
        #expect(out.enumerated().filter { $0.offset != 580 }.allSatisfy { $0.element == 0 })
        // 200 ms apart, but no layer moves more than the 50 ms Align Range.
        let far = try await layer([click(at: 0, frames: 12_000), click(at: 9_600, frames: 12_000)], ["align": .choice("peak")])
        #expect(far[2_400] == 0.5 && far[9_600] == 0.5)
    }

    @Test func randomOffsetsStayInRangeAndRepeatForTheSameCombination() async throws {
        let clicks = [click(at: 0, frames: 1_000), click(at: 0, frames: 1_000), click(at: 0, frames: 1_000, level: 0.25)]
        func onsets(_ combination: Int) async throws -> [Int] {
            let out = try await layer(clicks, ["align": .choice("random"), "alignRange": .number(20), "combination": .number(Double(combination))])
            #expect(out.count == 1_000 + 960)
            return out.indices.filter { out[$0] != 0 }
        }
        let first = try await onsets(3)
        #expect(!first.isEmpty && first.allSatisfy { $0 <= 960 })
        #expect(try await onsets(3) == first)
        var differs = false
        for combination in 4..<8 where try await onsets(combination) != first { differs = true }
        #expect(differs)
    }

    @Test func theCeilingScalesALoudSumDownAndLeavesAQuietOneAlone() async throws {
        let loud = [Float](repeating: 0.8, count: 1_000)
        let scaled = try await layer([loud, loud], ["align": .choice("start"), "ceiling": .number(-6)])
        #expect(scaled.allSatisfy { abs($0 - Float(pow(10, -6.0 / 20))) < 1e-6 })
        let quiet = [Float](repeating: 0.1, count: 1_000)
        #expect(try await layer([quiet, quiet], ["align": .choice("start")]).allSatisfy { abs($0 - 0.2) < 1e-7 })
    }

    @Test func anySplitIntoChunksGivesTheSameFile() async throws {
        let inputs = [click(at: 700, frames: 9_000), wave, ramp]
        let whole = try await layer(inputs, ["align": .choice("peak")], chunkFrames: 16_384)
        #expect(try await layer(inputs, ["align": .choice("peak")], chunkFrames: 1_000) == whole)
    }
}
