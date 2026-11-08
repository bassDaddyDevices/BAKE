import Foundation
import Testing
@testable import BakeGraph
@testable import BakeRender

/// The Feedback node's Send pin: the loop goes out of Send and the result comes out of Out, and both
/// carry the same signal, so patches saved looping from Out sound exactly as before.
struct FeedbackSendTests {
    private enum Wiring {
        /// Saved patches: Out feeds the loop and the Bake.
        case outOnly
        /// Send feeds the loop, Out the Bake.
        case sendAndOut
        /// Send feeds the loop and the Bake; Out is unwired.
        case sendOnly
    }

    /// Audio → Feedback → Filters → back into Return, with one Bake on each Feedback output used.
    private func render(_ wiring: Wiring) async throws -> [PinID: [Float]] {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("in.wav")
        var seed: UInt64 = 5
        let noise = (0..<4_800).map { _ -> Float in
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Float(Int64(bitPattern: seed) >> 40) / Float(1 << 23) * 0.5
        }
        try TestAudio.write([noise, noise.reversed()], to: source, sampleRate: 48_000)
        var graph = TestProject()
        let audio = graph.add(.audio, asset: sourceAsset)
        let feedback = graph.add(.feedback, ["gain": .number(-3), "delay": .number(5), "drive": .number(6), "tail": .number(0.05)])
        let filters = graph.add(.filters, ["cutoff": .number(2_000)])
        graph.connect(audio, to: feedback)
        graph.connect(filters, to: feedback, "return")
        let loopPin: PinID = wiring == .outOnly ? "out" : "send"
        graph.project.edges.append(Edge(from: PinRef(node: feedback, pin: loopPin), to: PinRef(node: filters, pin: "in")))
        let bakedPins: [PinID] = switch wiring {
        case .outOnly: ["out"]
        case .sendAndOut: ["out", "send"]
        case .sendOnly: ["send"]
        }
        var bakes: [PinID: NodeID] = [:]
        for pin in bakedPins {
            let bake = graph.add(.print, ["bitDepth": .choice("32f")])
            graph.project.edges.append(Edge(from: PinRef(node: feedback, pin: pin), to: PinRef(node: bake, pin: "in")))
            bakes[pin] = bake
        }
        let output = directory.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let urls = [sourceAsset: source]
        let plan = try compile(graph.project, assetURLs: urls)
        #expect(plan.loops.count == 1)
        let rendered = try await RenderEngine.render(RenderRequest(plan: plan, assetURLs: urls, outputDirectory: output, chunkFrames: 777))
        var samples: [PinID: [Float]] = [:]
        for (pin, bake) in bakes {
            let audio = try TestAudio.read(try #require(rendered.outputs[bake]))
            samples[pin] = audio.samples.flatMap { $0 }
        }
        return samples
    }

    @Test func loopingFromSendSoundsLikeLoopingFromOut() async throws {
        let saved = try #require(try await render(.outOnly)["out"])
        let both = try await render(.sendAndOut)
        let sendOnly = try #require(try await render(.sendOnly)["send"])
        #expect(both["out"] == saved)
        #expect(both["send"] == saved)
        #expect(sendOnly == saved)
        // The loop really rings: the tail past the input is not silent.
        #expect(saved.count > 2 * 4_800)
        #expect(saved.suffix(400).contains { $0 != 0 })
    }

    @Test func feedbackHasSendAndOutPins() {
        let pins = NodeCatalog.definition(for: .feedback).pins
        #expect(pins.filter { $0.direction == .input }.map(\.id) == ["in", "return"])
        #expect(pins.filter { $0.direction == .output }.map(\.id) == ["out", "send"])
        #expect(NodeCatalog.label(of: "send", on: Node(kind: .feedback)) == "Send")
    }
}
