import Foundation
import Testing
@testable import BakeGraph

/// The parameters the Waveshaper, Wavefolder and Phaser cards show, and what happens to documents
/// saved before they existed.
struct ShapingParametersTests {
    private func load(_ json: String) throws -> ProjectFile {
        let wrapper = FileWrapper(directoryWithFileWrappers: ["project.json": FileWrapper(regularFileWithContents: Data(json.utf8))])
        return try ProjectPackage.project(from: wrapper)
    }

    private func node(_ kind: String, _ parameters: String = "{}") -> String {
        #"{"id":"\#(UUID().uuidString)","kind":"\#(kind)","position":{"x":0,"y":0},"parameters":\#(parameters),"modulated":[]}"#
    }

    private func macros(_ kind: NodeKind) -> [String] {
        NodeCatalog.definition(for: kind).parameters.filter { $0.role == .macro }.map(\.id)
    }

    // MARK: What the cards show on the front

    @Test func theWaveshaperShowsItsCurveDriveBiasAndMix() {
        #expect(macros(.waveshaper) == ["curve", "intensity", "bias", "mix"])
        #expect(NodeCatalog.definition(for: .waveshaper).parameter("intensity")?.name == "Drive")
        #expect(NodeCatalog.definition(for: .waveshaper).parameter("oversampling")?.role == .setting)
    }

    @Test func theWavefolderShowsTypeFoldSymmetryStagesAndMix() {
        #expect(macros(.wavefolder) == ["foldShape", "fold", "symmetry", "stages", "mix"])
    }

    @Test func thePhaserShowsCenterWidthStagesRateDepthFeedbackAndMix() {
        #expect(macros(.phaser) == ["center", "width", "stages", "rate", "depth", "feedback", "mix"])
    }

    @Test func offlineLuxuriesAreOnOffer() throws {
        func options(_ kind: NodeKind, _ id: String) throws -> [String] {
            guard case .choice(let options, _) = try #require(NodeCatalog.definition(for: kind).parameter(id)).kind else { return [] }
            return options
        }
        #expect(try options(.waveshaper, "oversampling").last == "256")
        #expect(try options(.wavefolder, "oversampling").last == "256")
        #expect(try options(.wavefolder, "stages").last == "8")
        #expect(try options(.phaser, "stages").last == "512")
        #expect(try options(.waveshaper, "curve").count == TransferCurves.waveshaperCurves.count)
    }

    @Test func newNodesStoreEverythingAndGetTheCleanDefaults() {
        var project = ProjectFile()
        let shaper = project.addNode(.waveshaper, at: CanvasPoint())
        let folder = project.addNode(.wavefolder, at: CanvasPoint())
        #expect(project.node(shaper)?.parameters["curve"] == .choice("tanh"))
        #expect(project.node(shaper)?.parameters["oversampling"] == .choice("8"))
        #expect(project.node(folder)?.parameters["foldShape"] == .choice("triangle"))
        #expect(project.node(folder)?.parameters["oversampling"] == .choice("8"))
    }

    // MARK: Old documents keep their sound

    @Test func olderWaveshapersStayPlainTanhAtTheSampleRate() throws {
        let project = try load(#"{"schemaVersion":2,"nodes":[\#(node("waveshaper", #"{"intensity":{"number":0.8}}"#))]}"#)
        #expect(project.schemaVersion == ProjectFile.currentSchemaVersion)
        let parameters = project.nodes[0].parameters
        #expect(parameters["curve"] == .choice("tanh"))
        #expect(parameters["bias"] == .number(0))
        #expect(parameters["oversampling"] == .choice("1"))
        #expect(parameters["intensity"] == .number(0.8))
    }

    @Test func olderWavefoldersStayTriangleFoldsAtTheSampleRate() throws {
        let project = try load(#"{"schemaVersion":1,"nodes":[\#(node("wavefolder"))]}"#)
        #expect(project.nodes[0].parameters["foldShape"] == .choice("triangle"))
        #expect(project.nodes[0].parameters["oversampling"] == .choice("1"))
    }

    @Test func settingsTheUserChoseAreNeverTouched() throws {
        let project = try load(#"{"schemaVersion":2,"nodes":[\#(node("waveshaper", #"{"oversampling":{"choice":"16"}}"#))]}"#)
        #expect(project.nodes[0].parameters["oversampling"] == .choice("16"))
    }

    @Test func currentDocumentsAreLeftAlone() throws {
        let project = try load(#"{"schemaVersion":3,"nodes":[\#(node("waveshaper"))]}"#)
        #expect(project.nodes[0].parameters["oversampling"] == nil)
    }

    // MARK: The plots

    @Test func theTransferPlotsAreIdentityWhereTheNodesDoNothing() {
        for curve in TransferCurves.waveshaperCurves {
            for x in stride(from: -1.0, through: 1.0, by: 0.25) {
                #expect(abs(TransferCurves.waveshaper(curve: curve, x: x, intensity: 0, bias: 0.7) - x) < 1e-12, "\(curve)")
            }
        }
        for x in stride(from: -1.0, through: 1.0, by: 0.25) {
            #expect(abs(TransferCurves.wavefolder(shape: "triangle", x: x, fold: 0, symmetry: 0.5, stages: 8, saturation: 0) - x) < 1e-12)
        }
    }

    @Test func theTransferPlotsReachFullScaleAndStayBounded() {
        for curve in ["tanh", "arctan", "softsign", "hardClip"] {
            #expect(abs(TransferCurves.waveshaper(curve: curve, x: 1, intensity: 1, bias: 0) - 1) < 1e-9, "\(curve)")
            #expect(abs(TransferCurves.waveshaper(curve: curve, x: -1, intensity: 1, bias: 0) + 1) < 1e-9, "\(curve)")
        }
        for curve in TransferCurves.waveshaperCurves {
            for x in stride(from: -1.0, through: 1.0, by: 0.05) {
                for bias in [-1.0, 0.0, 1.0] {
                    #expect(abs(TransferCurves.waveshaper(curve: curve, x: x, intensity: 1, bias: bias)) <= 2, "\(curve)")
                }
            }
        }
        for shape in ["triangle", "sine"] {
            for x in stride(from: -1.0, through: 1.0, by: 0.05) {
                #expect(abs(TransferCurves.wavefolder(shape: shape, x: x, fold: 1, symmetry: 1, stages: 8, saturation: 1)) <= 1)
            }
        }
    }

    @Test func aTriangleFoldReflectsAtTheEdges() {
        // Fold 0.5 multiplies by 8.5: 0.2 → 1.7 → reflected to 0.3; stage count 1.
        #expect(abs(TransferCurves.wavefolder(shape: "triangle", x: 0.2, fold: 0.5, symmetry: 0, stages: 1, saturation: 0) - 0.3) < 1e-9)
    }
}
