import Foundation
import Testing
@testable import BakeGraph
@testable import BakeRender

/// A problem inside a custom node shows on the card inside, and on the custom node named after it.
struct InsideIssuesTests {
    private func issues(_ project: ProjectFile) -> GraphIssues? {
        do {
            _ = try GraphCompiler.compile(project, assets: [sourceAsset: AssetInfo(frameCount: 48_000, channelCount: 2, sampleRate: 48_000)])
            return nil
        } catch {
            return GraphIssues(error, in: project)
        }
    }

    @Test func aLookaheadFilterInAFeedbackGroupIsMarkedInsideAndNamedOutside() throws {
        var graph = TestProject()
        let audio = graph.add(.audio, asset: sourceAsset)
        let filters = graph.add(.filters, ["phase": .choice("linear")])
        let distortion = graph.add(.distortion, ["oversampling": .choice("1")])
        let bake = graph.add(.print)
        graph.connect(audio, to: filters)
        graph.connect(filters, to: distortion)
        graph.connect(distortion, to: bake)
        var project = graph.project
        let made = project.makeFeedbackGroup([filters, distortion])
        let custom = try #require(made)
        let definition = try #require(project.node(custom)?.customDefinition)

        let found = try #require(issues(project))
        let inside = try #require(found.inside[definition])
        let message = "Can't run inside a feedback loop: it looks ahead in its input. Set Phase to Minimum, or move it outside the loop."
        #expect(inside.nodes[filters] == [message])
        #expect(inside.nodes[distortion] == nil)
        #expect(found.nodes[custom] == ["Filters: " + message])
        #expect(found.nodes[filters] == nil)
    }

    @Test func aMissingInputInsideIsMarkedOnItsPinInside() throws {
        var graph = TestProject()
        let audio = graph.add(.audio, asset: sourceAsset)
        let mixer = graph.add(.mixer)
        let vocoder = graph.add(.vocoder)
        let bake = graph.add(.print)
        graph.connect(audio, to: mixer, "in1")
        graph.project.edges.append(Edge(from: PinRef(node: mixer, pin: "out"), to: PinRef(node: vocoder, pin: "modulator")))
        graph.connect(vocoder, to: bake)
        var project = graph.project
        let grouped = project.groupNodes([mixer, vocoder])
        let custom = try #require(grouped)
        let definition = try #require(project.node(custom)?.customDefinition)

        let found = try #require(issues(project))
        let inside = try #require(found.inside[definition])
        #expect(inside.nodes[vocoder] == ["Needs an input."])
        #expect(inside.pins == [PinRef(node: vocoder, pin: "carrier")])
        #expect(found.nodes[custom] == ["Vocoder: Needs an input."])
        #expect(found.pins.isEmpty)
    }

    @Test func problemsOutsideCustomNodesAreAsBefore() throws {
        var graph = TestProject()
        let filters = graph.add(.filters)
        let bake = graph.add(.print)
        graph.connect(filters, to: bake)
        let found = try #require(issues(graph.project))
        #expect(found.nodes[filters] == ["Needs an input."])
        #expect(found.inside.isEmpty)
    }

    @Test func aBakeOrPreviewInsideACustomNodeIsRefused() throws {
        var graph = TestProject()
        let audio = graph.add(.audio, asset: sourceAsset)
        let filters = graph.add(.filters)
        let bake = graph.add(.print)
        graph.connect(audio, to: filters)
        graph.connect(filters, to: bake)
        var project = graph.project
        let grouped = project.groupNodes([filters])
        let custom = try #require(grouped)
        // A hand-made or imported definition could still hold one.
        project.customNodes[0].nodes.append(Node(kind: .preview))
        #expect(throws: CompileFailure(errors: [.outputInCustomNode(custom)])) {
            try GraphCompiler.compile(project, assets: [sourceAsset: AssetInfo(frameCount: 48_000, channelCount: 2, sampleRate: 48_000)])
        }
        #expect(!project.canGroup([bake]))
    }
}
