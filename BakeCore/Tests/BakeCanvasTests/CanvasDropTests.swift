import BakeGraph
import Foundation
import Testing
@testable import BakeCanvas

@MainActor
struct CanvasDropTests {
    /// A minimal RIFF/WAVE file.
    private func wav(at url: URL) throws {
        func le32(_ value: UInt32) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }
        var body = Data("WAVE".utf8)
        body += Data("fmt ".utf8) + le32(16) + Data(repeating: 1, count: 16)
        body += Data("data".utf8) + le32(4) + Data(repeating: 0, count: 4)
        try (Data("RIFF".utf8) + le32(UInt32(body.count)) + body).write(to: url)
    }

    @Test func aBakedWAVOpensItsPatchAndAPlainOneBecomesAnAudioNode() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let baked = folder.appendingPathComponent("baked.wav"), plain = folder.appendingPathComponent("plain.wav")
        try wav(at: baked)
        try wav(at: plain)
        var project = ProjectFile()
        let bake = project.addNode(.print, at: CanvasPoint())
        try BakedWorkflow(bakeNode: bake, project: project).append(toWAV: baked)

        var opened: BakedWorkflow?
        var added: (URL, CanvasPoint)?
        let actions = NodeActions(openWorkflow: { opened = $0 }, addAudio: { added = ($0, $1) })
        // Panned by (100, 50) at scale 2: view (300, 250) is world (100, 100).
        let viewport = Viewport(offset: CGPoint(x: 100, y: 50), scale: 2)

        #expect(CanvasDrop.handle(baked, atView: CGPoint(x: 300, y: 250), viewport: viewport, actions: actions))
        #expect(opened?.project == project && opened?.bakeNode == bake && added == nil)

        opened = nil
        #expect(CanvasDrop.handle(plain, atView: CGPoint(x: 300, y: 250), viewport: viewport, actions: actions))
        #expect(opened == nil && added?.0 == plain && added?.1 == CanvasPoint(x: 60, y: 80))
    }

    @Test func aDroppedCustomNodeFileIsAddedWhereItLands() {
        var dropped: (URL, CanvasPoint)?
        var actions = NodeActions(addAudio: { _, _ in Issue.record("not audio") })
        actions.addCustomNodeFile = { dropped = ($0, $1) }
        let url = URL(filePath: "/tmp/Crunch.bakenode")
        let viewport = Viewport(offset: CGPoint(x: 100, y: 50), scale: 2)
        #expect(CanvasDrop.handle(url, atView: CGPoint(x: 300, y: 250), viewport: viewport, actions: actions))
        #expect(dropped?.0 == url)
        #expect(dropped?.1 == CanvasPoint(x: 100 - Double(NodeLayout.width) / 2, y: 80))
    }

    @Test func addingFromAFileTwiceUsesOneDefinition() {
        let model = CanvasModel()
        var project = ProjectFile()
        let file = CustomNodeFile(definition: CustomNodeDefinition(name: "Crunch"), from: ProjectFile())
        model.addCustomNode(from: file, at: CanvasPoint(), in: &project)
        model.addCustomNode(from: file, at: CanvasPoint(x: 300), in: &project)
        #expect(project.customNodes.count == 1)
        #expect(project.nodes.filter { $0.kind == .custom }.count == 2)
        #expect(model.selection == [project.nodes[1].id])
    }
}
