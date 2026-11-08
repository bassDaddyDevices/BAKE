import BakeDSP
import Foundation
import Testing
@testable import BakeGraph
@testable import BakeRender

struct DualFilterTests {
    struct Settings {
        var cutoff: Float = 1_000
        var q: Float = 0.707
        var bandwidth: Float = 1
        var morph: Float = 0.5
        var lfoRate: Float = 0.5
        var lfoDepth: Float = 0
        var drive: Float = 0
        var mix: Float = 1
        var alpha: bake.dsp.FilterType = .lowpass
        var beta: bake.dsp.FilterType = .highpass
        var shape: bake.dsp.DualFilterLFOShape = .sine
        var inverted = true
        var slope: Int32 = 24
        var seed: UInt64 = 1
        var modulation: [String: [Float]] = [:]
    }

    private func render(_ input: [Float], _ settings: Settings, chunk: Int? = nil) -> [Float] {
        var controls = bake.dsp.DualFilterControls()
        controls.cutoff = signal(settings.cutoff, 20, 20_000, scale: .exponential)
        controls.q = signal(settings.q, 0.1, 20)
        controls.bandwidth = signal(settings.bandwidth, 0, 4)
        controls.morph = signal(settings.morph, 0, 1)
        controls.lfoRate = signal(settings.lfoRate, 0.01, 50, scale: .exponential)
        controls.lfoDepth = signal(settings.lfoDepth, 0, 1)
        controls.drive = signal(settings.drive, 0, 24)
        controls.mix = signal(settings.mix, 0, 1)
        controls.alphaType = settings.alpha
        controls.betaType = settings.beta
        controls.lfoShape = settings.shape
        controls.inverted = settings.inverted
        controls.alphaTypeIndex = signal(0, 0, 3)
        controls.betaTypeIndex = signal(0, 0, 3)
        controls.lfoShapeIndex = signal(0, 0, 4)
        controls.lfoPhaseIndex = signal(0, 0, 1)
        controls.sections = settings.slope / 12
        controls.seed = settings.seed
        controls.sampleRate = 48_000
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
            case "cutoff": attach(&controls.cutoff)
            case "q": attach(&controls.q)
            case "bandwidth": attach(&controls.bandwidth)
            case "morph": attach(&controls.morph)
            case "lfoRate": attach(&controls.lfoRate)
            case "lfoDepth": attach(&controls.lfoDepth)
            case "drive": attach(&controls.drive)
            case "mix": attach(&controls.mix)
            case "alphaType": attach(&controls.alphaTypeIndex)
            case "betaType": attach(&controls.betaTypeIndex)
            case "lfoShape": attach(&controls.lfoShapeIndex)
            case "lfoPhase": attach(&controls.lfoPhaseIndex)
            default: Issue.record("unknown control \(id)")
            }
        }
        var state = bake.dsp.DualFilterState()
        var output = [Float](repeating: 0, count: input.count)
        input.withUnsafeBufferPointer { source in
            output.withUnsafeMutableBufferPointer { destination in
                var start = 0
                while start < input.count {
                    let count = min(chunk ?? input.count, input.count - start)
                    bake.dsp.renderDualFilter(&state, controls, source.baseAddress! + start, destination.baseAddress! + start, start, count)
                    start += count
                }
            }
        }
        return output
    }

    private func level(_ samples: ArraySlice<Float>) -> Float {
        20 * log10(max(sqrt(samples.reduce(0) { $0 + $1 * $1 } / Float(max(samples.count, 1))), 1e-12))
    }

    private func noise(frames: Int, amplitude: Float = 0.5) -> [Float] {
        var seed: UInt32 = 9
        return (0..<frames).map { _ in
            seed = seed &* 1_664_525 &+ 1_013_904_223
            return amplitude * (Float(seed >> 8) / Float(1 << 23) - 1)
        }
    }

    @Test func morphZeroIsAlpha() {
        // Alpha lowpass at 500 Hz (Spread 0), 24 dB/oct.
        let settings = Settings(cutoff: 500, bandwidth: 0, morph: 0)
        let high = sine(frequency: 1_000, frames: 9_600)
        let low = sine(frequency: 100, frames: 9_600)
        #expect(level(render(high, settings)[4_800...]) < level(high[4_800...]) - 20)
        #expect(abs(level(render(low, settings)[4_800...]) - level(low[4_800...])) < 1)
    }

    @Test func morphOneIsBeta() {
        // Beta highpass at 500 Hz.
        let settings = Settings(cutoff: 500, bandwidth: 0, morph: 1)
        let low = sine(frequency: 100, frames: 9_600)
        let high = sine(frequency: 5_000, frames: 9_600)
        #expect(level(render(low, settings)[4_800...]) < level(low[4_800...]) - 20)
        #expect(abs(level(render(high, settings)[4_800...]) - level(high[4_800...])) < 1)
    }

    @Test func spreadSeparatesTheCutoffs() {
        // Spread 2 octaves around 1 kHz: Alpha lowpass at 2 kHz passes 1.2 kHz better than at Spread 0.
        let tone = sine(frequency: 1_500, frames: 9_600)
        let narrow = level(render(tone, Settings(bandwidth: 0, morph: 0))[4_800...])
        let wide = level(render(tone, Settings(bandwidth: 2, morph: 0))[4_800...])
        #expect(wide > narrow + 3)
    }

    @Test func lfoSweepsTheCutoff() {
        let tone = sine(frequency: 1_000, frames: 96_000)
        let output = render(tone, Settings(cutoff: 1_000, bandwidth: 0, morph: 0, lfoRate: 2, lfoDepth: 1))
        let windows = stride(from: 0, to: 96_000 - 4_800, by: 4_800).map { level(output[$0..<($0 + 4_800)]) }
        #expect((windows.max() ?? 0) - (windows.min() ?? 0) > 6)
    }

    @Test func phaseModesDiffer() {
        let input = noise(frames: 9_600)
        let settings = Settings(lfoRate: 3, lfoDepth: 0.8)
        var inPhase = settings
        inPhase.inverted = false
        #expect(render(input, settings) != render(input, inPhase))
    }

    @Test func sampleAndHoldIsSeeded() {
        let input = noise(frames: 48_000)
        var settings = Settings(lfoRate: 10, lfoDepth: 1, shape: .sampleAndHold)
        let first = render(input, settings)
        #expect(first == render(input, settings))
        settings.seed = 2
        #expect(render(input, settings) != first)
    }

    @Test func everySettingMatters() {
        let input = noise(frames: 9_600)
        let base = Settings(lfoRate: 5, lfoDepth: 0.5)
        let reference = render(input, base)
        var slope = base
        slope.slope = 96
        #expect(render(input, slope) != reference)
        for shape in [bake.dsp.DualFilterLFOShape.triangle, .saw, .square, .sampleAndHold] {
            var changed = base
            changed.shape = shape
            #expect(render(input, changed) != reference)
        }
        for type in [bake.dsp.FilterType.highpass, .bandpass, .notch] {
            var changed = base
            changed.alpha = type
            #expect(render(input, changed) != reference)
        }
    }

    @Test func driveSaturates() {
        let input = sine(frequency: 200, frames: 9_600, amplitude: 1)
        let clean = render(input, Settings(cutoff: 20_000, bandwidth: 0, morph: 0))
        let driven = render(input, Settings(cutoff: 20_000, bandwidth: 0, morph: 0, drive: 24))
        #expect((driven.map(abs).max() ?? 0) < (clean.map(abs).max() ?? 0))
    }

    @Test func chunksOf777MatchOneRender() {
        let input = noise(frames: 9_600)
        let settings = Settings(q: 4, bandwidth: 2, morph: 0.3, lfoRate: 7, lfoDepth: 0.7, drive: 6, mix: 0.8, shape: .sampleAndHold, slope: 48)
        #expect(render(input, settings, chunk: 777) == render(input, settings))
    }

    @Test func extremesAreFinite() {
        let input = noise(frames: 4_800, amplitude: 1)
        for settings in [
            Settings(cutoff: 20, q: 20, bandwidth: 4, morph: 1, lfoRate: 50, lfoDepth: 1, drive: 24, slope: 96),
            Settings(cutoff: 20_000, q: 0.1, bandwidth: 0, morph: 0, lfoRate: 0.01, lfoDepth: 0, drive: 0, mix: 0, slope: 12),
        ] {
            let output = render(input, settings)
            #expect(output.allSatisfy { $0.isFinite })
        }
    }

    @Test(arguments: ["cutoff", "q", "bandwidth", "morph", "lfoRate", "lfoDepth", "drive", "mix", "alphaType", "betaType", "lfoShape", "lfoPhase"])
    func modulationMovesEveryControl(id: String) {
        let input = noise(frames: 9_600)
        let base = Settings(q: 2, morph: 0.4, lfoRate: 3, lfoDepth: 0.4, drive: 6, mix: 0.7)
        var moved = base
        moved.modulation[id] = [Float](repeating: 0.6, count: 9_600)
        let modulated = render(input, moved, chunk: 777)
        #expect(modulated != render(input, base, chunk: 777))
        #expect(modulated == render(input, moved))
    }

    @Test func audioDualFilterPrintKeepsLengthAndChannels() async throws {
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
            var values = NodeCatalog.defaultParameters(for: .dualFilter)
            values["lfoDepth"] = .number(0.5)
            let node = graph.add(.dualFilter, values)
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
