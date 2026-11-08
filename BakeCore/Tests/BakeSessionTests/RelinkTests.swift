import BakeGraph
import Foundation
import Testing
@testable import BakeSession

/// M6 step 4: a missing audio file is marked, and Locate… fixes every node playing it at once.
@MainActor
struct RelinkTests {
    private let access = PlainFileAccess()

    @Test func relinkingAFileFixesEveryNodePlayingIt() throws {
        var project = ProjectFile()
        let a = project.addNode(.audio, at: CanvasPoint())
        let b = project.addNode(.audio, at: CanvasPoint(x: 300))
        let asset = project.assignAudio(path: "/old/loop.wav", bookmark: nil, to: a)
        _ = project.assignAudio(path: "/old/loop.wav", bookmark: nil, to: b)
        let id = try #require(asset)
        project.customNodes.append(CustomNodeDefinition(name: "Inside", nodes: [Node(kind: .audio, assetID: id)]))
        #expect(project.relinkAsset(id, path: "/new/loop.wav", bookmark: Data([1])) == 3)
        #expect(project.assets == [AssetReference(id: id, lastKnownPath: "/new/loop.wav", bookmark: Data([1]))])
        #expect(project.audioFileName(for: b) == "loop.wav")
        #expect(project.relinkAsset(AssetID(), path: "/x.wav", bookmark: nil) == 0)
    }

    @Test func aMissingFileIsMarkedUntilItIsLocated() async throws {
        let folder = try makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let original = folder.appending(path: "loop.wav")
        try writeSine(to: original, seconds: 0.1)
        var project = ProjectFile()
        let audio = project.addNode(.audio, at: CanvasPoint())
        let asset = try #require(project.assignAudio(
            path: original.path(percentEncoded: false), bookmark: try access.bookmark(for: original, writable: false), to: audio
        ))
        let session = BakeSession(access: access)
        await session.refreshAssetInfo(for: project)
        #expect(session.missingAssets.isEmpty)

        // Moved somewhere the stored reference can't follow (a plain path, no bookmark).
        let moved = folder.appending(path: "elsewhere/loop.wav")
        try FileManager.default.createDirectory(at: moved.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: original, to: moved)
        project.assets[0].bookmark = nil
        await session.refreshAssetInfo(for: project)
        #expect(session.missingAssets == [asset])

        project.relinkAsset(asset, path: moved.path(percentEncoded: false), bookmark: try access.bookmark(for: moved, writable: false))
        await session.refreshAssetInfo(for: project)
        #expect(session.missingAssets.isEmpty)
        #expect(session.assetInfo[asset]?.frameCount == 4_800)
    }
}
