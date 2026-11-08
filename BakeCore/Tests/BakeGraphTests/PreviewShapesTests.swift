import Testing
@testable import BakeGraph

struct PreviewShapesTests {
    @Test func everyNodeGetsALengthEvenWithoutABake() throws {
        var project = ProjectFile()
        let audio = project.addNode(.audio, at: CanvasPoint())
        let stretch = project.addNode(.stretch, at: CanvasPoint())
        let assigned = project.assignAudio(path: "/x/a.wav", bookmark: nil, to: audio)
        let asset = try #require(assigned)
        project.setParameter("ratio", of: stretch, to: .number(500))
        try project.connect(from: PinRef(node: audio, pin: "out"), to: PinRef(node: stretch, pin: "in"))

        // No Print node: nothing would bake, but the canvas still shows what each node makes.
        let shapes = GraphCompiler.previewShapes(project, assets: [asset: AssetInfo(frameCount: 96_000, channelCount: 2, sampleRate: 48_000)])

        #expect(shapes[audio] == SignalShape(frames: 96_000, channels: 2))
        #expect(shapes[stretch] == SignalShape(frames: 48_000_000, channels: 2))
    }

    @Test func nodesThatCantResolveAreLeftOut() {
        var project = ProjectFile()
        let filters = project.addNode(.filters, at: CanvasPoint())
        #expect(GraphCompiler.previewShapes(project, assets: [:])[filters] == nil)
    }
}
