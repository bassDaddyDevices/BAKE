import Foundation
import Testing
@testable import BakeGraph

/// What Batch Conform does to a file, from its tempo, key and the targets.
struct ConformPlanTests {
    private func values(_ parameters: [ParameterID: ParameterValue] = [:]) -> [ParameterID: ParameterValue] {
        NodeCatalog.resolvedParameters(of: Node(kind: .batchConform, parameters: parameters))
    }

    @Test func tempoFoldsTowardTheTargetAndKeysTakeTheNearestMove() {
        #expect(ConformPlan.fold(70, to: 140) == 140)
        #expect(ConformPlan.fold(180, to: 90) == 90)
        #expect(ConformPlan.fold(100, to: 120) == 100)
        #expect(ConformPlan.nearestShift(from: 9, to: 0) == 3)  // A to C: up 3, not down 9
        #expect(ConformPlan.nearestShift(from: 2, to: 0) == -2)  // D to C
        #expect(ConformPlan.nearestShift(from: 6, to: 0) == -6)  // F♯ to C: the tritone goes down
        #expect(ConformPlan.nearestShift(from: 0, to: 0) == 0)
    }

    @Test func theNameComesBeforeWhatWasDetected() {
        let named = ConformPlan.settings(values(), name: "drums 100bpm Am", detectedBPM: 133, detectedKey: .init(root: 2, minor: false))
        #expect(named.bpm == 100 && named.key == .init(root: 9, minor: true))
        #expect(abs(named.ratio - 100.0 / 120) < 1e-12 && named.shift == 3)
        let unnamed = ConformPlan.settings(values(), name: "loop", detectedBPM: 140, detectedKey: .init(root: 2, minor: false))
        #expect(abs(unnamed.ratio - 140.0 / 120) < 1e-12 && unnamed.shift == -2)
    }

    @Test func depthModeAndWhatIsntFoundLimitTheChange() {
        let half = ConformPlan.settings(values(["depth": .number(50)]), name: nil, detectedBPM: 90, detectedKey: nil)
        #expect(abs(half.ratio - (90.0 / 120).squareRoot()) < 1e-12)
        let keyOnly = ConformPlan.settings(values(["conform": .choice("key")]), name: "x 90bpm Em", detectedBPM: nil, detectedKey: nil)
        #expect(keyOnly.ratio == 1 && keyOnly.shift == -4)
        let tempoOnly = ConformPlan.settings(values(["conform": .choice("tempo")]), name: "x 90bpm Em", detectedBPM: nil, detectedKey: nil)
        #expect(abs(tempoOnly.ratio - 0.75) < 1e-12 && tempoOnly.shift == 0)
        let nothing = ConformPlan.settings(values(), name: "hit", detectedBPM: nil, detectedKey: nil)
        #expect(nothing.ratio == 1 && nothing.shift == 0 && nothing.bpm == nil && nothing.key == nil)
    }

    @Test func aBatchBakeAfterAConformCanPutItsTargetsInTheName() throws {
        var project = ProjectFile()
        let source = project.addNode(.batchAudio, at: CanvasPoint())
        let conform = project.addNode(.batchConform, at: CanvasPoint())
        let bake = project.addNode(.batchBake, at: CanvasPoint())
        project.setSourceFolder(FileReference(lastKnownPath: "/loops"), for: source)
        project.setParameter("targetBPM", of: conform, to: .number(128))
        project.setParameter("targetKey", of: conform, to: .choice("F#"))
        project.setParameter("name", of: bake, to: .text("{source}_{bpm}_{key}"))
        try project.connect(from: PinRef(node: source, pin: "out"), to: PinRef(node: conform, pin: "in"))
        try project.connect(from: PinRef(node: conform, pin: "out"), to: PinRef(node: bake, pin: "in"))
        let run = BatchRun(project: project, files: [source: [BatchFile(path: "/loops/groove.wav")]])
        #expect(run.fileName(of: bake, pass: 0) == "groove_128_F#")
        #expect(run.conforms == [conform])
        #expect(run.measureProbe(0)?.node(conform)?.kind == .print)
        let pass = try #require(run.batchPass(0, settings: [conform: ["ratio": .number(1.5)]]))
        #expect(pass.node(conform)?.parameters["ratio"] == .number(1.5))
    }
}
