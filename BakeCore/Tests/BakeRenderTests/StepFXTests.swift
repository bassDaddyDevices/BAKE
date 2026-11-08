import BakeDSP
import Foundation
import Testing
@testable import BakeGraph
@testable import BakeRender

/// At 120 BPM and 48 kHz a 1/16 step is 6000 frames; Stutter Size 30 ms is 1440 frames.
struct StepFXTests {
    private struct Settings {
        var pattern = "S", steps = 1
        var tempo = 120.0, step = "1/16", rotate = 0.0, chance = 1.0, variation = 0.0
        var stutterSize = 30.0, speed = 0.5, curve = 1.0, gate = 0.5, smooth = 0.0, mix = 1.0
        var seed: UInt32 = 0
        var modulation: [String: [Float]] = [:]
    }

    private func settings(_ change: (inout Settings) -> Void = { _ in }) -> Settings {
        var settings = Settings()
        change(&settings)
        return settings
    }

    private func render(_ source: [Float], settings: Settings? = nil, clock: [Float]? = nil, chunk: Int? = nil) -> [Float] {
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
        let lengths = StepFXPattern.stepLengths
        var controls = bake.dsp.StepFXControls()
        controls.tempo = control("tempo", settings.tempo, 20, 300)
        controls.step = control("step", Double(lengths.firstIndex(of: settings.step) ?? 3), 0, Double(lengths.count - 1))
        controls.rotate = control("rotate", settings.rotate, -32, 32)
        controls.chance = control("chance", settings.chance, 0, 1)
        controls.variation = control("variation", settings.variation, 0, 1)
        controls.stutterSize = control("stutterSize", settings.stutterSize, 1, 500)
        controls.speed = control("speed", settings.speed, 0.05, 1)
        controls.curve = control("curve", settings.curve, 0.25, 4)
        controls.gate = control("gate", settings.gate, 0.05, 1)
        controls.smooth = control("smooth", settings.smooth, 0, 20)
        controls.mix = control("mix", settings.mix, 0, 1)
        controls.sampleRate = 48_000
        controls.seed = settings.seed
        let pattern = StepFXPattern.effects(settings.pattern, steps: settings.steps).map { Int32($0.rawValue) }
        let quarters = lengths.map { BeatRepeatNotes.quarterNotes($0)! }

        var state = bake.dsp.StepFXState()
        var output = [Float](repeating: 0, count: source.count)
        let clockValues = clock ?? []
        pattern.withUnsafeBufferPointer { cells in
            quarters.withUnsafeBufferPointer { quarterPointer in
                controls.pattern = cells.baseAddress
                controls.steps = Int32(cells.count)
                controls.stepQuarters = quarterPointer.baseAddress
                controls.stepCount = Int32(quarterPointer.count)
                clockValues.withUnsafeBufferPointer { clockPointer in
                    source.withUnsafeBufferPointer { sourcePointer in
                        output.withUnsafeMutableBufferPointer { destination in
                            var clockInput = bake.dsp.ControlInput()
                            if clock != nil { clockInput.samples = clockPointer.baseAddress; clockInput.frames = clockPointer.count }
                            var start = 0
                            while start < source.count {
                                let count = min(chunk ?? source.count, source.count - start)
                                bake.dsp.renderStepFX(
                                    &state, controls, clockInput, sourcePointer.baseAddress, sourcePointer.count,
                                    destination.baseAddress! + start, start, count
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

    private func ramp(_ frames: Int) -> [Float] { (0..<frames).map { Float($0) / Float(frames) } }
    private func at(_ position: Double) -> Float { Float(position / 48_000) }

    // MARK: the pattern

    @Test func thePatternParsesFormatsAndKeepsHiddenSteps() {
        #expect(StepFXPattern.effects("S.r-T h G·x", steps: 8) == [.stutter, .pass, .reverse, .pass, .tapeStop, .halfTime, .gate, .pass])
        #expect(StepFXPattern.text([.stutter, .pass, .gate]) == "S · G")
        #expect(StepFXPattern.effects(StepFXPattern.text([.reverse, .halfTime]), steps: 2) == [.reverse, .halfTime])
        // Editing step 1 with Steps 2 keeps steps 3 and 4.
        #expect(StepFXPattern.setting(0, to: .gate, in: "S R T H", steps: 2) == "G R T H")
        #expect(StepFXPattern.Effect.gate.next == .pass && StepFXPattern.Effect.pass.next == .stutter)
    }

    // MARK: each effect

    @Test func passIsDry() {
        let source = ramp(48_000)
        #expect(render(source, settings: settings { $0.pattern = "·" }) == source)
    }

    @Test func stutterRepeatsTheStepsFirstSlice() {
        let source = ramp(48_000)
        let output = render(source)
        #expect(Array(output[0..<1_440]) == Array(source[0..<1_440]))
        #expect(output[1_440 + 10] == source[10] && output[4_320 + 10] == source[10])
        #expect(output[6_000 + 1_440 + 10] == source[6_000 + 10])               // the next step's own slice
    }

    @Test func reversePlaysTheStepBackwards() {
        let source = ramp(48_000)
        let output = render(source, settings: settings { $0.pattern = "R" })
        #expect(output[10] == source[5_989] && output[6_010] == source[11_989])
    }

    @Test func tapeStopSlowsToAStop() {
        let source = ramp(48_000)
        let output = render(source, settings: settings { $0.pattern = "T" })
        // Speed 1 − t/6000: after t frames the read is t − t(t − 1)/12000.
        #expect(abs(output[3_000] - at(3_000 - 3_000 * 2_999 / 12_000.0)) < 1e-5)
        #expect(abs(output[5_999] - output[5_998]) < 1e-6)                       // nearly stopped
    }

    @Test func halfTimeAndGate() {
        let source = ramp(48_000)
        let half = render(source, settings: settings { $0.pattern = "H" })
        #expect(abs(half[3_001] - at(1_500.5)) < 1e-6)
        let gated = render(source, settings: settings { $0.pattern = "G" })
        #expect(gated[1_000] == source[1_000] && gated[3_100] == 0 && gated[7_000] == source[7_000])
    }

    // MARK: timing and variation

    @Test func clockBangsStartStepsThatLastUntilTheNextBang() {
        let source = ramp(48_000)
        var clock = [Float](repeating: 0, count: 48_000)
        for start in [1_000, 5_000, 9_000] { for frame in start..<(start + 10) { clock[frame] = 1 } }
        let output = render(source, settings: settings { $0.pattern = "R" }, clock: clock)
        #expect(output[500] == source[500])                                      // before the first bang
        #expect(output[1_010] == source[1_000 + 3_999 - 10])                     // look-ahead: 4000-frame steps
        #expect(output[9_010] == source[9_000 + 3_999 - 10])                     // the last lasts as long as the one before
        #expect(output[14_000] == source[14_000])
    }

    @Test func theTimerFollowsStepAndRotateShiftsThePattern() {
        let source = ramp(48_000)
        let eighths = render(source, settings: settings { $0.pattern = "R"; $0.step = "1/8" })
        #expect(eighths[10] == source[11_989])
        let rotated = render(source, settings: settings { $0.pattern = "· R"; $0.steps = 2; $0.rotate = 1 })
        #expect(rotated[10] == source[5_989] && rotated[6_010] == source[6_010])
    }

    @Test func chanceAndVariationAreSeeded() {
        let source = sine(frequency: 333, frames: 96_000)
        let reversed = settings { $0.pattern = "R" }
        #expect(render(source, settings: settings { $0.pattern = "R"; $0.chance = 0 }) == source)
        let half = render(source, settings: settings { $0.pattern = "R"; $0.chance = 0.5 })
        #expect(half == render(source, settings: settings { $0.pattern = "R"; $0.chance = 0.5 }))
        #expect(half != source && half != render(source, settings: reversed))
        #expect(render(source, settings: settings { $0.pattern = "R"; $0.chance = 0.5; $0.seed = 4 }) != half)
        let varied = render(source, settings: settings { $0.pattern = "·"; $0.variation = 1 })
        #expect(varied != source && varied == render(source, settings: settings { $0.pattern = "·"; $0.variation = 1 }))
    }

    @Test func smoothRemovesTheClickAtEachSlice() {
        // At 225 Hz the first slice ends near −0.8 (source 1439) and repeats from 0.
        let source = sine(frequency: 225, frames: 48_000, amplitude: 0.8)
        func largestStep(_ output: [Float]) -> Float {
            (1_000..<2_000).map { abs(output[$0] - output[$0 - 1]) }.max() ?? 0
        }
        #expect(largestStep(render(source)) > 0.2)
        #expect(largestStep(render(source, settings: settings { $0.smooth = 2 })) < 0.05)
    }

    @Test func chunksOf777MatchOneWholeRender() {
        let source = sine(frequency: 190, frames: 96_000, amplitude: 0.7)
        func wave(_ period: Double) -> [Float] { (0..<96_000).map { Float(sin(Double($0) / period)) * 0.3 } }
        let modulated = settings {
            $0.pattern = "S R T H G · S R"; $0.steps = 8; $0.chance = 0.8; $0.variation = 0.3; $0.smooth = 2
            for (index, id) in ["tempo", "step", "rotate", "chance", "variation", "stutterSize", "speed", "curve",
                                "gate", "smooth", "mix"].enumerated() {
                $0.modulation[id] = wave(3_000 + Double(index) * 900)
            }
        }
        #expect(render(source, settings: modulated, chunk: 777) == render(source, settings: modulated))
    }

    @Test func extremesStayFinite() {
        let source = sine(frequency: 500, frames: 48_000, amplitude: 1)
        let wild = settings {
            $0.pattern = "S R T H G"; $0.steps = 5; $0.tempo = 300; $0.step = "1/64"; $0.stutterSize = 1
            $0.curve = 4; $0.speed = 0.05; $0.gate = 0.05; $0.smooth = 20; $0.variation = 1
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
        let stepFX = graph.add(.stepFX, NodeCatalog.defaultParameters(for: .stepFX))
        let print = graph.add(.print, ["bitDepth": .choice("32f")])
        graph.connect(audio, to: stepFX)
        graph.connect(stepFX, to: print)
        let urls = [sourceAsset: file]
        let request = RenderRequest(plan: try compile(graph.project, assetURLs: urls), assetURLs: urls, outputDirectory: output, chunkFrames: 777)
        let rendered = try TestAudio.read(try #require(try await RenderEngine.render(request).outputs[print]))
        #expect(rendered.samples.count == 2 && rendered.samples[0].count == 60_000)
        #expect(rendered.samples[0] != TestAudio.samples(frames: 60_000, channels: 2)[0])
    }

    @Test func theCatalogDescribesStepFX() {
        let definition = NodeCatalog.definition(for: .stepFX)
        #expect(definition.pins.map(\.id) == ["in", "clock", "out"])
        #expect(definition.lengthRule == .sameAsInput("in"))
        #expect(NodeKind.stepFX.category == .time)
        #expect(definition.parameters.filter { !$0.isModulatable }.map(\.id) == ["steps", "pattern", "seed"])
        let pattern: String = if case .text(let value) = definition.parameter("pattern")!.defaultValue { value } else { "" }
        #expect(StepFXPattern.effects(pattern, steps: 16).count == 16)
    }
}
