import BakeGraph
import BakeRender
import Foundation

public enum ImportError: Error, Equatable, Sendable {
    /// Not a WAV, AIFF, or CAF file BAKE can read (file name).
    case unreadableAudio(String)
    /// The system wouldn't create a bookmark (file name).
    case cantBookmark(String)
}

/// Turns files and folders the user picked into references the document can keep.
public enum FileImport {
    /// Checks that BAKE can read the audio, then bookmarks it read-only.
    public static func audioReference(for url: URL, access: any FileAccess) throws(ImportError) -> FileReference {
        let started = access.startAccessing(url)
        defer { if started { access.stopAccessing(url) } }
        guard (try? AssetInfoReader.info(for: url)) != nil else { throw .unreadableAudio(url.lastPathComponent) }
        return try reference(for: url, writable: false, access: access)
    }

    /// Bookmarks a folder read/write (the Print folder).
    public static func folderReference(for url: URL, access: any FileAccess) throws(ImportError) -> FileReference {
        let started = access.startAccessing(url)
        defer { if started { access.stopAccessing(url) } }
        return try reference(for: url, writable: true, access: access)
    }

    /// Bookmarks a folder read-only (a Batch Audio node's folder).
    public static func sourceFolderReference(for url: URL, access: any FileAccess) throws(ImportError) -> FileReference {
        let started = access.startAccessing(url)
        defer { if started { access.stopAccessing(url) } }
        return try reference(for: url, writable: false, access: access)
    }

    private static func reference(for url: URL, writable: Bool, access: any FileAccess) throws(ImportError) -> FileReference {
        do {
            return FileReference(lastKnownPath: url.path(percentEncoded: false), bookmark: try access.bookmark(for: url, writable: writable))
        } catch {
            throw .cantBookmark(url.lastPathComponent)
        }
    }
}
