import Foundation
import Testing
@testable import BakeGraph
@testable import BakeRender

/// The Mixer, end to end: inputs sum sample for sample, then the master Gain applies.
struct MixerTests {
    private let second = AssetID(testUUID(9_200))

    @Test func twoInputsSumSampleForSample() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var patch = Patch()
        try patch.source(sourceAsset, channels: 2, frames: 2_000, in: directory)
        try patch.source(second, channels: 2, frames: 2_000, in: directory)
        let a = patch.graph.add(.audio, asset: sourceAsset)
        let b = patch.graph.add(.audio, asset: second)
        let mixer = patch.graph.add(.mixer)
        patch.wire(a, "out", to: mixer, "in1")
        patch.wire(b, "out", to: mixer, "in2")
        patch.bake("a", from: a)
        patch.bake("b", from: b)
        patch.bake("mix", from: mixer)

        let files = try await patch.render(in: directory)

        let (left, right, mix) = (try #require(files["a"]), try #require(files["b"]), try #require(files["mix"]))
        for channel in 0..<2 {
            #expect(mix[channel] == zip(left[channel], right[channel]).map(+))
        }
    }

    @Test func gainScalesTheMix() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var patch = Patch()
        try patch.source(sourceAsset, channels: 1, frames: 2_000, in: directory)
        let audio = patch.graph.add(.audio, asset: sourceAsset)
        let mixer = patch.graph.add(.mixer, ["gain": .number(-20 * log10(2))])   // −6.02 dB = half
        patch.wire(audio, "out", to: mixer, "in1")
        patch.bake("direct", from: audio)
        patch.bake("mix", from: mixer)

        let files = try await patch.render(in: directory)

        let direct = try #require(files["direct"]?[0])
        let mix = try #require(files["mix"]?[0])
        #expect(zip(direct, mix).allSatisfy { abs($0 * 0.5 - $1) < 1e-6 })
    }

    @Test func monoInputsSpreadIntoAStereoMix() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var patch = Patch()
        try patch.source(sourceAsset, channels: 1, frames: 2_000, in: directory)
        try patch.source(second, channels: 2, frames: 2_000, in: directory)
        let mono = patch.graph.add(.audio, asset: sourceAsset)
        let stereo = patch.graph.add(.audio, asset: second)
        let mixer = patch.graph.add(.mixer)
        patch.wire(mono, "out", to: mixer, "in1")
        patch.wire(stereo, "out", to: mixer, "in2")
        patch.bake("mono", from: mono)
        patch.bake("stereo", from: stereo)
        patch.bake("mix", from: mixer)

        let files = try await patch.render(in: directory)

        let monoSamples = try #require(files["mono"]?[0])
        let stereoSamples = try #require(files["stereo"])
        let mix = try #require(files["mix"])
        #expect(mix.count == 2)
        #expect(mix[1] == zip(monoSamples, stereoSamples[1]).map(+))
    }

    @Test func aShorterInputIsSilentPastItsEnd() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var patch = Patch()
        try patch.source(sourceAsset, channels: 1, frames: 1_000, in: directory)
        try patch.source(second, channels: 1, frames: 3_000, in: directory)
        let short = patch.graph.add(.audio, asset: sourceAsset)
        let long = patch.graph.add(.audio, asset: second)
        let mixer = patch.graph.add(.mixer)
        patch.wire(short, "out", to: mixer, "in1")
        patch.wire(long, "out", to: mixer, "in2")
        patch.bake("long", from: long)
        patch.bake("mix", from: mixer)

        let files = try await patch.render(in: directory)

        let mix = try #require(files["mix"]?[0])
        let longSamples = try #require(files["long"]?[0])
        #expect(mix.count == 3_000)
        #expect(Array(mix[1_000...]) == Array(longSamples[1_000...]))
    }

    @Test func gainModulationMovesTheLevel() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var patch = Patch()
        try patch.source(sourceAsset, channels: 1, frames: 4_800, in: directory)
        let audio = patch.graph.add(.audio, asset: sourceAsset)
        let lfo = patch.graph.add(.lfo, ["rate": .number(20)])
        let steady = patch.graph.add(.mixer)
        let moving = NodeID(testUUID(500))
        patch.graph.project.nodes.append(Node(id: moving, kind: .mixer, parameters: NodeCatalog.defaultParameters(for: .mixer), modulated: ["gain"]))
        patch.wire(audio, "out", to: steady, "in1")
        patch.wire(audio, "out", to: moving, "in1")
        patch.wire(lfo, "out", to: moving, "mod.gain")
        patch.bake("steady", from: steady)
        patch.bake("moving", from: moving)

        let files = try await patch.render(in: directory)

        #expect(files["steady"] != files["moving"])
    }

    @Test func chunkSizeNeverChangesTheMix() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var patch = Patch()
        try patch.source(sourceAsset, channels: 2, frames: 5_000, in: directory)
        try patch.source(second, channels: 1, frames: 3_000, in: directory)
        let a = patch.graph.add(.audio, asset: sourceAsset)
        let b = patch.graph.add(.audio, asset: second)
        let mixer = patch.graph.add(.mixer, ["gain": .number(-3)])
        patch.wire(a, "out", to: mixer, "in1")
        patch.wire(b, "out", to: mixer, "in2")
        patch.bake("mix", from: mixer)

        let whole = try await patch.render(in: directory, chunkFrames: 65_536)
        let chunked = try await patch.render(in: directory, chunkFrames: 777)

        #expect(whole == chunked)
    }

    @Test func sixteenInputsMix() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var patch = Patch()
        try patch.source(sourceAsset, channels: 1, frames: 1_000, in: directory)
        let audio = patch.graph.add(.audio, asset: sourceAsset)
        let mixer = patch.graph.add(.mixer, ["inputCount": .number(16)])
        for index in 1...16 { patch.wire(audio, "out", to: mixer, "in\(index)") }
        patch.bake("direct", from: audio)
        patch.bake("mix", from: mixer)

        let files = try await patch.render(in: directory)

        let direct = try #require(files["direct"]?[0])
        let mix = try #require(files["mix"]?[0])
        #expect(zip(direct, mix).allSatisfy { abs($0 * 16 - $1) < 1e-5 })
    }
}
