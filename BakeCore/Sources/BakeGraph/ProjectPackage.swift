import Foundation

public enum ProjectPackageError: Error, Equatable {
    case notAPackage
    case missingProjectFile
    case unsupportedSchemaVersion(Int)
}

/// Reads and writes the `.bake` document package (a directory) as a `FileWrapper`.
public enum ProjectPackage {
    public static let projectFileName = "project.json"
    /// Where collected audio lives inside the package.
    public static let mediaFolder = "Media"

    /// The package: `project.json`, and the collected audio its assets point at (`media`, by package
    /// path). Media no asset uses is left out, so removing a collected file's last node drops its copy.
    public static func fileWrapper(for project: ProjectFile, media: [String: Data] = [:]) throws -> FileWrapper {
        let encoder = JSONEncoder()
        // Sorted, pretty JSON keeps project files diffable.
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let projectData = try encoder.encode(project)

        var files = [projectFileName: FileWrapper(regularFileWithContents: projectData)]
        let used = Set(project.assets.compactMap(\.packagePath))
        let collected = media.filter { used.contains($0.key) && $0.key.hasPrefix(mediaFolder + "/") }
        if !collected.isEmpty {
            let wrappers = Dictionary(uniqueKeysWithValues: collected.map { path, data in
                (String(path.dropFirst(mediaFolder.count + 1)), FileWrapper(regularFileWithContents: data))
            })
            files[mediaFolder] = FileWrapper(directoryWithFileWrappers: wrappers)
        }
        return FileWrapper(directoryWithFileWrappers: files)
    }

    /// The collected audio in a package, by package path (`Media/loop.wav`).
    public static func media(from wrapper: FileWrapper) -> [String: Data] {
        guard let folder = wrapper.fileWrappers?[mediaFolder], folder.isDirectory else { return [:] }
        var media: [String: Data] = [:]
        for (name, file) in folder.fileWrappers ?? [:] {
            if let data = file.regularFileContents { media["\(mediaFolder)/\(name)"] = data }
        }
        return media
    }

    /// A package path for a file called `name`, not already taken: `Media/loop.wav`, `Media/loop 2.wav`…
    public static func mediaPath(for name: String, taken: Set<String>) -> String {
        let url = URL(filePath: name)
        let stem = url.deletingPathExtension().lastPathComponent
        let suffix = url.pathExtension.isEmpty ? "" : ".\(url.pathExtension)"
        var candidate = "\(mediaFolder)/\(stem)\(suffix)"
        var number = 2
        while taken.contains(candidate) {
            candidate = "\(mediaFolder)/\(stem) \(number)\(suffix)"
            number += 1
        }
        return candidate
    }

    public static func project(from wrapper: FileWrapper) throws -> ProjectFile {
        guard wrapper.isDirectory else { throw ProjectPackageError.notAPackage }
        guard let data = wrapper.fileWrappers?[projectFileName]?.regularFileContents else {
            throw ProjectPackageError.missingProjectFile
        }

        // Check the version before decoding the full model so newer files fail clearly.
        let version = try JSONDecoder().decode(SchemaVersionProbe.self, from: data).schemaVersion
        guard version <= ProjectFile.currentSchemaVersion else {
            throw ProjectPackageError.unsupportedSchemaVersion(version)
        }
        var project = try JSONDecoder().decode(ProjectFile.self, from: data)
        ProjectMigration.migrate(&project)
        return project
    }

    private struct SchemaVersionProbe: Decodable {
        let schemaVersion: Int
    }
}
