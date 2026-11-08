import BakeGraph
import Foundation
import Testing
@testable import BakeSession

/// Batch bakes through the session, with real files: the patch is baked once per input file.
@MainActor
struct BatchBakeTests {
    private let access = PlainFileAccess()

    private struct Setup {
        let input: URL, output: URL
        var project = ProjectFile()
        let source: NodeID, filters: NodeID, bake: NodeID

        func remove() {
            try? FileManager.default.removeItem(at: input)
            try? FileManager.default.removeItem(at: output)
        }
    }

    /// in/: a.wav (0.1 s), b.wav (0.2 s), c.wav (0.3 s); Batch Audio → Filters → Batch Bake (32-bit float) → out/.
    private func setup() throws -> Setup {
        let input = try makeTemporaryFolder()
        let output = try makeTemporaryFolder()
        for (name, seconds) in [("a", 0.1), ("b", 0.2), ("c", 0.3)] {
            try writeSine(to: input.appending(path: "\(name).wav"), seconds: seconds)
        }
        var project = ProjectFile()
        let source = project.addNode(.batchAudio, at: CanvasPoint())
        let filters = project.addNode(.filters, at: CanvasPoint())
        let bake = project.addNode(.batchBake, at: CanvasPoint())
        try project.connect(from: PinRef(node: source, pin: "out"), to: PinRef(node: filters, pin: "in"))
        try project.connect(from: PinRef(node: filters, pin: "out"), to: PinRef(node: bake, pin: "in"))
        project.setParameter("bitDepth", of: bake, to: .choice("32f"))
        project.setSourceFolder(try reference(input, writable: false), for: source)
        project.setOutputFolder(try reference(output, writable: true), for: bake)
        return Setup(input: input, output: output, project: project, source: source, filters: filters, bake: bake)
    }

    private func reference(_ url: URL, writable: Bool) throws -> FileReference {
        FileReference(lastKnownPath: url.path(percentEncoded: false), bookmark: try access.bookmark(for: url, writable: writable))
    }

    private func bake(_ project: ProjectFile, only node: NodeID? = nil) async -> BakeState {
        let session = BakeSession(access: access)
        session.bake(project, only: node, embedWorkflow: false)
        await session.waitUntilFinished()
        return session.state
    }

    private func names(in folder: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false)).sorted()
    }

    /// One input file through the same Filters with a plain Audio and Bake.
    private func plainBake(_ file: URL, into folder: URL) async throws -> [[Float]] {
        var project = ProjectFile()
        let audio = project.addNode(.audio, at: CanvasPoint())
        let filters = project.addNode(.filters, at: CanvasPoint())
        let bake = project.addNode(.print, at: CanvasPoint())
        project.assignAudio(path: file.path(percentEncoded: false), bookmark: try access.bookmark(for: file, writable: false), to: audio)
        try project.connect(from: PinRef(node: audio, pin: "out"), to: PinRef(node: filters, pin: "in"))
        try project.connect(from: PinRef(node: filters, pin: "out"), to: PinRef(node: bake, pin: "in"))
        project.setParameter("bitDepth", of: bake, to: .choice("32f"))
        project.setOutputFolder(try reference(folder, writable: true), for: bake)
        guard case .finished(let outputs) = await self.bake(project), let url = outputs.first else {
            Issue.record("the plain bake failed")
            return []
        }
        return try samples(url)
    }

    @Test func aFolderOfThreeFilesBakesThreeFilesLikeBakingEachOne() async throws {
        let setup = try setup()
        defer { setup.remove() }
        guard case .finished(let outputs) = await bake(setup.project) else {
            Issue.record("the batch failed")
            return
        }
        #expect(outputs.map(\.lastPathComponent) == ["a.wav", "b.wav", "c.wav"])
        #expect(try names(in: setup.output) == ["a.wav", "b.wav", "c.wav"])
        let reference = try makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: reference) }
        for (name, seconds) in [("a", 0.1), ("b", 0.2), ("c", 0.3)] {
            let batched = try samples(setup.output.appending(path: "\(name).wav"))
            #expect(batched.first?.count == Int(seconds * 48_000))
            #expect(try await batched == plainBake(setup.input.appending(path: "\(name).wav"), into: reference), "\(name).wav")
        }
    }

    @Test func plainBakesRenderOnceBesideABatch() async throws {
        var setup = try setup()
        defer { setup.remove() }
        let generator = setup.project.addNode(.generator, at: CanvasPoint())
        let plain = setup.project.addNode(.print, at: CanvasPoint())
        try setup.project.connect(from: PinRef(node: generator, pin: "out"), to: PinRef(node: plain, pin: "in"))
        setup.project.setParameter("prefix", of: plain, to: .text("noise"))
        setup.project.setOutputFolder(try reference(setup.output, writable: true), for: plain)
        guard case .finished(let outputs) = await bake(setup.project) else {
            Issue.record("the batch failed")
            return
        }
        #expect(outputs.map(\.lastPathComponent) == ["a.wav", "b.wav", "c.wav", "noise.wav"])
    }

    @Test func skipLeavesExistingFilesAndBakesTheRest() async throws {
        var setup = try setup()
        defer { setup.remove() }
        setup.project.setParameter("versions", of: setup.bake, to: .choice("skip"))
        let existing = setup.output.appending(path: "b.wav")
        try writeSine(to: existing, seconds: 0.05, channels: 1)
        guard case .finished(let outputs) = await bake(setup.project) else {
            Issue.record("the batch failed")
            return
        }
        #expect(outputs.map(\.lastPathComponent) == ["a.wav", "c.wav"])
        #expect(try samples(existing).count == 1)
        #expect(try samples(existing).first?.count == 2_400)
    }

    @Test func anUnreadableFileStopsTheBatchBeforeAnythingIsWritten() async throws {
        let setup = try setup()
        defer { setup.remove() }
        try Data("not audio".utf8).write(to: setup.input.appending(path: "broken.wav"))
        guard case .failed(let issues) = await bake(setup.project) else {
            Issue.record("expected the batch to fail")
            return
        }
        #expect(issues.nodes[setup.source]?.contains { $0.contains("broken.wav") } == true)
        #expect(try names(in: setup.output).isEmpty)
    }

    @Test func problemsLandOnTheirCards() async throws {
        var setup = try setup()
        defer { setup.remove() }
        setup.project.setSourceFolder(nil, for: setup.source)
        let plain = setup.project.addNode(.print, at: CanvasPoint())
        try setup.project.connect(from: PinRef(node: setup.filters, pin: "out"), to: PinRef(node: plain, pin: "in"))
        guard case .failed(let issues) = await bake(setup.project) else {
            Issue.record("expected the batch to fail")
            return
        }
        #expect(issues.nodes[setup.source] == [BatchIssue.noFolder(setup.source).message])
        #expect(issues.nodes[plain]?.contains(BatchIssue.plainBakeInBatch(plain).message) == true)
        #expect(try names(in: setup.output).isEmpty)
    }

    @Test func bakeThisNodeOnABatchBakeBakesOnlyItsBatch() async throws {
        var setup = try setup()
        defer { setup.remove() }
        let generator = setup.project.addNode(.generator, at: CanvasPoint())
        let plain = setup.project.addNode(.print, at: CanvasPoint())
        try setup.project.connect(from: PinRef(node: generator, pin: "out"), to: PinRef(node: plain, pin: "in"))
        setup.project.setOutputFolder(try reference(setup.output, writable: true), for: plain)
        guard case .finished(let outputs) = await bake(setup.project, only: setup.bake) else {
            Issue.record("the batch failed")
            return
        }
        #expect(outputs.map(\.lastPathComponent) == ["a.wav", "b.wav", "c.wav"])
    }

    @Test func previewPlaysTheFirstFileAndTheSessionListsTheFolder() async throws {
        var setup = try setup()
        defer { setup.remove() }
        let preview = setup.project.addNode(.preview, at: CanvasPoint())
        try setup.project.connect(from: PinRef(node: setup.filters, pin: "out"), to: PinRef(node: preview, pin: "in"))
        let session = BakeSession(access: access)
        await session.refreshAssetInfo(for: setup.project)
        #expect(session.batchFiles[setup.source]?.map(\.name) == ["a", "b", "c"])
        #expect(session.assetInfo[BatchRun.assetID(of: setup.source, pass: 0)]?.frameCount == 4_800)
        session.preview(setup.project, node: preview)
        await session.waitUntilFinished()
        guard case .previewReady(_, let url) = session.state else {
            Issue.record("expected previewReady, got \(session.state)")
            return
        }
        #expect(try samples(url).first?.count == 4_800)
        #expect(try names(in: setup.output).isEmpty)
    }

    @Test func nameAndNumberAndRandomWordsNameTheFiles() async throws {
        var setup = try setup()
        defer { setup.remove() }
        setup.project.setParameter("naming", of: setup.bake, to: .choice("numbered"))
        setup.project.setParameter("name", of: setup.bake, to: .text("Kick"))
        guard case .finished(let numbered) = await bake(setup.project) else {
            Issue.record("the numbered batch failed")
            return
        }
        #expect(numbered.map(\.lastPathComponent) == ["Kick_001.wav", "Kick_002.wav", "Kick_003.wav"])

        setup.project.setParameter("naming", of: setup.bake, to: .choice("random"))
        setup.project.setParameter("seed", of: setup.bake, to: .number(3))
        let session = BakeSession(access: access)
        let lists = try #require(WordLists(adjectives: "Red\nBlue", prefixes: "Fox\nOwl", suffixes: "of_Doom\nof_Rain"))
        session.wordLists = lists
        session.bake(setup.project, embedWorkflow: false)
        await session.waitUntilFinished()
        guard case .finished(let random) = session.state else {
            Issue.record("the random batch failed")
            return
        }
        let expected = BatchNames.random(seed: 3, passes: 3, lists: lists).map { "\($0).wav" }
        #expect(random.map(\.lastPathComponent) == expected.sorted())
    }

    @Test func aWordListsFolderNeedsItsThreeFiles() throws {
        let folder = try makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try "Red\nBlue\n".write(to: folder.appending(path: "adjectives.txt"), atomically: true, encoding: .utf8)
        try "Fox\n".write(to: folder.appending(path: "prefixes.txt"), atomically: true, encoding: .utf8)
        #expect(AppPreferences.readWordLists(in: folder, access: access) == nil)
        try "of Doom\n".write(to: folder.appending(path: "suffixes.txt"), atomically: true, encoding: .utf8)
        let lists = try #require(AppPreferences.readWordLists(in: folder, access: access))
        #expect(lists.adjectives == ["Red", "Blue"] && lists.suffixes == ["of_Doom"])
        #expect(lists.combinations == 2)
    }
}
