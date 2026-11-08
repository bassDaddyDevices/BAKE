import BakeDSP
import Foundation
import Testing
@testable import BakeGraph
@testable import BakeRender

struct GranularCloudTests {
    struct Settings {
        var size: Float = 80
        var density: Float = 25
        var spray: Float = 100
        var pitchSpread: Float = 0
        var mix: Float = 1
        var pitch: Float = 0
        var reverse: Float = 0
        var stereoSpread: Float = 0.5
        var seed: UInt64 = 1
        var modulation: [String: [Float]] = [:]
    }

    /// Renders every output channel in `chunk`-frame calls (a mono input feeds every channel).
    private func render(_ input: [Float], channels: Int = 1, _ settings: Settings, chunk: Int? = nil) -> [[Float]] {
        var controls = bake.dsp.GranularCloudControls()
        controls.size = signal(settings.size, 5, 500)
        controls.density = signal(settings.density, 1, 200, scale: .exponential)
        controls.spray = signal(settings.spray, 0, 2_000)
        controls.pitchSpread = signal(settings.pitchSpread, 0, 24)
        controls.mix = signal(settings.mix, 0, 1)
        controls.pitch = signal(settings.pitch, -24, 24)
        controls.reverse = signal(settings.reverse, 0, 1)
        controls.stereoSpread = signal(settings.stereoSpread, 0, 1)
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
            case "size": attach(&controls.size)
            case "density": attach(&controls.density)
            case "spray": attach(&controls.spray)
            case "pitchSpread": attach(&controls.pitchSpread)
            case "mix": attach(&controls.mix)
            case "pitch": attach(&controls.pitch)
            case "reverse": attach(&controls.reverse)
            case "stereoSpread": attach(&controls.stereoSpread)
            default: Issue.record("unknown control \(id)")
            }
        }
        return (0..<channels).map { channel in
            var output = [Float](repeating: 0, count: input.count)
            input.withUnsafeBufferPointer { source in
                output.withUnsafeMutableBufferPointer { destination in
                    var start = 0
                    while start < input.count {
                        let count = min(chunk ?? input.count, input.count - start)
                        bake.dsp.renderGranularCloud(
                            controls, source.baseAddress!, input.count, channel, channels,
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

    private func noise(frames: Int, amplitude: Float = 0.5) -> [Float] {
        var seed: UInt32 = 19
        return (0..<frames).map { _ in
            seed = seed &* 1_664_525 &+ 1_013_904_223
            return amplitude * (Float(seed >> 8) / Float(1 << 23) - 1)
        }
    }

    @Test func grainsKeepTheSourcePitch() {
        let input = sine(frequency: 440, frames: 48_000)
        let output = render(input, Settings(size: 40, density: 50, spray: 0))[0][4_800..<43_200]
        let peak = power(of: output, at: 440)
        #expect(peak > 20 * power(of: output, at: 300))
        #expect(peak > 20 * power(of: output, at: 600))
    }

    @Test func pitchShiftsEveryGrain() {
        let input = sine(frequency: 440, frames: 48_000)
        let output = render(input, Settings(size: 40, density: 50, spray: 0, pitch: 12))[0][4_800..<43_200]
        #expect(power(of: output, at: 880) > 20 * power(of: output, at: 440))
    }

    @Test func reverseMirrorsEachGrain() {
        // Density 200 plays every slot; 5 ms grains are exactly one slot long, so grains never overlap.
        // A reversed grain reads the same samples backwards: reverse(j) == forward(size − j).
        let input = noise(frames: 9_600)
        let settings = Settings(size: 5, density: 200, spray: 0)
        var reversed = settings
        reversed.reverse = 1
        let forward = render(input, settings)[0]
        let backward = render(input, reversed)[0]
        let size = 240
        for grain in 4..<30 {
            let start = grain * 240
            for j in 1..<size {
                #expect(abs(backward[start + j] - forward[start + size - j]) < 1e-5)
            }
        }
    }

    @Test func seedsAreDeterministicAndDistinct() {
        let input = noise(frames: 24_000)
        var settings = Settings(spray: 200, pitchSpread: 5, reverse: 0.3)
        let first = render(input, settings)
        #expect(first == render(input, settings))
        settings.seed = 2
        #expect(render(input, settings) != first)
    }

    @Test func stereoSpreadPans() {
        let input = noise(frames: 24_000)
        let output = render(input, channels: 2, Settings(stereoSpread: 1))
        #expect(output[0] != output[1])
        let centred = render(input, channels: 2, Settings(stereoSpread: 0))
        #expect(zip(centred[0], centred[1]).allSatisfy { abs($0 - $1) < 1e-6 })
    }

    @Test func chunksOf777MatchOneRender() {
        let input = noise(frames: 24_000)
        let settings = Settings(size: 120, density: 60, spray: 300, pitchSpread: 7, mix: 0.8, pitch: -5, reverse: 0.4)
        #expect(render(input, channels: 2, settings, chunk: 777) == render(input, channels: 2, settings))
    }

    @Test func extremesAreFinite() {
        let input = noise(frames: 9_600, amplitude: 1)
        for settings in [
            Settings(size: 500, density: 200, spray: 2_000, pitchSpread: 24, mix: 1, pitch: 24, reverse: 1, stereoSpread: 1),
            Settings(size: 5, density: 1, spray: 0, pitchSpread: 0, mix: 0, pitch: -24, reverse: 0, stereoSpread: 0),
        ] {
            let output = render(input, channels: 2, settings)
            #expect(output.allSatisfy { $0.allSatisfy { $0.isFinite } })
        }
    }

    @Test(arguments: ["size", "density", "spray", "pitchSpread", "mix", "pitch", "reverse", "stereoSpread"])
    func modulationMovesEveryControl(id: String) {
        let input = noise(frames: 24_000)
        let base = Settings(size: 60, density: 40, spray: 100, pitchSpread: 3, mix: 0.7, pitch: 2, reverse: 0.2, stereoSpread: 0.5)
        var moved = base
        moved.modulation[id] = [Float](repeating: 0.3, count: 24_000)
        let modulated = render(input, channels: 2, moved, chunk: 777)
        #expect(modulated != render(input, channels: 2, base, chunk: 777))
        #expect(modulated == render(input, channels: 2, moved))
    }

    @Test func audioGranularCloudPrintKeepsLengthAndChannels() async throws {
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
            let node = graph.add(.granularCloud, NodeCatalog.defaultParameters(for: .granularCloud))
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
