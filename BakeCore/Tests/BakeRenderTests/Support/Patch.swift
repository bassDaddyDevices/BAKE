import Foundation
import Testing
@testable import BakeGraph
@testable import BakeRender

/// A render graph built pin by pin, with named 32-bit float Bake nodes, for end-to-end tests.
struct Patch {
    var graph = TestProject()
    var assets: [AssetID: URL] = [:]
    var bakes: [String: NodeID] = [:]

    mutating func wire(_ source: NodeID, _ sourcePin: PinID, to target: NodeID, _ pin: PinID = "in") {
        graph.project.edges.append(Edge(from: PinRef(node: source, pin: sourcePin), to: PinRef(node: target, pin: pin)))
    }

    /// A 32-bit float Bake node called `name`, fed from `source.sourcePin`.
    mutating func bake(_ name: String, from source: NodeID, _ sourcePin: PinID = "out") {
        let node = graph.add(.print, ["bitDepth": .choice("32f"), "prefix": .text(name)])
        wire(source, sourcePin, to: node)
        bakes[name] = node
    }

    /// Writes TestAudio.samples as a source file for `asset` and registers it.
    mutating func source(_ asset: AssetID, channels: Int, frames: Int, in directory: URL) throws {
        let url = directory.appendingPathComponent("source-\(asset.rawValue.uuidString).wav")
        try TestAudio.write(TestAudio.samples(frames: frames, channels: channels), to: url, sampleRate: 48_000)
        assets[asset] = url
    }

    /// Renders every Bake node and returns each file's samples by name.
    func render(in directory: URL, chunkFrames: Int = 4_096) async throws -> [String: [[Float]]] {
        let output = directory.appendingPathComponent("out-\(chunkFrames)", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let plan = try compile(graph.project, assetURLs: assets)
        let result = try await RenderEngine.render(
            RenderRequest(plan: plan, assetURLs: assets, outputDirectory: output, chunkFrames: chunkFrames)
        )
        var decoded: [String: [[Float]]] = [:]
        for (name, node) in bakes {
            decoded[name] = try TestAudio.read(try #require(result.outputs[node])).samples
        }
        return decoded
    }
}
