import AVFAudio
import BakeGraph
import Foundation
import Testing
@testable import BakeSession

@MainActor
struct BakeSessionTests {
    private let access = PlainFileAccess()

    private struct Chain {
        var project: ProjectFile
        let audio: NodeID, filters: NodeID, resonator: NodeID, print: NodeID
    }

    /// Audio → Filters (LFO on cutoff) → Resonator → Print, writing into `folder`.
    private func chain(source: URL, folder: URL?) throws -> Chain {
        var project = ProjectFile()
        let audio = project.addNode(.audio, at: CanvasPoint())
        let lfo = project.addNode(.lfo, at: CanvasPoint())
        let filters = project.addNode(.filters, at: CanvasPoint())
        let resonator = project.addNode(.resonator, at: CanvasPoint())
        let print = project.addNode(.print, at: CanvasPoint())
        project.assignAudio(path: source.path(percentEncoded: false), bookmark: try access.bookmark(for: source, writable: false), to: audio)
        project.setModulated("cutoff", of: filters, true)
        try project.connect(from: PinRef(node: audio, pin: "out"), to: PinRef(node: filters, pin: "in"))
        try project.connect(from: PinRef(node: lfo, pin: "out"), to: PinRef(node: filters, pin: "mod.cutoff"))
        try project.connect(from: PinRef(node: filters, pin: "out"), to: PinRef(node: resonator, pin: "in"))
        try project.connect(from: PinRef(node: resonator, pin: "out"), to: PinRef(node: print, pin: "in"))
        if let folder {
            project.settings.printFolder = FileReference(lastKnownPath: folder.path(percentEncoded: false), bookmark: try access.bookmark(for: folder, writable: true))
        }
        return Chain(project: project, audio: audio, filters: filters, resonator: resonator, print: print)
    }

    private func bake(_ project: ProjectFile) async -> BakeState {
        let session = BakeSession(access: access)
        session.bake(project)
        await session.waitUntilFinished()
        return session.state
    }

    @Test func bakingWritesThePrintFile() async throws {
        let folder = try makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appending(path: "source.wav")
        try writeSine(to: source, seconds: 0.5)
        let output = folder.appending(path: "out", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        let state = await bake(try chain(source: source, folder: output).project)

        guard case .finished(let outputs) = state else { Issue.record("expected finished, got \(state)"); return }
        let written = try #require(outputs.first)
        #expect(written.lastPathComponent == "bake.wav")
        #expect(try AVAudioFile(forReading: written).length == 24_000)
    }

    @Test func aBakeNodeWithoutAnyFolderIsMarked() async throws {
        let folder = try makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appending(path: "source.wav")
        try writeSine(to: source, seconds: 0.1)
        let built = try chain(source: source, folder: nil)

        let state = await bake(built.project)

        guard case .failed(let issues) = state else { Issue.record("expected failed, got \(state)"); return }
        #expect(issues.nodes[built.print] == ["Choose a folder for this Bake node, or a default folder in the toolbar."])
    }

    @Test func aNodeFolderOverridesTheDefault() async throws {
        let folder = try makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appending(path: "source.wav")
        try writeSine(to: source, seconds: 0.1)
        let shared = folder.appending(path: "shared", directoryHint: .isDirectory)
        let own = folder.appending(path: "own", directoryHint: .isDirectory)
        for url in [shared, own] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        var built = try chain(source: source, folder: shared)
        built.project.setOutputFolder(FileReference(lastKnownPath: own.path(percentEncoded: false), bookmark: try access.bookmark(for: own, writable: true)), for: built.print)

        let state = await bake(built.project)

        guard case .finished = state else { Issue.record("expected finished, got \(state)"); return }
        #expect(try FileManager.default.contentsOfDirectory(atPath: own.path(percentEncoded: false)) == ["bake.wav"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: shared.path(percentEncoded: false)).isEmpty)
    }

    @Test func bakingOneNodeWritesOnlyItsFile() async throws {
        let folder = try makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appending(path: "source.wav")
        try writeSine(to: source, seconds: 0.1)
        let output = folder.appending(path: "out", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var built = try chain(source: source, folder: output)
        let other = built.project.addNode(.print, at: CanvasPoint())
        built.project.setParameter("prefix", of: other, to: .text("other"))
        try built.project.connect(from: PinRef(node: built.audio, pin: "out"), to: PinRef(node: other, pin: "in"))
        let session = BakeSession(access: access)

        session.bake(built.project, only: other)
        await session.waitUntilFinished()

        guard case .finished = session.state else { Issue.record("expected finished, got \(session.state)"); return }
        #expect(try FileManager.default.contentsOfDirectory(atPath: output.path(percentEncoded: false)) == ["other.wav"])
    }

    @Test func problemsLandOnTheirNodesAndPins() async throws {
        let folder = try makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appending(path: "source.wav")
        try writeSine(to: source, seconds: 0.1)
        var built = try chain(source: source, folder: folder)
        built.project.removeEdge(Edge(from: PinRef(node: built.resonator, pin: "out"), to: PinRef(node: built.print, pin: "in")))

        let state = await bake(built.project)

        guard case .failed(let issues) = state else { Issue.record("expected failed, got \(state)"); return }
        #expect(issues.nodes[built.print] == ["Needs an input."])
        #expect(issues.pins.contains(PinRef(node: built.print, pin: "in")))
    }

    @Test func aDeletedSourceIsReportedOnItsAudioNode() async throws {
        let folder = try makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appending(path: "source.wav")
        try writeSine(to: source, seconds: 0.1)
        let built = try chain(source: source, folder: folder)
        try FileManager.default.removeItem(at: source)

        let state = await bake(built.project)

        guard case .failed(let issues) = state else { Issue.record("expected failed, got \(state)"); return }
        #expect(issues.nodes[built.audio] == ["Can't find “source.wav” — choose the file again."])
    }

    @Test func cancellingStopsWithoutWritingFiles() async throws {
        let folder = try makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appending(path: "source.wav")
        try writeSine(to: source, seconds: 5)
        let output = folder.appending(path: "out", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let session = BakeSession(access: access)

        session.bake(try chain(source: source, folder: output).project)
        session.cancel()
        await session.waitUntilFinished()

        #expect(session.state == .cancelled)
        #expect(try FileManager.default.contentsOfDirectory(atPath: output.path(percentEncoded: false)).isEmpty)
    }

    /// PRD v1 success criterion: save → reopen → re-bake gives an identical file.
    @Test func aSavedAndReopenedProjectReBakesIdentically() async throws {
        let folder = try makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appending(path: "source.wav")
        try writeSine(to: source, seconds: 0.5)
        let first = folder.appending(path: "first", directoryHint: .isDirectory)
        let second = folder.appending(path: "second", directoryHint: .isDirectory)
        for url in [first, second] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        var project = try chain(source: source, folder: first).project

        let original = await bake(project)
        project.settings.printFolder = FileReference(lastKnownPath: second.path(percentEncoded: false), bookmark: try access.bookmark(for: second, writable: true))
        let reopened = try ProjectPackage.project(from: ProjectPackage.fileWrapper(for: project))
        let again = await bake(reopened)

        guard case .finished(let a) = original, case .finished(let b) = again else {
            Issue.record("expected two finished bakes, got \(original) and \(again)"); return
        }
        let firstFile = try #require(a.first)
        let secondFile = try #require(b.first)
        // The same audio, sample for sample. (The files' embedded patches differ: the second records the
        // folder it was moved to.)
        #expect(try samples(firstFile) == samples(secondFile))
        #expect(BakedWorkflow.read(fromWAV: secondFile)?.project == reopened)
    }

    /// Product-owner report: change the patch, bake again — a new version with the new sound,
    /// and the earlier take is kept.
    @Test func reBakingAnEditedPatchSavesANewVersion() async throws {
        let folder = try makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appending(path: "source.wav")
        try writeSine(to: source, seconds: 0.5)
        let output = folder.appending(path: "out", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var built = try chain(source: source, folder: output)
        let session = BakeSession(access: access)

        session.bake(built.project)
        await session.waitUntilFinished()
        guard case .finished(let first) = session.state else { Issue.record("expected finished, got \(session.state)"); return }
        let firstFile = try #require(first.first)
        let before = try Data(contentsOf: firstFile)

        built.project.setParameter("root", of: built.resonator, to: .number(440))
        session.projectDidChange()
        session.bake(built.project)
        await session.waitUntilFinished()
        guard case .finished(let second) = session.state else { Issue.record("expected finished, got \(session.state)"); return }
        let secondFile = try #require(second.first)

        #expect(secondFile.lastPathComponent == "bake-2.wav")
        #expect(try Data(contentsOf: secondFile) != before)
        #expect(try Data(contentsOf: firstFile) == before)
    }

    @Test func bakingOneNodeEmbedsTheWholePatchAndPreviewsStayPlain() async throws {
        let folder = try makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appending(path: "source.wav")
        try writeSine(to: source, seconds: 0.1)
        let output = folder.appending(path: "out", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var built = try chain(source: source, folder: output)
        let other = built.project.addNode(.print, at: CanvasPoint())
        built.project.setParameter("prefix", of: other, to: .text("other"))
        try built.project.connect(from: PinRef(node: built.audio, pin: "out"), to: PinRef(node: other, pin: "in"))
        let preview = built.project.addNode(.preview, at: CanvasPoint())
        try built.project.connect(from: PinRef(node: built.audio, pin: "out"), to: PinRef(node: preview, pin: "in"))
        let session = BakeSession(access: access)

        session.bake(built.project, only: other)
        await session.waitUntilFinished()
        guard case .finished(let outputs) = session.state, let baked = outputs.first else { Issue.record("expected finished, got \(session.state)"); return }
        // The whole patch, both Bake nodes and the Preview included, not the trimmed copy that rendered.
        let workflow = try #require(BakedWorkflow.read(fromWAV: baked))
        #expect(workflow.bakeNode == other && workflow.project == built.project)

        session.preview(built.project, node: preview)
        await session.waitUntilFinished()
        guard case .previewReady(_, let url) = session.state else { Issue.record("expected previewReady, got \(session.state)"); return }
        #expect(BakedWorkflow.read(fromWAV: url) == nil)
    }

    @Test func withEmbeddingOffBakesArePlain() async throws {
        let folder = try makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appending(path: "source.wav")
        try writeSine(to: source, seconds: 0.1)
        let output = folder.appending(path: "out", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let built = try chain(source: source, folder: output)
        let session = BakeSession(access: access)

        session.bake(built.project, embedWorkflow: false)
        await session.waitUntilFinished()
        guard case .finished(let outputs) = session.state, let baked = outputs.first else { Issue.record("expected finished, got \(session.state)"); return }
        #expect(BakedWorkflow.read(fromWAV: baked) == nil)
    }

    @Test func previewingRendersToTheSessionsOwnFolder() async throws {
        let folder = try makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appending(path: "source.wav")
        try writeSine(to: source, seconds: 0.2)
        let output = folder.appending(path: "out", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var built = try chain(source: source, folder: output)
        let preview = built.project.addNode(.preview, at: CanvasPoint())
        try built.project.connect(from: PinRef(node: built.audio, pin: "out"), to: PinRef(node: preview, pin: "in"))
        let session = BakeSession(access: access)

        session.preview(built.project, node: preview)
        await session.waitUntilFinished()

        guard case .previewReady(let node, let url) = session.state else { Issue.record("expected previewReady, got \(session.state)"); return }
        #expect(node == preview)
        #expect(url.deletingLastPathComponent().standardizedFileURL == session.previewFolder.standardizedFileURL)
        #expect(try FileManager.default.contentsOfDirectory(atPath: output.path(percentEncoded: false)).isEmpty)
        #expect(session.previewWaveforms[preview]?.peaks.isEmpty == false)
    }

    @Test func previewsNeedNoFolder() async throws {
        let folder = try makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appending(path: "source.wav")
        try writeSine(to: source, seconds: 0.1)
        var built = try chain(source: source, folder: nil)
        let preview = built.project.addNode(.preview, at: CanvasPoint())
        try built.project.connect(from: PinRef(node: built.audio, pin: "out"), to: PinRef(node: preview, pin: "in"))
        let session = BakeSession(access: access)

        session.preview(built.project, node: preview)
        await session.waitUntilFinished()

        guard case .previewReady = session.state else { Issue.record("expected previewReady, got \(session.state)"); return }
    }

    @Test func bakeAllIgnoresPreviews() async throws {
        let folder = try makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appending(path: "source.wav")
        try writeSine(to: source, seconds: 0.1)
        let output = folder.appending(path: "out", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var built = try chain(source: source, folder: output)
        built.project.addNode(.preview, at: CanvasPoint())   // unwired: would fail "Needs an input." if baked

        let state = await bake(built.project)

        guard case .finished(let outputs) = state else { Issue.record("expected finished, got \(state)"); return }
        #expect(outputs.map(\.lastPathComponent) == ["bake.wav"])
    }

    @Test func sourceWaveformsAreReadForCards() async throws {
        let folder = try makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appending(path: "source.wav")
        try writeSine(to: source, seconds: 0.5)
        let built = try chain(source: source, folder: folder)
        let session = BakeSession(access: access)

        await session.refreshAssetInfo(for: built.project)

        #expect(session.assetWaveforms.values.first?.peaks.count == 160)
    }

    @Test func sourceInfoIsReadForPreviews() async throws {
        let folder = try makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appending(path: "source.wav")
        try writeSine(to: source, seconds: 0.5)
        let built = try chain(source: source, folder: folder)
        let session = BakeSession(access: access)

        await session.refreshAssetInfo(for: built.project)

        #expect(session.assetInfo.values.first?.frameCount == 24_000)
    }

    @Test func editingAfterAFailedBakeClearsItsProblems() async throws {
        let session = BakeSession(access: access)
        session.bake(ProjectFile())
        await session.waitUntilFinished()
        #expect(!session.issues.isEmpty)
        session.projectDidChange()
        #expect(session.state == .idle)
    }
    /// A node with two control outputs (the Pitch Follower) keeps a summary for each, so a wire from
    /// its second output can show that output's trace.
    @Test func aBakeKeepsASummaryForEveryOutputPin() async throws {
        let folder = try makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appending(path: "source.wav")
        try writeSine(to: source, seconds: 0.5)
        let output = folder.appending(path: "out", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var built = try chain(source: source, folder: output)
        let follower = built.project.addNode(.pitchFollower, at: CanvasPoint())
        built.project.setModulated("q", of: built.filters, true)
        built.project.setModulated("mix", of: built.resonator, true)
        try built.project.connect(from: PinRef(node: built.audio, pin: "out"), to: PinRef(node: follower, pin: "in"))
        try built.project.connect(from: PinRef(node: follower, pin: "out"), to: PinRef(node: built.filters, pin: "mod.q"))
        try built.project.connect(from: PinRef(node: follower, pin: "confidence"), to: PinRef(node: built.resonator, pin: "mod.mix"))
        let session = BakeSession(access: access)

        session.bake(built.project)
        await session.waitUntilFinished()

        let pitch = try #require(session.outputSummaries[PinRef(node: follower, pin: "out")])
        let confidence = try #require(session.outputSummaries[PinRef(node: follower, pin: "confidence")])
        #expect(pitch.isControl && confidence.isControl)
        #expect(pitch.detail != confidence.detail)
        #expect(session.nodeSummaries[follower] == pitch)   // a node's own summary is still its first output
        #expect(session.outputSummaries[PinRef(node: built.filters, pin: "out")] == session.nodeSummaries[built.filters])
    }

    @Test func aBakeLeavesASummaryOnEveryNodeThatMadeSomethingAndNoticesWhenItGoesStale() async throws {
        let folder = try makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appending(path: "source.wav")
        try writeSine(to: source, seconds: 0.5)
        let output = folder.appending(path: "out", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var built = try chain(source: source, folder: output)
        let session = BakeSession(access: access)

        session.bake(built.project)
        await session.waitUntilFinished()

        #expect(session.nodeSummaries[built.audio]?.frames == 24_000)
        #expect(session.nodeSummaries[built.filters]?.spectrogram != nil)
        #expect(session.nodeSummaries[built.resonator] != nil)
        #expect(session.nodeSummaries[built.print] == nil)   // a Bake node makes a file, not a signal
        #expect(session.staleSummaryNodes(in: built.project).isEmpty)

        built.project.moveNodes([built.filters], byX: 50, y: 0)
        #expect(session.staleSummaryNodes(in: built.project).isEmpty)

        built.project.setParameter("q", of: built.filters, to: .number(3))
        let stale = session.staleSummaryNodes(in: built.project)
        #expect(stale.contains(built.filters) && stale.contains(built.resonator))
        #expect(!stale.contains(built.audio))
    }
}
