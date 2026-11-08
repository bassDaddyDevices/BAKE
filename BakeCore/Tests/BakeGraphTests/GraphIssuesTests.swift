import Testing
@testable import BakeGraph

struct GraphIssuesTests {
    private func issues(_ project: ProjectFile) -> GraphIssues {
        do {
            _ = try GraphCompiler.compile(project)
            return GraphIssues()
        } catch {
            return GraphIssues(error, in: project)
        }
    }

    @Test func aGraphWithoutPrintSaysSo() {
        var project = ProjectFile()
        project.addNode(.lfo, at: CanvasPoint())
        #expect(issues(project).general == ["Add a Bake node — nothing would be baked."])
    }

    @Test func missingInputsMarkTheNodeAndPin() {
        var project = ProjectFile()
        let print = project.addNode(.print, at: CanvasPoint())
        let found = issues(project)
        #expect(found.nodes[print] == ["Needs an input."])
        #expect(found.pins == [PinRef(node: print, pin: "in")])
    }

    @Test func audioNodesWithoutAFileSayWhatToDo() throws {
        var project = ProjectFile()
        let audio = project.addNode(.audio, at: CanvasPoint())
        let print = project.addNode(.print, at: CanvasPoint())
        try project.connect(from: PinRef(node: audio, pin: "out"), to: PinRef(node: print, pin: "in"))
        #expect(issues(project).nodes[audio] == ["No audio file — drop one on this node or choose one."])

        project.assignAudio(path: "/gone/kick.wav", bookmark: nil, to: audio)
        #expect(issues(project).nodes[audio] == ["Can't find “kick.wav” — choose the file again."])
    }

    @Test func addingTheSameMessageTwiceKeepsOne() {
        var found = GraphIssues()
        let node = NodeID()
        found.add("Needs an input.", to: node)
        found.add("Needs an input.", to: node)
        #expect(found.nodes[node] == ["Needs an input."])
        #expect(!found.isEmpty)
    }
}
