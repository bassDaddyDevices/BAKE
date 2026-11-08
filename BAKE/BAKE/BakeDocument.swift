import SwiftUI
import UniformTypeIdentifiers
import BakeGraph

/// SwiftUI document wrapper; all format logic lives in `BakeGraph.ProjectPackage`.
/// `nonisolated` because `FileDocument` reads and writes off the main actor.
nonisolated struct BakeDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.bakeProject]

    var project: ProjectFile
    /// Collected audio (Collect Files), by package path; saved inside the package.
    var media: [String: Data] = [:]

    init(project: ProjectFile = ProjectFile()) {
        self.project = project
    }

    init(configuration: ReadConfiguration) throws {
        project = try ProjectPackage.project(from: configuration.file)
        media = ProjectPackage.media(from: configuration.file)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        try ProjectPackage.fileWrapper(for: project, media: media)
    }
}
