import BakeDSP
import Foundation
import Testing
@testable import BakeGraph
@testable import BakeRender

/// The Spectral Resynthesis extras: the table transform and its renderer (BakeDSP/Resynthesis.h).
struct ResynthesisExtrasTests {
    private typealias Transform = bake.dsp.ResynthesisTransform
    private let sampleRate = 48_000.0

    private func settings(fftSize: Int32 = 4_096, partials: Int32 = 128) -> bake.dsp.ResynthesisSettings {
        var settings = bake.dsp.ResynthesisSettings()
        settings.fftSize = fftSize
        settings.partials = partials
        return settings
    }

    /// Knob values and modulation, as the processor would pass them.
    private struct Extras {
        var pitch = 0.0, stretch = 1.0, crystallize = 0.0, quantize = 0.0, glide = 0.0, decay = 0.0, phaseRandomize = 0.0
        var scale = bake.dsp.QuantizerScale.chromatic, root: Int32 = 0, seed: UInt32 = 0
        var freeze: [Float]? = nil
        var b: [Float]? = nil
        var mode = bake.dsp.ResynthesisMode.off, amount = 1.0, split = 1_000.0
        var modulation: [String: [Float]] = [:]
    }

    private func extras(_ change: (inout Extras) -> Void = { _ in }) -> Extras {
        var extras = Extras()
        change(&extras)
        return extras
    }

    /// Analyses `input`, transforms the table and renders through the transformed path.
    private func render(
        _ input: [Float], _ extras: Extras, balance: Float = 0, chunk: Int? = nil,
        settings: bake.dsp.ResynthesisSettings? = nil
    ) -> [Float] {
        let settings = settings ?? self.settings()
        let count = input.count
        let outputCount = Int((Double(count) * extras.stretch).rounded())
        let maxCount = chunk ?? outputCount
        var buffers: [UnsafeMutableBufferPointer<Float>] = []
        defer { buffers.forEach { $0.deallocate() } }
        func pointer(_ values: [Float]) -> UnsafeMutableBufferPointer<Float> {
            let buffer = UnsafeMutableBufferPointer<Float>.allocate(capacity: values.count)
            _ = buffer.initialize(from: values)
            buffers.append(buffer)
            return buffer
        }
        func control(_ id: String, _ base: Double, _ minimum: Double, _ maximum: Double) -> bake.dsp.ParameterSignal {
            var control = signal(Float(base), Float(minimum), Float(maximum))
            if let values = extras.modulation[id] {
                let buffer = pointer(values)
                control.modulation = UnsafePointer(buffer.baseAddress)
                control.modulationFrames = buffer.count
            }
            return control
        }
        var transform = Transform()
        transform.pitch = control("pitch", extras.pitch, -24, 24)
        transform.stretch = extras.stretch
        transform.crystallize = control("crystallize", extras.crystallize, 0, 1)
        transform.quantize = control("quantize", extras.quantize, 0, 1)
        transform.scale = extras.scale
        transform.root = extras.root
        transform.glide = control("glide", extras.glide, 0, 500)
        transform.decay = control("decay", extras.decay, 0, 60)
        transform.phaseRandomize = control("phaseRandomize", extras.phaseRandomize, 0, 1)
        transform.seed = extras.seed
        transform.mode = extras.b == nil ? .off : extras.mode
        transform.amount = control("amount", extras.amount, 0, 1)
        transform.split = control("split", extras.split, 100, 10_000)
        if let freeze = extras.freeze {
            let buffer = pointer(freeze)
            transform.freeze.samples = UnsafePointer(buffer.baseAddress)
            transform.freeze.frames = buffer.count
        }

        var source = [Float](repeating: 0, count: Int(bake.dsp.resynthesisTableFloats(settings, count)))
        let b = extras.b ?? []
        var bTable = [Float](repeating: 0, count: max(Int(bake.dsp.resynthesisTableFloats(settings, b.count)), 1))
        var table = [Float](repeating: 0, count: Int(bake.dsp.resynthesisOutputTableFloats(settings, transform, outputCount)))
        var noiseMap = [Float](repeating: 0, count: Int(bake.dsp.resynthesisNoiseMapFloats(settings, outputCount)))
        let scratchBytes = max(Int(bake.dsp.resynthesisScratchBytes(settings, maxCount)), Int(bake.dsp.resynthesisTransformScratchBytes(settings)))
        let scratch = UnsafeMutableRawPointer.allocate(byteCount: scratchBytes, alignment: 16)
        defer { scratch.deallocate() }
        var work = [Float](repeating: 0, count: max(
            Int(bake.dsp.resynthesisAnalysisWorkFloats(settings)), Int(bake.dsp.resynthesisRenderWorkFloats(settings, maxCount))
        ))
        var output = [Float](repeating: 0, count: outputCount)
        let tilt = signal(0, -12, 12), balanceSignal = signal(balance, 0, 1)
        input.withUnsafeBufferPointer { samples in
            bake.dsp.resynthesisAnalyse(settings, sampleRate, samples.baseAddress!, count, &source, scratch, &work)
            b.withUnsafeBufferPointer { bSamples in
            let hasB = extras.b != nil
            if hasB {
                bake.dsp.resynthesisAnalyse(settings, sampleRate, bSamples.baseAddress!, b.count, &bTable, scratch, &work)
            }
            bTable.withUnsafeBufferPointer { bTablePointer in
            let bTableBase = hasB ? bTablePointer.baseAddress : nil
            bake.dsp.resynthesisTransformTable(settings, sampleRate, transform, source, count, bTableBase, b.count, &table, outputCount, &noiseMap, scratch)
            output.withUnsafeMutableBufferPointer { destination in
                var start = 0
                while start < outputCount {
                    let length = min(maxCount, outputCount - start)
                    bake.dsp.resynthesisRenderTransformed(
                        settings, sampleRate, transform, tilt, balanceSignal, samples.baseAddress!, count, source,
                        hasB ? bSamples.baseAddress : nil, b.count, bTableBase, table, noiseMap,
                        outputCount, destination.baseAddress! + start, start, length, 0, scratch, &work
                    )
                    start += length
                }
            }
            }
            }
        }
        return output
    }

    /// Hann-windowed Goertzel amplitude of a sine at `frequency`.
    private func amplitude(_ signal: [Float], _ range: Range<Int>, at frequency: Double) -> Double {
        let w = 2 * Double.pi * frequency / sampleRate
        var (real, imaginary) = (0.0, 0.0)
        for index in range {
            let hann = 0.5 - 0.5 * cos(2 * Double.pi * Double(index - range.lowerBound) / Double(range.count))
            real += hann * Double(signal[index]) * cos(w * Double(index))
            imaginary += hann * Double(signal[index]) * sin(w * Double(index))
        }
        return (real * real + imaginary * imaginary).squareRoot() / (0.25 * Double(range.count))
    }

    /// Frequency from upward zero crossings over a range.
    private func frequency(_ signal: [Float], _ range: Range<Int>) -> Double {
        let crossings = range.dropFirst().filter { signal[$0 - 1] < 0 && signal[$0] >= 0 }
        guard let first = crossings.first, let last = crossings.last, crossings.count > 1 else { return 0 }
        return Double(crossings.count - 1) / (Double(last - first) / sampleRate)
    }

    private func rms(_ signal: [Float], _ range: Range<Int>) -> Double {
        (signal[range].reduce(0.0) { $0 + Double($1) * Double($1) } / Double(range.count)).squareRoot()
    }

    // MARK: compatibility

    @Test func thePlainPathKeepsItsExactBits() {
        // A fingerprint of the original renderer's output, taken before the extras existed. If this
        // changes, documents saved before the extras would sound different.
        var settings = bake.dsp.ResynthesisSettings()
        settings.fftSize = 2_048
        settings.partials = 64
        let count = 60_000
        let input = (0..<count).map { Float(sin(Double($0) * 0.031) * 0.4 + sin(Double($0) * 0.11) * 0.2) + Float(($0 * 7_919) % 101) / 5_000 }
        var table = [Float](repeating: 0, count: Int(bake.dsp.resynthesisTableFloats(settings, count)))
        let scratch = UnsafeMutableRawPointer.allocate(byteCount: Int(bake.dsp.resynthesisScratchBytes(settings, 777)), alignment: 16)
        defer { scratch.deallocate() }
        var work = [Float](repeating: 0, count: max(
            Int(bake.dsp.resynthesisAnalysisWorkFloats(settings)), Int(bake.dsp.resynthesisRenderWorkFloats(settings, 777))
        ))
        var output = [Float](repeating: 0, count: count)
        input.withUnsafeBufferPointer { source in
            bake.dsp.resynthesisAnalyse(settings, 48_000, source.baseAddress!, count, &table, scratch, &work)
            output.withUnsafeMutableBufferPointer { destination in
                var start = 0
                while start < count {
                    let length = min(777, count - start)
                    bake.dsp.resynthesisRender(
                        settings, 48_000, signal(1.5, -12, 12), signal(0.4, 0, 1), source.baseAddress!, count, table,
                        destination.baseAddress! + start, start, length, 3, scratch, &work
                    )
                    start += length
                }
            }
        }
        var hash: UInt64 = 1_469_598_103_934_665_603
        for value in output { hash = (hash ^ UInt64(value.bitPattern)) &* 1_099_511_628_211 }
        #expect(hash == 6_380_851_796_214_454_577)
    }

    @Test func onlyNeutralSettingsSkipTheTransform() {
        var transform = Transform()
        #expect(bake.dsp.resynthesisTransformIsNeutral(transform))
        transform.stretch = 2
        #expect(!bake.dsp.resynthesisTransformIsNeutral(transform))
        transform = Transform()
        transform.pitch.base = 0.5
        #expect(!bake.dsp.resynthesisTransformIsNeutral(transform))
        transform = Transform()
        let gate: [Float] = [0, 1]
        gate.withUnsafeBufferPointer { transform.freeze.samples = $0.baseAddress; transform.freeze.frames = 2 }
        #expect(!bake.dsp.resynthesisTransformIsNeutral(transform))
    }

    @Test func aNeutralTransformKeepsASine() {
        let input = sine(frequency: 440, frames: 96_000, amplitude: 0.5)
        let output = render(input, extras())
        #expect(abs(amplitude(output, 20_000..<76_000, at: 440) - 0.5) < 0.02)
    }

    // MARK: the extras

    @Test func pitchMovesTheSinesAndTheResidual() {
        let input = sine(frequency: 440, frames: 96_000, amplitude: 0.5)
        let up = render(input, extras { $0.pitch = 12 })
        #expect(abs(amplitude(up, 20_000..<76_000, at: 880) - 0.5) < 0.03)
        #expect(amplitude(up, 20_000..<76_000, at: 440) < 0.02)
        // Low noise (a one-pole low-pass at about 380 Hz): pitched an octave up, its energy moves up the
        // spectrum, so the band above 800 Hz gains on the band below 400 Hz.
        var state: UInt32 = 9
        var level: Float = 0
        let rumble = (0..<96_000).map { _ -> Float in
            state = state &* 1_664_525 &+ 1_013_904_223
            level += 0.05 * ((Float(state >> 8) / 8_388_608 - 1) - level)
            return level
        }
        func brightness(_ signal: [Float]) -> Double {
            func band(_ frequencies: StrideThrough<Double>) -> Double {
                frequencies.reduce(0) { $0 + pow(amplitude(signal, 20_000..<76_000, at: $1), 2) }
            }
            return band(stride(from: 850, through: 1_600, by: 50)) / band(stride(from: 100, through: 400, by: 50))
        }
        let plain = render(rumble, extras(), balance: 1)
        let raised = render(rumble, extras { $0.pitch = 12 }, balance: 1)
        #expect(brightness(raised) > 2 * brightness(plain))
    }

    @Test func stretchLengthensAndKeepsThePitch() {
        let input = sine(frequency: 440, frames: 48_000, amplitude: 0.5)
        let output = render(input, extras { $0.stretch = 2 })
        #expect(output.count == 96_000)
        #expect(abs(amplitude(output, 20_000..<76_000, at: 440) - 0.5) < 0.03)
    }

    @Test func quantizeLandsOnTheScaleAndGlideSlowsIt() {
        // 450 Hz is between A4 (440) and A#4 (466); the nearest note is A.
        let input = sine(frequency: 450, frames: 144_000, amplitude: 0.5)
        let snapped = render(input, extras { $0.quantize = 1 })
        #expect(abs(frequency(snapped, 20_000..<120_000) - 440) < 1)
        // Quantize steps from 0 to 1 at one second; with a 500 ms glide it is still near 450 just after.
        var step = [Float](repeating: 0, count: 144_000)
        for frame in 48_000..<144_000 { step[frame] = 1 }
        let glided = render(input, extras { $0.glide = 500; $0.modulation["quantize"] = step })
        #expect(frequency(glided, 49_000..<53_000) > 446)
        #expect(abs(frequency(glided, 120_000..<140_000) - 440) < 1)
    }

    @Test func freezeHoldsTheMomentAndDecayFadesIt() {
        // A tone for one second, then silence; frozen from 0.8 s on.
        let input = sine(frequency: 440, frames: 48_000, amplitude: 0.5) + [Float](repeating: 0, count: 48_000)
        var gate = [Float](repeating: 0, count: 96_000)
        for frame in 38_400..<96_000 { gate[frame] = 1 }
        let held = render(input, extras { $0.freeze = gate })
        #expect(abs(amplitude(held, 60_000..<90_000, at: 440) - 0.5) < 0.05)
        let fading = render(input, extras { $0.freeze = gate; $0.decay = 20 })
        let early = amplitude(fading, 50_000..<60_000, at: 440), late = amplitude(fading, 80_000..<90_000, at: 440)
        // 30000 frames apart at 20 dB/s: 12.5 dB.
        #expect(abs(20 * log10(early / late) - 12.5) < 1.5)
    }

    @Test func crystallizePullsAPartialOntoAHarmonic() {
        let input = (0..<96_000).map { Float(0.5 * sin(2 * Double.pi * 200 * Double($0) / 48_000) + 0.3 * sin(2 * Double.pi * 430 * Double($0) / 48_000)) }
        let pure = render(input, extras { $0.crystallize = 1 })
        #expect(amplitude(pure, 20_000..<76_000, at: 400) > 0.25)
        #expect(amplitude(pure, 20_000..<76_000, at: 430) < 0.03)
    }

    @Test func phaseRandomizeChangesTheWaveformButNotTheSpectrum() {
        let input = (0..<96_000).map { index in
            Float((1...6).reduce(0.0) { $0 + 0.15 / Double($1) * sin(2 * Double.pi * 200 * Double($1) * Double(index) / 48_000) })
        }
        let plain = render(input, extras())
        let smeared = render(input, extras { $0.phaseRandomize = 1; $0.seed = 5 })
        #expect((20_000..<76_000).map { abs(plain[$0] - smeared[$0]) }.max()! > 0.05)
        for harmonic in 1...4 {
            let frequency = 200.0 * Double(harmonic)
            let a = amplitude(plain, 20_000..<76_000, at: frequency), b = amplitude(smeared, 20_000..<76_000, at: frequency)
            #expect(abs(a - b) / a < 0.1, "harmonic \(harmonic)")
        }
    }

    @Test func chunksOf777MatchOneWholeRender() {
        let input = (0..<72_000).map { Float(0.4 * sin(Double($0) * 0.037)) + Float(($0 * 7_919) % 97) / 4_000 }
        func wave(_ period: Double) -> [Float] { (0..<108_000).map { Float(sin(Double($0) / period)) * 0.5 } }
        var gate = [Float](repeating: 0, count: 108_000)
        for frame in 50_000..<70_000 { gate[frame] = 1 }
        let modulated = extras {
            $0.stretch = 1.5; $0.quantize = 0.5; $0.glide = 80; $0.crystallize = 0.3; $0.phaseRandomize = 0.4; $0.decay = 6
            $0.freeze = gate
            for (index, id) in ["pitch", "crystallize", "quantize", "glide", "decay", "phaseRandomize"].enumerated() {
                $0.modulation[id] = wave(5_000 + Double(index) * 1_300)
            }
        }
        let small = render(input, modulated, balance: 0.5, chunk: 777, settings: settings(fftSize: 2_048, partials: 64))
        let whole = render(input, modulated, balance: 0.5, settings: settings(fftSize: 2_048, partials: 64))
        #expect(small == whole)
    }

    @Test func extremesStayFinite() {
        let input = (0..<48_000).map { Float(sin(Double($0) * 0.4)) * 0.9 }
        let wild = extras { $0.pitch = 24; $0.stretch = 0.25; $0.crystallize = 1; $0.quantize = 1; $0.phaseRandomize = 1 }
        let output = render(input, wild, balance: 0.5)
        let finite = output.allSatisfy { $0.isFinite && abs($0) < 4 }
        #expect(finite && output.count == 12_000)
    }

    // MARK: the second input

    private func tones(_ partials: [(Double, Double)], frames: Int = 96_000) -> [Float] {
        (0..<frames).map { index in
            Float(partials.reduce(0.0) { $0 + $1.1 * sin(2 * Double.pi * $1.0 * Double(index) / 48_000) })
        }
    }

    @Test func crossGivesTheInputsPartialsBsLevels() {
        let input = tones([(400, 0.2), (1_600, 0.2)])
        let b = tones([(400, 0.4), (1_600, 0.05)])
        let crossed = render(input, extras { $0.b = b; $0.mode = .cross })
        #expect(abs(amplitude(crossed, 20_000..<76_000, at: 400) - 0.4) < 0.04)
        #expect(abs(amplitude(crossed, 20_000..<76_000, at: 1_600) - 0.05) < 0.02)
        let half = render(input, extras { $0.b = b; $0.mode = .cross; $0.amount = 0.5 })
        #expect(abs(amplitude(half, 20_000..<76_000, at: 400) - 0.3) < 0.04)
    }

    @Test func morphGlidesEachPartialTowardBs() {
        let input = tones([(400, 0.5)]), b = tones([(600, 0.5)])
        #expect(abs(frequency(render(input, extras { $0.b = b; $0.mode = .morph; $0.amount = 0 }), 20_000..<76_000) - 400) < 1)
        #expect(abs(frequency(render(input, extras { $0.b = b; $0.mode = .morph; $0.amount = 1 }), 20_000..<76_000) - 600) < 1)
        let middle = render(input, extras { $0.b = b; $0.mode = .morph; $0.amount = 0.5 })
        #expect(abs(frequency(middle, 20_000..<76_000) - (400 * 600).squareRoot()) < 2)        // halfway in pitch
        #expect(abs(amplitude(middle, 20_000..<76_000, at: (400 * 600).squareRoot()) - 0.5) < 0.04)   // one partial, no cancelling
    }

    @Test func spliceTakesTheInputBelowAndBAbove() {
        let input = tones([(400, 0.2), (3_000, 0.2)]), b = tones([(500, 0.2), (2_500, 0.2)])
        let spliced = render(input, extras { $0.b = b; $0.mode = .splice; $0.split = 1_000 })
        let range = 20_000..<76_000
        #expect(amplitude(spliced, range, at: 400) > 0.17 && amplitude(spliced, range, at: 2_500) > 0.17)
        #expect(amplitude(spliced, range, at: 3_000) < 0.02 && amplitude(spliced, range, at: 500) < 0.02)
    }

    @Test func swapNoisePutsTheInputsSinesOverBsResidual() {
        let input = tones([(440, 0.4)])
        var state: UInt32 = 3
        let hiss = (0..<96_000).map { _ -> Float in
            state = state &* 1_664_525 &+ 1_013_904_223
            return 0.2 * (Float(state >> 8) / 8_388_608 - 1)
        }
        let range = 20_000..<76_000
        let plain = render(input, extras(), balance: 0.5)
        let swapped = render(input, extras { $0.b = hiss; $0.mode = .swapNoise }, balance: 0.5)
        #expect(abs(amplitude(swapped, range, at: 440) - 0.4) < 0.04)                  // the sine stays
        let noiseOf = { (signal: [Float]) in stride(from: 2_000.0, through: 8_000, by: 500).reduce(0) { $0 + amplitude(signal, range, at: $1) } }
        #expect(noiseOf(swapped) > 10 * noiseOf(plain))                                  // B's hiss arrives
    }

    @Test func theSecondInputChunksTheSame() {
        let input = (0..<60_000).map { Float(0.4 * sin(Double($0) * 0.037)) + Float(($0 * 7_919) % 97) / 4_000 }
        let b = (0..<50_000).map { Float(0.3 * sin(Double($0) * 0.051) + 0.2 * sin(Double($0) * 0.13)) }
        func wave(_ period: Double) -> [Float] { (0..<60_000).map { Float(sin(Double($0) / period)) * 0.5 } }
        for mode in [bake.dsp.ResynthesisMode.cross, .morph, .splice, .swapNoise] {
            let modulated = extras {
                $0.b = b; $0.mode = mode; $0.amount = 0.6; $0.pitch = 2
                $0.modulation["amount"] = wave(4_000); $0.modulation["split"] = wave(7_000)
            }
            let small = render(input, modulated, balance: 0.5, chunk: 777, settings: settings(fftSize: 2_048, partials: 64))
            let whole = render(input, modulated, balance: 0.5, settings: settings(fftSize: 2_048, partials: 64))
            #expect(small == whole, "\(mode)")
        }
    }

    @Test func modeOffOrBUnwiredStaysNeutral() {
        var transform = Transform()
        transform.mode = .cross
        #expect(!bake.dsp.resynthesisTransformIsNeutral(transform))
        #expect(bake.dsp.resynthesisOutputSlots(settings(partials: 64), transform) == 64)
        transform.mode = .morph
        #expect(bake.dsp.resynthesisOutputSlots(settings(partials: 64), transform) == 128)
    }

    // MARK: the node

    @Test func theNodeStretchesEndToEnd() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("source.wav")
        try TestAudio.write(TestAudio.samples(frames: 30_000, channels: 2), to: file, sampleRate: 48_000)
        let output = directory.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var graph = TestProject()
        let audio = graph.add(.audio, asset: sourceAsset)
        var parameters = NodeCatalog.defaultParameters(for: .spectralResynthesis)
        parameters["stretch"] = .number(2)
        parameters["fftSize"] = .choice("2048")
        let resynthesis = graph.add(.spectralResynthesis, parameters)
        let print = graph.add(.print, ["bitDepth": .choice("32f")])
        graph.connect(audio, to: resynthesis)
        graph.connect(resynthesis, to: print)
        let urls = [sourceAsset: file]
        let request = RenderRequest(plan: try compile(graph.project, assetURLs: urls), assetURLs: urls, outputDirectory: output, chunkFrames: 777)
        let rendered = try TestAudio.read(try #require(try await RenderEngine.render(request).outputs[print]))
        #expect(rendered.samples.count == 2 && rendered.samples[0].count == 60_000)
        #expect(rendered.samples[0].allSatisfy(\.isFinite) && rendered.samples[0].contains { abs($0) > 0.01 })
    }

    @Test func theNodeMorphsTowardASecondInputEndToEnd() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("source.wav")
        try TestAudio.write(TestAudio.samples(frames: 30_000, channels: 2), to: file, sampleRate: 48_000)
        let output = directory.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var graph = TestProject()
        let audio = graph.add(.audio, asset: sourceAsset)
        let other = graph.add(.audio, asset: sourceAsset)
        var parameters = NodeCatalog.defaultParameters(for: .spectralResynthesis)
        parameters["mode"] = .choice("morph")
        parameters["amount"] = .number(0.5)
        parameters["fftSize"] = .choice("2048")
        let resynthesis = graph.add(.spectralResynthesis, parameters)
        let print = graph.add(.print, ["bitDepth": .choice("32f")])
        graph.connect(audio, to: resynthesis)
        graph.connect(other, to: resynthesis, "b")
        graph.connect(resynthesis, to: print)
        let urls = [sourceAsset: file]
        let request = RenderRequest(plan: try compile(graph.project, assetURLs: urls), assetURLs: urls, outputDirectory: output, chunkFrames: 777)
        let rendered = try TestAudio.read(try #require(try await RenderEngine.render(request).outputs[print]))
        #expect(rendered.samples.count == 2 && rendered.samples[0].count == 30_000)
        #expect(rendered.samples[0].allSatisfy(\.isFinite) && rendered.samples[0].contains { abs($0) > 0.01 })
    }

    @Test func theExtrasAreInTheCatalog() {
        let definition = NodeCatalog.definition(for: .spectralResynthesis)
        let modulatable = Set(definition.parameters.filter(\.isModulatable).map(\.id))
        #expect(modulatable == ["tilt", "balance", "pitch", "crystallize", "quantize", "glide", "decay", "phaseRandomize", "amount", "split"])
        #expect(NodeCatalog.defaultParameters(for: .spectralResynthesis)["mode"] == .choice("off"))
        #expect(definition.parameter("stretch")?.isModulatable == false)
        // Every extra defaults to doing nothing.
        let defaults = NodeCatalog.defaultParameters(for: .spectralResynthesis)
        #expect(defaults["pitch"] == .number(0) && defaults["stretch"] == .number(1) && defaults["quantize"] == .number(0))
        #expect(defaults["crystallize"] == .number(0) && defaults["phaseRandomize"] == .number(0))
    }
}
