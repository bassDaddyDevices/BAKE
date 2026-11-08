import Foundation
import Testing
@testable import BakeGraph
@testable import BakeSession

/// The custom node library folder (spec §12, Phase C).
struct CustomNodeLibraryTests {
    private func folder() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "bake-library-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    private func file(_ name: String, id: UUID = UUID()) -> CustomNodeFile {
        CustomNodeFile(definition: CustomNodeDefinition(id: id, name: name), from: ProjectFile())
    }

    @Test func savedFilesAreListedByName() throws {
        let library = folder()
        defer { try? FileManager.default.removeItem(at: library) }
        #expect(CustomNodeLibrary.entries(in: library).isEmpty)
        try CustomNodeLibrary.save(file("Vox + Step"), in: library)
        let url = try CustomNodeLibrary.save(file("Crunch"), in: library)
        #expect(url.lastPathComponent == "Crunch.bakenode")
        try Data("not a custom node".utf8).write(to: library.appending(path: "broken.bakenode"))
        #expect(CustomNodeLibrary.entries(in: library).map(\.definition.name) == ["Crunch", "Vox + Step"])
    }

    @Test func savingADefinitionAgainReplacesItsFileEvenAfterARename() throws {
        let library = folder()
        defer { try? FileManager.default.removeItem(at: library) }
        let id = UUID()
        try CustomNodeLibrary.save(file("Crunch", id: id), in: library)
        try CustomNodeLibrary.save(file("Crunchier", id: id), in: library)
        #expect(CustomNodeLibrary.entries(in: library).map(\.definition.name) == ["Crunchier"])
        // A different custom node with a taken name gets its own file.
        let url = try CustomNodeLibrary.save(file("Crunchier"), in: library)
        #expect(url.lastPathComponent == "Crunchier 2.bakenode")
        #expect(CustomNodeLibrary.fileName(for: "A/B: C", in: library) == "A-B- C.bakenode")
    }
}
