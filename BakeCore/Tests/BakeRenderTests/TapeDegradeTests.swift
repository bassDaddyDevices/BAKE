import BakeDSP
import Foundation
import Testing
@testable import BakeGraph
@testable import BakeRender

struct TapeDegradeTests {
    struct Settings {
        var wow: Float = 1
        var flutter: Float = 0.08
        var saturation: Float = 6
        var tone: Float = 9_000
        var mix: Float = 1
        var wowRate: Float = 0.5
        var flutterRate: Float = 9
        var hiss: Float = -90
        var dropouts: Float = 0
        var seed: Double = 1
        var modulation: [String: [Float]] = [:]
    }

    /// Everything off: only the tone lowpass at 20 kHz remains.
    static let neutral = Settings(wow: 0, flutter: 0, saturation: 0, tone: 20_000, hiss: -120, dropouts: 0)

    private func render(_ channels: [[Float]], _ settings: Settings, chunk: Int? = nil) -> [[Float]] {
        let frames = channels[0].count
        var controls = bake.dsp.TapeDegradeControls()
        controls.wow = signal(settings.wow, 0, 5)
        controls.flutter = signal(settings.flutter, 0, 0.5)
        controls.saturation = signal(settings.saturation, 0, 24)
        controls.tone = signal(settings.tone, 1_000, 20_000, scale: .exponential)
        controls.mix = signal(settings.mix, 0, 1)
        controls.wowRate = signal(settings.wowRate, 0.1, 4, scale: .exponential)
        controls.flutterRate = signal(settings.flutterRate, 4, 20, scale: .exponential)
        controls.hiss = signal(settings.hiss, -120, -30)
        controls.dropouts = signal(settings.dropouts, 0, 1)
        controls.seed = UInt64(settings.seed)
        controls.sampleRate = 48_000
        controls.channelCount = channels.count
        var buffers: [UnsafeMutableBufferPointer<Float>] = []
        defer { buffers.forEach { $0.deallocate() } }
        for (id, values) in settings.modulation {
            let buffer = UnsafeMutableBufferPointer<Float>.allocate(capacity: values.count)
            _ = buffer.initialize(from: values)
            buffers.append(buffer)
            let pointer = UnsafePointer(buffer.baseAddress)
            switch id {
            case "wow": controls.wow.modulation = pointer; controls.wow.modulationFrames = values.count
            case "flutter": controls.flutter.modulation = pointer; controls.flutter.modulationFrames = values.count
            case "saturation": controls.saturation.modulation = pointer; controls.saturation.modulationFrames = values.count
            case "tone": controls.tone.modulation = pointer; controls.tone.modulationFrames = values.count
            case "mix": controls.mix.modulation = pointer; controls.mix.modulationFrames = values.count
            case "wowRate": controls.wowRate.modulation = pointer; controls.wowRate.modulationFrames = values.count
            case "flutterRate": controls.flutterRate.modulation = pointer; controls.flutterRate.modulationFrames = values.count
            case "hiss": controls.hiss.modulation = pointer; controls.hiss.modulationFrames = values.count
            case "dropouts": controls.dropouts.modulation = pointer; controls.dropouts.modulationFrames = values.count
            default: Issue.record("unknown control \(id)")
            }
        }
        return channels.enumerated().map { channel, samples in
            var state = bake.dsp.TapeDegradeState()
            var output = [Float](repeating: 0, count: frames)
            samples.withUnsafeBufferPointer { source in
                output.withUnsafeMutableBufferPointer { destination in
                    var start = 0
                    while start < frames {
                        let count = min(chunk ?? frames, frames - start)
                        bake.dsp.renderTapeDegrade(
                            &state, controls, source.baseAddress!, frames, channel,
                            destination.baseAddress! + start, start, count
                        )
                        start += count
                    }
                }
            }
            return output
        }
    }

    private func power(of signal: ArraySlice<Float>, at frequency: Double) -> Double {
        let w = 2 * Double.pi * frequency / 48_000
        var s1 = 0.0, s2 = 0.0
        for (index, sample) in signal.enumerated() {
            let hann = 0.5 - 0.5 * cos(2 * Double.pi * Double(index) / Double(signal.count - 1))
            let s = Double(sample) * hann + 2 * cos(w) * s1 - s2
            s2 = s1
            s1 = s
        }
        return s1 * s1 + s2 * s2 - 2 * cos(w) * s1 * s2
    }

    private func rms(_ samples: ArraySlice<Float>) -> Float {
        sqrt(samples.reduce(0) { $0 + $1 * $1 } / Float(max(samples.count, 1)))
    }

    private func noise(frames: Int, amplitude: Float = 0.5) -> [Float] {
        var seed: UInt32 = 5
        return (0..<frames).map { _ in
            seed = seed &* 1_664_525 &+ 1_013_904_223
            return amplitude * (Float(seed >> 8) / Float(1 << 23) - 1)
        }
    }

    @Test func neutralSettingsPassTheInput() {
        // A one-pole at 20 kHz is nearly flat at 200 Hz: a few thousandths of phase lag at most.
        let input = sine(frequency: 200, frames: 9_600)
        let output = render([input], Self.neutral)[0]
        #expect((480..<9_600).allSatisfy { abs(output[$0] - input[$0]) < 2e-3 })
    }

    @Test func wowSmearsATone() {
        let input = sine(frequency: 1_000, frames: 96_000)
        let clean = power(of: render([input], Self.neutral)[0][...], at: 1_000)
        var wobbly = Self.neutral
        wobbly.wow = 2
        let smeared = power(of: render([input], wobbly)[0][...], at: 1_000)
        #expect(smeared < 0.5 * clean)
    }

    @Test func wowHasNoLatency() {
        // The mean delay is zero: averaged over a whole wow cycle, the output lines up with the input.
        let input = sine(frequency: 50, frames: 96_000)
        var settings = Self.neutral
        settings.wow = 1
        settings.wowRate = 1
        let output = render([input], settings)[0]
        let correlation = zip(output[0..<96_000], input[0..<96_000]).reduce(0) { $0 + $1.0 * $1.1 }
        let energy = input.reduce(0) { $0 + $1 * $1 }
        #expect(correlation / energy > 0.95)
    }

    @Test func dropoutsDuck() {
        let input = sine(frequency: 440, frames: 48_000)
        var settings = Self.neutral
        settings.dropouts = 1
        #expect(rms(render([input], settings)[0][...]) < 0.2 * rms(input[...]))
    }

    @Test func saturationIsBoundedAndNormalised() {
        // tanh(g·x) / tanh(g): a full-scale input still peaks at full scale.
        let input = sine(frequency: 200, frames: 9_600, amplitude: 1)
        var settings = Self.neutral
        settings.saturation = 24
        let output = render([input], settings)[0]
        let peak = output.map(abs).max() ?? 0
        #expect(peak <= 1.01)
        #expect(peak > 0.95)
    }

    @Test func seedsAreDeterministicAndDistinct() {
        let input = [noise(frames: 9_600)]
        var settings = Settings(hiss: -40, dropouts: 0.5)
        let first = render(input, settings)
        #expect(first == render(input, settings))
        settings.seed = 2
        #expect(render(input, settings) != first)
    }

    @Test func stereoChannelsDiffer() {
        let input = sine(frequency: 1_000, frames: 9_600)
        let output = render([input, input], Settings(wow: 3))
        #expect(output[0] != output[1])
    }

    @Test func chunksOf777MatchOneRender() {
        let input = [noise(frames: 9_600), noise(frames: 9_600, amplitude: 0.3)]
        let settings = Settings(wow: 3, flutter: 0.3, saturation: 12, tone: 4_000, mix: 0.8, hiss: -50, dropouts: 0.4)
        #expect(render(input, settings, chunk: 777) == render(input, settings))
    }

    @Test func extremesAreFinite() {
        let input = [noise(frames: 9_600, amplitude: 1)]
        for settings in [
            Settings(wow: 5, flutter: 0.5, saturation: 24, tone: 1_000, mix: 1, wowRate: 4, flutterRate: 20, hiss: -30, dropouts: 1),
            Settings(wow: 0, flutter: 0, saturation: 0, tone: 20_000, mix: 0, wowRate: 0.1, flutterRate: 4, hiss: -120, dropouts: 0),
        ] {
            let output = render(input, settings)
            #expect(output[0].allSatisfy { $0.isFinite })
        }
    }

    @Test(arguments: ["wow", "flutter", "saturation", "tone", "mix", "wowRate", "flutterRate", "hiss", "dropouts"])
    func modulationMovesEveryControl(id: String) {
        let input = [sine(frequency: 1_000, frames: 9_600)]
        let base = Settings(wow: 2, flutter: 0.2, saturation: 6, tone: 5_000, mix: 0.5, hiss: -60, dropouts: 0.3)
        var moved = base
        moved.modulation[id] = [Float](repeating: 0.3, count: 9_600)
        let modulated = render(input, moved, chunk: 777)
        #expect(modulated != render(input, base, chunk: 777))
        #expect(modulated == render(input, moved))
    }

    @Test func audioTapeDegradePrintKeepsLengthAndChannels() async throws {
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
            let node = graph.add(.tapeDegrade, NodeCatalog.defaultParameters(for: .tapeDegrade))
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
