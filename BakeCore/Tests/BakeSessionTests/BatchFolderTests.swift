import BakeGraph
import BakeRender
import Foundation
import Testing
@testable import BakeSession

struct BatchFolderTests {
    private func list(_ folder: URL, _ parameters: [ParameterID: ParameterValue] = [:]) -> [String] {
        BatchFolder.files(in: folder, parameters: parameters, sampleRate: 48_000) { try? AssetInfoReader.info(for: $0) }
            .map(\.lastPathComponent)
    }

    @Test func onlyTheFoldersOwnAudioFilesAreListedInFinderOrder() throws {
        let folder = try makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        for name in ["b.wav", "10.wav", "2.wav"] { try writeSine(to: folder.appending(path: name), seconds: 0.01) }
        try writeSine(to: folder.appending(path: "a.aiff"), seconds: 0.01)
        try Data("notes".utf8).write(to: folder.appending(path: "notes.txt"))
        let sub = folder.appending(path: "sub", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try writeSine(to: sub.appending(path: "c.wav"), seconds: 0.01)
        #expect(list(folder) == ["2.wav", "10.wav", "a.aiff", "b.wav"])
    }

    @Test func wavOnlyAndProjectRateOnlyFilter() throws {
        let folder = try makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try writeSine(to: folder.appending(path: "slow.wav"), seconds: 0.01, sampleRate: 44_100)
        try writeSine(to: folder.appending(path: "fast.wav"), seconds: 0.01)
        try writeSine(to: folder.appending(path: "other.aiff"), seconds: 0.01)
        #expect(list(folder, ["formats": .choice("wav")]) == ["fast.wav", "slow.wav"])
        #expect(list(folder, ["formats": .choice("matchRate")]) == ["fast.wav", "other.aiff"])
    }

    @Test func durationAndSizeOrdersBreakTiesByName() throws {
        let folder = try makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try writeSine(to: folder.appending(path: "long.wav"), seconds: 0.3)
        try writeSine(to: folder.appending(path: "b-short.wav"), seconds: 0.1)
        try writeSine(to: folder.appending(path: "a-short.wav"), seconds: 0.1)
        try writeSine(to: folder.appending(path: "mid.wav"), seconds: 0.2)
        #expect(list(folder, ["order": .choice("duration")]) == ["a-short.wav", "b-short.wav", "mid.wav", "long.wav"])
        #expect(list(folder, ["order": .choice("size")]) == ["a-short.wav", "b-short.wav", "mid.wav", "long.wav"])
    }

    @Test func randomOrderIsTheSameEveryTimeAndChangesWithTheSeed() throws {
        let folder = try makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let names = (1...12).map { "hit \($0).wav" }
        for name in names { try writeSine(to: folder.appending(path: name), seconds: 0.01) }
        let one = list(folder, ["order": .choice("random"), "seed": .number(1)])
        #expect(Set(one) == Set(names))
        #expect(one == list(folder, ["order": .choice("random"), "seed": .number(1)]))
        #expect(one != list(folder, ["order": .choice("random"), "seed": .number(2)]))
        #expect(one != list(folder))
    }

    @Test func aMissingFolderHasNoFiles() {
        #expect(list(URL(filePath: "/no/such/folder")).isEmpty)
    }

    /// The resolver opens Batch Audio folders for reading and finds Batch Bake folders like Bake ones.
    @Test func batchFoldersAreResolved() throws {
        let access = PlainFileAccess()
        let input = try makeTemporaryFolder()
        let output = try makeTemporaryFolder()
        defer {
            try? FileManager.default.removeItem(at: input)
            try? FileManager.default.removeItem(at: output)
        }
        var project = ProjectFile()
        let source = project.addNode(.batchAudio, at: CanvasPoint())
        let bake = project.addNode(.batchBake, at: CanvasPoint())
        project.setSourceFolder(FileReference(lastKnownPath: input.path(percentEncoded: false), bookmark: try access.bookmark(for: input, writable: false)), for: source)
        project.setOutputFolder(FileReference(lastKnownPath: output.path(percentEncoded: false), bookmark: try access.bookmark(for: output, writable: true)), for: bake)
        let files = FileResolver.resolve(project, access: access)
        #expect(try samePath(#require(files.sourceFolders[source]), input))
        #expect(try samePath(#require(files.outputFolders[bake]), output))
    }
}
