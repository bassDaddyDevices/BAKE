import BakeDSP
import Foundation
import Testing
@testable import BakeGraph
@testable import BakeRender

struct SampleAndHoldTests {
    private static let frames = 6_000

    /// A ramp from 0 up by 1 every 1,000 frames: the held value tells exactly which frame it was taken at.
    private static let ramp: [Float] = (0..<frames).map { Float($0) / 1_000 }

    private func bangs(at starts: [Int], length: Int = 100, frames: Int = SampleAndHoldTests.frames) -> [Float] {
        var signal = [Float](repeating: 0, count: frames)
        for start in starts { for frame in start..<min(start + length, frames) { signal[frame] = 1 } }
        return signal
    }

    /// `trigger` nil = unwired (Rate). The source is a control signal on `signal`.
    private func render(
        _ mode: bake.dsp.SampleAndHoldMode = .hold, source: [Float] = SampleAndHoldTests.ramp, trigger: [Float]? = nil,
        rate: Float = 10, glide: Float = 0, chunk: Int? = nil
    ) -> [Float] {
        var state = bake.dsp.SampleAndHoldState()
        var output = [Float](repeating: 0, count: source.count)
        source.withUnsafeBufferPointer { sourcePointer in
            (trigger ?? []).withUnsafeBufferPointer { triggerPointer in
                var signalInput = bake.dsp.ControlInput()
                signalInput.samples = sourcePointer.baseAddress
                signalInput.frames = sourcePointer.count
                var triggerInput = bake.dsp.ControlInput()
                if trigger != nil { triggerInput.samples = triggerPointer.baseAddress; triggerInput.frames = triggerPointer.count }
                output.withUnsafeMutableBufferPointer { buffer in
                    var start = 0
                    while start < source.count {
                        let count = min(chunk ?? source.count, source.count - start)
                        bake.dsp.renderSampleAndHold(
                            &state, mode, bake.dsp.AudioInput(), signalInput, triggerInput, signal(rate, 0.01, 2_000, scale: .exponential),
                            signal(glide, 0, 5_000), 48_000, buffer.baseAddress! + start, start, count
                        )
                        start += count
                    }
                }
            }
        }
        return output
    }

    @Test func eachBangHoldsTheValueTheSignalHadThen() {
        let output = render(trigger: bangs(at: [500, 1_500, 2_500]))
        #expect(output[0] == 0 && output[499] == 0)              // before the first bang: the value at frame 0
        #expect(output[500] == 0.5 && output[1_499] == 0.5)
        #expect(output[1_500] == 1.5 && output[2_499] == 1.5)
        #expect(output[2_500] == 2.5 && output[5_999] == 2.5)
    }

    @Test func trackAndHoldFollowsWhileTheTriggerIsHighThenFreezes() {
        let output = render(.trackAndHold, trigger: bangs(at: [1_000], length: 300))
        #expect(output[999] == 0)
        #expect(output[1_000] == 1.0 && output[1_150] == 1.15 && output[1_299] == 1.299)   // following
        #expect(output[1_300] == 1.299 && output[5_999] == 1.299)                           // frozen at the last tracked value
    }

    @Test func unwiredItSamplesAtTheRate() {
        // 10 Hz at 48 kHz: a sample every 4,800 frames, so two takes in 6,000 frames: at frame 0 and about 4,800.
        let output = render(rate: 10)
        #expect(output[4_000] == output[0])
        #expect(output[5_500] != output[0] && abs(output[5_500] - 4.8) < 0.01)
    }

    @Test func glideSoftensTheJumps() {
        let hard = render(trigger: bangs(at: [1_000, 3_000]), glide: 0)
        let soft = render(trigger: bangs(at: [1_000, 3_000]), glide: 5)
        func largestJump(_ values: [Float]) -> Float { zip(values, values.dropFirst()).map { abs($0 - $1) }.max() ?? 0 }
        #expect(largestJump(soft) < largestJump(hard) * 0.2)
        #expect(abs(soft[2_900] - 1.0) < 0.01)                    // settled on the first held value before the next bang
    }

    @Test func anyChunkSizeGivesTheSameBits() {
        for mode in [bake.dsp.SampleAndHoldMode.hold, .trackAndHold] {
            for trigger in [nil, bangs(at: [333, 2_000, 2_050, 4_321], length: 40)] {
                let whole = render(mode, trigger: trigger, rate: 37, glide: 3)
                for chunk in [1, 777, 4_096] {
                    #expect(render(mode, trigger: trigger, rate: 37, glide: 3, chunk: chunk) == whole, "\(mode) trigger \(trigger != nil) chunk \(chunk)")
                }
            }
        }
    }

    @Test func theCatalogDescribesSampleAndHold() {
        let definition = NodeCatalog.definition(for: .sampleAndHold)
        #expect(definition.pins.map(\.id) == ["in", "signal", "trigger", "out"])
        #expect(definition.lengthRule == .followsConsumers)
        #expect(NodeKind.sampleAndHold.category == .modulation)
        #expect(NodeCatalog.outputSignals(of: .sampleAndHold).allSatisfy { $0 == .control })
        #expect(NodeKind.sampleAndHold.title == "Sample & Hold")
    }

    /// An audio ramp into In, a Clock into Trigger: the held values are the ramp at each bang (every 12,000 frames).
    @Test func anAudioInputIsSampledOnAClock() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let rampFile = directory.appendingPathComponent("ramp.wav")
        let dcFile = directory.appendingPathComponent("dc.wav")
        try TestAudio.write([(0..<48_000).map { Float($0) / 48_000 }], to: rampFile, sampleRate: 48_000)
        try TestAudio.write([[Float](repeating: 1, count: 48_000)], to: dcFile, sampleRate: 48_000)
        let dcAsset = AssetID(testUUID(9_801))
        var graph = TestProject()
        let ramp = graph.add(.audio, asset: sourceAsset)
        let dc = graph.add(.audio, asset: dcAsset)
        let clock = graph.add(.clock, ["bpm": .number(240), "division": .choice("1/4")])
        let hold = graph.add(.sampleAndHold, ["mode": .choice("hold")])
        // Ring-mod mode passes the control value straight through as the gain (VCA mode would map −1…1 to 0…1).
        var vcaParameters = NodeCatalog.defaultParameters(for: .gainVCA)
        vcaParameters["mode"] = .choice("ringMod")
        let vca = graph.add(.gainVCA, vcaParameters)
        let bake = graph.add(.print, ["bitDepth": .choice("32f")])
        graph.connect(ramp, to: hold, "in")
        graph.connect(clock, to: hold, "trigger")
        graph.connect(dc, to: vca)
        graph.connect(hold, to: vca, "amount")
        graph.connect(vca, to: bake)
        let output = directory.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let urls = [sourceAsset: rampFile, dcAsset: dcFile]
        let request = RenderRequest(plan: try compile(graph.project, assetURLs: urls), assetURLs: urls, outputDirectory: output)
        let samples = try TestAudio.read(try #require(try await RenderEngine.render(request).outputs[bake])).samples[0]
        #expect(samples.count == 48_000)
        for (frame, expected) in [(6_000, 0.0), (18_000, 0.25), (30_000, 0.5), (42_000, 0.75)] as [(Int, Float)] {
            #expect(abs(samples[frame] - expected) < 2e-3, "frame \(frame): \(samples[frame])")
        }
    }
}
