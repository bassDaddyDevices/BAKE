import Foundation
import Testing
@testable import BakeGraph
@testable import BakeRender

/// The "modulate more" pass: each control made modulatable changes the output when an LFO drives it,
/// and the result is the same in any chunk size. (`ModulationGoldenTests` pins the unmodulated bits.)
struct ModulateMoreTests {
    struct Case: Sendable, CustomTestStringConvertible {
        let kind: NodeKind
        let parameter: ParameterID
        var parameters: [ParameterID: ParameterValue] = [:]
        var feeds: [PinID: NodeKind] = [:]
        var outPin: PinID = "out"
        var testDescription: String {
            let extras = parameters.keys.sorted().map { "\($0)=\(parameters[$0]!)" }.joined(separator: ",")
            return "\(kind.rawValue).\(parameter)" + (extras.isEmpty ? "" : " [\(extras)]")
        }
    }

    static let cases: [Case] = [
        Case(kind: .envelopeFollower, parameter: "attack"),
        Case(kind: .envelopeFollower, parameter: "release"),
        Case(kind: .envelopeFollower, parameter: "gain"),
        Case(kind: .envelope, parameter: "timeScale", feeds: ["trigger": .clock]),
        Case(kind: .math, parameter: "scale", feeds: ["a": .lfo, "b": .clock]),
        Case(kind: .math, parameter: "clampMax", parameters: ["clampMax": .number(0.3)], feeds: ["a": .lfo, "b": .clock]),
        Case(kind: .lfo, parameter: "phase", parameters: ["rate": .number(3)]),
        Case(kind: .logic, parameter: "hysteresis", parameters: ["hysteresis": .number(0.2)], feeds: ["a": .lfo]),
        Case(kind: .logic, parameter: "holdTime", parameters: ["holdTime": .number(0.05)], feeds: ["a": .lfo]),
        Case(kind: .quantizer, parameter: "glide", parameters: ["glide": .number(0.2)], feeds: ["in": .lfo]),
        Case(kind: .generator, parameter: "level", parameters: ["type": .choice("pink")]),
        Case(kind: .generator, parameter: "density", parameters: ["type": .choice("dust"), "level": .number(-6)]),
        Case(kind: .delay, parameter: "time", parameters: ["feedback": .number(0.5)]),
        Case(kind: .delay, parameter: "feedback"),
        Case(kind: .delay, parameter: "damping", parameters: ["feedback": .number(0.7)]),
        Case(kind: .delay, parameter: "mix"),
        Case(kind: .convolver, parameter: "mix"),
        Case(kind: .compressor, parameter: "mix", parameters: ["threshold": .number(-60), "ratio": .number(20)]),
        Case(kind: .compressor, parameter: "makeup"),
        Case(kind: .limiter, parameter: "gain"),
        Case(kind: .otftCompressor, parameter: "mix", parameters: ["downThreshold": .number(-70), "fftSize": .choice("2048")]),
        Case(kind: .otftCompressor, parameter: "outputGain", parameters: ["fftSize": .choice("2048")]),
        Case(kind: .frequencyShifter, parameter: "shift", parameters: ["precision": .choice("standard")]),
        Case(kind: .frequencyShifter, parameter: "mix", parameters: ["precision": .choice("standard")]),
        Case(kind: .reverb, parameter: "mix", parameters: ["lines": .choice("16"), "tail": .number(1)]),
        Case(kind: .utility, parameter: "gain"),
        Case(kind: .utility, parameter: "balance"),
        Case(kind: .sampleAndHold, parameter: "rate"),
        Case(kind: .sampleAndHold, parameter: "glide", parameters: ["glide": .number(5)], feeds: ["trigger": .clock]),
        Case(kind: .random, parameter: "rate", parameters: ["interpolation": .choice("linear")]),
        Case(kind: .random, parameter: "max", parameters: ["interpolation": .choice("cosine")]),
        Case(kind: .stepSwitchFanOut, parameter: "crossfade", parameters: ["crossfade": .number(20)], feeds: ["advance": .clock], outPin: "out1"),
        Case(kind: .stepSwitch, parameter: "crossfade", parameters: ["crossfade": .number(20)], feeds: ["advance": .clock, "in1": .audio, "in2": .audio]),
        Case(kind: .redux, parameter: "mask", parameters: ["reduxMode": .choice("bitwise"), "mask": .number(20_000)]),
        Case(kind: .redux, parameter: "reduxMode"),
        Case(kind: .redux, parameter: "bitwiseOperator", parameters: ["reduxMode": .choice("bitwise")]),
        Case(kind: .chorus, parameter: "driftRate"),
        Case(kind: .chorus, parameter: "panSpread"),
        Case(kind: .phaser, parameter: "stereoOffset"),
        Case(kind: .flanger, parameter: "hfDamping"),
        Case(kind: .wavefolder, parameter: "saturation"),
        Case(kind: .wavefolder, parameter: "foldShape"),
        Case(kind: .halfTime, parameter: "window", parameters: ["window": .number(120)]),
        Case(kind: .halfTime, parameter: "smooth", parameters: ["window": .number(120), "smooth": .number(20)]),
        Case(kind: .halfTime, parameter: "grain", parameters: ["mode": .choice("granular"), "grain": .number(60)]),
        Case(kind: .stretch, parameter: "pitchCents", parameters: ["fftSize": .choice("1024")]),
        Case(kind: .vocoder, parameter: "attack", feeds: ["carrier": .audio, "modulator": .audio]),
        Case(kind: .vocoder, parameter: "release", feeds: ["carrier": .audio, "modulator": .audio]),
        Case(kind: .vocoder, parameter: "sibilance", feeds: ["carrier": .audio, "modulator": .audio]),
        Case(kind: .clock, parameter: "bpm"),
        Case(kind: .clock, parameter: "gateLength", parameters: ["gateLength": .number(40)]),
        Case(kind: .clock, parameter: "division"),
        Case(kind: .resonator, parameter: "root"),
        Case(kind: .resonator, parameter: "fine"),
        Case(kind: .resonator, parameter: "decay"),
        Case(kind: .resonator, parameter: "inharmonicity", parameters: ["inharmonicity": .number(0.3)]),
        Case(kind: .resonator, parameter: "mix"),
        Case(kind: .derivativeDistortion, parameter: "slopeDrive"),
        Case(kind: .derivativeDistortion, parameter: "curveDrive", parameters: ["curveDrive": .number(30)]),
        Case(kind: .derivativeDistortion, parameter: "edge"),
        Case(kind: .derivativeDistortion, parameter: "splay"),
        Case(kind: .derivativeDistortion, parameter: "output"),
        Case(kind: .derivativeDistortion, parameter: "mix"),
        Case(kind: .residualExplosion, parameter: "severity"),
        Case(kind: .residualExplosion, parameter: "residualGain"),
        Case(kind: .residualExplosion, parameter: "body"),
        Case(kind: .residualExplosion, parameter: "mix", parameters: ["body": .number(0.5)]),
        Case(kind: .subHarmonic, parameter: "sub1"),
        Case(kind: .subHarmonic, parameter: "sub2"),
        Case(kind: .subHarmonic, parameter: "tone"),
        Case(kind: .subHarmonic, parameter: "dry"),
        Case(kind: .subHarmonic, parameter: "track"),
        Case(kind: .subHarmonic, parameter: "release"),
        Case(kind: .tapeDegrade, parameter: "wow"),
        Case(kind: .tapeDegrade, parameter: "flutter"),
        Case(kind: .tapeDegrade, parameter: "saturation"),
        Case(kind: .tapeDegrade, parameter: "tone"),
        Case(kind: .tapeDegrade, parameter: "mix", parameters: ["mix": .number(0.5)]),
        Case(kind: .tapeDegrade, parameter: "wowRate"),
        Case(kind: .tapeDegrade, parameter: "flutterRate"),
        Case(kind: .tapeDegrade, parameter: "hiss", parameters: ["hiss": .number(-60)]),
        Case(kind: .tapeDegrade, parameter: "dropouts", parameters: ["dropouts": .number(0.3)]),
        Case(kind: .dualFilter, parameter: "cutoff"),
        Case(kind: .dualFilter, parameter: "q"),
        Case(kind: .dualFilter, parameter: "bandwidth"),
        Case(kind: .dualFilter, parameter: "morph"),
        Case(kind: .dualFilter, parameter: "lfoRate", parameters: ["lfoDepth": .number(0.5)]),
        Case(kind: .dualFilter, parameter: "lfoDepth"),
        Case(kind: .dualFilter, parameter: "drive"),
        Case(kind: .dualFilter, parameter: "mix", parameters: ["mix": .number(0.5)]),
        Case(kind: .adaptiveClipping, parameter: "threshold"),
        Case(kind: .adaptiveClipping, parameter: "release"),
        Case(kind: .adaptiveClipping, parameter: "makeup"),
        Case(kind: .adaptiveClipping, parameter: "mix", parameters: ["mix": .number(0.5)]),
        Case(kind: .adaptiveClipping, parameter: "floor", parameters: ["floor": .number(-30)]),
        Case(kind: .granularCloud, parameter: "size"),
        Case(kind: .granularCloud, parameter: "density"),
        Case(kind: .granularCloud, parameter: "spray"),
        Case(kind: .granularCloud, parameter: "pitchSpread"),
        Case(kind: .granularCloud, parameter: "mix", parameters: ["mix": .number(0.5)]),
        Case(kind: .granularCloud, parameter: "pitch"),
        Case(kind: .granularCloud, parameter: "reverse"),
        Case(kind: .granularCloud, parameter: "stereoSpread"),
        Case(kind: .temporalShatter, parameter: "grain"),
        // Pass 2: choices, switched per sample (or per filter block).
        Case(kind: .adaptiveClipping, parameter: "knee", parameters: ["threshold": .number(-12)]),
        Case(kind: .dualFilter, parameter: "alphaType"),
        Case(kind: .dualFilter, parameter: "betaType"),
        Case(kind: .dualFilter, parameter: "lfoShape", parameters: ["lfoDepth": .number(0.5), "lfoRate": .number(3)]),
        Case(kind: .dualFilter, parameter: "lfoPhase", parameters: ["lfoDepth": .number(0.5), "lfoRate": .number(3)]),
        Case(kind: .residualExplosion, parameter: "mode"),
        Case(kind: .fractalFilter, parameter: "iterations", parameters: ["fftSize": .choice("1024")]),
        Case(kind: .fractalFilter, parameter: "pattern", parameters: ["fftSize": .choice("1024")]),
        Case(kind: .fractalFilter, parameter: "phaseMode", parameters: ["fftSize": .choice("1024")]),
        Case(kind: .fractalFilter, parameter: "bias", parameters: ["fftSize": .choice("1024")]),
        Case(kind: .fractalFilter, parameter: "q", parameters: ["fftSize": .choice("1024")]),
        Case(kind: .fractalFilter, parameter: "mix", parameters: ["fftSize": .choice("1024"), "mix": .number(0.5)]),
        Case(kind: .distortion, parameter: "mode", parameters: ["drive": .number(18)]),
        Case(kind: .waveshaper, parameter: "curve", parameters: ["intensity": .number(0.9)]),
        Case(kind: .filters, parameter: "type"),
        Case(kind: .filters, parameter: "type", parameters: ["phase": .choice("linear"), "firTaps": .choice("1025")]),
        Case(kind: .math, parameter: "operator", feeds: ["a": .lfo, "b": .clock]),
        Case(kind: .logic, parameter: "operator", feeds: ["a": .lfo, "b": .clock]),
        Case(kind: .lfo, parameter: "shape", parameters: ["rate": .number(3)]),
        Case(kind: .quantizer, parameter: "scale", feeds: ["in": .lfo]),
        // Root only matters off the chromatic scale, where every note is allowed.
        Case(kind: .quantizer, parameter: "root", parameters: ["scale": .choice("major")], feeds: ["in": .lfo]),
    ]

    /// Renders the case; with `modulate`, a 6.3 Hz LFO drives the parameter's Page 2 pin.
    static func render(_ test: Case, modulate: Bool, chunk: Int) async throws -> [[Float]] {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("source.wav")
        try TestAudio.write(TestAudio.samples(frames: 48_000, channels: 2), to: file, sampleRate: 48_000)
        let output = directory.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        var graph = TestProject()
        let audio = graph.add(.audio, asset: sourceAsset)
        var parameters = NodeCatalog.defaultParameters(for: test.kind)
        parameters.merge(test.parameters) { $1 }
        let node = graph.add(test.kind, parameters, modulated: modulate ? [test.parameter] : [])
        let definition = NodeCatalog.definition(for: test.kind)
        for (pin, kind) in test.feeds.sorted(by: { $0.key < $1.key }) {
            let source = kind == .audio ? audio : graph.add(kind, NodeCatalog.defaultParameters(for: kind))
            graph.connect(source, to: node, pin)
        }
        if definition.pins.contains(where: { $0.id == "in" && $0.signal == .audio }) && test.feeds["in"] == nil {
            graph.connect(audio, to: node)
        }
        if modulate {
            var lfo = NodeCatalog.defaultParameters(for: .lfo)
            lfo["rate"] = .number(6.3)
            graph.connect(graph.add(.lfo, lfo), to: node, NodeCatalog.modulationPinID(for: test.parameter))
        }
        let bake = graph.add(.print, ["bitDepth": .choice("32f")])
        if definition.pins.first(where: { $0.direction == .output })?.signal == .control {
            let vca = graph.add(.gainVCA, NodeCatalog.defaultParameters(for: .gainVCA))
            graph.connect(audio, to: vca)
            graph.connect(node, to: vca, "amount")
            graph.connect(vca, to: bake)
        } else {
            graph.project.edges.append(Edge(from: PinRef(node: node, pin: test.outPin), to: PinRef(node: bake, pin: "in")))
        }
        let urls = [sourceAsset: file]
        let request = RenderRequest(plan: try compile(graph.project, assetURLs: urls), assetURLs: urls, outputDirectory: output, chunkFrames: chunk)
        return try TestAudio.read(try #require(try await RenderEngine.render(request).outputs[bake])).samples
    }

    @Test(arguments: cases)
    func modulationChangesTheSoundTheSameInAnyChunkSize(_ test: Case) async throws {
        #expect(NodeCatalog.definition(for: test.kind).parameter(test.parameter)?.isModulatable == true)
        let still = try await Self.render(test, modulate: false, chunk: 65_536)
        let moving = try await Self.render(test, modulate: true, chunk: 65_536)
        #expect(moving != still, "modulating \(test.testDescription) changed nothing")
        #expect(try await Self.render(test, modulate: true, chunk: 777) == moving)
        let finite = moving.joined().allSatisfy(\.isFinite)
        #expect(finite)
    }
}
