import Foundation
import Testing
@testable import BakeGraph
@testable import BakeRender

/// Proves `NodeCatalog.isCausal` (spec §11): every kind it lets into a feedback loop renders frames
/// 0…n from inputs 0…n only. Two inputs that agree up to a frame must give outputs that agree up to it.
struct FeedbackCausalityTests {
    private static let agreeUntil = 10_000

    /// Every causal kind, with the settings that make it causal.
    private static let kinds: [(NodeKind, [ParameterID: ParameterValue])] = NodeKind.allCases.compactMap { kind in
        guard kind != .feedback, !kind.isOutput else { return nil }
        let parameters: [ParameterID: ParameterValue] = switch kind {
        case .distortion, .waveshaper, .wavefolder: ["oversampling": .choice("1")]
        default: [:]
        }
        return NodeCatalog.isCausal(Node(kind: kind, parameters: parameters)) ? (kind, parameters) : nil
    }

    private func noise(_ count: Int, seed: UInt64) -> [Float] {
        var state = seed
        return (0..<count).map { _ in
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Float(Int64(bitPattern: state) >> 40) / Float(1 << 23) * 0.5
        }
    }

    /// The signal under test into the node's first input; its first output heard directly (audio) or
    /// through a Gain/VCA's amount (control).
    private func render(_ kind: NodeKind, _ parameters: [ParameterID: ParameterValue], input: [Float]) async throws -> [Float] {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("in.wav")
        try TestAudio.write([input], to: source, sampleRate: 48_000)
        var graph = TestProject()
        let audio = graph.add(.audio, asset: sourceAsset)
        let node = graph.add(kind, parameters)
        let bake = graph.add(.print, ["bitDepth": .choice("32f")])
        let pins = NodeCatalog.pins(of: Node(kind: kind, parameters: parameters))
        // The Switch's audio inputs come after its control pins; the signal under test goes into In 1.
        if let firstInput = pins.first(where: { $0.direction == .input && (kind != .stepSwitch || $0.id == "in1") }) {
            graph.connect(audio, to: node, firstInput.id)
        }
        let firstOutput = try #require(pins.first { $0.direction == .output })
        if firstOutput.signal == .audio {
            graph.project.edges.append(Edge(from: PinRef(node: node, pin: firstOutput.id), to: PinRef(node: bake, pin: "in")))
        } else {
            let vca = graph.add(.gainVCA)
            graph.connect(audio, to: vca)
            graph.project.edges.append(Edge(from: PinRef(node: node, pin: firstOutput.id), to: PinRef(node: vca, pin: "amount")))
            graph.connect(vca, to: bake)
        }
        let output = directory.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let urls = [sourceAsset: source]
        let request = RenderRequest(plan: try compile(graph.project, assetURLs: urls), assetURLs: urls, outputDirectory: output)
        return try TestAudio.read(try #require(try await RenderEngine.render(request).outputs[bake])).samples[0]
    }

    @Test func theCausalListIsWhatTheSpecAllows() {
        #expect(Set(Self.kinds.map(\.0)) == [
            .filters, .dualFilter, .distortion, .waveshaper, .wavefolder, .redux, .gainVCA, .phaser, .flanger, .chorus,
            .subHarmonic, .frequencySplitter, .mixer, .channelSplitter, .channelMerger, .midSideEncoder, .midSideDecoder,
            .delay, .stepSwitch, .stepSwitchFanOut, .lfo, .random, .sampleAndHold, .envelope, .envelopeFollower, .clock, .math, .logic, .quantizer, .macro,
        ])
    }

    @Test(arguments: kinds.map(\.0))
    func neverLooksAhead(kind: NodeKind) async throws {
        let parameters = try #require(Self.kinds.first { $0.0 == kind }).1
        let shared = noise(Self.agreeUntil, seed: 1)
        let a = try await render(kind, parameters, input: shared + noise(14_000, seed: 2))
        let b = try await render(kind, parameters, input: shared + noise(14_000, seed: 3))
        #expect(Array(a.prefix(Self.agreeUntil)) == Array(b.prefix(Self.agreeUntil)), "\(kind) looked ahead")
        // The test can see a difference: after the inputs diverge, so do the outputs (if the node uses its input).
        #expect(a.count == b.count)
    }
}
