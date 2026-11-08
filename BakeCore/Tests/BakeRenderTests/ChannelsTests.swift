import Foundation
import Testing
@testable import BakeGraph
@testable import BakeRender

/// Channel Splitter and Channel Merger, end to end through the render engine.
struct ChannelsTests {
    private let longAsset = AssetID(testUUID(9_100))

    private func render(_ patch: Patch, in directory: URL, chunkFrames: Int = 4_096) async throws -> [String: [[Float]]] {
        try await patch.render(in: directory, chunkFrames: chunkFrames)
    }

    private func source(_ channels: Int, frames: Int = 2_000, in directory: URL, asset: AssetID = sourceAsset) throws -> URL {
        let url = directory.appendingPathComponent("source-\(asset.rawValue.uuidString).wav")
        try TestAudio.write(TestAudio.samples(frames: frames, channels: channels), to: url, sampleRate: 48_000)
        return url
    }

    @Test func splitterOutputsAreTheSourceChannels() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var patch = Patch()
        patch.assets = [sourceAsset: try source(2, in: directory)]
        let audio = patch.graph.add(.audio, asset: sourceAsset)
        let splitter = patch.graph.add(.channelSplitter)
        patch.wire(audio, "out", to: splitter)
        patch.bake("direct", from: audio)
        patch.bake("left", from: splitter, "out1")
        patch.bake("right", from: splitter, "out2")

        let files = try await render(patch, in: directory)

        let direct = try #require(files["direct"])
        #expect(files["left"] == [direct[0]])
        #expect(files["right"] == [direct[1]])
    }

    @Test func channelsTheSourceDoesntHaveAreSilent() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var patch = Patch()
        patch.assets = [sourceAsset: try source(1, in: directory)]
        let audio = patch.graph.add(.audio, asset: sourceAsset)
        let splitter = patch.graph.add(.channelSplitter, ["channels": .choice("4")])
        patch.wire(audio, "out", to: splitter)
        patch.bake("first", from: splitter, "out1")
        patch.bake("second", from: splitter, "out2")
        patch.bake("fourth", from: splitter, "out4")

        let files = try await render(patch, in: directory)

        #expect(files["first"]?[0].contains { $0 != 0 } == true)
        #expect(files["second"]?[0].allSatisfy { $0 == 0 } == true)
        #expect(files["fourth"]?[0].allSatisfy { $0 == 0 } == true)
    }

    @Test func splittingThenMergingIsBitExact() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var patch = Patch()
        patch.assets = [sourceAsset: try source(2, in: directory)]
        let audio = patch.graph.add(.audio, asset: sourceAsset)
        let splitter = patch.graph.add(.channelSplitter)
        let merger = patch.graph.add(.channelMerger)
        let swapped = patch.graph.add(.channelMerger)
        patch.wire(audio, "out", to: splitter)
        patch.wire(splitter, "out1", to: merger, "in1")
        patch.wire(splitter, "out2", to: merger, "in2")
        patch.wire(splitter, "out1", to: swapped, "in2")
        patch.wire(splitter, "out2", to: swapped, "in1")
        patch.bake("direct", from: audio)
        patch.bake("merged", from: merger)
        patch.bake("swapped", from: swapped)

        let files = try await render(patch, in: directory)

        let direct = try #require(files["direct"])
        #expect(files["merged"] == direct)
        #expect(files["swapped"] == [direct[1], direct[0]])
    }

    @Test func mergersAreAsLongAsTheirLongestInput() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var patch = Patch()
        patch.assets = [
            sourceAsset: try source(1, frames: 1_000, in: directory),
            longAsset: try source(1, frames: 3_000, in: directory, asset: longAsset),
        ]
        let short = patch.graph.add(.audio, asset: sourceAsset)
        let long = patch.graph.add(.audio, asset: longAsset)
        let merger = patch.graph.add(.channelMerger, ["channels": .choice("3")])
        patch.wire(short, "out", to: merger, "in1")
        patch.wire(long, "out", to: merger, "in2")
        patch.bake("merged", from: merger)

        let merged = try #require(try await render(patch, in: directory)["merged"])

        #expect(merged.count == 3)
        #expect(merged.allSatisfy { $0.count == 3_000 })
        #expect(merged[0][1_000...].allSatisfy { $0 == 0 })   // the short input has ended
        #expect(merged[1][1_000...].contains { $0 != 0 })
        #expect(merged[2].allSatisfy { $0 == 0 })             // nothing wired to in3
    }

    @Test func chunkSizeNeverChangesTheResult() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var patch = Patch()
        patch.assets = [sourceAsset: try source(2, frames: 5_000, in: directory)]
        let audio = patch.graph.add(.audio, asset: sourceAsset)
        let splitter = patch.graph.add(.channelSplitter)
        let merger = patch.graph.add(.channelMerger)
        patch.wire(audio, "out", to: splitter)
        patch.wire(splitter, "out2", to: merger, "in1")
        patch.bake("merged", from: merger)

        let whole = try await render(patch, in: directory, chunkFrames: 65_536)
        let chunked = try await render(patch, in: directory, chunkFrames: 777)

        #expect(whole == chunked)
    }
}
