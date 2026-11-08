import BakeDSP
import Foundation
import Testing
@testable import BakeGraph
@testable import BakeRender

struct AdaptiveClippingTests {
    struct Settings {
        var threshold: Float = -6
        var release: Float = 100
        var soft = true
        var makeup: Float = 0
        var mix: Float = 1
        var floor: Float = -60
        var oversampling: Int32 = 1
        var modulation: [String: [Float]] = [:]
    }

    private func render(_ input: [Float], _ settings: Settings, chunk: Int? = nil) -> [Float] {
        let maxCount = chunk ?? input.count
        var controls = bake.dsp.AdaptiveClippingControls()
        controls.threshold = signal(settings.threshold, -24, 0)
        controls.release = signal(settings.release, 5, 1_000)
        controls.kneeIndex = signal(settings.soft ? 1 : 0, 0, 1)
        controls.makeup = signal(settings.makeup, 0, 24)
        controls.mix = signal(settings.mix, 0, 1)
        controls.floor = signal(settings.floor, -80, -20)
        controls.knee = settings.soft ? .soft : .hard
        controls.sampleRate = 48_000
        controls.oversampling = settings.oversampling
        var buffers: [UnsafeMutableBufferPointer<Float>] = []
        defer { buffers.forEach { $0.deallocate() } }
        for (id, values) in settings.modulation {
            let buffer = UnsafeMutableBufferPointer<Float>.allocate(capacity: values.count)
            _ = buffer.initialize(from: values)
            buffers.append(buffer)
            let pointer = UnsafePointer(buffer.baseAddress)
            func attach(_ target: inout bake.dsp.ParameterSignal) {
                target.modulation = pointer
                target.modulationFrames = values.count
            }
            switch id {
            case "threshold": attach(&controls.threshold)
            case "release": attach(&controls.release)
            case "knee": attach(&controls.kneeIndex)
            case "makeup": attach(&controls.makeup)
            case "mix": attach(&controls.mix)
            case "floor": attach(&controls.floor)
            default: Issue.record("unknown control \(id)")
            }
        }
        var state = bake.dsp.AdaptiveClippingState()
        var scratch = [Float](repeating: 0, count: max(bake.dsp.adaptiveClippingScratchFloats(settings.oversampling, maxCount), 1))
        var history = [Float](repeating: 0, count: max(bake.dsp.adaptiveClippingHistoryFloats(settings.oversampling), 1))
        var output = [Float](repeating: 0, count: input.count)
        input.withUnsafeBufferPointer { source in
            output.withUnsafeMutableBufferPointer { destination in
                var start = 0
                while start < input.count {
                    let count = min(maxCount, input.count - start)
                    bake.dsp.renderAdaptiveClipping(
                        &state, controls, source.baseAddress!, input.count,
                        destination.baseAddress! + start, start, count, &scratch, &history
                    )
                    start += count
                }
            }
        }
        return output
    }

    private func rms(_ samples: ArraySlice<Float>) -> Float {
        sqrt(samples.reduce(0) { $0 + $1 * $1 } / Float(max(samples.count, 1)))
    }

    private func noise(frames: Int, amplitude: Float = 0.5) -> [Float] {
        var seed: UInt32 = 13
        return (0..<frames).map { _ in
            seed = seed &* 1_664_525 &+ 1_013_904_223
            return amplitude * (Float(seed >> 8) / Float(1 << 23) - 1)
        }
    }

    @Test func hardKneeClipsAtThresholdBelowTheEnvelope() {
        // Envelope ≈ 0.8 (the peak), so the ceiling is 0.8 · 10^(−6/20) ≈ 0.40.
        let input = sine(frequency: 200, frames: 9_600, amplitude: 0.8)
        let output = render(input, Settings(soft: false))
        let tail = output[4_800...]
        let ceiling = Float(0.8 * pow(10, -6.0 / 20))
        #expect(tail.allSatisfy { abs($0) <= ceiling * 1.01 })
        #expect((tail.map(abs).max() ?? 0) > 0.9 * ceiling)
    }

    @Test func quietAndLoudAreClippedAlike() {
        func ratio(_ amplitude: Float) -> Float {
            let input = sine(frequency: 200, frames: 9_600, amplitude: amplitude)
            return rms(render(input, Settings())[4_800...]) / rms(input[4_800...])
        }
        #expect(abs(decibels(ratio(0.1) / ratio(0.9))) < 0.5)
        #expect(ratio(0.9) < 0.9)
    }

    @Test func belowTheFloorPassesUntouched() {
        // A signal far below the floor (−60 dB = 0.001) is never clipped by the soft knee much.
        let input = sine(frequency: 200, frames: 9_600, amplitude: 0.0001)
        let output = render(input, Settings())
        #expect(zip(output, input).allSatisfy { abs($0 - $1) < 1e-6 })
    }

    @Test func silenceStaysSilent() {
        #expect(render([Float](repeating: 0, count: 4_800), Settings()).allSatisfy { $0 == 0 })
    }

    @Test func oversamplingKeepsTheLevel() {
        let input = sine(frequency: 1_000, frames: 9_600, amplitude: 0.7)
        let reference = rms(render(input, Settings())[4_800...])
        for factor: Int32 in [2, 8, 32] {
            let level = rms(render(input, Settings(oversampling: factor))[4_800...])
            #expect(abs(decibels(level / reference)) < 0.5, "factor \(factor)")
        }
    }

    @Test func mixAndMakeup() {
        let input = noise(frames: 4_800)
        #expect(render(input, Settings(mix: 0)) == input)
        let unity = render(input, Settings())
        let louder = render(input, Settings(makeup: 6))
        let gain = Float(pow(10, 6.0 / 20))
        #expect(zip(louder, unity).allSatisfy { abs($0 - gain * $1) <= 1e-5 + 1e-4 * abs($0) })
    }

    @Test(arguments: [Int32(1), 8])
    func chunksOf777MatchOneRender(factor: Int32) {
        let input = noise(frames: 9_600, amplitude: 0.8)
        let settings = Settings(threshold: -12, release: 30, soft: false, makeup: 3, mix: 0.8, oversampling: factor)
        #expect(render(input, settings, chunk: 777) == render(input, settings))
    }

    @Test func rendersAreBitIdentical() {
        let input = noise(frames: 9_600)
        #expect(render(input, Settings(oversampling: 4)) == render(input, Settings(oversampling: 4)))
    }

    @Test(arguments: [Int32(1), 32])
    func extremesAreFinite(factor: Int32) {
        let input = noise(frames: 4_800, amplitude: 1)
        for settings in [
            Settings(threshold: -24, release: 5, soft: false, makeup: 24, mix: 1, floor: -80, oversampling: factor),
            Settings(threshold: 0, release: 1_000, soft: true, makeup: 0, mix: 0, floor: -20, oversampling: factor),
        ] {
            let output = render(input, settings)
            #expect(output.allSatisfy { $0.isFinite })
        }
    }

    @Test(arguments: ["threshold", "release", "knee", "makeup", "mix", "floor"])
    func modulationMovesEveryControl(id: String) {
        // A burst then quiet, so Release and Floor both matter.
        let input = noise(frames: 4_800, amplitude: 0.8) + noise(frames: 4_800, amplitude: 0.002)
        let base = Settings(threshold: -12, release: 100, makeup: 3, mix: 0.7, floor: -50)
        var moved = base
        moved.modulation[id] = [Float](repeating: id == "knee" ? -0.6 : 0.6, count: 9_600)
        let modulated = render(input, moved, chunk: 777)
        #expect(modulated != render(input, base, chunk: 777))
        #expect(modulated == render(input, moved))
    }

    @Test func audioAdaptiveClippingPrintKeepsLengthAndChannels() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.wav")
        let samples = TestAudio.samples(frames: 48_000, channels: 2)
        try TestAudio.write(samples, to: source, sampleRate: 48_000)
        func bake(chunk: Int) async throws -> [[Float]] {
            let output = directory.appendingPathComponent("out-\(chunk)", isDirectory: true)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            var graph = TestProject()
            let audio = graph.add(.audio, asset: sourceAsset)
            let node = graph.add(.adaptiveClipping, NodeCatalog.defaultParameters(for: .adaptiveClipping))
            let print = graph.add(.print, ["bitDepth": .choice("32f")])
            graph.connect(audio, to: node)
            graph.connect(node, to: print)
            let urls = [sourceAsset: source]
            let request = RenderRequest(plan: try compile(graph.project, assetURLs: urls), assetURLs: urls, outputDirectory: output, chunkFrames: chunk)
            return try TestAudio.read(try #require(try await RenderEngine.render(request).outputs[print])).samples
        }
        let rendered = try await bake(chunk: 4_096)
        #expect(rendered.count == 2)
        #expect(rendered.allSatisfy { $0.count == 48_000 && $0.allSatisfy { $0.isFinite } })
        #expect(rendered[0] != samples[0])
        #expect(try await bake(chunk: 777) == rendered)
    }
}
