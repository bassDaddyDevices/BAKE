import BakeDSP
import Foundation
import Testing
@testable import BakeGraph
@testable import BakeRender

struct SwitchTests {
    private typealias Order = bake.dsp.SwitchOrder

    /// Per-frame gains (frame-major, `outputs` per frame) from the kernel.
    private func gains(
        _ order: Order, outputs: Int = 4, pattern: [Int32] = [], seed: UInt32 = 0, fade: Double = 0,
        advance: [Float]? = nil, reset: [Float]? = nil, frames: Int, chunk: Int? = nil
    ) -> [Float] {
        var state = bake.dsp.SwitchState()
        var result = [Float](repeating: -1, count: frames * outputs)
        let advanceValues = advance ?? [], resetValues = reset ?? []
        advanceValues.withUnsafeBufferPointer { advancePointer in
            resetValues.withUnsafeBufferPointer { resetPointer in
                pattern.withUnsafeBufferPointer { patternPointer in
                    result.withUnsafeMutableBufferPointer { destination in
                        var advanceInput = bake.dsp.ControlInput()
                        if advance != nil { advanceInput.samples = advancePointer.baseAddress; advanceInput.frames = advancePointer.count }
                        var resetInput = bake.dsp.ControlInput()
                        if reset != nil { resetInput.samples = resetPointer.baseAddress; resetInput.frames = resetPointer.count }
                        var start = 0
                        while start < frames {
                            let count = min(chunk ?? frames, frames - start)
                            bake.dsp.renderSwitchGains(
                                &state, order, Int32(outputs), patternPointer.baseAddress, Int32(pattern.count), seed, fade,
                                advanceInput, resetInput, destination.baseAddress! + start * outputs, start, count
                            )
                            start += count
                        }
                    }
                }
            }
        }
        return result
    }

    private func bangs(at starts: [Int], frames: Int, length: Int = 10) -> [Float] {
        var signal = [Float](repeating: 0, count: frames)
        for start in starts { for frame in start..<min(start + length, frames) { signal[frame] = 1 } }
        return signal
    }

    /// The output playing at `frame` (the one with the largest gain).
    private func active(_ gains: [Float], _ frame: Int, outputs: Int = 4) -> Int {
        let slice = gains[(frame * outputs)..<((frame + 1) * outputs)]
        return slice.indices.max { slice[$0] < slice[$1] }! - frame * outputs
    }

    @Test func eachOrderPlaysTheSameStepsAsTheCard() {
        let starts = (0..<12).map { $0 * 1_000 }
        let advance = bangs(at: starts, frames: 12_000)
        let cases: [(Order, String, [Int])] = [(.forward, "forward", []), (.pingPong, "pingPong", []), (.random, "random", []), (.pattern, "pattern", [0, 0, 2, 1])]
        for (order, name, pattern) in cases {
            let output = gains(order, pattern: pattern.map(Int32.init), seed: 7, advance: advance, frames: 12_000)
            let played = starts.map { active(output, $0 + 10) }
            #expect(played == SwitchSteps.sequence(order: name, outputs: 4, pattern: pattern, seed: 7, count: 12), "\(name)")
        }
    }

    @Test func untilTheFirstBangStepOnePlays() {
        let output = gains(.forward, frames: 500)
        #expect((0..<500).allSatisfy { active(output, $0) == 0 && output[$0 * 4] == 1 })
    }

    @Test func withNoCrossfadeTheAudioMovesOnTheBangFrame() {
        let output = gains(.forward, advance: bangs(at: [0, 500], frames: 1_000), frames: 1_000)
        #expect(active(output, 499) == 0 && active(output, 500) == 1)
        #expect(output[499 * 4] == 1 && output[500 * 4 + 1] == 1 && output[500 * 4] == 0)
    }

    @Test func resetReturnsToStepOneAndBeatsAdvance() {
        let advance = bangs(at: [0, 100, 200, 300, 400], frames: 500)
        let reset = bangs(at: [200], frames: 500)
        let output = gains(.forward, advance: advance, reset: reset, frames: 500)
        #expect(active(output, 150) == 1)
        #expect(active(output, 210) == 0)    // Reset and Advance on the same frame: Reset wins
        #expect(active(output, 310) == 0)    // the first bang after a Reset plays step 1 again
        #expect(active(output, 410) == 1)
    }

    @Test func theCrossfadeKeepsPowerSteady() {
        let output = gains(.forward, fade: 240, advance: bangs(at: [0, 1_000, 1_100], frames: 2_000), frames: 2_000)
        for frame in 0..<2_000 {
            let power = (0..<4).map { output[frame * 4 + $0] * output[frame * 4 + $0] }.reduce(0, +)
            #expect(abs(10 * log10(power)) < 0.1, "frame \(frame): \(power)")
        }
        #expect(output[1_000 * 4] == 1)                                   // the fade starts on the bang frame
        // The bang at 1100 interrupts the fade to Out 2 and starts one to Out 3, done 240 frames later.
        #expect(output[1_339 * 4 + 2] > 0.99)
    }

    @Test func aBangOnAChunkBoundaryAdvancesOnce() {
        let advance = bangs(at: [0, 777 * 3, 777 * 5 + 776, 6_000], frames: 8_000)
        for fade in [0.0, 240] {
            #expect(gains(.random, seed: 4, fade: fade, advance: advance, frames: 8_000, chunk: 777)
                == gains(.random, seed: 4, fade: fade, advance: advance, frames: 8_000), "fade \(fade)")
        }
    }

    // MARK: end to end

    @Test func aClockSendsAudioToEachOutputInTurn() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let audioFile = directory.appendingPathComponent("dc.wav")
        try TestAudio.write([[Float](repeating: 0.5, count: 48_000)], to: audioFile, sampleRate: 48_000)
        let output = directory.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var graph = TestProject()
        let audio = graph.add(.audio, asset: sourceAsset)
        let clock = graph.add(.clock, ["bpm": .number(240), "division": .choice("1/4")])        // a bang every 12000 frames
        let router = graph.add(.stepSwitchFanOut, ["outputs": .choice("4"), "crossfade": .number(0)])
        graph.connect(audio, to: router)
        graph.connect(clock, to: router, "advance")
        var prints: [NodeID] = []
        for number in 1...4 {
            let print = graph.add(.print, ["bitDepth": .choice("32f")])
            graph.project.edges.append(Edge(from: PinRef(node: router, pin: "out\(number)"), to: PinRef(node: print, pin: "in")))
            prints.append(print)
        }
        let urls = [sourceAsset: audioFile]
        let request = RenderRequest(plan: try compile(graph.project, assetURLs: urls), assetURLs: urls, outputDirectory: output)
        let written = try await RenderEngine.render(request).outputs
        for (index, print) in prints.enumerated() {
            let samples = try TestAudio.read(try #require(written[print])).samples[0]
            let open = samples.indices.filter { samples[$0] != 0 }
            #expect(open == Array((index * 12_000)..<((index + 1) * 12_000)), "Out \(index + 1)")
        }
    }

    @Test func theCatalogDescribesTheFanOutSwitch() {
        let definition = NodeCatalog.definition(for: .stepSwitchFanOut)
        #expect(definition.pins.map(\.id) == ["in", "advance", "reset"])
        #expect(NodeCatalog.pins(of: Node(kind: .stepSwitchFanOut)).filter { $0.direction == .output }.map(\.id) == ["out1", "out2", "out3", "out4"])
        #expect(definition.lengthRule == .sameAsInput("in"))
        #expect(NodeKind.stepSwitchFanOut.category == .routing && NodeKind.stepSwitchFanOut.isLegacy)
    }
}
