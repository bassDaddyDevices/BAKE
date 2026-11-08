import BakeDSP
import Foundation
import Testing
@testable import BakeGraph
@testable import BakeRender

/// At 48 kHz the defaults below start a burst every second (48000 frames) of 3 repeats of 100 ms
/// (4800 frames): the live first repeat, then two of it again.
struct StutterTests {
    private struct Settings {
        var every = 1_000.0, chance = 1.0, size = 100.0, repeats = 3.0, capture = 0.0, shrink = 1.0, gate = 1.0
        var decay = 0.0, pitch = 0.0, pitchDrift = 0.0, pan = 0.0, panDrift = 0.0, reverse = 0.0, jitter = 0.0
        var smooth = 0.0, mix = 1.0
        var seed: UInt32 = 0
        var modulation: [String: [Float]] = [:]
    }

    private func settings(_ change: (inout Settings) -> Void = { _ in }) -> Settings {
        var settings = Settings()
        change(&settings)
        return settings
    }

    /// Renders each channel of `channels` (all the same length).
    private func render(
        _ channels: [[Float]], settings: Settings? = nil, trigger: [Float]? = nil, chunk: Int? = nil
    ) -> [[Float]] {
        let settings = settings ?? Settings()
        var buffers: [UnsafeMutableBufferPointer<Float>] = []
        defer { buffers.forEach { $0.deallocate() } }
        func control(_ id: String, _ base: Double, _ minimum: Double, _ maximum: Double) -> bake.dsp.ParameterSignal {
            var control = signal(Float(base), Float(minimum), Float(maximum))
            if let values = settings.modulation[id] {
                let buffer = UnsafeMutableBufferPointer<Float>.allocate(capacity: values.count)
                _ = buffer.initialize(from: values)
                buffers.append(buffer)
                control.modulation = UnsafePointer(buffer.baseAddress)
                control.modulationFrames = buffer.count
            }
            return control
        }
        var controls = bake.dsp.StutterControls()
        controls.every = control("every", settings.every, 10, 10_000)
        controls.chance = control("chance", settings.chance, 0, 1)
        controls.size = control("size", settings.size, 1, 1_000)
        controls.repeats = control("repeats", settings.repeats, 1, 64)
        controls.capture = control("capture", settings.capture, -1_000, 1_000)
        controls.shrink = control("shrink", settings.shrink, 0.5, 2)
        controls.gate = control("gate", settings.gate, 0.05, 1)
        controls.decay = control("decay", settings.decay, 0, 1)
        controls.pitch = control("pitch", settings.pitch, -24, 24)
        controls.pitchDrift = control("pitchDrift", settings.pitchDrift, -12, 12)
        controls.pan = control("pan", settings.pan, -1, 1)
        controls.panDrift = control("panDrift", settings.panDrift, -1, 1)
        controls.reverse = control("reverse", settings.reverse, 0, 2)
        controls.jitter = control("jitter", settings.jitter, 0, 100)
        controls.smooth = control("smooth", settings.smooth, 0, 20)
        controls.mix = control("mix", settings.mix, 0, 1)
        controls.sampleRate = 48_000
        controls.seed = settings.seed

        let triggerValues = trigger ?? []
        return channels.enumerated().map { channel, source in
            var state = bake.dsp.StutterState()
            var output = [Float](repeating: 0, count: source.count)
            triggerValues.withUnsafeBufferPointer { triggerPointer in
                source.withUnsafeBufferPointer { sourcePointer in
                    output.withUnsafeMutableBufferPointer { destination in
                        var triggerInput = bake.dsp.ControlInput()
                        if trigger != nil { triggerInput.samples = triggerPointer.baseAddress; triggerInput.frames = triggerPointer.count }
                        var start = 0
                        while start < source.count {
                            let count = min(chunk ?? source.count, source.count - start)
                            bake.dsp.renderStutter(
                                &state, controls, triggerInput, Int32(channel), Int32(channels.count),
                                sourcePointer.baseAddress, sourcePointer.count, destination.baseAddress! + start, start, count
                            )
                            start += count
                        }
                    }
                }
            }
            return output
        }
    }

    private func render(_ source: [Float], settings: Settings? = nil, trigger: [Float]? = nil, chunk: Int? = nil) -> [Float] {
        render([source], settings: settings, trigger: trigger, chunk: chunk)[0]
    }

    private func ramp(_ frames: Int) -> [Float] { (0..<frames).map { Float($0) / Float(frames) } }

    @Test func burstsRepeatTheFirstSliceEverySecond() {
        let source = ramp(96_000)
        let output = render(source)
        #expect(Array(output[0..<4_800]) == Array(source[0..<4_800]))           // repeat 0 is live
        for k in [0, 2_000, 4_799] {
            #expect(output[4_800 + k] == source[k], "repeat 1, \(k)")
            #expect(output[9_600 + k] == source[k], "repeat 2, \(k)")
        }
        #expect(Array(output[14_400..<48_000]) == Array(source[14_400..<48_000]))
        #expect(output[52_800 + 10] == source[48_000 + 10])                      // the next second's burst
    }

    @Test func triggerBangsStartBurstsAndTheTimerStops() {
        let source = ramp(96_000)
        var trigger = [Float](repeating: 0, count: 96_000)
        for frame in 30_000..<30_010 { trigger[frame] = 1 }
        let output = render(source, trigger: trigger)
        #expect(output[1_000 + 4_800] == source[1_000 + 4_800])                  // nothing at frame 0
        #expect(output[34_800 + 10] == source[30_000 + 10])
        #expect(output[60_000] == source[60_000])                                // nothing at 48000
    }

    @Test func gateChopsEveryRepeatWithoutClicks() {
        let source = ramp(96_000)
        let output = render(source, settings: settings { $0.gate = 0.5 })
        #expect(output[1_000] == source[1_000])
        #expect(output[2_400 + 100] == 0)                                        // repeat 0 closes halfway
        #expect(output[4_800 + 1_000] == source[1_000])                          // repeat 1 reopens
        #expect(output[14_400 + 100] == source[14_400 + 100])                    // open again after the burst
        let steps = (2_300..<2_600).map { abs(output[$0] - output[$0 - 1]) }.max() ?? 0
        #expect(steps < 0.002)                                                    // closing is a 1 ms ramp, not a cut
    }

    @Test func panDriftBouncesEachRepeatAcrossTheSpeakers() {
        let source = ramp(96_000)
        let output = render([source, source], settings: settings { $0.panDrift = 0.5; $0.repeats = 4 })
        #expect(output[0][100] == source[100] && output[1][100] == source[100])  // repeat 0 centred
        #expect(abs(output[0][4_810] - 0.5 * source[10]) < 1e-6 && output[1][4_810] == source[10])
        #expect(output[0][9_610] == 0 && output[1][9_610] == source[10])          // hard right
        #expect(abs(output[0][14_410] - 0.5 * source[10]) < 1e-6)               // 1.5 bounces back to 0.5
    }

    @Test func reverseAlternatesAndPitchDrifts() {
        let source = ramp(96_000)
        let alternate = render(source, settings: settings { $0.reverse = 1 })
        #expect(alternate[4_800 + 10] == source[4_799 - 10])
        #expect(alternate[9_600 + 10] == source[10])
        func at(_ position: Double) -> Float { Float(position / 96_000) }
        let drift = render(source, settings: settings { $0.pitchDrift = -12 })
        #expect(abs(drift[4_800 + 101] - at(50.5)) < 1e-6)                       // repeat 1 an octave down
    }

    @Test func decayAndShrinkChangeEachRepeat() {
        let level = [Float](repeating: 0.8, count: 48_000)
        let decayed = render(level, settings: settings { $0.decay = 0.5 })
        #expect(abs(decayed[6_000] - 0.4) < 1e-6 && abs(decayed[11_000] - 0.2) < 1e-6)
        let source = ramp(96_000)
        let shrunk = render(source, settings: settings { $0.shrink = 0.5 })
        #expect(shrunk[4_800 + 2_400] == source[0])                              // repeats of 4800, 2400, 1200
        #expect(shrunk[8_400 + 10] == source[8_400 + 10])                        // the burst is over
    }

    @Test func chanceJitterAndSeedAreRepeatable() {
        let source = sine(frequency: 333, frames: 48_000 * 20)
        #expect(render(source, settings: settings { $0.chance = 0 }) == source)
        let once = render(source, settings: settings { $0.chance = 0.5 })
        #expect(render(source, settings: settings { $0.chance = 0.5 }) == once)
        #expect(once != source)
        #expect(render(source, settings: settings { $0.chance = 0.5; $0.seed = 9 }) != once)
        let jittered = render(source, settings: settings { $0.jitter = 20; $0.seed = 3 })
        #expect(jittered != render(source, settings: settings { $0.seed = 3 }))
        #expect(render(source, settings: settings { $0.jitter = 20; $0.seed = 3 }) == jittered)
    }

    @Test func mixBlendsTheInputAndTheRepeats() {
        let source = sine(frequency: 300, frames: 48_000)
        let half = render(source, settings: settings { $0.mix = 0.5 })
        let wet = render(source)
        #expect(zip(half, zip(source, wet)).allSatisfy { abs($0 - ($1.0 + $1.1) / 2) < 1e-6 })
    }

    @Test func smoothRemovesTheClickAtEachRepeat() {
        // 25 ms repeats at 225 Hz: repeat 0 ends near −0.55 (source 1199) and repeat 1 starts at 0.
        let source = sine(frequency: 225, frames: 48_000, amplitude: 0.8)
        func largestStep(_ output: [Float]) -> Float {
            (1_000..<1_500).map { abs(output[$0] - output[$0 - 1]) }.max() ?? 0
        }
        #expect(largestStep(render(source, settings: settings { $0.size = 25 })) > 0.2)
        #expect(largestStep(render(source, settings: settings { $0.size = 25; $0.smooth = 2 })) < 0.05)
    }

    @Test func chunksOf777MatchOneWholeRenderInStereo() {
        let left = sine(frequency: 190, frames: 96_000, amplitude: 0.7), right = sine(frequency: 260, frames: 96_000, amplitude: 0.7)
        func wave(_ period: Double) -> [Float] { (0..<96_000).map { Float(sin(Double($0) / period)) * 0.3 } }
        let modulated = settings {
            $0.every = 300; $0.repeats = 6; $0.chance = 0.7; $0.jitter = 10; $0.smooth = 2; $0.gate = 0.7; $0.panDrift = 0.3
            for (index, id) in ["every", "chance", "size", "repeats", "capture", "shrink", "gate", "decay", "pitch",
                                "pitchDrift", "pan", "panDrift", "reverse", "jitter", "smooth", "mix"].enumerated() {
                $0.modulation[id] = wave(2_000 + Double(index) * 700)
            }
        }
        #expect(render([left, right], settings: modulated, chunk: 777) == render([left, right], settings: modulated))
    }

    @Test func extremesStayFinite() {
        let source = sine(frequency: 500, frames: 48_000, amplitude: 1)
        let wild = settings {
            $0.every = 10; $0.size = 1; $0.repeats = 64; $0.shrink = 0.5; $0.pitch = 24; $0.pitchDrift = 12
            $0.capture = 1_000; $0.jitter = 100; $0.smooth = 20; $0.panDrift = 1; $0.gate = 0.05
        }
        let output = render([source, source], settings: wild)
        let finite = output.joined().allSatisfy { $0.isFinite && abs($0) <= 1.5 }
        #expect(finite)
    }

    @Test func rendersEndToEndKeepingLengthAndChannels() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("source.wav")
        try TestAudio.write(TestAudio.samples(frames: 60_000, channels: 2), to: file, sampleRate: 48_000)
        let output = directory.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var graph = TestProject()
        let audio = graph.add(.audio, asset: sourceAsset)
        let stutter = graph.add(.stutter, NodeCatalog.defaultParameters(for: .stutter))
        let print = graph.add(.print, ["bitDepth": .choice("32f")])
        graph.connect(audio, to: stutter)
        graph.connect(stutter, to: print)
        let urls = [sourceAsset: file]
        let request = RenderRequest(plan: try compile(graph.project, assetURLs: urls), assetURLs: urls, outputDirectory: output, chunkFrames: 777)
        let rendered = try TestAudio.read(try #require(try await RenderEngine.render(request).outputs[print]))
        #expect(rendered.samples.count == 2 && rendered.samples[0].count == 60_000)
        #expect(rendered.samples[0] != TestAudio.samples(frames: 60_000, channels: 2)[0])
    }

    @Test func theCatalogDescribesStutter() {
        let definition = NodeCatalog.definition(for: .stutter)
        #expect(definition.pins.map(\.id) == ["in", "trigger", "out"])
        #expect(definition.lengthRule == .sameAsInput("in"))
        #expect(NodeKind.stutter.category == .time)
        #expect(definition.parameters.filter { !$0.isModulatable }.map(\.id) == ["seed", LegacyModulationRanges.parameterID])
    }
}
