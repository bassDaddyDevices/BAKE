import BakeDSP
import Foundation
import Testing
@testable import BakeGraph
@testable import BakeRender

struct ReverseTests {
    private func reverse(_ input: [Float], mix: Float = 1, modulation: [Float]? = nil, chunk: Int? = nil) -> [Float] {
        var state = signal(mix, 0, 1)
        let modulationSamples = modulation ?? []
        var output = [Float](repeating: 0, count: input.count)
        modulationSamples.withUnsafeBufferPointer { pointer in
            if modulation != nil { state.modulation = pointer.baseAddress; state.modulationFrames = pointer.count }
            input.withUnsafeBufferPointer { source in
                output.withUnsafeMutableBufferPointer { destination in
                    var start = 0
                    while start < input.count {
                        let count = min(chunk ?? input.count, input.count - start)
                        bake.dsp.renderReverse(
                            source.baseAddress!, source.count, destination.baseAddress! + start,
                            start, count, state
                        )
                        start += count
                    }
                }
            }
        }
        return output
    }

    @Test func globalReverseMatchesKnownAnswer() {
        #expect(reverse([0, 1, 2, 3, 4]) == [4, 3, 2, 1, 0])
        #expect(reverse([0, 1, 2, 3, 4], mix: 0) == [0, 1, 2, 3, 4])
    }

    @Test func chunksOf777MatchOneWholeRender() {
        let input = TestAudio.samples(frames: 6_013, channels: 1)[0]
        #expect(reverse(input) == reverse(input, chunk: 777))
    }

    @Test func repeatedRendersAreDeterministic() {
        let input = TestAudio.samples(frames: 2_048, channels: 1)[0]
        #expect(reverse(input) == reverse(input))
    }

    @Test func mixExtremesAreFinite() {
        let input = TestAudio.samples(frames: 1_024, channels: 1)[0]
        for mix in [Float(0), 1] {
            #expect(reverse(input, mix: mix).allSatisfy { $0.isFinite })
        }
    }

    @Test func mixModulationChangesOutput() {
        let input: [Float] = [0, 1, 0, -1, 0.5, 0.25]
        let modulation = [Float](repeating: -1, count: input.count)
        #expect(reverse(input, mix: 1, modulation: modulation) == input)
        #expect(reverse(input, mix: 1) != reverse(input, mix: 1, modulation: modulation))
    }

    @Test func audioReversePrintPreservesLengthChannelsAndOrder() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.wav")
        let samples: [[Float]] = [[-0.9, -0.5, -0.1, 0.3, 0.7], [0.8, 0.4, 0, -0.4, -0.8]]
        try TestAudio.write(samples, to: source, sampleRate: 48_000)
        let output = directory.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var graph = TestProject()
        let audio = graph.add(.audio, asset: sourceAsset)
        let reverse = graph.add(.reverse)
        let print = graph.add(.print, ["bitDepth": .choice("32f")])
        graph.connect(audio, to: reverse)
        graph.connect(reverse, to: print)
        let urls = [sourceAsset: source]
        let request = RenderRequest(plan: try compile(graph.project, assetURLs: urls), assetURLs: urls, outputDirectory: output)
        let written = try #require(try await RenderEngine.render(request).outputs[print])
        let rendered = try TestAudio.read(written).samples
        #expect(rendered.count == 2)
        #expect(rendered.allSatisfy { $0.count == samples[0].count })
        for channel in rendered.indices {
            #expect(zip(rendered[channel], samples[channel].reversed()).allSatisfy { abs($0 - $1) < 2e-6 })
        }
    }
}
