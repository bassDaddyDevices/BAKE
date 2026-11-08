import Foundation
import Testing
@testable import BakeGraph
@testable import BakeRender

/// The Mid/Side Encoder, end to end: Mid = (L+R)/2, Side = (L−R)/2, both mono.
struct MidSideEncoderTests {
    private func patch(channels: Int, frames: Int = 2_000, in directory: URL) throws -> (patch: Patch, audio: NodeID, encoder: NodeID) {
        var patch = Patch()
        try patch.source(sourceAsset, channels: channels, frames: frames, in: directory)
        let audio = patch.graph.add(.audio, asset: sourceAsset)
        let encoder = patch.graph.add(.midSideEncoder)
        patch.wire(audio, "out", to: encoder)
        patch.bake("direct", from: audio)
        patch.bake("mid", from: encoder, "mid")
        patch.bake("side", from: encoder, "side")
        return (patch, audio, encoder)
    }

    @Test func midAndSideAreTheSumAndDifferenceOverTwo() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let files = try await patch(channels: 2, in: directory).patch.render(in: directory)

        let direct = try #require(files["direct"])
        let mid = try #require(files["mid"])
        let side = try #require(files["side"])
        #expect(mid.count == 1 && side.count == 1)
        #expect(mid[0].count == 2_000 && side[0].count == 2_000)
        #expect(mid[0] == zip(direct[0], direct[1]).map { ($0 + $1) * 0.5 })
        #expect(side[0] == zip(direct[0], direct[1]).map { ($0 - $1) * 0.5 })
    }

    @Test func monoInputIsAllMid() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let files = try await patch(channels: 1, in: directory).patch.render(in: directory)

        #expect(files["mid"] == files["direct"])
        #expect(files["side"]?[0].allSatisfy { $0 == 0 } == true)
    }

    @Test func identicalChannelsHaveNoSide() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var patch = Patch()
        try patch.source(sourceAsset, channels: 1, frames: 2_000, in: directory)
        let audio = patch.graph.add(.audio, asset: sourceAsset)
        let merger = patch.graph.add(.channelMerger)
        let encoder = patch.graph.add(.midSideEncoder)
        patch.wire(audio, "out", to: merger, "in1")
        patch.wire(audio, "out", to: merger, "in2")
        patch.wire(merger, "out", to: encoder)
        patch.bake("direct", from: audio)
        patch.bake("mid", from: encoder, "mid")
        patch.bake("side", from: encoder, "side")

        let files = try await patch.render(in: directory)

        #expect(files["mid"] == files["direct"])
        #expect(files["side"]?[0].allSatisfy { $0 == 0 } == true)
    }

    @Test func chunkSizeNeverChangesTheResult() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let built = try patch(channels: 2, frames: 5_000, in: directory).patch

        let whole = try await built.render(in: directory, chunkFrames: 65_536)
        let chunked = try await built.render(in: directory, chunkFrames: 777)

        #expect(whole == chunked)
    }

    @Test func rendersAreBitIdentical() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let built = try patch(channels: 2, in: directory).patch

        let first = try await built.render(in: directory, chunkFrames: 4_096)
        let second = try await built.render(in: directory, chunkFrames: 4_096)

        #expect(first == second)
    }

    @Test func eachOutputCanBeUsedAlone() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var patch = Patch()
        try patch.source(sourceAsset, channels: 2, frames: 2_000, in: directory)
        let audio = patch.graph.add(.audio, asset: sourceAsset)
        let encoder = patch.graph.add(.midSideEncoder)
        patch.wire(audio, "out", to: encoder)
        patch.bake("side", from: encoder, "side")

        let files = try await patch.render(in: directory)

        #expect(files["side"]?.first?.contains { $0 != 0 } == true)
    }

    @Test func pinsAreOneInputAndTwoMonoOutputs() throws {
        let definition = NodeCatalog.definition(for: .midSideEncoder)
        #expect(definition.pins.map(\.id) == ["in", "mid", "side"])
        #expect(definition.pins.dropFirst().allSatisfy { $0.direction == .output && $0.channels == .mono })
        #expect(definition.parameters.isEmpty)
    }
}
