import Foundation
import Testing
@testable import BakeGraph
@testable import BakeRender

/// Owner rule: saved patches never change sound. Fingerprints of each node the "modulate more"
/// pass touches, rendered unmodulated through the real engine, taken before any of them changed.
/// Making a control modulatable must leave every one of these bits alone.
struct ModulationGoldenTests {
    /// Audio nodes run Audio → node → Bake; control nodes drive a Gain/VCA's amount.
    private enum Shape { case audio, control }

    private struct Case: Sendable {
        let name: String
        let kind: NodeKind
        let parameters: [ParameterID: ParameterValue]
        var feeds: [PinID: NodeKind] = [:]    // extra sources wired into the node's inputs
        var outPin: PinID = "out"
    }

    private static func choices(_ kind: NodeKind, _ id: ParameterID) -> [String] {
        if case .choice(let options, _)? = NodeCatalog.definition(for: kind).parameter(id)?.kind { options } else { [] }
    }

    private static let cases: [Case] = {
        var cases: [Case] = [
            Case(name: "envelopeFollower", kind: .envelopeFollower, parameters: ["attack": .number(3), "release": .number(40), "gain": .number(2)]),
            Case(name: "fractalFilter", kind: .fractalFilter, parameters: [:]),
            Case(name: "envelope", kind: .envelope, parameters: ["timeScale": .number(0.7)], feeds: ["trigger": .clock]),
            Case(name: "resonator", kind: .resonator, parameters: ["root": .number(220), "fine": .number(13), "decay": .number(1.1), "inharmonicity": .number(0.2), "mix": .number(0.6)]),
            Case(name: "clock", kind: .clock, parameters: ["bpm": .number(133.3), "gateLength": .number(37), "division": .choice("1/8")]),
            Case(name: "math", kind: .math, parameters: ["scale": .number(1.7), "clampMin": .number(-0.5), "clampMax": .number(0.8)], feeds: ["a": .lfo, "b": .clock]),
            Case(name: "lfo", kind: .lfo, parameters: ["phase": .number(90), "rate": .number(3)]),
            Case(name: "chorus", kind: .chorus, parameters: ["driftRate": .number(0.9), "panSpread": .number(0.7)]),
            Case(name: "phaser", kind: .phaser, parameters: ["stereoOffset": .number(0.4)]),
            // The saved sound: causal head, old modulation range. Through-zero is the new default.
            Case(name: "flanger", kind: .flanger, parameters: ["hfDamping": .number(0.5), "readHead": .choice("causal"), "modulationRange": .choice("legacy")]),
            Case(name: "wavefolder", kind: .wavefolder, parameters: ["saturation": .number(0.4)]),
            Case(name: "stretch", kind: .stretch, parameters: ["pitchCents": .number(37), "fftSize": .choice("1024")]),
            Case(name: "halfTimeRepitch", kind: .halfTime, parameters: ["window": .number(120), "smooth": .number(7)]),
            Case(name: "halfTimeGranular", kind: .halfTime, parameters: ["window": .number(120), "mode": .choice("granular"), "grain": .number(30)]),
            Case(name: "vocoder", kind: .vocoder, parameters: ["attack": .number(5), "release": .number(60), "sibilance": .number(0.5)], feeds: ["carrier": .audio, "modulator": .audio]),
            Case(name: "logic", kind: .logic, parameters: ["hysteresis": .number(0.1), "holdTime": .number(0.05)], feeds: ["a": .lfo]),
            Case(name: "quantizer", kind: .quantizer, parameters: ["glide": .number(0.1), "scale": .choice("major"), "root": .choice("3")], feeds: ["in": .lfo]),
            Case(name: "switch", kind: .stepSwitchFanOut, parameters: ["crossfade": .number(12)], feeds: ["advance": .clock], outPin: "out1"),
            Case(name: "fractalFilter.fft1024", kind: .fractalFilter, parameters: ["fftSize": .choice("1024")]),
            // Single Cycle before Mode / Frequency / Harmonic (2026-10-27): Wavetable mode keeps these bits.
            Case(name: "singleCycle", kind: .singleCycle, parameters: [:]),
            Case(name: "singleCycle.shaped", kind: .singleCycle, parameters: ["cycles": .number(4), "phase": .number(37), "warp": .number(0.4), "morph": .number(0.3)]),
            Case(name: "singleCycle.additive", kind: .singleCycle, parameters: ["shape": .choice("additive"), "partials": .text("1 0 0.5 0.25"), "frameSize": .choice("512"), "cycles": .number(8)]),
            Case(name: "singleCycle.noise", kind: .singleCycle, parameters: ["shape": .choice("noise"), "seed": .number(7), "cycles": .number(3)]),
            Case(name: "singleCycle.pulse", kind: .singleCycle, parameters: ["shape": .choice("pulse"), "width": .number(0.2), "warp": .number(-0.6)]),
            Case(name: "reduxBitwise", kind: .redux, parameters: ["reduxMode": .choice("bitwise"), "mask": .number(12_345)]),
        ]
        // Every option of the choices pass 2 opens up.
        for curve in choices(.waveshaper, "curve") { cases.append(Case(name: "waveshaper.\(curve)", kind: .waveshaper, parameters: ["curve": .choice(curve)])) }
        for mode in choices(.distortion, "mode") { cases.append(Case(name: "distortion.\(mode)", kind: .distortion, parameters: ["mode": .choice(mode)])) }
        for shape in choices(.wavefolder, "foldShape") { cases.append(Case(name: "wavefolder.\(shape)", kind: .wavefolder, parameters: ["foldShape": .choice(shape)])) }
        for type in choices(.filters, "type") { cases.append(Case(name: "filters.\(type)", kind: .filters, parameters: ["type": .choice(type)])) }
        for mode in choices(.redux, "reduxMode") { cases.append(Case(name: "redux.\(mode)", kind: .redux, parameters: ["reduxMode": .choice(mode), "antiAlias": .choice("biquad")])) } // the saved sound; linear phase is the new default
        for op in choices(.redux, "bitwiseOperator") { cases.append(Case(name: "redux.bitwise.\(op)", kind: .redux, parameters: ["reduxMode": .choice("bitwise"), "bitwiseOperator": .choice(op)])) }
        for op in choices(.math, "operator") { cases.append(Case(name: "math.\(op)", kind: .math, parameters: ["operator": .choice(op)], feeds: ["a": .lfo, "b": .clock])) }
        for op in choices(.logic, "operator") { cases.append(Case(name: "logic.\(op)", kind: .logic, parameters: ["operator": .choice(op)], feeds: ["a": .lfo, "b": .clock])) }
        for shape in choices(.lfo, "shape") { cases.append(Case(name: "lfo.\(shape)", kind: .lfo, parameters: ["shape": .choice(shape), "rate": .number(3)])) }
        for pattern in choices(.fractalFilter, "pattern") { cases.append(Case(name: "fractalFilter.pattern.\(pattern)", kind: .fractalFilter, parameters: ["pattern": .choice(pattern)])) }
        for phase in choices(.fractalFilter, "phaseMode") { cases.append(Case(name: "fractalFilter.phaseMode.\(phase)", kind: .fractalFilter, parameters: ["phaseMode": .choice(phase)])) }
        return cases
    }()

    private func fingerprint(_ test: Case) async throws -> UInt64 {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("source.wav")
        try TestAudio.write(TestAudio.samples(frames: 24_000, channels: 2), to: file, sampleRate: 48_000)
        let output = directory.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        var graph = TestProject()
        let audio = graph.add(.audio, asset: sourceAsset)
        var parameters = NodeCatalog.defaultParameters(for: test.kind)
        parameters.merge(test.parameters) { $1 }
        let node = graph.add(test.kind, parameters)
        let definition = NodeCatalog.definition(for: test.kind)
        let isControl = definition.pins.first { $0.direction == .output }?.signal == .control
        for (pin, kind) in test.feeds.sorted(by: { $0.key < $1.key }) {
            let source = kind == .audio ? audio : graph.add(kind, NodeCatalog.defaultParameters(for: kind))
            graph.connect(source, to: node, pin)
        }
        if definition.pins.contains(where: { $0.id == "in" && $0.signal == .audio }) && test.feeds["in"] == nil {
            graph.connect(audio, to: node)
        }
        let bake = graph.add(.print, ["bitDepth": .choice("32f")])
        if isControl {
            let vca = graph.add(.gainVCA, NodeCatalog.defaultParameters(for: .gainVCA))
            graph.connect(audio, to: vca)
            graph.connect(node, to: vca, "amount")
            graph.connect(vca, to: bake)
        } else {
            graph.project.edges.append(Edge(from: PinRef(node: node, pin: test.outPin), to: PinRef(node: bake, pin: "in")))
        }
        let urls = [sourceAsset: file]
        let request = RenderRequest(plan: try compile(graph.project, assetURLs: urls), assetURLs: urls, outputDirectory: output, chunkFrames: 777)
        let rendered = try TestAudio.read(try #require(try await RenderEngine.render(request).outputs[bake]))
        var hash: UInt64 = 1_469_598_103_934_665_603
        for channel in rendered.samples { for value in channel { hash = (hash ^ UInt64(value.bitPattern)) &* 1_099_511_628_211 } }
        return hash
    }

    /// Taken on main at cb37bc8, before the pass.
    private static let expected: [String: UInt64] = [
        "envelopeFollower": 4146703185513696510,
        "singleCycle": 3651027608192902019,
        "singleCycle.additive": 3718159561937247043,
        "singleCycle.noise": 7534459583099371085,
        "singleCycle.pulse": 13368562782352794499,
        "singleCycle.shaped": 7631037880590179651,
        "fractalFilter": 6504625733350534677,
        "fractalFilter.fft1024": 730158544134234313,
        "fractalFilter.pattern.cantor": 6504625733350534677,
        "fractalFilter.pattern.mandelbrot": 14054968688805071158,
        "fractalFilter.pattern.julia": 1171220526673465355,
        "fractalFilter.pattern.koch": 16316875172439351471,
        "fractalFilter.phaseMode.preserved": 6504625733350534677,
        "fractalFilter.phaseMode.randomized": 9044321879474052470,
        "fractalFilter.phaseMode.mirrored": 2844377078684973457,
        "envelope": 2473577668339541757,
        "resonator": 1474359751824395798,
        "clock": 12630019383023940801,
        "math": 7541357495849223351,
        "lfo": 15752171983209411154,
        "chorus": 9821288481851984695,
        "phaser": 6145461584447620882,
        "flanger": 13359462231239488601,
        "wavefolder": 7221654525625125781,
        "stretch": 15525338448015515018,
        "halfTimeRepitch": 4248298689356042374,
        "halfTimeGranular": 17789487645453505562,
        "vocoder": 2430850985453030818,
        "logic": 15730968136808182977,
        "quantizer": 4534259675678935332,
        "switch": 5070778570116216001,
        "reduxBitwise": 6833925035156131203,
        "waveshaper.tanh": 10584225623934119770,
        "waveshaper.arctan": 12610496959917003132,
        "waveshaper.softsign": 724707705340493142,
        "waveshaper.sine": 18045752622716429491,
        "waveshaper.cubic": 6652169391841078127,
        "waveshaper.hardClip": 2636138799838096463,
        "waveshaper.asymmetric": 18388838552653525687,
        "waveshaper.chebyshev": 12118564644286218923,
        "distortion.soft": 9258712486208788676,
        "distortion.hard": 11663110341612852589,
        "wavefolder.triangle": 6602767680098572721,
        "wavefolder.sine": 6116573468758910035,
        "filters.lowpass": 13672394650127207541,
        "filters.highpass": 3708989016244727520,
        "filters.bandpass": 263793984161884277,
        "filters.notch": 5038751744562577920,
        "redux.classic": 10086037185513868675,
        "redux.bitReduction": 10086037185513868675,
        "redux.downsampling": 4491659445140100592,
        "redux.sampleAndHold": 5070778570116216001,
        "redux.bitwise": 3286572119577677187,
        "redux.bitwise.and": 10880242907946671089,
        "redux.bitwise.or": 16637667413714750851,
        "redux.bitwise.xor": 3286572119577677187,
        "math.add": 623482217916239765,
        "math.subtract": 15994427799005698061,
        "math.multiply": 17171369584530383396,
        "math.divide": 17171369584530383396,
        "math.abs": 11976074404322023500,
        "math.invert": 3427395634010807464,
        "math.modulo": 17171369584530383396,
        "logic.threshold": 1264563938892231873,
        "logic.and": 9475872571505292481,
        "logic.or": 18258774623899399361,
        "logic.xor": 18258774623899399361,
        "logic.not": 14507412000540243137,
        "lfo.sine": 10614965821035982816,
        "lfo.triangle": 273957977650721851,
        "lfo.saw": 13416265662924893710,
        "lfo.square": 8921017406087460662,
        "lfo.sampleAndHold": 196802507423046932,
    ]

    @Test(arguments: cases.map(\.name))
    func unmodulatedOutputKeepsItsBits(name: String) async throws {
        let test = try #require(Self.cases.first { $0.name == name })
        let actual = try await fingerprint(test)
        #expect(actual == Self.expected[name], "\(name) changed sound: \(actual)")
    }
}
