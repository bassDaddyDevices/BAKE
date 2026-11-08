import Testing
@testable import BakeGraph

/// A batch through a Combinatorial Matrix: one pass per combination of its inputs' batches.
struct MatrixBatchRunTests {
    private struct Patch {
        var project = ProjectFile()
        let clicks: NodeID, subs: NodeID, room: NodeID, matrix: NodeID, bake: NodeID
    }

    /// Batch Audio (clicks) → A, Batch Audio (subs) → B, a plain Audio (room) → C; Matrix → Filters → Batch Bake.
    private func patch() throws -> Patch {
        var project = ProjectFile()
        let clicks = project.addNode(.batchAudio, at: CanvasPoint())
        let subs = project.addNode(.batchAudio, at: CanvasPoint())
        let room = project.addNode(.audio, at: CanvasPoint())
        let matrix = project.addNode(.combinatorialMatrix, at: CanvasPoint())
        let filters = project.addNode(.filters, at: CanvasPoint())
        let bake = project.addNode(.batchBake, at: CanvasPoint())
        project.setSourceFolder(FileReference(lastKnownPath: "/clicks"), for: clicks)
        project.setSourceFolder(FileReference(lastKnownPath: "/subs"), for: subs)
        project.assignAudio(path: "/room.wav", bookmark: nil, to: room)
        try project.connect(from: PinRef(node: clicks, pin: "out"), to: PinRef(node: matrix, pin: "a"))
        try project.connect(from: PinRef(node: subs, pin: "out"), to: PinRef(node: matrix, pin: "b"))
        try project.connect(from: PinRef(node: room, pin: "out"), to: PinRef(node: matrix, pin: "c"))
        try project.connect(from: PinRef(node: matrix, pin: "out"), to: PinRef(node: filters, pin: "in"))
        try project.connect(from: PinRef(node: filters, pin: "out"), to: PinRef(node: bake, pin: "in"))
        return Patch(project: project, clicks: clicks, subs: subs, room: room, matrix: matrix, bake: bake)
    }

    private let clicks = ["/clicks/c1.wav", "/clicks/c2.wav"].map { BatchFile(path: $0) }
    private let subs = ["/subs/s1.wav", "/subs/s2.wav", "/subs/s3.wav"].map { BatchFile(path: $0) }

    private func path(of node: NodeID, in pass: ProjectFile) -> String? {
        pass.assets.first { $0.id == pass.node(node)?.assetID }?.lastKnownPath
    }

    @Test func thePassesAreEveryCombinationWithCChangingFastest() throws {
        let patch = try patch()
        let run = BatchRun(project: patch.project, files: [patch.clicks: clicks, patch.subs: subs])
        #expect(run.axisCounts == [2, 3, 1])
        #expect(run.passCount == 6)
        let played = (0..<6).map { index in
            let pass = run.pass(index)
            return [path(of: patch.clicks, in: pass), path(of: patch.subs, in: pass)]
        }
        #expect(played == [
            ["/clicks/c1.wav", "/subs/s1.wav"], ["/clicks/c1.wav", "/subs/s2.wav"], ["/clicks/c1.wav", "/subs/s3.wav"],
            ["/clicks/c2.wav", "/subs/s1.wav"], ["/clicks/c2.wav", "/subs/s2.wav"], ["/clicks/c2.wav", "/subs/s3.wav"],
        ])
        // The plain Audio on C is in every combination, and the matrix knows which one it is rendering.
        #expect((0..<6).allSatisfy { run.pass($0).node(patch.room)?.kind == .audio })
        #expect(run.pass(4).node(patch.matrix)?.parameters["combination"] == .number(4))
    }

    @Test func aSourceNameAfterTheMatrixIsTheCombination() throws {
        let patch = try patch()
        let run = BatchRun(project: patch.project, files: [patch.clicks: clicks, patch.subs: subs])
        #expect((0..<6).map { run.fileName(of: patch.bake, pass: $0) } == ["c1+s1", "c1+s2", "c1+s3", "c2+s1", "c2+s2", "c2+s3"])
        #expect(run.issues().isEmpty)
    }

    @Test func aMatrixOfPlainAudioIsNoBatch() throws {
        var project = ProjectFile()
        let one = project.addNode(.audio, at: CanvasPoint())
        let matrix = project.addNode(.combinatorialMatrix, at: CanvasPoint())
        let bake = project.addNode(.print, at: CanvasPoint())
        try project.connect(from: PinRef(node: one, pin: "out"), to: PinRef(node: matrix, pin: "a"))
        try project.connect(from: PinRef(node: matrix, pin: "out"), to: PinRef(node: bake, pin: "in"))
        let run = BatchRun(project: project, files: [:])
        #expect(run.passCount == 0 && !run.hasBatch && run.issues().isEmpty)
    }

    @Test func tooManyCombinationsAndASecondMatrixAreIssues() throws {
        var patch = try patch()
        let many = (0..<101).map { BatchFile(path: "/many/\($0).wav") }
        let crowded = BatchRun(project: patch.project, files: [patch.clicks: many, patch.subs: many])
        #expect(crowded.passCount == 10_201)
        #expect(crowded.issues() == [.tooManyCombinations(patch.matrix)])

        let second = patch.project.addNode(.combinatorialMatrix, at: CanvasPoint())
        let other = patch.project.addNode(.batchBake, at: CanvasPoint())
        try patch.project.connect(from: PinRef(node: patch.subs, pin: "out"), to: PinRef(node: second, pin: "a"))
        try patch.project.connect(from: PinRef(node: second, pin: "out"), to: PinRef(node: other, pin: "in"))
        let run = BatchRun(project: patch.project, files: [patch.clicks: clicks, patch.subs: subs])
        #expect(run.issues().contains(.twoMatrices(second)))
    }
}
