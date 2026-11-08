import Foundation
import Testing
@testable import BakeGraph

struct ProjectPackageTests {
    @Test func newProjectUsesCurrentSchemaVersion() {
        #expect(ProjectFile().schemaVersion == ProjectFile.currentSchemaVersion)
        #expect(ProjectFile.currentSchemaVersion == 11)
    }

    @Test func roundTripsThroughFileWrapper() throws {
        let original = ProjectFile()
        let wrapper = try ProjectPackage.fileWrapper(for: original)

        #expect(wrapper.isDirectory)
        #expect(wrapper.fileWrappers?[ProjectPackage.projectFileName] != nil)
        #expect(try ProjectPackage.project(from: wrapper) == original)
    }

    @Test func roundTripsThroughDisk() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("bake")
        defer { try? FileManager.default.removeItem(at: url) }

        try ProjectPackage.fileWrapper(for: ProjectFile())
            .write(to: url, options: .atomic, originalContentsURL: nil)
        let reread = try FileWrapper(url: url)

        #expect(try ProjectPackage.project(from: reread) == ProjectFile())
    }

    @Test func projectJSONIsStableAndReadable() throws {
        let wrapper = try ProjectPackage.fileWrapper(for: ProjectFile())
        let data = try #require(wrapper.fileWrappers?[ProjectPackage.projectFileName]?.regularFileContents)
        let text = try #require(String(data: data, encoding: .utf8))

        #expect(text.contains("\"schemaVersion\" : \(ProjectFile.currentSchemaVersion)"))
    }

    @Test func rejectsRegularFile() {
        let file = FileWrapper(regularFileWithContents: Data("{}".utf8))
        #expect(throws: ProjectPackageError.notAPackage) {
            try ProjectPackage.project(from: file)
        }
    }

    @Test func rejectsPackageWithoutProjectFile() {
        let empty = FileWrapper(directoryWithFileWrappers: [:])
        #expect(throws: ProjectPackageError.missingProjectFile) {
            try ProjectPackage.project(from: empty)
        }
    }

    @Test func rejectsNewerSchemaVersion() throws {
        let json = Data(#"{ "schemaVersion" : 99 }"#.utf8)
        let wrapper = FileWrapper(directoryWithFileWrappers: [
            ProjectPackage.projectFileName: FileWrapper(regularFileWithContents: json),
        ])
        #expect(throws: ProjectPackageError.unsupportedSchemaVersion(99)) {
            try ProjectPackage.project(from: wrapper)
        }
    }
}
