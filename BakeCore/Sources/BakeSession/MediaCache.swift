import CryptoKit
import Foundation

/// Collected audio (Collect Files), unpacked so it can be read like any file. The engine reads
/// files by URL, and a document's package contents arrive as data, so each one is written once to
/// Caches/BAKE/Media under its content hash; reopening the same document finds them there.
public enum MediaCache {
    public static var defaultFolder: URL {
        URL.cachesDirectory.appending(path: "BAKE/Media", directoryHint: .isDirectory)
    }

    /// Each package path's file in the cache, writing the ones not there yet.
    public static func unpack(_ media: [String: Data], into folder: URL = defaultFolder) throws -> [String: URL] {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var urls: [String: URL] = [:]
        for (path, data) in media {
            let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            let suffix = URL(filePath: path).pathExtension
            let url = folder.appending(path: suffix.isEmpty ? hash : "\(hash).\(suffix)")
            if !FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
                try data.write(to: url, options: .atomic)
            }
            urls[path] = url
        }
        return urls
    }
}
