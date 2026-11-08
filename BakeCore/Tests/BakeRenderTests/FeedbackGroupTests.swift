import Foundation
import Testing
@testable import BakeGraph
@testable import BakeRender

/// Make Feedback Group (issue 004): a chain inside a feedback loop, as one custom node.
struct FeedbackGroupTests {
    /// Audio → Filters → Distortion → Bake, with an LFO on the Filters' Cutoff; both causal, so they
    /// can sit in a loop.
    private struct Patch {
        var graph = TestProject()
        let audio, lfo, filters, distortion, bake: NodeID

        init() {
            audio = graph.add(.audio, asset: sourceAsset)
            lfo = graph.add(.lfo, ["rate": .number(2)])
            filters = graph.add(.filters, ["cutoff": .number(900), "phase": .choice("minimum")], modulated: ["cutoff"])
            distortion = graph.add(.distortion, ["drive": .number(9), "oversampling": .choice("1")])
            bake = graph.add(.print, ["bitDepth": .choice("32f")])
            graph.connect(audio, to: filters)
            graph.connect(lfo, to: filters, "mod.cutoff")
            graph.connect(filters, to: distortion)
            graph.connect(distortion, to: bake)
            for (index, id) in [audio, lfo, filters, distortion, bake].enumerated() {
                graph.project.nodes[graph.project.index(of: id)!].position = CanvasPoint(x: Double(index) * 300, y: 100)
            }
        }
    }

    private func bake(_ project: ProjectFile, _ bake: NodeID) async throws -> [[Float]] {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.wav")
        try TestAudio.write(TestAudio.samples(frames: 12_000, channels: 2), to: source, sampleRate: 48_000)
        let output = directory.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let urls = [sourceAsset: source]
        let request = RenderRequest(plan: try compile(project, assetURLs: urls), assetURLs: urls, outputDirectory: output, chunkFrames: 777)
        return try TestAudio.read(try #require(try await RenderEngine.render(request).outputs[bake])).samples
    }

    @Test func aFeedbackGroupBakesLikeTheSameLoopWiredByHand() async throws {
        let patch = Patch()
        var grouped = patch.graph.project
        let made = grouped.makeFeedbackGroup([patch.filters, patch.distortion])
        let custom = try #require(made)
        #expect(grouped.node(custom)?.kind == .custom)
        let node = try #require(grouped.node(custom))
        #expect(grouped.definition(of: node)?.name == "Feedback 1")

        // By hand: Audio → Feedback → Filters → Distortion → Bake, Distortion back into Return.
        var direct = patch.graph.project
        let feedback = direct.addNode(.feedback, at: CanvasPoint())
        direct.edges.removeAll { $0.to == PinRef(node: patch.filters, pin: "in") }
        try direct.connect(from: PinRef(node: patch.audio, pin: "out"), to: PinRef(node: feedback, pin: "in"))
        try direct.connect(from: PinRef(node: feedback, pin: "out"), to: PinRef(node: patch.filters, pin: "in"))
        try direct.connect(from: PinRef(node: patch.distortion, pin: "out"), to: PinRef(node: feedback, pin: "return"))
        #expect(direct.feedbackLoops().count == 1)

        let groupedSound = try await bake(grouped, patch.bake)
        #expect(try await groupedSound == bake(direct, patch.bake))
        // The loop rings on past the source: the Feedback node's tail.
        #expect(try await groupedSound.first?.count ?? 0 > bake(patch.graph.project, patch.bake).first?.count ?? 0)
    }

    @Test func theLoopsMainControlsAreOnTheCard() throws {
        let patch = Patch()
        var project = patch.graph.project
        let made = project.makeFeedbackGroup([patch.filters, patch.distortion])
        let custom = try #require(made)
        let node = try #require(project.node(custom))
        #expect(NodeCatalog.visibleParameters(of: node, in: project).map(\.name) == ["Feedback", "Delay", "Drive"])
        // Pins: the audio in (through the Feedback node), the LFO's Cutoff, and the chain's end out.
        let pins = NodeCatalog.pins(of: node, in: project)
        #expect(pins.filter { $0.direction == .input }.map(\.signal) == [.audio, .control])
        #expect(pins.filter { $0.direction == .output }.count == 1)
    }

    @Test func ungroupingLeavesTheLoopOnTheCanvas() throws {
        let patch = Patch()
        var project = patch.graph.project
        let made = project.makeFeedbackGroup([patch.filters, patch.distortion])
        let custom = try #require(made)
        let restored = project.ungroup(custom)
        #expect(restored.count == 3)
        let loops = project.feedbackLoops()
        #expect(loops.count == 1)
        #expect(loops.first?.members.isSuperset(of: [patch.filters, patch.distortion]) == true)
    }

    @Test func aLoopCantBeCutInTwoByGrouping() throws {
        let patch = Patch()
        var project = patch.graph.project
        let feedback = project.addNode(.feedback, at: CanvasPoint())
        project.edges.removeAll { $0.to == PinRef(node: patch.filters, pin: "in") }
        try project.connect(from: PinRef(node: patch.audio, pin: "out"), to: PinRef(node: feedback, pin: "in"))
        try project.connect(from: PinRef(node: feedback, pin: "out"), to: PinRef(node: patch.filters, pin: "in"))
        try project.connect(from: PinRef(node: patch.distortion, pin: "out"), to: PinRef(node: feedback, pin: "return"))
        #expect(!project.canGroup([patch.filters]))
        #expect(!project.canGroup([feedback, patch.filters]))
        #expect(project.canGroup([feedback, patch.filters, patch.distortion]))
        #expect(project.canGroup([patch.lfo]))
        // A chain that already has its own Feedback node isn't made into another loop.
        #expect(!project.canMakeFeedbackGroup([feedback, patch.filters, patch.distortion]))
        // Nor is one with no audio going in.
        #expect(!project.canMakeFeedbackGroup([patch.lfo]))
    }

    @Test func aGroupedLoopBakesLikeTheLoopOnTheCanvas() async throws {
        let patch = Patch()
        var project = patch.graph.project
        let feedback = project.addNode(.feedback, at: CanvasPoint())
        project.edges.removeAll { $0.to == PinRef(node: patch.filters, pin: "in") }
        try project.connect(from: PinRef(node: patch.audio, pin: "out"), to: PinRef(node: feedback, pin: "in"))
        try project.connect(from: PinRef(node: feedback, pin: "out"), to: PinRef(node: patch.filters, pin: "in"))
        try project.connect(from: PinRef(node: patch.distortion, pin: "out"), to: PinRef(node: feedback, pin: "return"))
        var grouped = project
        #expect(grouped.groupNodes([feedback, patch.filters, patch.distortion]) != nil)
        #expect(try await bake(grouped, patch.bake) == bake(project, patch.bake))
    }
}
