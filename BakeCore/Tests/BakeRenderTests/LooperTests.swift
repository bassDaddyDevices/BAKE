import BakeDSP
import Foundation
import Testing
@testable import BakeGraph
@testable import BakeRender

/// At 48 kHz with Start 0.25 of a 48000-frame input, the region starts at frame 12000; Length
/// 100 ms is 4800 frames.
struct LooperTests {
    private typealias Direction = bake.dsp.LooperDirection

    private struct Settings {
        var start = 0.25, length = 100.0, passes = 3.0, shrink = 1.0, keep = "whole"
        var scrub = 0.0, direction = Direction.forward, pitch = 0.0, pitchDrift = 0.0, decay = 0.0, crossfade = 0.0
        var snap = false
        var modulation: [String: [Float]] = [:]

        var parameters: [ParameterID: ParameterValue] {
            ["mode": .choice("once"), "start": .number(start), "length": .number(length), "passes": .number(passes), "shrink": .number(shrink), "keep": .choice(keep)]
        }
    }

    private func settings(_ change: (inout Settings) -> Void = { _ in }) -> Settings {
        var settings = Settings()
        change(&settings)
        return settings
    }

    private func layout(_ settings: Settings, inputFrames: Int) -> LooperPlan.Layout {
        LooperPlan.layout(inputFrames: inputFrames, parameters: settings.parameters, sampleRate: 48_000)
    }

    private func render(_ source: [Float], settings: Settings? = nil, chunk: Int? = nil) -> [Float] {
        let settings = settings ?? Settings()
        let plan = layout(settings, inputFrames: source.count)
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
        var controls = bake.dsp.LooperControls()
        controls.scrub = control("scrub", settings.scrub, -2_000, 2_000)
        controls.direction = control("direction", Double(settings.direction.rawValue), 0, 2)
        controls.pitch = control("pitch", settings.pitch, -24, 24)
        controls.pitchDrift = control("pitchDrift", settings.pitchDrift, -12, 12)
        controls.decay = control("decay", settings.decay, 0, 1)
        controls.crossfade = control("crossfade", settings.crossfade, 0, 200)
        controls.sampleRate = 48_000
        controls.snap = settings.snap

        let passLengths = plan.passLengths.map(Int64.init)
        var state = bake.dsp.LooperState()
        var output = [Float](repeating: 0, count: plan.frames)
        passLengths.withUnsafeBufferPointer { lengths in
            source.withUnsafeBufferPointer { sourcePointer in
                var layout = bake.dsp.LooperLayout()
                layout.passLengths = lengths.baseAddress
                layout.passCount = Int32(lengths.count)
                layout.regionStart = Double(plan.regionStart)
                layout.regionLength = Double(plan.regionLength)
                layout.introFrames = Double(plan.intro)
                controls.snapSource = sourcePointer.baseAddress
                controls.snapFrames = sourcePointer.count
                output.withUnsafeMutableBufferPointer { destination in
                    var start = 0
                    while start < destination.count {
                        let count = min(chunk ?? destination.count, destination.count - start)
                        bake.dsp.renderLooper(
                            &state, layout, controls, sourcePointer.baseAddress, sourcePointer.count,
                            destination.baseAddress! + start, start, count
                        )
                        start += count
                    }
                }
            }
        }
        return output
    }

    private func ramp(_ frames: Int) -> [Float] { (0..<frames).map { Float($0) / Float(frames) } }

    @Test func passesRepeatTheRegionThenTheInputCarriesOn() {
        let source = ramp(48_000)
        let output = render(source)
        #expect(output.count == 48_000 + 2 * 4_800)
        #expect(Array(output[0..<16_800]) == Array(source[0..<16_800]))        // intro, then pass 0 is live
        for k in [0, 1_000, 4_799] {
            #expect(output[16_800 + k] == source[12_000 + k], "pass 1, \(k)")
            #expect(output[21_600 + k] == source[12_000 + k], "pass 2, \(k)")
        }
        #expect(Array(output[26_400...]) == Array(source[16_800...]))          // the tail
    }

    @Test func keepLoopOutputsOnlyThePasses() {
        let source = ramp(48_000)
        let output = render(source, settings: settings { $0.keep = "loop" })
        #expect(output.count == 3 * 4_800)
        #expect(output[0] == source[12_000] && output[4_800] == source[12_000] && output[14_399] == source[16_799])
    }

    @Test func shrinkSetsEachPassLength() {
        let plan = layout(settings { $0.shrink = 0.5; $0.passes = 4 }, inputFrames: 48_000)
        #expect(plan.passLengths == [4_800, 2_400, 1_200, 600])
        #expect(plan.frames == 48_000 - 4_800 + 9_000)
        let grow = layout(settings { $0.shrink = 2; $0.passes = 2; $0.keep = "loop" }, inputFrames: 48_000)
        #expect(grow.passLengths == [4_800, 9_600])
        let output = render(ramp(48_000), settings: settings { $0.shrink = 0.5; $0.passes = 4 })
        #expect(output[12_000 + 4_800 + 2_400] == ramp(48_000)[12_000])        // pass 2 starts after 4800 + 2400
    }

    @Test func reverseAndPingPong() {
        let source = ramp(48_000)
        let reversed = render(source, settings: settings { $0.direction = .reverse })
        #expect(reversed[12_000] == source[16_799] && reversed[16_799] == source[12_000])
        let pingPong = render(source, settings: settings { $0.direction = .pingPong })
        #expect(pingPong[12_000 + 10] == source[12_000 + 10])                  // pass 0 forward
        #expect(pingPong[16_800 + 10] == source[16_799 - 10])                  // pass 1 backward
        #expect(pingPong[21_600 + 10] == source[12_000 + 10])                  // pass 2 forward
    }

    @Test func modulatedScrubMovesLaterPasses() {
        let source = ramp(48_000)
        // From pass 1 on, scrub +50 ms (2400 frames): base 0 + 1 × modulation × 4000 ms.
        var scrub = [Float](repeating: 0, count: 60_000)
        for frame in 16_000..<60_000 { scrub[frame] = 50.0 / 4_000 }
        let output = render(source, settings: settings { $0.modulation["scrub"] = scrub })
        #expect(output[12_000 + 10] == source[12_000 + 10])
        #expect(output[16_800 + 10] == source[14_400 + 10])
    }

    @Test func pitchAndDriftRepitchEachPass() {
        let source = ramp(48_000)
        func at(_ position: Double) -> Float { Float(position / 48_000) }
        let drift = render(source, settings: settings { $0.pitchDrift = -12 })
        #expect(drift[12_000 + 100] == source[12_000 + 100])                   // pass 0 at speed 1
        #expect(abs(drift[16_800 + 101] - at(12_000 + 50.5)) < 1e-6)          // pass 1 an octave down
    }

    @Test func decayLowersEachPass() {
        let source = [Float](repeating: 0.8, count: 48_000)
        let output = render(source, settings: settings { $0.decay = 0.5 })
        #expect(output[14_000] == 0.8)
        #expect(abs(output[18_000] - 0.4) < 1e-6)
        #expect(abs(output[23_000] - 0.2) < 1e-6)
        #expect(output[30_000] == 0.8)                                          // the tail is at full level
    }

    @Test func snapLandsEachPassOnARisingZeroCrossing() {
        // 230 Hz: frame 12000 is 57.5 cycles in, a falling zero; the nearest rising one is half a cycle away.
        let source = sine(frequency: 230, frames: 48_000, amplitude: 0.8)
        let output = render(source, settings: settings { $0.snap = true; $0.keep = "loop" })
        #expect(abs(output[0]) < 0.03 && output[1] > output[0])        // within one sample step of 0
        #expect(abs(output[4_800]) < 0.03 && output[4_801] > output[4_800])
    }

    @Test func crossfadeRemovesTheClickBetweenPasses() {
        // At 225 Hz pass 0 ends near −0.8 (source 16799) and pass 1 starts at +0.8 (source 12000).
        let source = sine(frequency: 225, frames: 48_000, amplitude: 0.8)
        func largestStep(_ output: [Float]) -> Float {
            (16_000..<18_000).map { abs(output[$0] - output[$0 - 1]) }.max() ?? 0
        }
        #expect(largestStep(render(source)) > 0.2)
        #expect(largestStep(render(source, settings: settings { $0.crossfade = 5 })) < 0.05)
    }

    @Test func chunksOf777MatchOneWholeRender() {
        let source = sine(frequency: 190, frames: 60_000, amplitude: 0.7)
        func wave(_ period: Double) -> [Float] { (0..<80_000).map { Float(sin(Double($0) / period)) * 0.3 } }
        let modulated = settings {
            $0.passes = 8; $0.shrink = 0.8; $0.crossfade = 10; $0.snap = true; $0.direction = .pingPong
            for (index, id) in ["scrub", "direction", "pitch", "pitchDrift", "decay", "crossfade"].enumerated() {
                $0.modulation[id] = wave(3_000 + Double(index) * 1_100)
            }
        }
        #expect(render(source, settings: modulated, chunk: 777) == render(source, settings: modulated))
    }

    @Test func extremesStayFinite() {
        let source = sine(frequency: 500, frames: 20_000, amplitude: 1)
        let wild = settings {
            $0.start = 0.99; $0.length = 1; $0.passes = 64; $0.shrink = 0.5; $0.pitch = 24; $0.pitchDrift = 12
            $0.crossfade = 200; $0.scrub = 2_000; $0.snap = true
        }
        let output = render(source, settings: wild)
        let finite = output.allSatisfy { $0.isFinite && abs($0) <= 1.5 }
        #expect(finite)
    }

    @Test func rendersEndToEndAtTheLaidOutLength() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("source.wav")
        try TestAudio.write(TestAudio.samples(frames: 30_000, channels: 2), to: file, sampleRate: 48_000)
        let output = directory.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var graph = TestProject()
        let audio = graph.add(.audio, asset: sourceAsset)
        var parameters = NodeCatalog.defaultParameters(for: .looper)
        parameters["mode"] = .choice("once")
        let looper = graph.add(.looper, parameters)
        let print = graph.add(.print, ["bitDepth": .choice("32f")])
        graph.connect(audio, to: looper)
        graph.connect(looper, to: print)
        let urls = [sourceAsset: file]
        let request = RenderRequest(plan: try compile(graph.project, assetURLs: urls), assetURLs: urls, outputDirectory: output, chunkFrames: 777)
        let rendered = try TestAudio.read(try #require(try await RenderEngine.render(request).outputs[print]))
        let expected = LooperPlan.layout(inputFrames: 30_000, parameters: parameters, sampleRate: 48_000).frames
        #expect(expected > 30_000)
        #expect(rendered.samples.count == 2 && rendered.samples[0].count == expected)
    }

    @Test func theCatalogDescribesLooper() {
        let definition = NodeCatalog.definition(for: .looper)
        #expect(definition.pins.map(\.id) == ["in", "trigger", "out"])
        #expect(definition.lengthRule == .looped("in"))
        #expect(NodeKind.looper.category == .time)
        let modulatable = definition.parameters.filter(\.isModulatable).map(\.id)
        #expect(Set(modulatable) == ["every", "scrub", "direction", "pitch", "pitchDrift", "decay", "crossfade"])
    }
}
