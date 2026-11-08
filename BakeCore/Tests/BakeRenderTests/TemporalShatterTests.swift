import BakeDSP
import Foundation
import Testing
@testable import BakeGraph
@testable import BakeRender

struct TemporalShatterTests {
    struct Settings {
        var stretch: Double = 4
        var attack: Float = 5
        var sensitivity: Float = 0.5
        var tape = false
        var grain: Float = 80
        var modulation: [String: [Float]] = [:]
    }

    struct Result {
        var output: [Float]
        var segments: [bake.dsp.TemporalShatterSegment]
    }

    private func controls(_ settings: Settings) -> bake.dsp.TemporalShatterControls {
        var controls = bake.dsp.TemporalShatterControls()
        controls.attack = signal(settings.attack, 0.5, 50)
        controls.sensitivity = signal(settings.sensitivity, 0, 1)
        controls.grain = signal(settings.grain, 20, 200)
        controls.mode = settings.tape ? .tape : .grains
        controls.sampleRate = 48_000
        return controls
    }

    /// Analyses and renders one channel, in `chunk`-frame calls.
    private func shatter(_ input: [Float], _ settings: Settings, chunk: Int? = nil) -> Result {
        var controls = controls(settings)
        var buffers: [UnsafeMutableBufferPointer<Float>] = []
        defer { buffers.forEach { $0.deallocate() } }
        for (id, values) in settings.modulation {
            let buffer = UnsafeMutableBufferPointer<Float>.allocate(capacity: values.count)
            _ = buffer.initialize(from: values)
            buffers.append(buffer)
            let pointer = UnsafePointer(buffer.baseAddress)
            switch id {
            case "attack": controls.attack.modulation = pointer; controls.attack.modulationFrames = values.count
            case "sensitivity": controls.sensitivity.modulation = pointer; controls.sensitivity.modulationFrames = values.count
            case "grain": controls.grain.modulation = pointer; controls.grain.modulationFrames = values.count
            default: Issue.record("unknown control \(id)")
            }
        }
        let outputFrames = Int((Double(input.count) * settings.stretch).rounded())
        var onsets = [Int](repeating: 0, count: bake.dsp.temporalShatterMaxOnsets(input.count, 48_000))
        var segments = Array(repeating: bake.dsp.TemporalShatterSegment(), count: bake.dsp.temporalShatterMaxSegments(input.count, 48_000))
        var output = [Float](repeating: 0, count: outputFrames)
        var segmentCount = 0
        input.withUnsafeBufferPointer { source in
            var audio = bake.dsp.AudioInput()
            audio.channels.0 = source.baseAddress
            audio.channelCount = 1
            audio.frames = input.count
            segmentCount = bake.dsp.analyzeTemporalShatter(controls, audio, outputFrames, &onsets, &segments)
            var state = bake.dsp.TemporalShatterState()
            output.withUnsafeMutableBufferPointer { destination in
                var start = 0
                while start < outputFrames {
                    let count = min(chunk ?? outputFrames, outputFrames - start)
                    bake.dsp.renderTemporalShatter(&state, controls, segments, segmentCount, source.baseAddress!, input.count,
                                                   destination.baseAddress! + start, start, count)
                    start += count
                }
            }
        }
        return Result(output: output, segments: Array(segments.prefix(segmentCount)))
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

    /// Short noise bursts (a 10 ms decay) every half second, starting at 0.25 s, on silence.
    private func bursts(frames: Int = 96_000) -> [Float] {
        var seed: UInt32 = 23
        var samples = [Float](repeating: 0, count: frames)
        for onset in stride(from: 12_000, to: frames, by: 24_000) {
            for n in 0..<2_400 where onset + n < frames {
                seed = seed &* 1_664_525 &+ 1_013_904_223
                samples[onset + n] = (Float(seed >> 8) / Float(1 << 23) - 1) * 0.8 * exp(-Float(n) / 480)
            }
        }
        return samples
    }

    @Test func attacksAreAnchoredAndBitFaithful() {
        let input = bursts()
        let result = shatter(input, Settings(tape: true))
        let anchors = result.segments.filter(\.anchor)
        #expect(anchors.count == 4)
        for anchor in anchors {
            // Each burst starts on a 5 ms hop boundary, so its onset is exactly the burst's first frame.
            #expect(Int(anchor.sourceStart) % 24_000 == 12_000)
            #expect(anchor.outputStart == anchor.outputStart.rounded())
            let out = Int(anchor.outputStart)
            let source = Int(anchor.sourceStart)
            for j in 0..<240 {
                #expect(result.output[out + j] == input[source + j])
            }
        }
    }

    @Test func theMapFillsTheOutputExactly() {
        let input = bursts()
        let result = shatter(input, Settings(tape: true))
        let total = Double(input.count) * 4
        // Pieces are contiguous and end exactly at the input's end, at the output's end.
        for (piece, next) in zip(result.segments, result.segments.dropFirst()) {
            let length = next.outputStart - piece.outputStart
            #expect(abs(piece.sourceStart + length * piece.speed - next.sourceStart) < 1e-6)
        }
        let last = result.segments[result.segments.count - 1]
        #expect(abs(last.sourceStart + (total - last.outputStart) * last.speed - Double(input.count)) < 1e-6)
        // Tails are stretched by about (T − A) / (N − A).
        let factor = (total - 960) / Double(input.count - 960)
        for tail in result.segments where !tail.anchor && tail.outputStart > 0 {
            #expect(abs(1 / tail.speed - factor) < 0.01)
        }
    }

    @Test func silenceIsAUniformStretch() {
        let result = shatter([Float](repeating: 0, count: 9_600), Settings())
        #expect(result.segments.count == 1)
        #expect(abs(result.segments[0].speed - 0.25) < 1e-12)
        #expect(result.output.allSatisfy { $0 == 0 })
    }

    @Test func grainsKeepThePitchAndTapeDropsIt() {
        // A 440 Hz tone (one onset at its start), stretched 4×.
        let input = sine(frequency: 440, frames: 48_000)
        let grains = shatter(input, Settings())
        let tape = shatter(input, Settings(tape: true))
        let middle = 48_000..<144_000
        #expect(power(of: grains.output[middle], at: 440) > 20 * power(of: grains.output[middle], at: 110))
        #expect(power(of: tape.output[middle], at: 110) > 20 * power(of: tape.output[middle], at: 440))
    }

    @Test func sensitivityFindsMoreOnsets() {
        // Bursts of decreasing size: the quieter ones only count when Sensitivity is high.
        var input = bursts()
        for n in 36_000..<96_000 { input[n] *= 0.05 }
        for n in 0..<96_000 where input[n] == 0 { input[n] = 0.003 * Float(sin(Double(n) * 0.37)) }
        let low = shatter(input, Settings(sensitivity: 0, tape: true)).segments.filter(\.anchor).count
        let high = shatter(input, Settings(sensitivity: 1, tape: true)).segments.filter(\.anchor).count
        #expect(high >= low)
        #expect(high >= 1)
    }

    @Test(arguments: [false, true])
    func chunksOf777MatchOneRender(tape: Bool) {
        let input = bursts(frames: 48_000)
        let settings = Settings(stretch: 3, attack: 12, tape: tape, grain: 60)
        #expect(shatter(input, settings, chunk: 777).output == shatter(input, settings).output)
    }

    @Test func extremesAreFinite() {
        let input = bursts(frames: 24_000)
        for settings in [
            Settings(stretch: 1, attack: 0.5, sensitivity: 0, tape: false, grain: 20),
            Settings(stretch: 20, attack: 50, sensitivity: 1, tape: false, grain: 200),
            Settings(stretch: 20, attack: 50, sensitivity: 1, tape: true),
        ] {
            #expect(shatter(input, settings).output.allSatisfy { $0.isFinite })
        }
    }

    @Test(arguments: ["attack", "sensitivity", "grain"])
    func modulationMovesEveryControl(id: String) {
        // A sine stepping from 0.1 to 0.22 on a hop boundary rises 6.8 dB: an onset at Sensitivity 0.8
        // (4.8 dB threshold) but not at 0.3 (9.3 dB). Bursts on silence would trigger at any setting.
        var input = sine(frequency: 220, frames: 48_000, amplitude: 0.1)
        for n in 24_000..<48_000 { input[n] *= 2.2 }
        let base = Settings(stretch: 2, attack: 5, sensitivity: 0.3)
        var moved = base
        moved.modulation[id] = [Float](repeating: 0.5, count: 96_000)
        let modulated = shatter(input, moved, chunk: 777).output
        #expect(modulated != shatter(input, base, chunk: 777).output)
        #expect(modulated == shatter(input, moved).output)
    }

    @Test func audioTemporalShatterPrintIsInputTimesStretch() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.wav")
        let samples = TestAudio.samples(frames: 24_000, channels: 2)
        try TestAudio.write(samples, to: source, sampleRate: 48_000)
        func bake(chunk: Int) async throws -> [[Float]] {
            let output = directory.appendingPathComponent("out-\(chunk)", isDirectory: true)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            var graph = TestProject()
            let audio = graph.add(.audio, asset: sourceAsset)
            var values = NodeCatalog.defaultParameters(for: .temporalShatter)
            values["stretch"] = .number(3)
            let node = graph.add(.temporalShatter, values)
            let print = graph.add(.print, ["bitDepth": .choice("32f")])
            graph.connect(audio, to: node)
            graph.connect(node, to: print)
            let urls = [sourceAsset: source]
            let request = RenderRequest(plan: try compile(graph.project, assetURLs: urls), assetURLs: urls, outputDirectory: output, chunkFrames: chunk)
            return try TestAudio.read(try #require(try await RenderEngine.render(request).outputs[print])).samples
        }
        let rendered = try await bake(chunk: 4_096)
        #expect(rendered.count == 2)
        #expect(rendered.allSatisfy { $0.count == 72_000 && $0.allSatisfy { $0.isFinite } })
        #expect(try await bake(chunk: 777) == rendered)
    }
}
