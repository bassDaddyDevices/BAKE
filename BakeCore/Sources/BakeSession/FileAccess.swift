import Foundation

public struct ResolvedBookmark: Sendable {
    public let url: URL
    /// The bookmark should be re-created (the file moved or the bookmark aged).
    public let isStale: Bool
}

/// Bookmark creation and resolution, swappable so tests run without the sandbox.
public protocol FileAccess: Sendable {
    func bookmark(for url: URL, writable: Bool) throws -> Data
    func resolve(_ bookmark: Data) throws -> ResolvedBookmark
    /// Starts security-scoped access; balance every `true` with `stopAccessing`.
    func startAccessing(_ url: URL) -> Bool
    func stopAccessing(_ url: URL)
}

/// The app's file access: app-scoped, security-scoped bookmarks (App Sandbox).
/// Audio files are bookmarked read-only, the Print folder read/write.
public struct SecurityScopedFileAccess: FileAccess {
    public init() {}

    public func bookmark(for url: URL, writable: Bool) throws -> Data {
        let started = url.startAccessingSecurityScopedResource()
        defer { if started { url.stopAccessingSecurityScopedResource() } }
        let options: URL.BookmarkCreationOptions = writable
            ? [.withSecurityScope]
            : [.withSecurityScope, .securityScopeAllowOnlyReadAccess]
        return try url.bookmarkData(options: options, includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    public func resolve(_ bookmark: Data) throws -> ResolvedBookmark {
        var isStale = false
        let url = try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &isStale)
        return ResolvedBookmark(url: url, isStale: isStale)
    }

    public func startAccessing(_ url: URL) -> Bool {
        url.startAccessingSecurityScopedResource()
    }

    public func stopAccessing(_ url: URL) {
        url.stopAccessingSecurityScopedResource()
    }
}

/// Plain bookmarks (they still follow moves), for tests and unsandboxed tools.
public struct PlainFileAccess: FileAccess {
    public init() {}

    public func bookmark(for url: URL, writable: Bool) throws -> Data {
        try url.bookmarkData()
    }

    public func resolve(_ bookmark: Data) throws -> ResolvedBookmark {
        var isStale = false
        let url = try URL(resolvingBookmarkData: bookmark, bookmarkDataIsStale: &isStale)
        return ResolvedBookmark(url: url, isStale: isStale)
    }

    public func startAccessing(_ url: URL) -> Bool { false }

    public func stopAccessing(_ url: URL) {}
}
