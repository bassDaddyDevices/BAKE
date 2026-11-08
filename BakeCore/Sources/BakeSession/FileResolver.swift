import BakeGraph
import Foundation

/// Where a project's files are right now, for one bake.
public struct ResolvedFiles: Sendable {
    public var assetURLs: [AssetID: URL] = [:]
    public var printFolder: URL?
    /// Bake and Batch Bake nodes' own folders.
    public var outputFolders: [NodeID: URL] = [:]
    /// Batch Audio nodes' folders, open for reading while this resolution lasts.
    public var sourceFolders: [NodeID: URL] = [:]
    /// References re-created because files moved; write them back into the document.
    public var refreshedAssets: [AssetID: FileReference] = [:]
    public var refreshedPrintFolder: FileReference?
    public var refreshedOutputFolders: [NodeID: FileReference] = [:]
    public var refreshedSourceFolders: [NodeID: FileReference] = [:]
    /// URLs whose security scope was started.
    var started: [URL] = []

    /// Ends access to every file and folder this resolution opened.
    public func release(using access: any FileAccess) {
        for url in started { access.stopAccessing(url) }
    }
}

public enum FileResolver {
    /// Resolves every referenced audio file, the default folder, and each Bake node's own folder. Files that can't be found are
    /// left out — the compiler reports them only if a scheduled node needs them. A collected asset
    /// plays its copy from the document (`media`, unpacked by package path) when there is one.
    public static func resolve(_ project: ProjectFile, access: any FileAccess, media: [String: URL] = [:]) -> ResolvedFiles {
        var files = ResolvedFiles()
        for asset in project.assets {
            if let path = asset.packagePath, let url = media[path], FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
                files.assetURLs[asset.id] = url
                continue
            }
            let reference = FileReference(lastKnownPath: asset.lastKnownPath, bookmark: asset.bookmark)
            if let found = locate(reference, writable: false, access: access, started: &files.started) {
                files.assetURLs[asset.id] = found.url
                files.refreshedAssets[asset.id] = found.refreshed
            }
        }
        if let folder = project.settings.printFolder,
           let found = locate(folder, writable: true, access: access, started: &files.started) {
            files.printFolder = found.url
            files.refreshedPrintFolder = found.refreshed
        }
        for node in project.nodes where node.kind == .print || node.kind == .batchBake {
            if let folder = node.outputFolder,
               let found = locate(folder, writable: true, access: access, started: &files.started) {
                files.outputFolders[node.id] = found.url
                files.refreshedOutputFolders[node.id] = found.refreshed
            }
        }
        // While a folder's security scope is open its files can be read, so they need no bookmarks.
        for node in project.nodes where node.kind == .batchAudio {
            if let folder = node.sourceFolder,
               let found = locate(folder, writable: false, access: access, started: &files.started) {
                files.sourceFolders[node.id] = found.url
                files.refreshedSourceFolders[node.id] = found.refreshed
            }
        }
        return files
    }

    /// Bookmark first (it follows moves), then the last known path.
    private static func locate(
        _ reference: FileReference, writable: Bool, access: any FileAccess, started: inout [URL]
    ) -> (url: URL, refreshed: FileReference?)? {
        if let bookmark = reference.bookmark, let resolved = try? access.resolve(bookmark) {
            if access.startAccessing(resolved.url) { started.append(resolved.url) }
            guard FileManager.default.fileExists(atPath: resolved.url.path(percentEncoded: false)) else { return nil }
            let moved = resolved.url.resolvingSymlinksInPath().path(percentEncoded: false)
                != URL(filePath: reference.lastKnownPath).resolvingSymlinksInPath().path(percentEncoded: false)
            guard resolved.isStale || moved else { return (resolved.url, nil) }
            let renewed = (try? access.bookmark(for: resolved.url, writable: writable)) ?? bookmark
            return (resolved.url, FileReference(lastKnownPath: resolved.url.path(percentEncoded: false), bookmark: renewed))
        }
        let url = URL(filePath: reference.lastKnownPath)
        return FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) ? (url, nil) : nil
    }
}
