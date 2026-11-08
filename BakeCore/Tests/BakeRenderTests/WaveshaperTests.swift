import BakeDSP
import Foundation
import Testing
@testable import BakeGraph
@testable import BakeRender

struct WaveshaperTests {
    private func shape(_ input: [Float], intensity: Float = 1, mix: Float = 1, chunk: Int? = nil) -> [Float] {
        var output = [Float](repeating: 0, count: input.count)
        let intensitySignal = signal(intensity, 0, 1)
        let mixSignal = signal(mix, 0, 1)
        input.withUnsafeBufferPointer { source in
            output.withUnsafeMutableBufferPointer { destination in
                var start = 0
                while start < input.count {
                    let count = min(chunk ?? input.count, input.count - start)
                    bake.dsp.renderWaveshaper(
                        intensitySignal, mixSignal,
                        source.baseAddress! + start, destination.baseAddress! + start,
                        start, count
                    )
                    start += count
                }
            }
        }
        return output
    }

    @Test func normalizedTanhTransferIsKnownAndBounded() {
        let output = shape([-1, -0.1, 0, 0.1, 1])
        #expect(output[0] == -1)
        #expect(output[2] == 0)
        #expect(output[4] == 1)
        #expect(output[1] < -0.1)
        #expect(output[3] > 0.1)
        #expect(output.allSatisfy { abs($0) <= 1 })
    }

    @Test func chunksOf777MatchOneWholeRender() {
        let input = TestAudio.samples(frames: 6_013, channels: 1)[0]
        #expect(shape(input, intensity: 0.8) == shape(input, intensity: 0.8, chunk: 777))
    }

    @Test func identicalRendersAreDeterministic() {
        let input = TestAudio.samples(frames: 4_096, channels: 1)[0]
        #expect(shape(input, intensity: 0.63) == shape(input, intensity: 0.63))
    }

    @Test func parameterExtremesStayFinite() {
        let input = TestAudio.samples(frames: 1_024, channels: 1)[0]
        for intensity in [Float(0), 1] {
            for mix in [Float(0), 1] {
                #expect(shape(input, intensity: intensity, mix: mix).allSatisfy { $0.isFinite })
            }
        }
    }

    @Test func intensityAndMixModulationChangeOutput() {
        let input = sine(frequency: 1_000, frames: 2_048, amplitude: 0.9)
        var highIntensity = signal(0, 0, 1)
        let intensityModulation = [Float](repeating: 1, count: input.count)
        intensityModulation.withUnsafeBufferPointer { pointer in
            highIntensity.modulation = pointer.baseAddress
            highIntensity.modulationFrames = pointer.count
            let withModulation = render(input, intensity: highIntensity, mix: signal(1, 0, 1))
            #expect(withModulation != shape(input, intensity: 0))
        }
        var dryMix = signal(1, 0, 1)
        let mixModulation = [Float](repeating: -1, count: input.count)
        mixModulation.withUnsafeBufferPointer { pointer in
            dryMix.modulation = pointer.baseAddress
            dryMix.modulationFrames = pointer.count
            #expect(render(input, intensity: signal(1, 0, 1), mix: dryMix) == input)
        }
    }

    private func render(_ input: [Float], intensity: bake.dsp.ParameterSignal, mix: bake.dsp.ParameterSignal) -> [Float] {
        var output = [Float](repeating: 0, count: input.count)
        input.withUnsafeBufferPointer { source in
            output.withUnsafeMutableBufferPointer { destination in
                bake.dsp.renderWaveshaper(intensity, mix, source.baseAddress!, destination.baseAddress!, 0, input.count)
            }
        }
        return output
    }

    @Test func audioWaveshaperPrintPreservesLengthAndChannels() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.wav")
        let samples = TestAudio.samples(frames: 2_048, channels: 2)
        try TestAudio.write(samples, to: source, sampleRate: 48_000)
        let output = directory.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        var graph = TestProject()
        let audio = graph.add(.audio, asset: sourceAsset)
        let waveshaper = graph.add(.waveshaper, ["intensity": .number(0.8)])
        let print = graph.add(.print, ["bitDepth": .choice("32f")])
        graph.connect(audio, to: waveshaper)
        graph.connect(waveshaper, to: print)
        let urls = [sourceAsset: source]
        let request = RenderRequest(plan: try compile(graph.project, assetURLs: urls), assetURLs: urls, outputDirectory: output)
        let written = try #require(try await RenderEngine.render(request).outputs[print])
        let rendered = try TestAudio.read(written)

        #expect(rendered.samples.count == 2)
        #expect(rendered.samples.allSatisfy { $0.count == 2_048 })
        #expect(rendered.samples.allSatisfy { $0.allSatisfy { $0.isFinite } })
        #expect(rendered.samples[0] != samples[0])
    }
}
