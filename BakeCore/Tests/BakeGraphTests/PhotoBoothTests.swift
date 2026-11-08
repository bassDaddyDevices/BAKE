import Foundation
import Testing
@testable import BakeGraph

/// Photo Booth's chunks and its place in a batch.
struct PhotoBoothTests {
    private let rate = 48_000.0

    private func values(_ parameters: [ParameterID: ParameterValue] = [:]) -> [ParameterID: ParameterValue] {
        NodeCatalog.resolvedParameters(of: Node(kind: .photoBooth, parameters: parameters))
    }

    @Test func noteValuesAreBeatsAtTheBPM() {
        #expect(PhotoBoothChunks.frames(of: "1/4", milliseconds: 0, bpm: 120, sampleRate: rate) == 24_000)
        #expect(PhotoBoothChunks.frames(of: "1/1", milliseconds: 0, bpm: 120, sampleRate: rate) == 96_000)
        #expect(PhotoBoothChunks.frames(of: "1/16", milliseconds: 0, bpm: 90, sampleRate: rate) == 8_000)
        #expect(PhotoBoothChunks.frames(of: "ms", milliseconds: 125, bpm: 120, sampleRate: rate) == 6_000)
    }

    @Test func theGridTilesTheInputUntilNext() {
        let frames = 4 * 48_000
        let starts = PhotoBoothChunks.gridStarts(frames: frames, parameters: values(), sampleRate: rate)
        #expect(starts == (0..<8).map { $0 * 24_000 })
        #expect(starts.allSatisfy { PhotoBoothChunks.isGridBang($0, period: 24_000) })
        #expect(!PhotoBoothChunks.isGridBang(24_001, period: 24_000))
        let chunks = PhotoBoothChunks.chunks(starts: starts, frames: frames, parameters: values(), sampleRate: rate)
        #expect(chunks == (0..<8).map { $0 * 24_000..<($0 + 1) * 24_000 })
        #expect(PhotoBoothChunks.gridCount(frames: frames, parameters: values(), sampleRate: rate) == 8)
        // A fractional period (10.01 ms = 480.48 frames) rounds each bang, not the period, so the grid never drifts.
        let odd = values(["every": .choice("ms"), "everyMs": .number(10.01)])
        let gaps = zip(PhotoBoothChunks.gridStarts(frames: 48_000, parameters: odd, sampleRate: rate).dropFirst(),
                       PhotoBoothChunks.gridStarts(frames: 48_000, parameters: odd, sampleRate: rate)).map { $0 - $1 }
        #expect(Set(gaps).isSubset(of: [480, 481]))
    }

    @Test func fixedChunksHaveTheirOwnLengthAndShortOnesAreSkipped() {
        let fixed = values(["length": .choice("fixed"), "fixedLength": .choice("1/16")])
        let chunks = PhotoBoothChunks.chunks(starts: [0, 24_000, 48_000], frames: 50_000, parameters: fixed, sampleRate: rate)
        #expect(chunks == [0..<6_000, 24_000..<30_000, 48_000..<50_000])
        // Triggers 5 ms apart: the first chunk is shorter than Min Length (10 ms) and is skipped.
        let close = PhotoBoothChunks.chunks(starts: [0, 240, 48_000], frames: 96_000, parameters: values(), sampleRate: rate)
        #expect(close == [240..<48_000, 48_000..<96_000])
    }

    @Test func risesAreTheBangs() {
        #expect(PhotoBoothChunks.rises([1, 1, 0, 0, 0.6, 0.6, 0.5, 0.9]) == [0, 4, 7])
    }

    private struct Patch {
        var project = ProjectFile()
        let audio: NodeID, clock: NodeID, booth: NodeID, bake: NodeID
    }

    /// Audio (groove.wav) → Photo Booth ← Clock, → Filters → Batch Bake.
    private func patch() throws -> Patch {
        var project = ProjectFile()
        let audio = project.addNode(.audio, at: CanvasPoint())
        let clock = project.addNode(.clock, at: CanvasPoint())
        let booth = project.addNode(.photoBooth, at: CanvasPoint())
        let filters = project.addNode(.filters, at: CanvasPoint())
        let bake = project.addNode(.batchBake, at: CanvasPoint())
        project.assignAudio(path: "/loops/groove.wav", bookmark: nil, to: audio)
        try project.connect(from: PinRef(node: audio, pin: "out"), to: PinRef(node: booth, pin: "in"))
        try project.connect(from: PinRef(node: clock, pin: "out"), to: PinRef(node: booth, pin: "trigger"))
        try project.connect(from: PinRef(node: booth, pin: "out"), to: PinRef(node: filters, pin: "in"))
        try project.connect(from: PinRef(node: filters, pin: "out"), to: PinRef(node: bake, pin: "in"))
        return Patch(project: project, audio: audio, clock: clock, booth: booth, bake: bake)
    }

    @Test func theCaptureRecordsTheInputAndTheTriggerAndNothingElse() throws {
        let patch = try patch()
        let run = BatchRun(project: patch.project, files: [:])
        #expect(run.photoBooths == [patch.booth])
        let capture = try #require(run.photoBoothCapture())
        let (input, trigger) = BatchRun.boothCaptures(of: patch.booth)
        #expect(Set(capture.nodes.filter(\.kind.isOutput).map(\.id)) == [input, trigger])
        #expect(capture.edges.contains(Edge(from: PinRef(node: patch.audio, pin: "out"), to: PinRef(node: input, pin: "in"))))
        #expect(capture.edges.contains(Edge(from: PinRef(node: patch.booth, pin: "out"), to: PinRef(node: trigger, pin: "in"))))
        #expect(capture.edges.filter { $0.from.node == patch.booth }.count == 1)
        #expect(capture.node(patch.booth)?.parameters["capture"] == .choice("on"))
        #expect(run.boothStem(of: patch.booth) == "groove")
    }

    @Test func eachPassPlaysAChunkWithItsWiresCut() throws {
        let patch = try patch()
        let chunks = (1...3).map { BatchFile(path: "/tmp/groove-00\($0).wav") }
        let run = BatchRun(project: patch.project, files: [patch.booth: chunks])
        #expect(run.passCount == 3)
        let pass = run.pass(1)
        #expect(pass.node(patch.booth)?.kind == .audio)
        #expect(!pass.edges.contains { $0.to.node == patch.booth })
        #expect(run.fileName(of: patch.bake, pass: 1) == "groove-002")
        #expect(run.issues().isEmpty)
    }

    @Test func aBatchIntoAPhotoBoothIsAnIssue() throws {
        var project = ProjectFile()
        let folder = project.addNode(.batchAudio, at: CanvasPoint())
        let booth = project.addNode(.photoBooth, at: CanvasPoint())
        let bake = project.addNode(.batchBake, at: CanvasPoint())
        project.setSourceFolder(FileReference(lastKnownPath: "/loops"), for: folder)
        try project.connect(from: PinRef(node: folder, pin: "out"), to: PinRef(node: booth, pin: "in"))
        try project.connect(from: PinRef(node: booth, pin: "out"), to: PinRef(node: bake, pin: "in"))
        let run = BatchRun(project: project, files: [folder: [BatchFile(path: "/loops/a.wav")]])
        #expect(run.issues().contains(.batchIntoPhotoBooth(booth)))
    }
}

struct PhotoBoothWaitTests {
    @Test func aBatchBakeWaitsOnAWiredTriggerUntilItsChunksAreKnown() throws {
        var project = ProjectFile()
        let booth = project.addNode(.photoBooth, at: CanvasPoint())
        let clock = project.addNode(.clock, at: CanvasPoint())
        let bake = project.addNode(.batchBake, at: CanvasPoint())
        try project.connect(from: PinRef(node: clock, pin: "out"), to: PinRef(node: booth, pin: "trigger"))
        try project.connect(from: PinRef(node: booth, pin: "out"), to: PinRef(node: bake, pin: "in"))
        #expect(BatchRun(project: project, files: [:]).waitsForTriggers(bake))
        #expect(!BatchRun(project: project, files: [booth: [BatchFile(path: "/tmp/a-001.wav")]]).waitsForTriggers(bake))
        project.edges.removeAll { $0.to.pin == "trigger" }
        #expect(!BatchRun(project: project, files: [:]).waitsForTriggers(bake))
    }
}
