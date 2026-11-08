import BakeGraph
import Foundation

/// The custom node library: `.bakenode` files in Application Support/BAKE/Custom Nodes, listed in
/// Add Node › Custom in every document (spec §12, Phase C).
public enum CustomNodeLibrary {
    public static var defaultFolder: URL {
        URL.applicationSupportDirectory.appending(path: "BAKE/Custom Nodes", directoryHint: .isDirectory)
    }

    /// Every readable file in `folder`, by name. Files this version can't read are skipped.
    public static func entries(in folder: URL = defaultFolder) -> [CustomNodeFile] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return urls
            .filter { $0.pathExtension == CustomNodeFile.fileExtension }
            .compactMap { url in (try? Data(contentsOf: url)).flatMap { try? CustomNodeFile.decoded($0) } }
            .sorted { $0.definition.name.localizedStandardCompare($1.definition.name) == .orderedAscending }
    }

    /// Saves a file into the library, named after its custom node. Saving the same definition again
    /// replaces its earlier file, even if it was renamed since.
    @discardableResult
    public static func save(_ file: CustomNodeFile, in folder: URL = defaultFolder) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        for url in urls where url.pathExtension == CustomNodeFile.fileExtension {
            if let data = try? Data(contentsOf: url), let saved = try? CustomNodeFile.decoded(data),
               saved.definition.id == file.definition.id {
                try FileManager.default.removeItem(at: url)
            }
        }
        let url = folder.appending(path: fileName(for: file.definition.name, in: folder))
        try file.encoded().write(to: url, options: .atomic)
        return url
    }

    /// "Dusty Loop.bakenode", or "Dusty Loop 2.bakenode" if that's taken; characters a file name
    /// can't hold become dashes.
    static func fileName(for name: String, in folder: URL) -> String {
        let cleaned = name.map { "/:\\".contains($0) ? "-" : $0 }.reduce(into: "") { $0.append($1) }
        let base = cleaned.trimmingCharacters(in: .whitespaces).isEmpty ? "Custom Node" : cleaned
        var candidate = "\(base).\(CustomNodeFile.fileExtension)"
        var number = 2
        while FileManager.default.fileExists(atPath: folder.appending(path: candidate).path) {
            candidate = "\(base) \(number).\(CustomNodeFile.fileExtension)"
            number += 1
        }
        return candidate
    }
}
