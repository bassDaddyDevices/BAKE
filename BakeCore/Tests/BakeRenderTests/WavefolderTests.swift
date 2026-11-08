import BakeDSP
import Foundation
import Testing
@testable import BakeGraph
@testable import BakeRender

struct WavefolderTests {
    private func fold(
        _ input: [Float], amount: Float = 0.5, symmetry: Float = 0, mix: Float = 1,
        stages: Int32 = 2, saturation: Float = 0,
        foldModulation: [Float]? = nil, symmetryModulation: [Float]? = nil, mixModulation: [Float]? = nil,
        chunk: Int? = nil
    ) -> [Float] {
        var output = [Float](repeating: 0, count: input.count)
        var foldSignal = signal(amount, 0, 1)
        var symmetrySignal = signal(symmetry, -1, 1)
        var mixSignal = signal(mix, 0, 1)
        let modulationA = foldModulation ?? []
        let modulationB = symmetryModulation ?? []
        let modulationC = mixModulation ?? []
        modulationA.withUnsafeBufferPointer { pointer in
            if foldModulation != nil { foldSignal.modulation = pointer.baseAddress; foldSignal.modulationFrames = pointer.count }
            modulationB.withUnsafeBufferPointer { pointer in
                if symmetryModulation != nil { symmetrySignal.modulation = pointer.baseAddress; symmetrySignal.modulationFrames = pointer.count }
                modulationC.withUnsafeBufferPointer { pointer in
                    if mixModulation != nil { mixSignal.modulation = pointer.baseAddress; mixSignal.modulationFrames = pointer.count }
                    input.withUnsafeBufferPointer { source in
                        output.withUnsafeMutableBufferPointer { destination in
                            var start = 0
                            while start < input.count {
                                let count = min(chunk ?? input.count, input.count - start)
                                bake.dsp.renderWavefolder(
                                    foldSignal, symmetrySignal, mixSignal, stages, saturation,
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
        return output
    }

    /// Review finding: a fold leaves values in −1…1 unchanged, so stages 2–4 did nothing. Each extra
    /// stage now scales by (1 + Fold) and folds again (worked by hand for 0.5 at Fold 0.35).
    @Test func stagesFoldAgain() {
        let one = fold([0.5], amount: 0.35, stages: 1)[0]
        let two = fold([0.5], amount: 0.35, stages: 2)[0]
        #expect(abs(one - (-0.875)) < 1e-5)
        #expect(abs(two - (-0.81875)) < 1e-5)
        let input = TestAudio.samples(frames: 4_096, channels: 1)[0]
        #expect(fold(input, amount: 0.35, stages: 1) != fold(input, amount: 0.35, stages: 3))
        // Fold 0 stays clean however many stages.
        #expect(fold([0.5], amount: 0, stages: 4)[0] == 0.5)
    }

    @Test func repeatedReflectionProducesFoldedKnownOutput() {
        let output = fold([0, 0.25, 0.5, 0.75, 1], amount: 0.5, stages: 1)
        #expect(output.allSatisfy { $0.isFinite && abs($0) <= 1 })
        #expect(output != [0, 0.25, 0.5, 0.75, 1])
    }

    @Test func chunksOf777MatchOneWholeRender() {
        let input = TestAudio.samples(frames: 6_013, channels: 1)[0]
        #expect(fold(input, amount: 0.83, symmetry: 0.25, stages: 3) == fold(input, amount: 0.83, symmetry: 0.25, stages: 3, chunk: 777))
    }

    @Test func repeatedRendersAreDeterministic() {
        let input = TestAudio.samples(frames: 2_048, channels: 1)[0]
        #expect(fold(input, amount: 0.42, symmetry: -0.3, stages: 4) == fold(input, amount: 0.42, symmetry: -0.3, stages: 4))
    }

    @Test func allParameterExtremesStayFinite() {
        let input = TestAudio.samples(frames: 1_024, channels: 1)[0]
        for amount in [Float(0), 1] {
            for symmetry in [Float(-1), 1] {
                for mix in [Float(0), 1] {
                    for stages in [Int32(1), 4] {
                        for saturation in [Float(0), 1] {
                            let output = fold(input, amount: amount, symmetry: symmetry, mix: mix, stages: stages, saturation: saturation)
                            #expect(output.allSatisfy { $0.isFinite })
                        }
                    }
                }
            }
        }
    }

    @Test func modulatableParametersChangeOutput() {
        let input = TestAudio.samples(frames: 512, channels: 1)[0]
        let positive = [Float](repeating: 1, count: input.count)
        let negative = [Float](repeating: -1, count: input.count)
        #expect(fold(input, amount: 0.5) != fold(input, amount: 0.5, foldModulation: positive))
        #expect(fold(input, symmetry: 0) != fold(input, symmetry: 0, symmetryModulation: positive))
        #expect(fold(input, mix: 1) != fold(input, mix: 1, mixModulation: negative))
    }

    @Test func audioWavefolderPrintPreservesLengthAndChannels() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.wav")
        let samples = TestAudio.samples(frames: 2_048, channels: 2)
        try TestAudio.write(samples, to: source, sampleRate: 48_000)
        let output = directory.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var graph = TestProject()
        let audio = graph.add(.audio, asset: sourceAsset)
        let wavefolder = graph.add(.wavefolder, ["fold": .number(0.7), "stages": .choice("3")])
        let print = graph.add(.print, ["bitDepth": .choice("32f")])
        graph.connect(audio, to: wavefolder)
        graph.connect(wavefolder, to: print)
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
