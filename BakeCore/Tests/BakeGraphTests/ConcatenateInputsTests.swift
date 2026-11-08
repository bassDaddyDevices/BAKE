import Testing
@testable import BakeGraph

/// Concatenate's several inputs: the join plan, the length, and the migration of saved wires.
struct ConcatenateInputsTests {
    @Test func theJoinPlanPlacesEachClip() {
        let plain = JoinPlan(lengths: [100, 200, 50], gapFrames: 0, crossfadeFrames: 0)
        #expect(plain.starts == [0, 100, 300] && plain.total == 350)
        let gapped = JoinPlan(lengths: [100, 200, 50], gapFrames: 10, crossfadeFrames: 40)  // a Gap turns crossfades off
        #expect(gapped.starts == [0, 110, 320] && gapped.holds == [0, 0, 0] && gapped.total == 370)
        let faded = JoinPlan(lengths: [100, 200, 50], gapFrames: 0, crossfadeFrames: 40)
        #expect(faded.holds == [40, 25, 0])  // at most half of either neighbour: 50 / 2 = 25
        #expect(faded.starts == [0, 60, 235] && faded.total == 285)
    }

    @Test func withoutABatchItsLengthIsItsInputsJoined() throws {
        var project = ProjectFile()
        let join = project.addNode(.concatenate, at: CanvasPoint())
        let bake = project.addNode(.print, at: CanvasPoint())
        var sources: [NodeID] = []
        for seconds in [1.0, 0.5, 0.25] {
            let generator = project.addNode(.generator, at: CanvasPoint())
            project.setParameter("length", of: generator, to: .number(seconds))
            sources.append(generator)
        }
        project.setParameter("crossfade", of: join, to: .number(0))
        for (index, source) in sources.enumerated() {
            try project.connect(from: PinRef(node: source, pin: "out"), to: PinRef(node: join, pin: PinID("in\(index + 1)")))
        }
        try project.connect(from: PinRef(node: join, pin: "out"), to: PinRef(node: bake, pin: "in"))
        let run = BatchRun(project: project, files: [:])
        #expect(run.gathers.isEmpty && !run.hasBatch && run.issues().isEmpty)
        let shapes = GraphCompiler.previewShapes(project, assets: [:])
        #expect(shapes[join]?.frames == 48_000 + 24_000 + 12_000)
    }

    @Test func aSavedConcatenatesWireMovesToInOne() throws {
        var project = ProjectFile()
        let source = project.addNode(.generator, at: CanvasPoint())
        let join = project.addNode(.concatenate, at: CanvasPoint())
        let mixer = project.addNode(.mixer, at: CanvasPoint())
        project.edges = [
            Edge(from: PinRef(node: source, pin: "out"), to: PinRef(node: join, pin: "in")),
            Edge(from: PinRef(node: join, pin: "out"), to: PinRef(node: mixer, pin: "in1")),
        ]
        project.schemaVersion = 10
        ProjectMigration.migrate(&project)
        #expect(project.edges[0].to == PinRef(node: join, pin: "in1"))
        #expect(project.edges[1].to == PinRef(node: mixer, pin: "in1"))
        #expect(project.schemaVersion == ProjectFile.currentSchemaVersion)
    }
}
