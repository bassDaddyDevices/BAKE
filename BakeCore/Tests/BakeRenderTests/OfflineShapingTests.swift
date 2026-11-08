import BakeDSP
import Foundation
import Testing
@testable import BakeGraph
@testable import BakeRender

/// Waveshaper curves/bias and Wavefolder shape/stages, and the 1–32x oversampling both gained.
struct OfflineShapingTests {
    private typealias Curve = bake.dsp.WaveshaperCurve
    private let curves: [Curve] = [.tanh, .arctan, .softsign, .sine, .cubic, .hardClip, .asymmetric, .chebyshev]
    private let input = TestAudio.samples(frames: 3_000, channels: 1)[0]

    private func shape(
        _ curve: Curve, oversampling: Int32 = 1, intensity: Float = 0.7, bias: Float = 0, mix: Float = 1,
        _ signalIn: [Float]? = nil, chunk: Int? = nil
    ) -> [Float] {
        let source = signalIn ?? input
        var output = [Float](repeating: 0, count: source.count)
        let size = chunk ?? source.count
        var scratch = [Float](repeating: 0, count: bake.dsp.waveshaperScratchFloats(oversampling, size) + 8)
        source.withUnsafeBufferPointer { input in
            output.withUnsafeMutableBufferPointer { destination in
                var start = 0
                while start < source.count {
                    let count = min(size, source.count - start)
                    bake.dsp.renderWaveshaperCurve(
                        curve, oversampling, signal(intensity, 0, 1), signal(bias, -1, 1), signal(mix, 0, 1),
                        input.baseAddress!, source.count, destination.baseAddress! + start, start, count, &scratch
                    )
                    start += count
                }
            }
        }
        return output
    }

    private func fold(
        _ shape: bake.dsp.WavefolderShape = .triangle, oversampling: Int32 = 1, amount: Float = 0.6, symmetry: Float = 0,
        mix: Float = 1, stages: Int32 = 2, saturation: Float = 0, _ signalIn: [Float]? = nil, chunk: Int? = nil
    ) -> [Float] {
        let source = signalIn ?? input
        var output = [Float](repeating: 0, count: source.count)
        let size = chunk ?? source.count
        var scratch = [Float](repeating: 0, count: bake.dsp.wavefolderScratchFloats(oversampling, size) + 8)
        source.withUnsafeBufferPointer { input in
            output.withUnsafeMutableBufferPointer { destination in
                var start = 0
                while start < source.count {
                    let count = min(size, source.count - start)
                    bake.dsp.renderWavefolderOversampled(
                        shape, oversampling, signal(amount, 0, 1), signal(symmetry, -1, 1), signal(mix, 0, 1), stages, saturation,
                        input.baseAddress!, source.count, destination.baseAddress! + start, start, count, &scratch
                    )
                    start += count
                }
            }
        }
        return output
    }

    // MARK: Frozen sound

    @Test func theOriginalWaveshaperIsTheTanhCurveAtOneTimes() {
        for intensity: Float in [0, 0.5, 1] {
            var original = [Float](repeating: 0, count: input.count)
            input.withUnsafeBufferPointer { source in
                original.withUnsafeMutableBufferPointer { destination in
                    bake.dsp.renderWaveshaper(signal(intensity, 0, 1), signal(0.8, 0, 1), source.baseAddress!, destination.baseAddress!, 0, input.count)
                }
            }
            #expect(original == shape(.tanh, intensity: intensity, mix: 0.8))
        }
    }

    @Test func theOriginalWavefolderIsTheTriangleFoldAtOneTimes() {
        for stages: Int32 in [1, 2, 4] {
            var original = [Float](repeating: 0, count: input.count)
            input.withUnsafeBufferPointer { source in
                original.withUnsafeMutableBufferPointer { destination in
                    bake.dsp.renderWavefolder(
                        signal(0.6, 0, 1), signal(0.2, -1, 1), signal(0.9, 0, 1), stages, 0.3,
                        source.baseAddress!, destination.baseAddress!, 0, input.count
                    )
                }
            }
            #expect(original == fold(.triangle, symmetry: 0.2, mix: 0.9, stages: stages, saturation: 0.3))
        }
    }

    // MARK: Waveshaper

    @Test func everyCurveIsBoundedFiniteAndSilentOnSilence() {
        let ramp = (0...200).map { Float($0) / 100 - 1 }
        for curve in curves {
            for intensity: Float in [0, 0.5, 1] {
                for bias: Float in [-1, 0, 1] {
                    let output = shape(curve, intensity: intensity, bias: bias, ramp)
                    #expect(output.allSatisfy { $0.isFinite && abs($0) <= 2 })
                    #expect(shape(curve, intensity: intensity, bias: bias, [Float](repeating: 0, count: 8)).allSatisfy { abs($0) < 1e-6 })
                }
            }
        }
    }

    @Test func everyCurveSoundsDifferent() {
        let results = curves.map { shape($0, intensity: 0.7) }
        for first in results.indices {
            for second in results.indices where second > first {
                #expect(results[first] != results[second], "\(curves[first]) vs \(curves[second])")
            }
        }
    }

    @Test func biasMovesTheOperatingPoint() {
        for curve in curves {
            #expect(shape(curve, intensity: 0.7, bias: 0.5) != shape(curve, intensity: 0.7, bias: 0), "\(curve)")
        }
    }

    @Test func fullScaleStaysFullScaleForTheSaturatingCurves() {
        for curve: Curve in [.tanh, .arctan, .softsign, .hardClip] {
            let output = shape(curve, intensity: 1, [-1, 1])
            #expect(abs(output[0] + 1) < 1e-5 && abs(output[1] - 1) < 1e-5, "\(curve)")
        }
    }

    // MARK: Oversampling

    @Test func oversamplingChangesTheWaveshaperAndTheWavefolder() {
        let drive = sine(frequency: 5_000, frames: 3_000, amplitude: 0.9)
        #expect(shape(.hardClip, oversampling: 1, intensity: 1, drive) != shape(.hardClip, oversampling: 8, intensity: 1, drive))
        #expect(fold(oversampling: 1, amount: 1, stages: 4, drive) != fold(oversampling: 8, amount: 1, stages: 4, drive))
    }

    @Test func higherOversamplingConvergesOnTheCleanAnswer() {
        // Hard folding of a bright tone aliases badly; each doubling of the rate should land
        // closer to what 32x gives (compared away from the ends, where the filter ramps in).
        let tone = sine(frequency: 7_000, frames: 4_000, amplitude: 0.9)
        let reference = fold(oversampling: 32, amount: 0.8, stages: 3, tone)
        func error(_ factor: Int32) -> Float {
            let output = fold(oversampling: factor, amount: 0.8, stages: 3, tone)
            return zip(output[200..<3_800], reference[200..<3_800]).map { abs($0 - $1) }.reduce(0, +)
        }
        #expect(error(1) > error(4))
        #expect(error(4) > error(16))
    }

    @Test func oversampledRendersDontDependOnChunkSize() {
        for factor: Int32 in [1, 4, 32] {
            #expect(shape(.asymmetric, oversampling: factor, bias: 0.3) == shape(.asymmetric, oversampling: factor, bias: 0.3, chunk: 777))
            #expect(fold(.triangle, oversampling: factor, stages: 3) == fold(.triangle, oversampling: factor, stages: 3, chunk: 777))
            #expect(fold(.sine, oversampling: factor, stages: 3) == fold(.sine, oversampling: factor, stages: 3, chunk: 777))
        }
    }

    @Test func oversampledRendersAreDeterministic() {
        #expect(shape(.cubic, oversampling: 16) == shape(.cubic, oversampling: 16))
        #expect(fold(.sine, oversampling: 16) == fold(.sine, oversampling: 16))
    }

    @Test func oversamplingExtremesStayFinite() {
        for factor: Int32 in [1, 32, 100] {
            #expect(shape(.chebyshev, oversampling: factor, intensity: 1, bias: 1).allSatisfy { $0.isFinite })
            #expect(fold(.sine, oversampling: factor, amount: 1, symmetry: 1, stages: 8, saturation: 1).allSatisfy { $0.isFinite })
        }
    }

    // MARK: Wavefolder

    @Test func theTwoFoldShapesAndMoreStagesAllDiffer() {
        #expect(fold(.triangle) != fold(.sine))
        #expect(fold(stages: 4) != fold(stages: 8))
        #expect(fold(.sine, stages: 1) != fold(.sine, stages: 6))
    }

    @Test func foldZeroIsCleanForEveryShapeAndStageCount() {
        let quiet = sine(frequency: 300, frames: 1_000, amplitude: 0.5)
        for shape: bake.dsp.WavefolderShape in [.triangle] {
            for stages: Int32 in [1, 4, 8] {
                let output = fold(shape, amount: 0, stages: stages, quiet)
                #expect(zip(output, quiet).allSatisfy { abs($0 - $1) < 1e-6 })
            }
        }
    }

    // MARK: End to end

    private func render(_ parameters: [ParameterID: ParameterValue], kind: NodeKind, directory: URL, chunk: Int = 4_096) async throws -> [[Float]] {
        let source = directory.appendingPathComponent("source.wav")
        try TestAudio.write(TestAudio.samples(frames: 5_000, channels: 2), to: source, sampleRate: 48_000)
        let output = directory.appendingPathComponent("out-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var graph = TestProject()
        let audio = graph.add(.audio, asset: sourceAsset)
        let node = graph.add(kind, parameters)
        let print = graph.add(.print, ["bitDepth": .choice("32f")])
        graph.connect(audio, to: node)
        graph.connect(node, to: print)
        let urls = [sourceAsset: source]
        let request = RenderRequest(plan: try compile(graph.project, assetURLs: urls), assetURLs: urls, outputDirectory: output, chunkFrames: chunk)
        return try TestAudio.read(try #require(try await RenderEngine.render(request).outputs[print])).samples
    }

    @Test func theNodesRenderThroughTheEngineWithEveryChoice() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var seen: [[[Float]]] = []
        for curve in TransferCurves.waveshaperCurves {
            let rendered = try await render(["curve": .choice(curve), "intensity": .number(0.8), "oversampling": .choice("4")], kind: .waveshaper, directory: directory)
            #expect(rendered.count == 2 && rendered.allSatisfy { $0.count == 5_000 && $0.allSatisfy { $0.isFinite } }, "\(curve)")
            #expect(!seen.contains { $0 == rendered })
            seen.append(rendered)
        }
        for shape in ["triangle", "sine"] {
            let rendered = try await render(["foldShape": .choice(shape), "fold": .number(0.8), "stages": .choice("6"), "oversampling": .choice("4")], kind: .wavefolder, directory: directory)
            #expect(rendered.count == 2 && rendered.allSatisfy { $0.count == 5_000 && $0.allSatisfy { $0.isFinite } })
        }
    }

    @Test func theFrozenSettingsSoundExactlyLikeTheOriginalNodes() async throws {
        // What a migrated older document holds (tanh, no bias, 1x / triangle, 1x) must render
        // bit-identically to the original kernels, whatever the new defaults are.
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = TestAudio.samples(frames: 5_000, channels: 2)

        let shaped = try await render(
            ["curve": .choice("tanh"), "bias": .number(0), "oversampling": .choice("1"), "intensity": .number(0.8), "mix": .number(0.9)],
            kind: .waveshaper, directory: directory
        )
        let folded = try await render(
            ["foldShape": .choice("triangle"), "oversampling": .choice("1"), "fold": .number(0.8), "stages": .choice("3"), "saturation": .number(0.2)],
            kind: .wavefolder, directory: directory
        )

        for channel in 0..<2 {
            var original = [Float](repeating: 0, count: 5_000)
            source[channel].withUnsafeBufferPointer { input in
                original.withUnsafeMutableBufferPointer { output in
                    bake.dsp.renderWaveshaper(signal(0.8, 0, 1), signal(0.9, 0, 1), input.baseAddress!, output.baseAddress!, 0, 5_000)
                }
            }
            #expect(shaped[channel] == original)
            var originalFold = [Float](repeating: 0, count: 5_000)
            source[channel].withUnsafeBufferPointer { input in
                originalFold.withUnsafeMutableBufferPointer { output in
                    bake.dsp.renderWavefolder(signal(0.8, 0, 1), signal(0, -1, 1), signal(1, 0, 1), 3, 0.2, input.baseAddress!, output.baseAddress!, 0, 5_000)
                }
            }
            #expect(folded[channel] == originalFold)
        }
    }

    @Test func chunkSizeNeverChangesTheEngineResult() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let parameters: [ParameterID: ParameterValue] = ["fold": .number(0.9), "stages": .choice("4"), "oversampling": .choice("8")]
        let whole = try await render(parameters, kind: .wavefolder, directory: directory, chunk: 65_536)
        let chunked = try await render(parameters, kind: .wavefolder, directory: directory, chunk: 777)
        #expect(whole == chunked)
    }
}
