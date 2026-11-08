import Foundation
import Testing
@testable import BakeGraph

/// `.bakenode` files (spec §12, Phase C).
struct CustomNodeFileTests {
    private let asset = AssetReference(id: AssetID(testUUID(80_001)), lastKnownPath: "/tmp/loop.wav")
    private let other = AssetReference(id: AssetID(testUUID(80_002)), lastKnownPath: "/tmp/other.wav")

    /// Filters grouped, with an Audio node inside (as custom nodes made before Audio was kept out of
    /// groups may have), and an unrelated file in the document.
    private func patch() throws -> (ProjectFile, CustomNodeDefinition) {
        var project = ProjectFile(assets: [asset, other])
        let filters = project.addNode(.filters, at: CanvasPoint(x: 300))
        let bake = project.addNode(.print, at: CanvasPoint(x: 600))
        try project.connect(from: PinRef(node: filters, pin: "out"), to: PinRef(node: bake, pin: "in"))
        project.groupNodes([filters], name: "Dusty Loop")
        project.customNodes[0].nodes.append(Node(kind: .audio, assetID: asset.id))
        return (project, try #require(project.customNodes.first))
    }

    @Test func aFileCarriesTheDefinitionAndOnlyTheFilesItPlays() throws {
        let (project, definition) = try patch()
        var file = CustomNodeFile(definition: definition, from: project)
        file.author = "Chris"
        #expect(file.assets == [asset])
        let data = try file.encoded()
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("\"formatVersion\" : 1"))
        #expect(text.contains("\"schemaVersion\" : \(ProjectFile.currentSchemaVersion)"))
        #expect(try CustomNodeFile.decoded(data) == file)
    }

    @Test func importingAddsTheDefinitionAndItsFilesOnce() throws {
        let (project, definition) = try patch()
        let file = CustomNodeFile(definition: definition, from: project)
        var other = ProjectFile()
        let id = other.importCustomNode(file)
        #expect(id == definition.id)
        #expect(other.customNodes == [definition])
        #expect(other.assets == [asset])
        // The same file again is the same definition: nothing new.
        #expect(other.importCustomNode(file) == id)
        #expect(other.customNodes.count == 1)
        #expect(other.assets == [asset])
        #expect(other.addCustomNode(id, at: CanvasPoint()) != nil)
    }

    @Test func aChangedVersionUnderTheSameIDIsKeptBesideTheOriginal() throws {
        let (project, definition) = try patch()
        var changed = definition
        changed.name = "Dustier Loop"
        var document = project
        let id = document.importCustomNode(CustomNodeFile(definition: changed, from: project))
        #expect(id != definition.id)
        #expect(document.customNodes.map(\.name) == ["Dusty Loop", "Dustier Loop"])
    }

    @Test func olderFilesAreMigratedAndNewerOnesRefused() throws {
        let (project, definition) = try patch()
        var old = definition
        old.nodes.append(Node(kind: .looper, parameters: ["length": .number(250)]))
        var file = CustomNodeFile(definition: old, from: project)
        file.schemaVersion = 5
        let migrated = try CustomNodeFile.decoded(try file.encoded())
        #expect(migrated.definition.nodes.last?.parameters["mode"] == .choice("once"))
        #expect(migrated.schemaVersion == ProjectFile.currentSchemaVersion)

        file.schemaVersion = ProjectFile.currentSchemaVersion + 1
        #expect(throws: CustomNodeFileError.unsupportedSchemaVersion(ProjectFile.currentSchemaVersion + 1)) {
            try CustomNodeFile.decoded(try file.encoded())
        }
        file.schemaVersion = ProjectFile.currentSchemaVersion
        file.formatVersion = 2
        #expect(throws: CustomNodeFileError.unsupportedFormat(2)) { try CustomNodeFile.decoded(try file.encoded()) }
        #expect(throws: CustomNodeFileError.unreadable) { try CustomNodeFile.decoded(Data("nope".utf8)) }
    }
}
