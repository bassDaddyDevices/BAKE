import BakeDSP
import Foundation
import Testing
@testable import BakeGraph
@testable import BakeRender

struct PhaserTests {
    private func phaser(
        _ input: [Float], center: Float = 700, width: Float = 2, feedback: Float = 0.2, mix: Float = 0.5,
        rate: Float = 0.3, depth: Float = 0,
        stages: Int32 = 4, stereoOffset: Double = 0.25, channel: bake.dsp.PhaserChannel = .mono,
        centerModulation: [Float]? = nil, widthModulation: [Float]? = nil,
        feedbackModulation: [Float]? = nil, mixModulation: [Float]? = nil,
        chunk: Int? = nil
    ) -> [Float] {
        var state = bake.dsp.PhaserState()
        var output = [Float](repeating: 0, count: input.count)
        var centerSignal = signal(center, 80, 8_000, scale: .exponential)
        var widthSignal = signal(width, 0.25, 4)
        var feedbackSignal = signal(feedback, -0.95, 0.95)
        var mixSignal = signal(mix, 0, 1)
        let rateSignal = signal(rate, 0.05, 5, scale: .exponential)
        let depthSignal = signal(depth, 0, 1)
        let centerValues = centerModulation ?? []
        let widthValues = widthModulation ?? []
        let feedbackValues = feedbackModulation ?? []
        let mixValues = mixModulation ?? []
        centerValues.withUnsafeBufferPointer { pointer in
            if centerModulation != nil { centerSignal.modulation = pointer.baseAddress; centerSignal.modulationFrames = pointer.count }
            widthValues.withUnsafeBufferPointer { pointer in
                if widthModulation != nil { widthSignal.modulation = pointer.baseAddress; widthSignal.modulationFrames = pointer.count }
                feedbackValues.withUnsafeBufferPointer { pointer in
                    if feedbackModulation != nil { feedbackSignal.modulation = pointer.baseAddress; feedbackSignal.modulationFrames = pointer.count }
                    mixValues.withUnsafeBufferPointer { pointer in
                        if mixModulation != nil { mixSignal.modulation = pointer.baseAddress; mixSignal.modulationFrames = pointer.count }
                        input.withUnsafeBufferPointer { source in
                            output.withUnsafeMutableBufferPointer { destination in
                                var start = 0
                                while start < input.count {
                                    let count = min(chunk ?? input.count, input.count - start)
                                    bake.dsp.renderPhaser(
                                        &state, channel, stages, centerSignal, widthSignal, rateSignal, depthSignal,
                                        feedbackSignal, mixSignal,
                                        48_000, stereoOffset, source.baseAddress! + start,
                                        destination.baseAddress! + start, start, count
                                    )
                                    start += count
                                }
                            }
                        }
                    }
                }
            }
        }
        return output
    }

    private func stereo(_ input: [Float], stages: Int32 = 4, stereoOffset: Double = 0.25) -> [[Float]] {
        [
            phaser(input, stages: stages, stereoOffset: stereoOffset, channel: .left),
            phaser(input, stages: stages, stereoOffset: stereoOffset, channel: .right),
        ]
    }

    /// Review finding: feedback was added after the all-pass stages, a one-pole boost of up to 20×
    /// (+26 dB) at full Feedback. Very low frequencies must pass at unity whatever the Feedback.
    @Test func feedbackNeverBoostsTheBass() {
        let constant = [Float](repeating: 0.5, count: 48_000)
        for feedback: Float in [-0.95, 0, 0.5, 0.95] {
            let output = phaser(constant, feedback: feedback, mix: 1)
            #expect(abs((output.last ?? 0) - 0.5) < 0.01, "feedback \(feedback): \(output.last ?? 0)")
        }
    }

    @Test func itSweepsOnItsOwn() {
        let input = TestAudio.samples(frames: 48_000, channels: 1)[0]
        let still = phaser(input, depth: 0)
        let sweeping = phaser(input, rate: 2, depth: 0.6)
        #expect(still != sweeping)
        #expect(sweeping != phaser(input, rate: 0.5, depth: 0.6))
        #expect(phaser(input, rate: 2, depth: 0.6, chunk: 777) == sweeping)
    }

    @Test func allPassStagesPreserveSteadyStateSineLevelAndMixCreatesPhasing() {
        let input = sine(frequency: 1_000, frames: 48_000)
        for stages in [Int32(2), 4, 8, 12, 24] {
            let allPass = phaser(input, mix: 1, stages: stages)
            let level = TestAudio.rms(Array(allPass[8_000...]))
            #expect(abs(level - TestAudio.rms(Array(input[8_000...]))) < 0.1)
        }
        #expect(phaser(input, mix: 0) == input)
        #expect(phaser(input, mix: 0.5) != input)
    }

    @Test func chunksOf777MatchOneWholeRender() {
        let input = TestAudio.samples(frames: 6_013, channels: 1)[0]
        #expect(phaser(input, center: 1_200, width: 3, feedback: 0.6) == phaser(input, center: 1_200, width: 3, feedback: 0.6, chunk: 777))
    }

    @Test func repeatedRendersAreDeterministic() {
        let input = TestAudio.samples(frames: 2_048, channels: 1)[0]
        #expect(phaser(input) == phaser(input))
    }

    @Test func parameterExtremesAndStagesStayFinite() {
        let input = TestAudio.samples(frames: 2_048, channels: 1)[0]
        for center in [Float(80), 8_000] {
            for width in [Float(0.25), 4] {
                for feedback in [Float(-0.95), 0.95] {
                    for mix in [Float(0), 1] {
                        for stages in [Int32(2), 24] {
                            #expect(phaser(input, center: center, width: width, feedback: feedback, mix: mix, stages: stages).allSatisfy { $0.isFinite })
                        }
                    }
                }
            }
        }
    }

    @Test func everyModulatableParameterChangesOutput() {
        let input = sine(frequency: 700, frames: 2_048)
        let modulation = [Float](repeating: 1, count: input.count)
        #expect(phaser(input, center: 700) != phaser(input, center: 700, centerModulation: modulation))
        #expect(phaser(input, width: 1) != phaser(input, width: 1, widthModulation: modulation))
        #expect(phaser(input, feedback: 0) != phaser(input, feedback: 0, feedbackModulation: modulation))
        #expect(phaser(input, mix: 0.5) != phaser(input, mix: 0.5, mixModulation: modulation))
    }

    @Test func stageCountAndStereoOffsetSettingsChangeOutput() {
        let input = sine(frequency: 900, frames: 4_096)
        #expect(phaser(input, stages: 2) != phaser(input, stages: 24))
        let noOffset = stereo(input, stereoOffset: 0)
        let offset = stereo(input, stereoOffset: 1)
        #expect(noOffset[0] == noOffset[1])
        #expect(offset[0] != offset[1])
    }

    @Test func audioPhaserPrintPreservesStereoShape() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.wav")
        let samples = TestAudio.samples(frames: 4_096, channels: 2)
        try TestAudio.write(samples, to: source, sampleRate: 48_000)
        let output = directory.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var graph = TestProject()
        let audio = graph.add(.audio, asset: sourceAsset)
        let phaser = graph.add(.phaser, ["center": .number(700), "mix": .number(0.7)])
        let print = graph.add(.print, ["bitDepth": .choice("32f")])
        graph.connect(audio, to: phaser)
        graph.connect(phaser, to: print)
        let urls = [sourceAsset: source]
        let request = RenderRequest(plan: try compile(graph.project, assetURLs: urls), assetURLs: urls, outputDirectory: output)
        let written = try #require(try await RenderEngine.render(request).outputs[print])
        let rendered = try TestAudio.read(written).samples
        #expect(rendered.count == 2)
        #expect(rendered.allSatisfy { $0.count == 4_096 })
        #expect(rendered.allSatisfy { channel in channel.allSatisfy { $0.isFinite } })
        #expect(rendered[0] != samples[0])
    }
}
