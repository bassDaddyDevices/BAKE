import Foundation
import Testing
@testable import BakeGraph
@testable import BakeRender

/// The Mid/Side Decoder, end to end: left = Mid + Side, right = Mid − Side, always stereo.
struct MidSideDecoderTests {
    private let sideAsset = AssetID(testUUID(9_300))

    /// Mono Mid and Side sources written from a stereo signal with the encoder's formula, so these
    /// tests don't depend on the encoder node being merged.
    private func encodedSources(of stereo: [[Float]], mid midFrames: Int? = nil, side sideFrames: Int? = nil, in directory: URL) throws -> Patch {
        var patch = Patch()
        let mid = zip(stereo[0], stereo[1]).map { ($0 + $1) * 0.5 }
        let side = zip(stereo[0], stereo[1]).map { ($0 - $1) * 0.5 }
        let midURL = directory.appendingPathComponent("mid.wav")
        let sideURL = directory.appendingPathComponent("side.wav")
        try TestAudio.write([Array(mid.prefix(midFrames ?? mid.count))], to: midURL, sampleRate: 48_000)
        try TestAudio.write([Array(side.prefix(sideFrames ?? side.count))], to: sideURL, sampleRate: 48_000)
        patch.assets = [sourceAsset: midURL, sideAsset: sideURL]
        return patch
    }

    private func decoder(_ patch: inout Patch) -> NodeID {
        let decoder = patch.graph.add(.midSideDecoder)
        let mid = patch.graph.add(.audio, asset: sourceAsset)
        let side = patch.graph.add(.audio, asset: sideAsset)
        patch.wire(mid, "out", to: decoder, "mid")
        patch.wire(side, "out", to: decoder, "side")
        return decoder
    }

    @Test func leftIsMidPlusSideAndRightIsMidMinusSide() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var patch = try encodedSources(of: TestAudio.samples(frames: 2_000, channels: 2), in: directory)
        let mid = patch.graph.add(.audio, asset: sourceAsset)
        let side = patch.graph.add(.audio, asset: sideAsset)
        let decoder = patch.graph.add(.midSideDecoder)
        patch.wire(mid, "out", to: decoder, "mid")
        patch.wire(side, "out", to: decoder, "side")
        patch.bake("mid", from: mid)
        patch.bake("side", from: side)
        patch.bake("decoded", from: decoder)

        let files = try await patch.render(in: directory)

        let (m, s, decoded) = (try #require(files["mid"]?[0]), try #require(files["side"]?[0]), try #require(files["decoded"]))
        #expect(decoded.count == 2)
        #expect(decoded[0] == zip(m, s).map(+))
        #expect(decoded[1] == zip(m, s).map(-))
    }

    @Test func roundTripsTheEncodersFormulaWithinFloatRounding() async throws {
        // Mid and Side are each rounded to Float, so M±S can differ from L and R in the last bit
        // or two; it can't be bit-exact for every input.
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = TestAudio.samples(frames: 2_000, channels: 2)
        var patch = try encodedSources(of: original, in: directory)
        let node = decoder(&patch)
        patch.bake("decoded", from: node)

        let decoded = try #require(try await patch.render(in: directory)["decoded"])

        for channel in 0..<2 {
            #expect(zip(decoded[channel], original[channel]).allSatisfy { abs($0 - $1) <= 2 * Float.ulpOfOne * max(1, abs($1)) })
        }
    }

    @Test func aLoneMidComesOutAsDualMono() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var patch = try encodedSources(of: TestAudio.samples(frames: 2_000, channels: 2), in: directory)
        let mid = patch.graph.add(.audio, asset: sourceAsset)
        let decoder = patch.graph.add(.midSideDecoder)
        patch.wire(mid, "out", to: decoder, "mid")
        patch.bake("mid", from: mid)
        patch.bake("decoded", from: decoder)

        let files = try await patch.render(in: directory)

        let decoded = try #require(files["decoded"])
        #expect(decoded.count == 2)
        #expect(decoded[0] == files["mid"]?[0])
        #expect(decoded[1] == files["mid"]?[0])
    }

    @Test func inputsOfDifferentLengthsAreAsLongAsTheLongest() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var patch = try encodedSources(of: TestAudio.samples(frames: 3_000, channels: 2), mid: 1_000, side: 3_000, in: directory)
        let node = decoder(&patch)
        patch.bake("decoded", from: node)

        let decoded = try #require(try await patch.render(in: directory)["decoded"])

        #expect(decoded.count == 2 && decoded.allSatisfy { $0.count == 3_000 })
        // Past the end of Mid only Side is left: left = +S, right = −S.
        #expect(zip(decoded[0][1_000...], decoded[1][1_000...]).allSatisfy { $0 == -$1 })
        #expect(decoded[0][1_000...].contains { $0 != 0 })
    }

    @Test func outputStaysStereoWhateverTheInputWidth() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var patch = Patch()
        try patch.source(sourceAsset, channels: 4, frames: 2_000, in: directory)
        try patch.source(sideAsset, channels: 1, frames: 2_000, in: directory)
        let node = decoder(&patch)
        patch.bake("decoded", from: node)

        let decoded = try #require(try await patch.render(in: directory)["decoded"])

        #expect(decoded.count == 2 && decoded.allSatisfy { $0.count == 2_000 && $0.allSatisfy { $0.isFinite } })
    }

    @Test func chunkSizeNeverChangesTheResult() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var patch = try encodedSources(of: TestAudio.samples(frames: 5_000, channels: 2), in: directory)
        let node = decoder(&patch)
        patch.bake("decoded", from: node)

        let whole = try await patch.render(in: directory, chunkFrames: 65_536)
        let chunked = try await patch.render(in: directory, chunkFrames: 777)

        #expect(whole == chunked)
    }

    @Test func rendersAreBitIdentical() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var patch = try encodedSources(of: TestAudio.samples(frames: 2_000, channels: 2), in: directory)
        let node = decoder(&patch)
        patch.bake("decoded", from: node)

        let first = try await patch.render(in: directory)
        let second = try await patch.render(in: directory)
        #expect(first == second)
    }

    @Test func pinsAreMidAndSideInAndStereoOut() {
        let definition = NodeCatalog.definition(for: .midSideDecoder)
        #expect(definition.pins.map(\.id) == ["mid", "side", "out"])
        #expect(definition.lengthRule == .longestInput)
        #expect(definition.channelRule == .fixed(2))
        #expect(definition.parameters.isEmpty)
    }
}
