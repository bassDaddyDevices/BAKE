import BakeDSP
import Foundation
import Testing
@testable import BakeGraph
@testable import BakeRender

struct ChorusTests {
    private func chorus(
        _ input: [Float], detune: Float = 10, spread: Float = 0.6, mix: Float = 0.5,
        voices: Int32 = 4, driftRate: Double = 0.3, panSpread: Double = 0.5,
        channel: Int = 0, detuneModulation: [Float]? = nil,
        spreadModulation: [Float]? = nil, mixModulation: [Float]? = nil,
        chunk: Int? = nil
    ) -> [Float] {
        var state = bake.dsp.ChorusState()
        var line = [Float](repeating: 0, count: 48_000 * 60 / 1_000 + 8)
        var output = [Float](repeating: 0, count: input.count)
        var detuneSignal = signal(detune, 0, 30)
        var spreadSignal = signal(spread, 0, 1)
        var mixSignal = signal(mix, 0, 1)
        let detuneValues = detuneModulation ?? []
        let spreadValues = spreadModulation ?? []
        let mixValues = mixModulation ?? []
        detuneValues.withUnsafeBufferPointer { pointer in
            if detuneModulation != nil { detuneSignal.modulation = pointer.baseAddress; detuneSignal.modulationFrames = pointer.count }
            spreadValues.withUnsafeBufferPointer { pointer in
                if spreadModulation != nil { spreadSignal.modulation = pointer.baseAddress; spreadSignal.modulationFrames = pointer.count }
                mixValues.withUnsafeBufferPointer { pointer in
                    if mixModulation != nil { mixSignal.modulation = pointer.baseAddress; mixSignal.modulationFrames = pointer.count }
                    input.withUnsafeBufferPointer { source in
                        output.withUnsafeMutableBufferPointer { destination in
                            line.withUnsafeMutableBufferPointer { delayLine in
                                var start = 0
                                while start < input.count {
                                    let count = min(chunk ?? input.count, input.count - start)
                                    bake.dsp.renderChorus(
                                        &state, detuneSignal, spreadSignal, mixSignal, voices, driftRate, panSpread,
                                        48_000, channel == 1 ? Double.pi * panSpread : 0,
                                        delayLine.baseAddress!, delayLine.count,
                                        source.baseAddress! + start, destination.baseAddress! + start,
                                        start, count
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

    /// Review finding: Detune only offset the voices' delays by a few samples, so it barely changed
    /// the sound. Detune sets each voice's peak pitch swing, so 30 ct must move the signal clearly.
    @Test func detuneMovesThePitch() {
        let input = (0..<48_000).map { Float(0.5 * sin(2 * Double.pi * 50 * Double($0) / 48_000)) }
        let still = chorus(input, detune: 0, spread: 0, mix: 1)
        let detuned = chorus(input, detune: 30, spread: 0, mix: 1)
        let difference = TestAudio.rms(zip(still, detuned).map { $0 - $1 })
        #expect(difference > 0.3 * TestAudio.rms(still))
    }

    @Test func delayedImpulseShowsChorusWetSignalAndMixZeroIsDry() {
        var impulse = [Float](repeating: 0, count: 2_048)
        impulse[0] = 1
        let dry = chorus(impulse, spread: 0, mix: 0)
        #expect(dry == impulse)
        let wet = chorus(impulse, spread: 0, mix: 1)
        #expect(wet != impulse)
        #expect(wet.allSatisfy { $0.isFinite })
    }

    @Test func chunksOf777MatchOneWholeRender() {
        let input = TestAudio.samples(frames: 8_003, channels: 1)[0]
        let whole = chorus(input, detune: 18, spread: 0.8, mix: 0.7)
        #expect(chorus(input, detune: 18, spread: 0.8, mix: 0.7, chunk: 777) == whole)
    }

    @Test func repeatedRendersAreDeterministic() {
        let input = TestAudio.samples(frames: 4_096, channels: 1)[0]
        #expect(chorus(input) == chorus(input))
    }

    @Test func allParameterExtremesStayFinite() {
        let input = TestAudio.samples(frames: 2_048, channels: 1)[0]
        for detune in [Float(0), 30] {
            for spread in [Float(0), 1] {
                for mix in [Float(0), 1] {
                    for voices in [Int32(2), 8] {
                        for driftRate in [0.05, 2.0] {
                            for panSpread in [0.0, 1.0] {
                                #expect(chorus(input, detune: detune, spread: spread, mix: mix, voices: voices, driftRate: driftRate, panSpread: panSpread).allSatisfy { $0.isFinite })
                            }
                        }
                    }
                }
            }
        }
    }

    @Test func everyModulatableParameterChangesOutput() {
        let input = sine(frequency: 440, frames: 8_192, amplitude: 0.6)
        let modulation = (0..<input.count).map { Float(sin(Double($0) * 2 * .pi / 1_024)) }
        #expect(chorus(input, detune: 10) != chorus(input, detune: 10, detuneModulation: modulation))
        #expect(chorus(input, spread: 0.5) != chorus(input, spread: 0.5, spreadModulation: modulation))
        #expect(chorus(input, mix: 0.5) != chorus(input, mix: 0.5, mixModulation: modulation))
    }

    @Test func everySettingChangesOutput() {
        let input = TestAudio.samples(frames: 8_192, channels: 1)[0]
        #expect(chorus(input, voices: 2) != chorus(input, voices: 8))
        #expect(chorus(input, driftRate: 0.05) != chorus(input, driftRate: 2))
        // Pan Spread offsets the right channel's wobble against the left.
        #expect(chorus(input, panSpread: 0, channel: 1) != chorus(input, panSpread: 1, channel: 1))
    }

    @Test func audioChorusPrintPreservesStereoShape() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.wav")
        let samples = TestAudio.samples(frames: 8_192, channels: 2)
        try TestAudio.write(samples, to: source, sampleRate: 48_000)
        let output = directory.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var graph = TestProject()
        let audio = graph.add(.audio, asset: sourceAsset)
        let chorus = graph.add(.chorus, ["detune": .number(12), "mix": .number(0.6)])
        let print = graph.add(.print, ["bitDepth": .choice("32f")])
        graph.connect(audio, to: chorus)
        graph.connect(chorus, to: print)
        let urls = [sourceAsset: source]
        let request = RenderRequest(plan: try compile(graph.project, assetURLs: urls), assetURLs: urls, outputDirectory: output)
        let written = try #require(try await RenderEngine.render(request).outputs[print])
        let rendered = try TestAudio.read(written).samples
        #expect(rendered.count == 2)
        #expect(rendered.allSatisfy { $0.count == 8_192 })
        #expect(rendered.allSatisfy { channel in channel.allSatisfy { $0.isFinite } })
        #expect(rendered[0] != samples[0])
    }
}
