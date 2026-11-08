import BakeGraph
import Foundation
import Testing
@testable import BakeSession

/// M6 step 4b: Collect Files copies a project's audio into its package, so it keeps its sound
/// wherever the package goes.
@MainActor
struct CollectFilesTests {
    private let access = PlainFileAccess()

    @Test func collectedAudioTravelsInsideThePackage() throws {
        var project = ProjectFile()
        let audio = project.addNode(.audio, at: CanvasPoint())
        let assigned = project.assignAudio(path: "/gone/loop.wav", bookmark: nil, to: audio)
        let asset = try #require(assigned)
        project.markCollected(asset, at: "Media/loop.wav")
        let media = ["Media/loop.wav": Data([1, 2, 3]), "Media/unused.wav": Data([9])]

        let folder = try makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appending(path: "song.bake")
        try ProjectPackage.fileWrapper(for: project, media: media).write(to: url, options: .atomic, originalContentsURL: nil)
        #expect(FileManager.default.fileExists(atPath: url.appending(path: "Media/loop.wav").path(percentEncoded: false)))
        #expect(!FileManager.default.fileExists(atPath: url.appending(path: "Media/unused.wav").path(percentEncoded: false)))

        let reopened = try FileWrapper(url: url, options: .immediate)
        #expect(try ProjectPackage.project(from: reopened).assets.first?.packagePath == "Media/loop.wav")
        #expect(ProjectPackage.media(from: reopened) == ["Media/loop.wav": Data([1, 2, 3])])
        #expect(ProjectPackage.mediaPath(for: "loop.wav", taken: ["Media/loop.wav"]) == "Media/loop 2.wav")
        #expect(ProjectPackage.mediaPath(for: "kick", taken: []) == "Media/kick")
    }

    @Test func aCollectedFilePlaysFromThePackageWhenTheOriginalIsGone() async throws {
        let folder = try makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let original = folder.appending(path: "loop.wav")
        try writeSine(to: original, seconds: 0.1)
        let data = try Data(contentsOf: original)
        try FileManager.default.removeItem(at: original)

        var project = ProjectFile()
        let audio = project.addNode(.audio, at: CanvasPoint())
        let bake = project.addNode(.print, at: CanvasPoint())
        let assigned = project.assignAudio(path: original.path(percentEncoded: false), bookmark: nil, to: audio)
        let asset = try #require(assigned)
        try project.connect(from: PinRef(node: audio, pin: "out"), to: PinRef(node: bake, pin: "in"))
        project.markCollected(asset, at: "Media/loop.wav")
        let output = folder.appending(path: "out", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        project.settings.printFolder = FileReference(
            lastKnownPath: output.path(percentEncoded: false), bookmark: try access.bookmark(for: output, writable: true)
        )

        let cache = folder.appending(path: "cache", directoryHint: .isDirectory)
        let media = try MediaCache.unpack(["Media/loop.wav": data], into: cache)
        // Unpacking again reuses the file: same content, same name.
        #expect(try MediaCache.unpack(["Media/loop.wav": data], into: cache) == media)
        #expect(FileResolver.resolve(project, access: access).assetURLs[asset] == nil)
        #expect(FileResolver.resolve(project, access: access, media: media).assetURLs[asset] == media["Media/loop.wav"])

        let session = BakeSession(access: access)
        session.collectedMedia = media
        await session.refreshAssetInfo(for: project)
        #expect(session.missingAssets.isEmpty)
        session.bake(project)
        await session.waitUntilFinished()
        guard case .finished(let outputs) = session.state else {
            Issue.record("expected a finished bake, got \(session.state)")
            return
        }
        #expect(outputs.count == 1)
    }

    @Test func locatingAFileStopsUsingItsCollectedCopy() throws {
        var project = ProjectFile()
        let audio = project.addNode(.audio, at: CanvasPoint())
        let assigned = project.assignAudio(path: "/old.wav", bookmark: nil, to: audio)
        let asset = try #require(assigned)
        project.markCollected(asset, at: "Media/old.wav")
        project.relinkAsset(asset, path: "/new.wav", bookmark: nil)
        #expect(project.assets.first?.packagePath == nil)
        // A custom node exported from here doesn't carry the copy's package path.
        project.customNodes.append(CustomNodeDefinition(name: "Loop", nodes: [Node(kind: .audio, assetID: asset)]))
        project.markCollected(asset, at: "Media/new.wav")
        #expect(CustomNodeFile(definition: project.customNodes[0], from: project).assets.first?.packagePath == nil)
    }
}
