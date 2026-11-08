import Foundation
import Testing
@testable import BakeGraph
@testable import BakeRender

/// Concatenate without a batch: its inputs rendered end to end, from known answers.
struct ConcatenateRenderTests {
    private func join(_ signals: [[Float]], _ parameters: [ParameterID: ParameterValue], chunkFrames: Int = 4_096) async throws -> [Float] {
        let folder = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        var patch = Patch()
        // Wiring in the app grows the pins; here the count is set directly.
        let concatenate = patch.graph.add(.concatenate, parameters.merging(["inputCount": .number(Double(max(2, signals.count)))]) { $1 })
        for (index, signal) in signals.enumerated() {
            let asset = AssetID(testUUID(6_000 + index))
            let url = folder.appending(path: "part \(index).wav")
            try TestAudio.write([signal], to: url, sampleRate: 48_000)
            patch.assets[asset] = url
            let audio = patch.graph.add(.audio, asset: asset)
            patch.wire(audio, "out", to: concatenate, PinID("in\(index + 1)"))
        }
        patch.bake("joined", from: concatenate)
        return try #require(try await patch.render(in: folder, chunkFrames: chunkFrames)["joined"]?.first)
    }

    private let ramp: [Float] = (0..<1_000).map { Float($0) / 2_000 }
    private let wave: [Float] = (0..<2_000).map { Float(sin(Double($0) * 0.05) * 0.3) }
    private let level = [Float](repeating: 0.25, count: 1_500)

    @Test func withNoCrossfadeTheInputsSitEndToEndInPinOrder() async throws {
        let out = try await join([ramp, wave, level], ["crossfade": .number(0)])
        #expect(out == ramp + wave + level)
    }

    @Test func aGapIsExactSilence() async throws {
        let out = try await join([ramp, level], ["gap": .number(50)])  // 2 400 frames at 48 kHz
        #expect(out == ramp + [Float](repeating: 0, count: 2_400) + level)
    }

    @Test func aCrossfadeOverlapsWithTheEqualPowerCurve() async throws {
        let out = try await join([level, ramp], ["crossfade": .number(10)])  // 480 frames
        #expect(out.count == level.count + ramp.count - 480)
        let start = level.count - 480
        for i in 0..<480 {
            let theta = Double.pi / 2 * (Double(i) + 0.5) / 480
            let expected = Double(level[start + i]) * cos(theta) + Double(ramp[i]) * sin(theta)
            #expect(abs(Double(out[start + i]) - expected) < 1e-6)
        }
        #expect(out[0..<start].elementsEqual(level[0..<start]))
        #expect(out[(start + 480)...].elementsEqual(ramp[480...]))
    }

    @Test func anySplitIntoChunksGivesTheSameFile() async throws {
        let inputs = [wave, ramp, level, wave]
        let whole = try await join(inputs, ["crossfade": .number(5)], chunkFrames: 16_384)
        #expect(try await join(inputs, ["crossfade": .number(5)], chunkFrames: 333) == whole)
    }
}
