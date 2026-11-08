import BakeDSP
import Foundation
import Testing
@testable import BakeGraph
@testable import BakeRender

/// The Filters node's linear-phase mode: a long FIR, run by FFT convolution, centred so it adds no
/// delay and no phase shift.
struct LinearPhaseTests {
    private typealias Kind = bake.dsp.FilterType
    private let sampleRate = 48_000.0

    /// `cutoffModulation` moves the cutoff (exponential, trim 1 unless `trim` says otherwise). `chunk` renders in pieces.
    private func filter(
        _ type: Kind = .lowpass, taps: Int32 = 1_025, cutoff: Float = 2_000, q: Float = 0.707, drive: Float = 0,
        cutoffModulation: [Float]? = nil, trim: Float = 1, _ input: [Float], chunk: Int? = nil
    ) -> [Float] {
        var output = [Float](repeating: 0, count: input.count)
        let modulation = cutoffModulation ?? []
        let moves = cutoffModulation != nil
        var scratch = [Double](repeating: 0, count: bake.dsp.linearPhaseScratchDoubles(taps, moves))
        input.withUnsafeBufferPointer { source in
            modulation.withUnsafeBufferPointer { modulationPointer in
                output.withUnsafeMutableBufferPointer { destination in
                    var cutoffSignal = signal(cutoff, 20, 20_000, scale: .exponential)
                    if moves {
                        cutoffSignal.modulation = modulationPointer.baseAddress
                        cutoffSignal.modulationFrames = modulationPointer.count
                        cutoffSignal.trim = trim
                    }
                    let size = chunk ?? input.count
                    var start = 0
                    while start < input.count {
                        let count = min(size, input.count - start)
                        bake.dsp.renderLinearPhaseFilter(
                            type, taps, cutoffSignal, signal(q, 0.1, 20), signal(drive, 0, 24), sampleRate,
                            source.baseAddress!, input.count, destination.baseAddress! + start, start, count, &scratch
                        )
                        start += count
                    }
                }
            }
        }
        return output
    }

    private func kernel(_ type: Kind, cutoff: Double, q: Double = 0.707, taps: Int32) -> [Double] {
        let count = Int(bake.dsp.linearPhaseTaps(taps))
        var window = [Double](repeating: 0, count: count)
        var result = [Double](repeating: 0, count: count)
        bake.dsp.kaiserWindow(taps, &window)
        bake.dsp.designLinearPhaseKernel(type, cutoff, q, taps, sampleRate, window, &result)
        return result
    }

    /// Gain of a kernel in dB at `hertz`, by direct evaluation of its transform.
    private func decibels(_ kernel: [Double], at hertz: Double) -> Double {
        let centre = (kernel.count - 1) / 2
        var real = 0.0, imaginary = 0.0
        for (index, tap) in kernel.enumerated() {
            let angle = -2 * Double.pi * hertz / sampleRate * Double(index - centre)
            real += tap * cos(angle)
            imaginary += tap * sin(angle)
        }
        return 20 * log10(max((real * real + imaginary * imaginary).squareRoot(), 1e-12))
    }

    private func noise(_ count: Int, seed: UInt32 = 7) -> [Float] {
        var state = seed
        return (0..<count).map { _ in
            state = state &* 1_664_525 &+ 1_013_904_223
            return Float(state >> 8) / 16_777_216 - 0.5
        }
    }

    // MARK: The kernel

    @Test func theKernelIsSymmetricWithTheRightGainAtDC() {
        for type: Kind in [.lowpass, .highpass, .bandpass, .notch] {
            let h = kernel(type, cutoff: 4_000, q: 2, taps: 1_025)
            #expect(zip(h, h.reversed()).allSatisfy { $0 == $1 }, "\(type)")
            let sum = h.reduce(0, +)
            let expected: Double = (type == .lowpass || type == .notch) ? 1 : 0
            #expect(abs(sum - expected) < 1e-12, "\(type)")
        }
    }

    @Test func aLowpassIsHalfAmplitudeAtItsCutoffAndFlatBelow() {
        let h = kernel(.lowpass, cutoff: 4_000, taps: 4_097)
        #expect(abs(decibels(h, at: 4_000) + 6.0206) < 0.01)
        #expect(abs(decibels(h, at: 1_000)) < 0.01)
        #expect(decibels(h, at: 4_000 + 2 * bake.dsp.linearPhaseTransitionHz(4_097, sampleRate)) < -90)
    }

    @Test func theEdgeIsAsNarrowAsPromised() {
        for taps: Int32 in [1_025, 4_097] {
            let h = kernel(.lowpass, cutoff: 4_000, taps: taps)
            var down1 = 0.0, down90 = 0.0
            var frequency = 3_500.0
            while down90 == 0 && frequency < 5_000 {
                let gain = decibels(h, at: frequency)
                if down1 == 0 && gain < -1 { down1 = frequency }
                if down90 == 0 && gain < -90 { down90 = frequency }
                frequency += 1
            }
            let promised = bake.dsp.linearPhaseTransitionHz(taps, sampleRate)
            #expect(abs((down90 - down1) - promised) < 0.1 * promised, "\(taps) taps: \(down90 - down1) Hz against \(promised) Hz")
        }
    }

    @Test func moreTapsMeanASteeperEdge() {
        let short = bake.dsp.linearPhaseTransitionHz(1_025, sampleRate)
        let long = bake.dsp.linearPhaseTransitionHz(131_073, sampleRate)
        #expect(short > 100 * long)
        #expect(long < 2)
    }

    @Test func qSetsTheWidthOfABandAndIsIgnoredByLowpass() {
        let narrow = kernel(.bandpass, cutoff: 4_000, q: 8, taps: 2_049)
        let wide = kernel(.bandpass, cutoff: 4_000, q: 0.5, taps: 2_049)
        #expect(decibels(narrow, at: 5_000) < decibels(wide, at: 5_000) - 6)
        #expect(kernel(.lowpass, cutoff: 4_000, q: 0.1, taps: 513) == kernel(.lowpass, cutoff: 4_000, q: 20, taps: 513))
    }

    // MARK: Filtering

    @Test func aPassbandSineComesOutUnchangedAndInPhase() {
        let input = sine(frequency: 500, frames: 48_000, amplitude: 0.5)
        let output = filter(taps: 4_097, cutoff: 4_000, input)
        // No delay and no phase shift: the same sample at the same time (away from the ends, where the file begins and stops).
        #expect(zip(output[2_100..<45_900], input[2_100..<45_900]).allSatisfy { abs($0 - $1) < 1e-4 })
    }

    @Test func aStopbandSineDisappears() {
        let input = sine(frequency: 10_000, frames: 48_000, amplitude: 0.5)
        let output = filter(taps: 4_097, cutoff: 2_000, input)
        let before = input[3_000..<45_000].reduce(0) { $0 + $1 * $1 }
        let after = output[3_000..<45_000].reduce(0) { $0 + $1 * $1 }
        #expect(10 * log10(after / before) < -90)
    }

    @Test func theImpulseResponseIsCentredOnTheImpulse() {
        var impulse = [Float](repeating: 0, count: 6_000)
        impulse[3_000] = 1
        let output = filter(taps: 1_025, cutoff: 3_000, impulse)
        #expect(output.firstIndex(of: output.max() ?? 0) == 3_000)
        #expect((1...400).allSatisfy { abs(output[3_000 + $0] - output[3_000 - $0]) < 1e-7 })
    }

    @Test func complementaryPairsAddBackToTheInput() {
        let input = noise(12_000)
        let low = filter(.lowpass, cutoff: 3_000, input), high = filter(.highpass, cutoff: 3_000, input)
        let band = filter(.bandpass, cutoff: 3_000, q: 1, input), notch = filter(.notch, cutoff: 3_000, q: 1, input)
        #expect(zip(zip(low, high), input).allSatisfy { abs($0.0 + $0.1 - $1) < 2e-6 })
        #expect(zip(zip(band, notch), input).allSatisfy { abs($0.0 + $0.1 - $1) < 2e-6 })
    }

    @Test func driveSaturatesTheInputFirst() {
        let input = sine(frequency: 300, frames: 6_000, amplitude: 0.8)
        #expect(filter(taps: 513, cutoff: 8_000, input) != filter(taps: 513, cutoff: 8_000, drive: 18, input))
    }

    // MARK: Chunking and determinism

    @Test func chunkSizeNeverChangesTheResult() {
        let input = noise(30_000)
        let sweep = (0..<30_000).map { Float(sin(2 * Double.pi * 24 * Double($0) / sampleRate)) }
        for taps: Int32 in [257, 1_025, 4_097] {
            for type: Kind in [.lowpass, .notch] {
                let whole = filter(type, taps: taps, q: 1, input)
                #expect(whole == filter(type, taps: taps, q: 1, input, chunk: 777))
                #expect(whole == filter(type, taps: taps, q: 1, input, chunk: 4_096))
                let moving = filter(type, taps: taps, q: 1, cutoffModulation: sweep, trim: 0.4, input)
                #expect(moving == filter(type, taps: taps, q: 1, cutoffModulation: sweep, trim: 0.4, input, chunk: 777))
                #expect(moving == filter(type, taps: taps, q: 1, cutoffModulation: sweep, trim: 0.4, input, chunk: 1_500))
                #expect(moving != whole)
            }
        }
    }

    @Test func rendersAreBitIdentical() {
        let input = noise(8_000)
        #expect(filter(taps: 1_025, input) == filter(taps: 1_025, input))
    }

    // MARK: Moving cutoff

    @Test func aCutoffThatDoesntMoveGivesTheFixedResult() {
        // The cross-faded path with a flat modulation must agree with the single-kernel path.
        let input = noise(20_000)
        let still = [Float](repeating: 0, count: input.count)
        let fixed = filter(taps: 1_025, input)
        let faded = filter(taps: 1_025, cutoffModulation: still, input)
        #expect(zip(fixed, faded).allSatisfy { abs($0 - $1) < 2e-6 })
    }

    @Test func aRisingCutoffLetsMoreThroughLater() {
        let input = noise(48_000)
        let ramp = (0..<input.count).map { Float(-1 + 2 * Double($0) / Double(input.count)) }
        let output = filter(taps: 1_025, cutoff: 1_500, cutoffModulation: ramp, trim: 0.6, input)
        func energy(_ range: Range<Int>) -> Float { output[range].reduce(0) { $0 + $1 * $1 } / Float(range.count) }
        #expect(energy(40_000..<46_000) > 4 * energy(2_000..<8_000))
    }

    // MARK: Settings and extremes

    @Test func everyTypeAndEveryLengthSoundsDifferent() {
        let input = noise(8_000)
        let types: [Kind] = [.lowpass, .highpass, .bandpass, .notch]
        let byType = types.map { filter($0, q: 1, input) }
        for first in byType.indices { for second in byType.indices where second > first { #expect(byType[first] != byType[second]) } }
        let lengths: [Int32] = [1_025, 4_097, 16_385]
        let byLength = lengths.map { filter(taps: $0, cutoff: 3_000, input) }
        for first in byLength.indices { for second in byLength.indices where second > first { #expect(byLength[first] != byLength[second]) } }
    }

    @Test func extremesStayFinite() {
        var input = [Float](repeating: -0.3, count: 4_000)
        for index in stride(from: 0, to: input.count, by: 97) { input[index] = 1 }
        for taps: Int32 in [-5, 1, 64, 65, 66, 4_097] {
            for type: Kind in [.lowpass, .highpass, .bandpass, .notch] {
                for cutoff: Float in [20, 20_000] {
                    for q: Float in [0.1, 20] {
                        #expect(filter(type, taps: taps, cutoff: cutoff, q: q, input).allSatisfy { $0.isFinite })
                    }
                }
            }
        }
        #expect(filter(taps: 65, [Float](repeating: .nan, count: 100)).allSatisfy { $0.isFinite })
        #expect(bake.dsp.linearPhaseTaps(66) == 67 && bake.dsp.linearPhaseTaps(-5) == 65 && bake.dsp.linearPhaseTaps(999_999) == 131_073)
    }

    // MARK: Through the engine

    private func render(_ parameters: [ParameterID: ParameterValue], samples: [[Float]], modulatedBy lfo: Bool = false, directory: URL) async throws -> [[Float]] {
        let source = directory.appendingPathComponent("source.wav")
        try TestAudio.write(samples, to: source, sampleRate: 48_000)
        let output = directory.appendingPathComponent("out-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var graph = TestProject()
        let audio = graph.add(.audio, asset: sourceAsset)
        let filters = graph.add(.filters, parameters)
        let print = graph.add(.print, ["bitDepth": .choice("32f")])
        graph.connect(audio, to: filters)
        if lfo {
            let generator = graph.add(.lfo, ["rate": .number(2)])
            let index = try #require(graph.project.nodes.firstIndex { $0.id == filters })
            graph.project.nodes[index].setModulated("cutoff", true)
            graph.connect(generator, to: filters, "mod.cutoff")
        }
        graph.connect(filters, to: print)
        let urls = [sourceAsset: source]
        let request = RenderRequest(plan: try compile(graph.project, assetURLs: urls), assetURLs: urls, outputDirectory: output)
        return try TestAudio.read(try #require(try await RenderEngine.render(request).outputs[print])).samples
    }

    @Test func minimumPhaseIsStillTheBiquadFilter() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let samples = TestAudio.samples(frames: 6_000, channels: 2)
        let rendered = try await render(["type": .choice("lowpass"), "cutoff": .number(900), "phase": .choice("minimum")], samples: samples, directory: directory)
        for channel in 0..<2 {
            var state = bake.dsp.FilterState()
            var expected = [Float](repeating: 0, count: samples[channel].count)
            samples[channel].withUnsafeBufferPointer { source in
                expected.withUnsafeMutableBufferPointer { destination in
                    bake.dsp.renderFilter(&state, .lowpass, 2, signal(900, 20, 20_000, scale: .exponential), signal(0.707, 0.1, 20), signal(0, 0, 24), 48_000, source.baseAddress!, destination.baseAddress!, 0, samples[channel].count)
                }
            }
            #expect(rendered[channel] == expected)
        }
    }

    @Test func linearPhaseHasNoDelayThroughTheEngine() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var impulse = [Float](repeating: 0, count: 8_000)
        impulse[4_000] = 1
        let rendered = try await render(["phase": .choice("linear"), "firTaps": .choice("1025"), "cutoff": .number(3_000)], samples: [impulse], directory: directory)
        #expect(rendered.count == 1 && rendered[0].count == 8_000)
        #expect(rendered[0].firstIndex(of: rendered[0].max() ?? 0) == 4_000)
        #expect((1...300).allSatisfy { abs(rendered[0][4_000 + $0] - rendered[0][4_000 - $0]) < 1e-6 })
    }

    @Test func thePhaseAndLengthSettingsChangeTheEngineRender() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let samples = TestAudio.samples(frames: 20_000, channels: 1)
        let minimum = try await render(["cutoff": .number(2_000)], samples: samples, directory: directory)
        let linear = try await render(["cutoff": .number(2_000), "phase": .choice("linear")], samples: samples, directory: directory)
        let longer = try await render(["cutoff": .number(2_000), "phase": .choice("linear"), "firTaps": .choice("16385")], samples: samples, directory: directory)
        #expect(minimum != linear && linear != longer)
        #expect(linear[0].count == 20_000 && longer[0].allSatisfy { $0.isFinite })
    }

    @Test func aLinearPhaseFilterTakesCutoffModulationThroughTheEngine() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let samples = TestAudio.samples(frames: 30_000, channels: 2)
        let settings: [ParameterID: ParameterValue] = ["cutoff": .number(1_500), "phase": .choice("linear"), "firTaps": .choice("1025")]
        let fixed = try await render(settings, samples: samples, directory: directory)
        let swept = try await render(settings, samples: samples, modulatedBy: true, directory: directory)
        #expect(swept.count == 2 && swept.allSatisfy { $0.count == 30_000 && $0.allSatisfy { $0.isFinite } })
        #expect(fixed != swept)
    }

    @Test func theCatalogOffersTheNewSettings() throws {
        let definition = NodeCatalog.definition(for: .filters)
        let phase = try #require(definition.parameter("phase"))
        #expect(phase.role == .macro && phase.defaultValue == .choice("minimum"))
        let taps = try #require(definition.parameter("firTaps"))
        #expect(taps.role == .setting && taps.defaultValue == .choice("4097"))
        guard case .choice(let options, _) = taps.kind else { Issue.record("firTaps is not a choice"); return }
        #expect(options.last == "131073")
    }
}
