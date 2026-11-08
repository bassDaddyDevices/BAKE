import BakeDSP
import BakeGPU
import Foundation
import Metal
import Testing
@testable import BakeGraph
@testable import BakeRender

struct FractalFilterTests {
    @Test func cpuMaskUsesTheApprovedPositionAndFloatSineAndMatchesMetal() async throws {
        let gpu = try GPUContext()
        let bins = 1_025
        let sampleRate = 48_000.0
        let fftSize = 2_048
        let positions = (0..<bins).map { FractalFilterKernel.position(bin: $0, sampleRate: sampleRate, fftSize: fftSize) }
        let kernel = try FractalFilterKernel(gpu: gpu, maxFrames: 1, maxBins: bins, sampleRate: sampleRate, fftSize: fftSize)
        for pattern in FractalMaskPattern.allCases {
            for iterations in [1, 8, 16] {
                for warp in [0.1, 1.0, 10.0] {
                    var settings = bake.dsp.FractalMaskSettings()
                    settings.iterations = UInt32(iterations)
                    settings.warp = Float(warp)
                    settings.center = 0.37
                    settings.q = 2.3
                    switch pattern {
                    case .cantor: settings.pattern = .cantor
                    case .mandelbrot: settings.pattern = .mandelbrot
                    case .julia: settings.pattern = .julia
                    case .koch: settings.pattern = .koch
                    }
                    var cpu = [Float](repeating: 0, count: bins)
                    positions.withUnsafeBufferPointer { x in
                        cpu.withUnsafeMutableBufferPointer { output in
                            bake.dsp.fractalMaskRaw(settings, x.baseAddress, bins, output.baseAddress)
                        }
                    }
                    let gpuBuffer = try await kernel.run(
                        frames: [FractalMaskFrame(iterations: iterations, warp: warp, center: 0.37, q: 2.3, pattern: pattern)],
                        binRange: 0..<bins, totalBins: bins, sampleRate: sampleRate, fftSize: fftSize
                    )
                    let metal = UnsafeBufferPointer(start: gpuBuffer.contents().assumingMemoryBound(to: Float.self), count: bins)
                    for bin in 0..<bins {
                        let relativeError = cpu[bin] == 0 ? abs(metal[bin]) : abs(cpu[bin] - metal[bin]) / abs(cpu[bin])
                        #expect(relativeError <= 1e-5, "\\(pattern) depth \\(iterations) warp \\(warp), bin \\(bin)")
                    }
                }
            }
        }
    }

    @Test func cantorDepthOneHasTheSpecifiedNotchBands() {
        let positions = (0..<8_193).map { Float($0) / Float(8_192) }
        var settings = bake.dsp.FractalMaskSettings()
        settings.iterations = 1
        settings.warp = 1
        settings.center = 0.5
        settings.q = 0.1
        settings.pattern = .cantor
        var mask = [Float](repeating: 0, count: positions.count)
        positions.withUnsafeBufferPointer { x in
            mask.withUnsafeMutableBufferPointer { output in
                bake.dsp.fractalMaskRaw(settings, x.baseAddress, positions.count, output.baseAddress)
            }
        }
        let inBand = mask.indices.filter {
            (positions[$0] >= 1.0 / 6.0 && positions[$0] <= 0.28) ||
            (positions[$0] >= 0.72 && positions[$0] <= 5.0 / 6.0)
        }.map { mask[$0] }
        let reference = [0.05, 0.5].map { x in
            mask[positions.indices.min(by: { abs(positions[$0] - Float(x)) < abs(positions[$1] - Float(x)) })!]
        }
        #expect(!inBand.isEmpty)
        #expect(inBand.max()! < reference[0] * 0.1)
        #expect(reference[1] >= 1)
    }

    @Test func mixZeroReturnsTheInputBitForBitThroughRenderEngine() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.wav")
        let samples = TestAudio.samples(frames: 8_193, channels: 2)
        try TestAudio.write(samples, to: source, sampleRate: 48_000)
        let output = directory.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var graph = TestProject()
        let audio = graph.add(.audio, asset: sourceAsset)
        let filter = graph.add(.fractalFilter, ["mix": .number(0)])
        let print = graph.add(.print, ["bitDepth": .choice("32f")])
        graph.connect(audio, to: filter)
        graph.connect(filter, to: print)
        let urls = [sourceAsset: source]
        let request = RenderRequest(
            plan: try compile(graph.project, assetURLs: urls), assetURLs: urls,
            outputDirectory: output, chunkFrames: 777
        )
        let file = try #require(try await RenderEngine.render(request).outputs[print])
        #expect(try TestAudio.read(file).samples == samples)
    }

    @Test func unityMaskMakesTheStftPathTransparent() {
        let layout = bake.dsp.StftLayout(fftSize: 1_024, hop: 256)
        let count = 4_097
        let input = (0..<count).map { Float(sin(Double($0) * 0.031)) * 0.4 }
        var output = [Float](repeating: 0, count: count)
        let window = UnsafeMutablePointer<Double>.allocate(capacity: 1_024)
        let scratch = UnsafeMutablePointer<Double>.allocate(capacity: Int(bake.dsp.stftScratchDoubles(layout)))
        let maxRows = Int(bake.dsp.fractalFilterMaxRows(layout, 777))
        let bins = 513
        let masks = UnsafeMutablePointer<Float>.allocate(capacity: maxRows * bins)
        let phases = UnsafeMutablePointer<UInt32>.allocate(capacity: maxRows)
        let spectrum = UnsafeMutablePointer<Float>.allocate(capacity: Int(bake.dsp.stftSpectrumFloats(layout, maxRows)))
        let rows = UnsafeMutablePointer<Float>.allocate(capacity: Int(bake.dsp.stftRowFloats(layout, maxRows)))
        defer {
            window.deallocate()
            scratch.deallocate()
            masks.deallocate()
            phases.deallocate()
            spectrum.deallocate()
            rows.deallocate()
        }
        bake.dsp.stftWindow(layout, window)
        var start = 0
        while start < count {
            let length = min(777, count - start)
            let covered = bake.dsp.stftFramesCovering(layout, count, start, length)
            let frameCount = Int(covered.count)
            masks.initialize(repeating: 1, count: frameCount * bins)
            phases.initialize(repeating: 0, count: frameCount)
            input.withUnsafeBufferPointer { source in
                output.withUnsafeMutableBufferPointer { destination in
                    let chunkOutput = UnsafeMutablePointer<Float>.allocate(capacity: length)
                    defer { chunkOutput.deallocate() }
                    bake.dsp.fractalFilterProcessChannel(
                        layout, window, source.baseAddress, count, start, length,
                        Int(covered.first), frameCount, masks, phases, 1, spectrum, rows, scratch, chunkOutput
                    )
                    destination.baseAddress!.advanced(by: start).update(from: chunkOutput, count: length)
                }
            }
            start += length
        }
        #expect(zip(input, output).allSatisfy { abs($0 - $1) < 1e-5 })
    }

    @Test func everyFractalFilterChoiceChangesTheRender() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.wav")
        try TestAudio.write(TestAudio.samples(frames: 8_000, channels: 1), to: source, sampleRate: 48_000)
        let urls = [sourceAsset: source]
        func render(_ parameters: [ParameterID: ParameterValue]) async throws -> [Float] {
            let output = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            var graph = TestProject()
            let audio = graph.add(.audio, asset: sourceAsset)
            let filter = graph.add(.fractalFilter, parameters)
            let print = graph.add(.print, ["bitDepth": .choice("32f")])
            graph.connect(audio, to: filter)
            graph.connect(filter, to: print)
            let request = RenderRequest(
                plan: try compile(graph.project, assetURLs: urls), assetURLs: urls,
                outputDirectory: output, chunkFrames: 8_000
            )
            let file = try #require(try await RenderEngine.render(request).outputs[print])
            return try TestAudio.read(file).samples[0]
        }
        let base: [ParameterID: ParameterValue] = ["fftSize": .choice("1024"), "mix": .number(0.5)]
        let variants: [[ParameterID: ParameterValue]] = [
            ["phaseMode": .choice("randomized")], ["phaseMode": .choice("mirrored")],
            ["pattern": .choice("mandelbrot")], ["pattern": .choice("julia")], ["pattern": .choice("koch")],
            ["iterations": .number(2)], ["warp": .number(2)], ["bias": .number(0.4)], ["q": .number(5)],
        ]
        for variant in variants {
            #expect(try await render(base) != render(base.merging(variant) { _, value in value }))
        }
    }

    @Test func chunksAndRepeatedRendersAreDeterministic() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.wav")
        let input = TestAudio.samples(frames: 10_031, channels: 1)
        try TestAudio.write(input, to: source, sampleRate: 48_000)
        func request(_ chunk: Int, _ folder: String) throws -> (RenderRequest, NodeID) {
            let output = directory.appendingPathComponent(folder, isDirectory: true)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            var graph = TestProject()
            let audio = graph.add(.audio, asset: sourceAsset)
            let filter = graph.add(.fractalFilter, ["fftSize": .choice("1024"), "phaseMode": .choice("randomized"), "seed": .number(17)])
            let print = graph.add(.print, ["bitDepth": .choice("32f")])
            graph.connect(audio, to: filter)
            graph.connect(filter, to: print)
            let urls = [sourceAsset: source]
            return (RenderRequest(plan: try compile(graph.project, assetURLs: urls), assetURLs: urls, outputDirectory: output, chunkFrames: chunk), print)
        }
        let (small, smallPrint) = try request(777, "small")
        let (large, largePrint) = try request(65_536, "large")
        let a = try #require(try await RenderEngine.render(small).outputs[smallPrint])
        let b = try #require(try await RenderEngine.render(large).outputs[largePrint])
        let samplesA = try TestAudio.read(a).samples[0]
        let samplesB = try TestAudio.read(b).samples[0]
        #expect(samplesA.count == input[0].count)
        let allFinite = samplesA.allSatisfy { $0.isFinite }
        #expect(allFinite)
        #expect(zip(samplesA, samplesB).allSatisfy { abs($0 - $1) < 1e-6 })
    }
}
