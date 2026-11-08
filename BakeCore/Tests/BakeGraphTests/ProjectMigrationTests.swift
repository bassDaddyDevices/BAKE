import Foundation
import Testing
@testable import BakeGraph

struct ProjectMigrationTests {
    private func load(_ json: String) throws -> ProjectFile {
        let wrapper = FileWrapper(directoryWithFileWrappers: ["project.json": FileWrapper(regularFileWithContents: Data(json.utf8))])
        return try ProjectPackage.project(from: wrapper)
    }

    private func node(_ kind: String, _ parameters: String = "{}") -> String {
        #"{"id":"\#(UUID().uuidString)","kind":"\#(kind)","position":{"x":0,"y":0},"parameters":\#(parameters),"modulated":[]}"#
    }

    @Test func olderDocumentsKeepTheDefaultsTheyWereMadeWith() throws {
        let project = try load(#"{"schemaVersion":1,"nodes":[\#(node("distortion"))]}"#)
        #expect(project.schemaVersion == ProjectFile.currentSchemaVersion)
        #expect(project.nodes[0].parameters["drive"] == .number(12))
    }

    @Test func olderResonatorsStayFullyWet() throws {
        let project = try load(#"{"schemaVersion":1,"nodes":[\#(node("resonator"))]}"#)
        #expect(project.nodes[0].parameters["mix"] == .number(1))
        #expect(NodeCatalog.defaultParameters(for: .resonator)["mix"] == .number(0.5))
    }

    @Test func olderWavetableFactoriesKeepReadingTheFirst1024Frames() throws {
        let project = try load(#"{"schemaVersion":7,"nodes":[\#(node("wavetableFactory"))]}"#)
        #expect(project.nodes[0].parameters["source"] == .choice("first1024"))
        #expect(NodeCatalog.defaultParameters(for: .wavetableFactory)["source"] == .choice("whole"))
    }

    @Test func olderReduxesKeepWholeBitsAndTheBiquadAntiAlias() throws {
        let project = try load(#"{"schemaVersion":7,"nodes":[\#(node("redux"))]}"#)
        #expect(project.nodes[0].parameters["bitSteps"] == .choice("whole"))
        #expect(project.nodes[0].parameters["antiAlias"] == .choice("biquad"))
        #expect(NodeCatalog.defaultParameters(for: .redux)["bitSteps"] == .choice("fractional"))
        #expect(NodeCatalog.defaultParameters(for: .redux)["antiAlias"] == .choice("linearPhase"))
    }

    @Test(arguments: [("granularCloud", NodeKind.granularCloud), ("stutter", .stutter)])
    func olderGranularAndStutterKeepTheirModulationRanges(name: String, kind: NodeKind) throws {
        let old = try load(#"{"schemaVersion":8,"nodes":[\#(node(name))]}"#)
        #expect(old.nodes[0].parameters["modulationRange"] == .choice("legacy"))
        #expect(NodeCatalog.defaultParameters(for: kind)["modulationRange"] == .choice("current"))
        let created = try load(#"{"schemaVersion":9,"nodes":[\#(node(name))]}"#)
        #expect(created.nodes[0].parameters["modulationRange"] == nil)
    }

    @Test func olderFlangersStayCausalWithTheOldDelayRange() throws {
        let old = try load(#"{"schemaVersion":8,"nodes":[\#(node("flanger"))]}"#)
        #expect(old.nodes[0].parameters["readHead"] == .choice("causal"))
        #expect(old.nodes[0].parameters["modulationRange"] == .choice("legacy"))
        #expect(NodeCatalog.defaultParameters(for: .flanger)["readHead"] == .choice("throughZero"))
        #expect(NodeCatalog.defaultParameters(for: .flanger)["modulationRange"] == .choice("current"))
    }

    @Test func valuesTheUserSetAreNeverTouched() throws {
        let project = try load(#"{"schemaVersion":1,"nodes":[\#(node("distortion", #"{"drive":{"number":3}}"#))]}"#)
        #expect(project.nodes[0].parameters["drive"] == .number(3))
    }

    @Test func currentDocumentsAreLeftAlone() throws {
        let project = try load(#"{"schemaVersion":2,"nodes":[\#(node("distortion"))]}"#)
        #expect(project.nodes[0].parameters["drive"] == nil)
    }

    @Test func newNodesStoreEveryParameter() {
        var project = ProjectFile()
        let id = project.addNode(.distortion, at: CanvasPoint())
        #expect(project.node(id)?.parameters == NodeCatalog.defaultParameters(for: .distortion))
    }

    @Test func olderSwitchesBecomeFanOutSwitchesAndKeepTheirWires() throws {
        let router = UUID().uuidString, audio = UUID().uuidString, bake = UUID().uuidString
        func plain(_ id: String, _ kind: String) -> String {
            #"{"id":"\#(id)","kind":"\#(kind)","position":{"x":0,"y":0},"parameters":{},"modulated":[]}"#
        }
        let edges = #"[{"from":{"node":"\#(audio)","pin":"out"},"to":{"node":"\#(router)","pin":"in"}},{"from":{"node":"\#(router)","pin":"out2"},"to":{"node":"\#(bake)","pin":"in"}}]"#
        let project = try load(#"{"schemaVersion":9,"nodes":[\#(plain(audio, "audio")),\#(plain(router, "stepSwitch")),\#(plain(bake, "print"))],"edges":\#(edges)}"#)
        #expect(project.nodes.map(\.kind) == [.audio, .stepSwitchFanOut, .print])
        #expect(project.edges.count == 2)
        let pins = NodeCatalog.pins(of: project.nodes[1])
        #expect(pins.filter { $0.direction == .output }.map(\.id) == ["out1", "out2", "out3", "out4"])
    }

    @Test func switchesSavedAtTheCurrentSchemaAreLeftAlone() throws {
        let project = try load(#"{"schemaVersion":10,"nodes":[\#(node("stepSwitch"))]}"#)
        #expect(project.nodes[0].kind == .stepSwitch)
    }
}
