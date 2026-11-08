import BakeDSP
import Foundation
import Testing
@testable import BakeGraph
@testable import BakeRender

struct SubHarmonicTests {
    struct Settings {
        var sub1: Float = 0.5
        var sub2: Float = 0
        var tone: Float = 200
        var dry: Float = 1
        var track: Float = 150
        var release: Float = 60
        var modulation: [String: [Float]] = [:]
    }

    /// Renders every channel in `chunk`-frame calls: the kernel's mono sub, then dry + sub per channel.
    private func render(_ channels: [[Float]], _ settings: Settings, chunk: Int? = nil) -> [[Float]] {
        let frames = channels[0].count
        var controls = bake.dsp.SubHarmonicControls()
        controls.sub1 = signal(settings.sub1, 0, 1)
        controls.sub2 = signal(settings.sub2, 0, 1)
        controls.tone = signal(settings.tone, 40, 2_000, scale: .exponential)
        controls.dry = signal(settings.dry, 0, 1)
        controls.track = signal(settings.track, 40, 400, scale: .exponential)
        controls.release = signal(settings.release, 10, 500)
        controls.sampleRate = 48_000
        var buffers: [UnsafeMutableBufferPointer<Float>] = []
        defer { buffers.forEach { $0.deallocate() } }
        for (id, values) in settings.modulation {
            let buffer = UnsafeMutableBufferPointer<Float>.allocate(capacity: values.count)
            _ = buffer.initialize(from: values)
            buffers.append(buffer)
            let pointer = UnsafePointer(buffer.baseAddress)
            switch id {
            case "sub1": controls.sub1.modulation = pointer; controls.sub1.modulationFrames = values.count
            case "sub2": controls.sub2.modulation = pointer; controls.sub2.modulationFrames = values.count
            case "tone": controls.tone.modulation = pointer; controls.tone.modulationFrames = values.count
            case "dry": controls.dry.modulation = pointer; controls.dry.modulationFrames = values.count
            case "track": controls.track.modulation = pointer; controls.track.modulationFrames = values.count
            case "release": controls.release.modulation = pointer; controls.release.modulationFrames = values.count
            default: Issue.record("unknown control \(id)")
            }
        }
        var state = bake.dsp.SubHarmonicState()
        var outputs = channels.map { [Float](repeating: 0, count: $0.count) }
        var sub = [Float](repeating: 0, count: chunk ?? frames)
        let left = channels[0]
        let right = channels.count > 1 ? channels[1] : []
        left.withUnsafeBufferPointer { leftPointer in
            right.withUnsafeBufferPointer { rightPointer in
                var input = bake.dsp.AudioInput()
                input.channels.0 = leftPointer.baseAddress
                input.channelCount = 1
                input.frames = frames
                if channels.count > 1 {
                    input.channels.1 = rightPointer.baseAddress
                    input.channelCount = 2
                }
                var start = 0
                while start < frames {
                    let count = min(chunk ?? frames, frames - start)
                    bake.dsp.renderSubHarmonic(&state, controls, input, &sub, start, count)
                    for channel in channels.indices {
                        channels[channel].withUnsafeBufferPointer { dry in
                            outputs[channel].withUnsafeMutableBufferPointer { out in
                                bake.dsp.addSubHarmonic(controls, dry.baseAddress!, frames, sub, out.baseAddress! + start, start, count)
                            }
                        }
                    }
                    start += count
                }
            }
        }
        return outputs
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
        var seed: UInt32 = 11
        return (0..<frames).map { _ in
            seed = seed &* 1_664_525 &+ 1_013_904_223
            return amplitude * (Float(seed >> 8) / Float(1 << 23) - 1)
        }
    }

    @Test func aSineGetsAnOctaveBelow() {
        let input = sine(frequency: 110, frames: 96_000)
        let output = render([input], Settings(sub1: 1, dry: 0))[0][24_000...]
        // 55 Hz dominates; an unrelated frequency in between stays far below.
        #expect(power(of: output, at: 55) > 100 * power(of: output, at: 82.5))
        #expect(power(of: output, at: 55) > power(of: output, at: 110))
        let rms = sqrt(output.reduce(0) { $0 + $1 * $1 } / Float(output.count))
        #expect(rms > 0.05)
    }

    @Test func twoOctavesBelow() {
        let input = sine(frequency: 110, frames: 96_000)
        let output = render([input], Settings(sub1: 0, sub2: 1, dry: 0))[0][24_000...]
        #expect(power(of: output, at: 27.5) > 100 * power(of: output, at: 41.25))
        #expect(power(of: output, at: 27.5) > power(of: output, at: 55))
    }

    @Test func silenceStaysSilent() {
        let output = render([[Float](repeating: 0, count: 9_600)], Settings(sub1: 1, sub2: 1))
        #expect(output[0].allSatisfy { $0 == 0 })
    }

    @Test func dryAndLevelsAtZeroAreSilent() {
        let output = render([sine(frequency: 110, frames: 9_600)], Settings(sub1: 0, sub2: 0, dry: 0))
        #expect(output[0].allSatisfy { $0 == 0 })
    }

    @Test func dryOnlyPassesTheInput() {
        let input = noise(frames: 9_600)
        #expect(render([input], Settings(sub1: 0, sub2: 0, dry: 1))[0] == input)
    }

    @Test func stereoGetsTheSameSub() {
        let left = sine(frequency: 110, frames: 9_600)
        let right = sine(frequency: 220, frames: 9_600, amplitude: 0.3)
        let output = render([left, right], Settings(sub1: 1, dry: 1))
        let subLeft = zip(output[0], left).map { $0 - $1 }
        let subRight = zip(output[1], right).map { $0 - $1 }
        #expect(zip(subLeft, subRight).allSatisfy { abs($0 - $1) < 1e-6 })
        #expect(subLeft.contains { abs($0) > 0.01 })
    }

    @Test func chunksOf777MatchOneRender() {
        let input = [noise(frames: 9_600), noise(frames: 9_600, amplitude: 0.3)]
        let settings = Settings(sub1: 0.8, sub2: 0.6, tone: 300, dry: 0.7, track: 200, release: 120)
        #expect(render(input, settings, chunk: 777) == render(input, settings))
    }

    @Test func rendersAreBitIdentical() {
        let input = [noise(frames: 9_600)]
        #expect(render(input, Settings(sub2: 0.5)) == render(input, Settings(sub2: 0.5)))
    }

    @Test func extremesAreFinite() {
        let input = [noise(frames: 4_800, amplitude: 1)]
        for settings in [
            Settings(sub1: 1, sub2: 1, tone: 40, dry: 1, track: 40, release: 10),
            Settings(sub1: 1, sub2: 1, tone: 2_000, dry: 1, track: 400, release: 500),
            Settings(sub1: 0, sub2: 0, tone: 40, dry: 0, track: 400, release: 10),
        ] {
            let output = render(input, settings)
            #expect(output[0].allSatisfy { $0.isFinite })
        }
    }

    @Test(arguments: ["sub1", "sub2", "tone", "dry", "track", "release"])
    func modulationMovesEveryControl(id: String) {
        let input = [sine(frequency: 110, frames: 9_600)]
        let base = Settings(sub1: 0.5, sub2: 0.5, dry: 0.5)
        var moved = base
        moved.modulation[id] = [Float](repeating: 0.3, count: 9_600)
        let modulated = render(input, moved, chunk: 777)
        #expect(modulated != render(input, base, chunk: 777))
        #expect(modulated == render(input, moved))
    }

    @Test func audioSubHarmonicPrintKeepsLengthAndChannels() async throws {
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
            let node = graph.add(.subHarmonic, NodeCatalog.defaultParameters(for: .subHarmonic))
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
