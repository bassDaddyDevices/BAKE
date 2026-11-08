import Foundation
import Testing
@testable import BakeGraph

struct ProjectModelTests {
    @Test func m0FileDecodesAsEmptyProject() throws {
        let data = Data(#"{ "schemaVersion" : 1 }"#.utf8)
        let project = try JSONDecoder().decode(ProjectFile.self, from: data)
        #expect(project == ProjectFile(schemaVersion: 1)) // decoded directly; ProjectPackage migrates on load
        #expect(project.settings.sampleRate == 48_000)
    }

    @Test func fullProjectRoundTripsThroughPackage() throws {
        let audio = Node(
            id: NodeID(testUUID(1)), kind: .audio, position: CanvasPoint(x: 10, y: 20),
            parameters: ["gain": .number(-6)], assetID: testAsset
        )
        let filters = Node(
            id: NodeID(testUUID(2)), kind: .filters,
            parameters: ["type": .choice("highpass")], modulated: ["cutoff"]
        )
        let project = ProjectFile(
            settings: ProjectSettings(sampleRate: 44_100),
            nodes: [audio, filters],
            edges: [Edge(from: PinRef(node: audio.id, pin: "out"), to: PinRef(node: filters.id, pin: "in"))],
            assets: [AssetReference(id: testAsset, lastKnownPath: "/tmp/kick.wav")]
        )
        let reread = try ProjectPackage.project(from: ProjectPackage.fileWrapper(for: project))
        #expect(reread == project)
    }

    @Test func modulatedParametersStaySortedAndUnique() {
        var node = Node(kind: .filters, modulated: ["q", "cutoff", "q"])
        #expect(node.modulated == ["cutoff", "q"])
        node.setModulated("drive", true)
        node.setModulated("q", false)
        #expect(node.modulated == ["cutoff", "drive"])
    }

    @Test func parameterValuesEncodeReadably() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let values: [String: ParameterValue] = ["a": .number(2), "b": .choice("sine"), "c": .text("kick")]
        let json = String(decoding: try encoder.encode(values), as: UTF8.self)
        #expect(json == #"{"a":{"number":2},"b":{"choice":"sine"},"c":{"text":"kick"}}"#)
    }

    @Test func encodingIsByteForByteStable() throws {
        let node = Node(
            id: NodeID(testUUID(1)), kind: .lfo,
            parameters: ["rate": .number(2), "depth": .number(0.5)], modulated: ["rate", "depth"]
        )
        let project = ProjectFile(nodes: [node])
        let first = try ProjectPackage.fileWrapper(for: project).fileWrappers?["project.json"]?.regularFileContents
        let second = try ProjectPackage.fileWrapper(for: project).fileWrappers?["project.json"]?.regularFileContents
        #expect(first != nil)
        #expect(first == second)
    }

    @Test func trimsDefaultToFullAndAreClamped() {
        var node = Node(kind: .filters, modulated: ["cutoff"])
        #expect(node.modulationTrims.isEmpty)
        node.setTrim(-3, for: "cutoff")
        #expect(node.modulationTrims["cutoff"] == -1)
        node.setTrim(0.25, for: "cutoff")
        #expect(node.modulationTrims["cutoff"] == 0.25)
    }

    @Test func nodesSavedBeforeTrimsStillDecode() throws {
        let json = #"{"id":"00000000-0000-0000-0000-000000000001","kind":"filters","position":{"x":0,"y":0},"parameters":{},"modulated":["cutoff"]}"#
        let node = try JSONDecoder().decode(Node.self, from: Data(json.utf8))
        #expect(node.modulated == ["cutoff"])
        #expect(node.modulationTrims.isEmpty)
    }
}
