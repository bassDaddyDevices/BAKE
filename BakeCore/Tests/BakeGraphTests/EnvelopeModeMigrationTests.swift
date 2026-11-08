import Foundation
import Testing
@testable import BakeGraph

struct EnvelopeModeMigrationTests {
    private func load(_ json: String) throws -> ProjectFile {
        let wrapper = FileWrapper(directoryWithFileWrappers: ["project.json": FileWrapper(regularFileWithContents: Data(json.utf8))])
        return try ProjectPackage.project(from: wrapper)
    }

    private func envelope(_ parameters: String = "{}") -> String {
        #"{"id":"\#(UUID().uuidString)","kind":"envelope","position":{"x":0,"y":0},"parameters":\#(parameters),"modulated":[]}"#
    }

    @Test func savedEnvelopesKeepTodaysBehaviour() throws {
        let project = try load(#"{"schemaVersion":3,"nodes":[\#(envelope())]}"#)
        #expect(project.nodes[0].parameters["triggerMode"] == .choice("classic"))
        #expect(project.schemaVersion == ProjectFile.currentSchemaVersion)
    }

    @Test func aChosenModeIsNeverTouched() throws {
        let project = try load(#"{"schemaVersion":3,"nodes":[\#(envelope(#"{"triggerMode":{"choice":"gate"}}"#))]}"#)
        #expect(project.nodes[0].parameters["triggerMode"] == .choice("gate"))
    }

    @Test func currentDocumentsAreLeftAlone() throws {
        let project = try load(#"{"schemaVersion":4,"nodes":[\#(envelope())]}"#)
        #expect(project.nodes[0].parameters["triggerMode"] == nil)
    }

    @Test func newEnvelopesAreOneShot() {
        #expect(NodeCatalog.defaultParameters(for: .envelope)["triggerMode"] == .choice("oneShot"))
    }
}
