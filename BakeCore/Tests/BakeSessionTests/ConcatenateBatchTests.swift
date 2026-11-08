import BakeGraph
import Foundation
import Testing
@testable import BakeSession

/// Concatenate through the session: every pass joined, then what follows renders once.
@MainActor
struct ConcatenateBatchTests {
    private let access = PlainFileAccess()

    private struct Setup {
        let folder: URL, input: URL, output: URL
        var project = ProjectFile()
        let source: NodeID, filters: NodeID, gather: NodeID, bake: NodeID
    }

    /// in/: a.wav (0.1 s), b.wav (0.2 s), c.wav (0.3 s); Batch Audio → Filters → Concatenate (no crossfade)
    /// → Bake (32-bit float, "joined") → out/.
    private func setup() throws -> Setup {
        let folder = try makeTemporaryFolder()
        let input = folder.appending(path: "in", directoryHint: .isDirectory)
        let output = folder.appending(path: "out", directoryHint: .isDirectory)
        for url in [input, output] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        for (name, seconds) in [("a", 0.1), ("b", 0.2), ("c", 0.3)] {
            try writeSine(to: input.appending(path: "\(name).wav"), seconds: seconds)
        }
        var project = ProjectFile()
        let source = project.addNode(.batchAudio, at: CanvasPoint())
        let filters = project.addNode(.filters, at: CanvasPoint())
        let gather = project.addNode(.concatenate, at: CanvasPoint())
        let bake = project.addNode(.print, at: CanvasPoint())
        project.setSourceFolder(try reference(input, writable: false), for: source)
        try project.connect(from: PinRef(node: source, pin: "out"), to: PinRef(node: filters, pin: "in"))
        try project.connect(from: PinRef(node: filters, pin: "out"), to: PinRef(node: gather, pin: "in1"))
        try project.connect(from: PinRef(node: gather, pin: "out"), to: PinRef(node: bake, pin: "in"))
        project.setParameter("crossfade", of: gather, to: .number(0))
        project.setParameter("bitDepth", of: bake, to: .choice("32f"))
        project.setParameter("prefix", of: bake, to: .text("joined"))
        project.setOutputFolder(try reference(output, writable: true), for: bake)
        return Setup(folder: folder, input: input, output: output, project: project, source: source, filters: filters, gather: gather, bake: bake)
    }

    private func reference(_ url: URL, writable: Bool) throws -> FileReference {
        FileReference(lastKnownPath: url.path(percentEncoded: false), bookmark: try access.bookmark(for: url, writable: writable))
    }

    private func bake(_ project: ProjectFile) async -> BakeState {
        let session = BakeSession(access: access)
        session.bake(project, embedWorkflow: false)
        await session.waitUntilFinished()
        return session.state
    }

    /// `file` through `chain` (kinds wired in a line) with a plain Audio and Bake, into `folder`.
    private func plainBake(_ file: URL, _ chain: [NodeKind], into folder: URL) async throws -> URL {
        var project = ProjectFile()
        let audio = project.addNode(.audio, at: CanvasPoint())
        project.assignAudio(path: file.path(percentEncoded: false), bookmark: nil, to: audio)
        var last = audio
        for kind in chain + [.print] {
            let node = project.addNode(kind, at: CanvasPoint())
            try project.connect(from: PinRef(node: last, pin: "out"), to: PinRef(node: node, pin: "in"))
            last = node
        }
        project.setParameter("bitDepth", of: last, to: .choice("32f"))
        project.setParameter("prefix", of: last, to: .text(file.deletingPathExtension().lastPathComponent))
        project.setOutputFolder(try reference(folder, writable: true), for: last)
        guard case .finished(let outputs) = await bake(project), let url = outputs.first else {
            Issue.record("the plain bake failed")
            return file
        }
        return url
    }

    @Test func aFolderBecomesOneFileOfEveryInputEndToEnd() async throws {
        let setup = try setup()
        defer { try? FileManager.default.removeItem(at: setup.folder) }
        guard case .finished(let outputs) = await bake(setup.project) else {
            Issue.record("the batch failed")
            return
        }
        #expect(outputs.map(\.lastPathComponent) == ["joined.wav"])
        // The same as baking each file through Filters and putting the results end to end.
        let reference = setup.folder.appending(path: "reference", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: reference, withIntermediateDirectories: true)
        var expected: [[Float]] = [[], []]
        for name in ["a", "b", "c"] {
            let single = try samples(await plainBake(setup.input.appending(path: "\(name).wav"), [.filters], into: reference))
            for channel in 0..<2 { expected[channel] += single[channel] }
        }
        #expect(try samples(#require(outputs.first)) == expected)
    }

    /// What follows the Concatenate renders once, on the joined signal: the same as joining first
    /// and running the result through Reverb on its own.
    @Test func whatFollowsRendersOnceOnTheJoinedSignal() async throws {
        var setup = try setup()
        defer { try? FileManager.default.removeItem(at: setup.folder) }
        let reverb = setup.project.addNode(.reverb, at: CanvasPoint())
        let gather = setup.gather, output = setup.bake
        setup.project.edges.removeAll { $0.from.node == gather }
        try setup.project.connect(from: PinRef(node: gather, pin: "out"), to: PinRef(node: reverb, pin: "in"))
        try setup.project.connect(from: PinRef(node: reverb, pin: "out"), to: PinRef(node: output, pin: "in"))
        guard case .finished(let outputs) = await bake(setup.project), let url = outputs.first else {
            Issue.record("the batch failed")
            return
        }
        #expect(outputs.count == 1)
        let reference = setup.folder.appending(path: "reference", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: reference, withIntermediateDirectories: true)
        var singles: [URL] = []
        for name in ["a", "b", "c"] {
            singles.append(try await plainBake(setup.input.appending(path: "\(name).wav"), [.filters], into: reference))
        }
        let joined = reference.appending(path: "joined by hand.wav")
        try Concatenation.join(singles, parameters: ["crossfade": .number(0)], to: joined)
        let expected = try await plainBake(joined, [.reverb], into: reference)
        #expect(try samples(url) == samples(expected))
    }

    @Test func aBatchBakeBesideAConcatenateRunsInTheSameBake() async throws {
        var setup = try setup()
        defer { try? FileManager.default.removeItem(at: setup.folder) }
        let batchBake = setup.project.addNode(.batchBake, at: CanvasPoint())
        try setup.project.connect(from: PinRef(node: setup.filters, pin: "out"), to: PinRef(node: batchBake, pin: "in"))
        setup.project.setOutputFolder(try reference(setup.output, writable: true), for: batchBake)
        guard case .finished(let outputs) = await bake(setup.project) else {
            Issue.record("the batch failed")
            return
        }
        #expect(outputs.map(\.lastPathComponent) == ["a.wav", "b.wav", "c.wav", "joined.wav"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: setup.output.path(percentEncoded: false)).sorted() == ["a.wav", "b.wav", "c.wav", "joined.wav"])
    }

    @Test func previewAfterConcatenatePlaysTheJoinedResult() async throws {
        var setup = try setup()
        defer { try? FileManager.default.removeItem(at: setup.folder) }
        let preview = setup.project.addNode(.preview, at: CanvasPoint())
        try setup.project.connect(from: PinRef(node: setup.gather, pin: "out"), to: PinRef(node: preview, pin: "in"))
        let session = BakeSession(access: access)
        session.preview(setup.project, node: preview)
        await session.waitUntilFinished()
        guard case .previewReady(_, let url) = session.state else {
            Issue.record("expected previewReady, got \(session.state)")
            return
        }
        #expect(try samples(url).first?.count == Int(0.6 * 48_000))
        #expect(session.nodeSummaries[setup.gather] != nil)
    }

    @Test func gatherProblemsLandOnTheirCards() async throws {
        var setup = try setup()
        defer { try? FileManager.default.removeItem(at: setup.folder) }
        let after = setup.project.addNode(.batchBake, at: CanvasPoint())
        try setup.project.connect(from: PinRef(node: setup.gather, pin: "out"), to: PinRef(node: after, pin: "in"))
        guard case .failed(let issues) = await bake(setup.project) else {
            Issue.record("expected the batch to fail")
            return
        }
        // It has no folder either, so that's said too.
        #expect(issues.nodes[after]?.contains(BatchIssue.batchBakeAfterGather(after).message) == true)
        #expect(try FileManager.default.contentsOfDirectory(atPath: setup.output.path(percentEncoded: false)).isEmpty)
    }
}
