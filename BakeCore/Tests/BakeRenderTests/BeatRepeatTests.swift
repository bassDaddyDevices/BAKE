import BakeDSP
import Foundation
import Testing
@testable import BakeGraph
@testable import BakeRender

/// At 120 BPM and 48 kHz: a bar (Interval 1/1) is 96000 frames, a sixteenth 6000. The defaults put
/// one event per bar at Offset 8/16 (frame 48000), Gate 4/16 (24000 frames), Grid 1/16 (6000).
struct BeatRepeatTests {
    private typealias Mode = bake.dsp.BeatRepeatMode

    /// Knob values in the node's own units; `modulation` maps a control to its modulation signal.
    private struct Settings {
        var tempo = 120.0, interval = "1/1", offset = 8.0, chance = 1.0, gate = 4.0, grid = "1/16"
        var capture = 0.0, variation = 0.0, accelerate = 1.0, pitch = 0.0, pitchDrift = 0.0, decay = 0.0
        var smooth = 0.0
        var seed: UInt32 = 0
        var modulation: [String: [Float]] = [:]
    }

    private func settings(_ change: (inout Settings) -> Void = { _ in }) -> Settings {
        var settings = Settings()
        change(&settings)
        return settings
    }

    private func render(
        _ source: [Float], mode: Mode = .insert, settings: Settings? = nil, trigger: [Float]? = nil, chunk: Int? = nil
    ) -> [Float] {
        let settings = settings ?? Settings()
        // Modulation buffers live until the render ends.
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
        let grids = BeatRepeatNotes.grids, intervals = BeatRepeatNotes.intervals
        var controls = bake.dsp.BeatRepeatControls()
        controls.tempo = control("tempo", settings.tempo, 20, 300)
        controls.interval = control("interval", Double(intervals.firstIndex(of: settings.interval) ?? 2), 0, Double(intervals.count - 1))
        controls.offset = control("offset", settings.offset, 0, 15)
        controls.chance = control("chance", settings.chance, 0, 1)
        controls.gate = control("gate", settings.gate, 1, 64)
        controls.grid = control("grid", Double(grids.firstIndex(of: settings.grid) ?? 3), 0, Double(grids.count - 1))
        controls.capture = control("capture", settings.capture, -16, 16)
        controls.variation = control("variation", settings.variation, 0, 1)
        controls.accelerate = control("accelerate", settings.accelerate, 0.5, 2)
        controls.pitch = control("pitch", settings.pitch, -48, 24)
        controls.pitchDrift = control("pitchDrift", settings.pitchDrift, -12, 12)
        controls.decay = control("decay", settings.decay, 0, 1)
        controls.smooth = control("smooth", settings.smooth, 0, 20)
        controls.seed = settings.seed
        controls.sampleRate = 48_000
        let gridQuarters = grids.map { BeatRepeatNotes.quarterNotes($0)! }
        let intervalQuarters = intervals.map { BeatRepeatNotes.quarterNotes($0)! }

        var state = bake.dsp.BeatRepeatState()
        var output = [Float](repeating: 0, count: source.count)
        let triggerValues = trigger ?? []
        gridQuarters.withUnsafeBufferPointer { gridPointer in
            intervalQuarters.withUnsafeBufferPointer { intervalPointer in
                controls.gridQuarters = gridPointer.baseAddress
                controls.gridCount = Int32(gridPointer.count)
                controls.intervalQuarters = intervalPointer.baseAddress
                controls.intervalCount = Int32(intervalPointer.count)
                triggerValues.withUnsafeBufferPointer { triggerPointer in
                    source.withUnsafeBufferPointer { sourcePointer in
                        output.withUnsafeMutableBufferPointer { destination in
                            var triggerInput = bake.dsp.ControlInput()
                            if trigger != nil { triggerInput.samples = triggerPointer.baseAddress; triggerInput.frames = triggerPointer.count }
                            var start = 0
                            while start < source.count {
                                let count = min(chunk ?? source.count, source.count - start)
                                bake.dsp.renderBeatRepeat(
                                    &state, mode, controls, triggerInput,
                                    sourcePointer.baseAddress, sourcePointer.count, destination.baseAddress! + start, start, count
                                )
                                start += count
                            }
                        }
                    }
                }
            }
        }
        return output
    }

    /// Each frame's value is its own position, so the output says where it read from.
    private func ramp(_ frames: Int) -> [Float] { (0..<frames).map { Float($0) / Float(frames) } }

    @Test func insertPlaysTheInputThenRepeatsTheFirstGrid() {
        let source = ramp(192_000)
        let output = render(source)
        #expect(Array(output[0..<54_000]) == Array(source[0..<54_000]))         // before the event, then the live first grid
        for k in [0, 1_234, 5_999] {
            #expect(output[54_000 + k] == source[48_000 + k], "repeat 1, \(k)")
            #expect(output[66_000 + k] == source[48_000 + k], "repeat 3, \(k)")
        }
        #expect(Array(output[72_000..<144_000]) == Array(source[72_000..<144_000]))  // after the gate until the next bar's event
        #expect(output[150_000] == source[144_000])
    }

    @Test func gateIsOnlyTheRepeatsAndMixAddsThem() {
        let source = ramp(96_000)
        let gated = render(source, mode: .gate)
        #expect(gated[0..<54_000].allSatisfy { $0 == 0 })                        // the live first grid isn't doubled
        #expect(gated[54_000 + 100] == source[48_000 + 100])
        #expect(gated[80_000] == 0)
        let mixed = render(source, mode: .mix)
        #expect(mixed[50_000] == source[50_000])
        #expect(abs(mixed[54_000 + 100] - (source[54_000 + 100] + source[48_000 + 100])) < 1e-6)
    }

    @Test func captureAheadRepeatsTheFuture() {
        let source = ramp(96_000)
        let output = render(source, settings: settings { $0.capture = 2 })
        #expect(output[48_000] == source[60_000])                                // the event opens on audio 2 grids ahead
        #expect(output[54_000 + 10] == source[60_000 + 10])
        let past = render(source, settings: settings { $0.capture = -1 })
        #expect(past[48_000 + 10] == source[42_000 + 10])
    }

    @Test func accelerateShortensEachRepeat() {
        let source = ramp(96_000)
        let output = render(source, settings: settings { $0.accelerate = 0.5 })
        // Repeats of 6000, 3000, 1500 … frames.
        #expect(output[53_999] == source[53_999])
        #expect(output[56_999] == source[48_000 + 2_999])
        #expect(output[57_000] == source[48_000])
        #expect(output[58_500] == source[48_000])
    }

    @Test func pitchRepitchesEachRepeatAndDriftMovesIt() {
        let source = ramp(96_000)
        func at(_ position: Double) -> Float { Float(position / 96_000) }
        let down = render(source, settings: settings { $0.pitch = -12 })
        #expect(abs(down[48_000 + 3_001] - at(48_000 + 1_500.5)) < 1e-6)        // an octave down is half speed
        let drift = render(source, settings: settings { $0.pitchDrift = 12 })
        #expect(abs(drift[48_000 + 100] - at(48_000 + 100)) < 1e-6)              // repeat 0 at speed 1
        #expect(abs(drift[54_000 + 100] - at(48_000 + 200)) < 1e-6)              // repeat 1 an octave up
    }

    @Test func decayLowersEachRepeat() {
        let source = [Float](repeating: 0.8, count: 96_000)
        let output = render(source, settings: settings { $0.decay = 0.5 })
        #expect(output[50_000] == 0.8)
        #expect(abs(output[55_000] - 0.4) < 1e-6)
        #expect(abs(output[61_000] - 0.2) < 1e-6)
        #expect(output[80_000] == 0.8)
    }

    @Test func chanceIsSeededAndRepeatable() {
        let source = sine(frequency: 333, frames: 96_000 * 20)
        #expect(render(source, settings: settings { $0.chance = 0 }) == source)
        let once = render(source, settings: settings { $0.chance = 0.5 })
        #expect(render(source, settings: settings { $0.chance = 0.5 }) == once)
        #expect(once != source)
        #expect(render(source, settings: settings { $0.chance = 0.5; $0.seed = 7 }) != once)
    }

    @Test func variationChangesTheGrid() {
        let source = ramp(96_000 * 8)
        #expect(render(source, settings: settings { $0.variation = 1; $0.seed = 3 }) != render(source))
    }

    @Test func modulationIsReadAsEachEventAndRepeatStarts() {
        let source = ramp(192_000)
        // Grid steps from 1/16 (index 3) to 1/8 (index 1) after the first bar: the second event's
        // slice is 12000 frames, the first's stays 6000.
        var grid = [Float](repeating: 0, count: 192_000)
        for frame in 96_000..<192_000 { grid[frame] = -2.0 / 12 }
        let output = render(source, settings: settings { $0.modulation["grid"] = grid })
        #expect(output[54_000 + 10] == source[48_000 + 10])
        #expect(output[150_000] == source[150_000])                              // still the live first grid
        #expect(output[156_000 + 10] == source[144_000 + 10])
        // Decay modulated up from repeat 2 on: repeat 1 keeps full level, repeat 2 drops.
        let level = [Float](repeating: 0.8, count: 96_000)
        var decay = [Float](repeating: 0, count: 96_000)
        for frame in 60_000..<96_000 { decay[frame] = 0.5 }
        let decayed = render(level, settings: settings { $0.modulation["decay"] = decay })
        #expect(decayed[55_000] == 0.8)
        #expect(abs(decayed[61_000] - 0.4) < 1e-6)
    }

    @Test func modulatedTempoMovesTheTimer() {
        let source = ramp(192_000)
        // Tempo held at 240 (base 120 + 120): a bar is 48000 frames, so events at 24000, 72000…
        let fast = render(source, settings: settings { $0.modulation["tempo"] = [Float](repeating: 120.0 / 280, count: 192_000) })
        #expect(abs(fast[27_000 + 10] - source[24_000 + 10]) < 1e-6)
        #expect(fast[40_000] == source[40_000])
    }

    @Test func triggerBangsStartEventsAndTheTimerStops() {
        let source = ramp(192_000)
        var trigger = [Float](repeating: 0, count: 192_000)
        for frame in 30_000..<30_010 { trigger[frame] = 1 }
        let output = render(source, trigger: trigger)
        #expect(output[36_000 + 50] == source[30_000 + 50])
        #expect(output[60_000] == source[60_000])                               // no timer event at 48000
        #expect(output[150_000] == source[150_000])
    }

    @Test func smoothRemovesTheClickAtEachRepeat() {
        // At 225 Hz the first repeat jumps from 0.71 × 0.8 (source 53999) to 0 (source 48000).
        let source = sine(frequency: 225, frames: 96_000, amplitude: 0.8)
        func largestStep(_ output: [Float]) -> Float {
            (53_000..<56_000).map { abs(output[$0] - output[$0 - 1]) }.max() ?? 0
        }
        #expect(largestStep(render(source)) > 0.2)
        #expect(largestStep(render(source, settings: settings { $0.smooth = 2 })) < 0.05)
    }

    @Test func chunksOf777MatchOneWholeRender() {
        let source = sine(frequency: 190, frames: 96_000 * 3, amplitude: 0.7)
        func wave(_ period: Double) -> [Float] { (0..<source.count).map { Float(sin(Double($0) / period)) * 0.3 } }
        // Every control modulated, including the timer (Tempo, Interval, Offset) and the choices.
        let modulated = settings {
            $0.variation = 0.5; $0.accelerate = 0.8; $0.pitchDrift = -2; $0.decay = 0.2; $0.capture = 1; $0.smooth = 2; $0.chance = 0.6
            for (index, id) in ["tempo", "interval", "offset", "chance", "gate", "grid", "capture", "variation",
                                "accelerate", "pitch", "pitchDrift", "decay", "smooth"].enumerated() {
                $0.modulation[id] = wave(9_000 + Double(index) * 1_700)
            }
        }
        for mode in [Mode.insert, .mix, .gate] {
            let whole = render(source, mode: mode, settings: modulated)
            #expect(render(source, mode: mode, settings: modulated, chunk: 777) == whole)
        }
    }

    @Test func extremesStayFinite() {
        let source = sine(frequency: 500, frames: 48_000, amplitude: 1)
        let wild = settings {
            $0.tempo = 300; $0.interval = "1/4"; $0.offset = 0; $0.gate = 1; $0.grid = "1/2048"
            $0.accelerate = 0.5; $0.pitch = 24; $0.pitchDrift = 12; $0.capture = 16; $0.smooth = 20
        }
        let output = render(source, settings: wild)
        let finite = output.allSatisfy { $0.isFinite && abs($0) <= 1.5 }
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
        var parameters = NodeCatalog.defaultParameters(for: .beatRepeat)
        parameters["offset"] = .number(0)
        let repeater = graph.add(.beatRepeat, parameters)
        let print = graph.add(.print, ["bitDepth": .choice("32f")])
        graph.connect(audio, to: repeater)
        graph.connect(repeater, to: print)
        let urls = [sourceAsset: file]
        let request = RenderRequest(plan: try compile(graph.project, assetURLs: urls), assetURLs: urls, outputDirectory: output, chunkFrames: 777)
        let rendered = try TestAudio.read(try #require(try await RenderEngine.render(request).outputs[print]))
        #expect(rendered.samples.count == 2 && rendered.samples[0].count == 60_000)
        #expect(rendered.samples[0] != TestAudio.samples(frames: 60_000, channels: 2)[0])
    }

    @Test func theCatalogDescribesBeatRepeat() {
        let definition = NodeCatalog.definition(for: .beatRepeat)
        #expect(definition.pins.map(\.id) == ["in", "trigger", "out"])
        #expect(definition.lengthRule == .sameAsInput("in"))
        #expect(NodeKind.beatRepeat.category == .time)
        let fixed = definition.parameters.filter { !$0.isModulatable }.map(\.id)
        #expect(fixed == ["mode", "seed"])                                       // everything else can be modulated
        #expect(BeatRepeatNotes.quarterNotes("1/16") == 0.25)
        #expect(BeatRepeatNotes.quarterNotes("2/1") == 8)
        #expect(BeatRepeatNotes.quarterNotes("1/16t") == 0.25 * 2 / 3)
        #expect(BeatRepeatNotes.grids.contains("1/2048"))
    }
}
