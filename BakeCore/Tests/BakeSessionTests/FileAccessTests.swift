import BakeGraph
import Foundation
import Testing
@testable import BakeSession

struct FileResolverTests {
    private let access = PlainFileAccess()

    private func project(audio url: URL, folder: URL?) throws -> (ProjectFile, AssetID) {
        var project = ProjectFile()
        let node = project.addNode(.audio, at: CanvasPoint())
        let bookmark = try access.bookmark(for: url, writable: false)
        let assigned = project.assignAudio(path: url.path(percentEncoded: false), bookmark: bookmark, to: node)
        let asset = try #require(assigned)
        if let folder {
            project.settings.printFolder = FileReference(lastKnownPath: folder.path(percentEncoded: false), bookmark: try access.bookmark(for: folder, writable: true))
        }
        return (project, asset)
    }

    @Test func bookmarksResolveToTheirFiles() throws {
        let folder = try makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appending(path: "kick.wav")
        try writeSine(to: source, seconds: 0.1)
        let (project, asset) = try project(audio: source, folder: folder)

        let files = FileResolver.resolve(project, access: access)
        defer { files.release(using: access) }

        let audioURL = try #require(files.assetURLs[asset])
        let folderURL = try #require(files.printFolder)
        #expect(samePath(audioURL, source))
        #expect(samePath(folderURL, folder))
        #expect(files.refreshedAssets.isEmpty)
    }

    @Test func movedFilesAreFoundAndTheirReferencesRefreshed() throws {
        let folder = try makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appending(path: "kick.wav")
        try writeSine(to: source, seconds: 0.1)
        let (project, asset) = try project(audio: source, folder: nil)
        let moved = folder.appending(path: "renamed.wav")
        try FileManager.default.moveItem(at: source, to: moved)

        let files = FileResolver.resolve(project, access: access)
        defer { files.release(using: access) }

        let audioURL = try #require(files.assetURLs[asset])
        #expect(samePath(audioURL, moved))
        let refreshed = try #require(files.refreshedAssets[asset])
        #expect(samePath(URL(filePath: refreshed.lastKnownPath), moved))
    }

    @Test func deletedFilesAreLeftOut() throws {
        let folder = try makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appending(path: "kick.wav")
        try writeSine(to: source, seconds: 0.1)
        let (project, asset) = try project(audio: source, folder: nil)
        try FileManager.default.removeItem(at: source)

        #expect(FileResolver.resolve(project, access: access).assetURLs[asset] == nil)
    }

    @Test func referencesWithoutBookmarksFallBackToTheirPath() throws {
        let folder = try makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appending(path: "kick.wav")
        try writeSine(to: source, seconds: 0.1)
        var project = ProjectFile()
        let node = project.addNode(.audio, at: CanvasPoint())
        let assigned = project.assignAudio(path: source.path(percentEncoded: false), bookmark: nil, to: node)
        let asset = try #require(assigned)

        let audioURL = try #require(FileResolver.resolve(project, access: access).assetURLs[asset])
        #expect(samePath(audioURL, source))
    }
}

struct FileImportTests {
    @Test func audioFilesImportWithABookmark() throws {
        let folder = try makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appending(path: "kick.wav")
        try writeSine(to: source, seconds: 0.1)

        let reference = try FileImport.audioReference(for: source, access: PlainFileAccess())

        #expect(reference.bookmark != nil)
        #expect(samePath(URL(filePath: reference.lastKnownPath), source))
    }

    @Test func nonAudioFilesAreRejected() throws {
        let folder = try makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let text = folder.appending(path: "notes.txt")
        try Data("hello".utf8).write(to: text)

        #expect(throws: ImportError.unreadableAudio("notes.txt")) {
            try FileImport.audioReference(for: text, access: PlainFileAccess())
        }
    }
}
