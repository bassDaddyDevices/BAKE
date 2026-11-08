import BakeDSP
import Foundation
import Testing
@testable import BakeGraph
@testable import BakeRender

/// The Vocoder kernel (BakeDSP/Vocoder.h) and the node around it.
struct VocoderTests {
    private typealias Settings = bake.dsp.VocoderSettings
    private let sampleRate = 48_000.0

    private func noise(_ count: Int, amplitude: Float, seed: UInt32) -> [Float] {
        var state = seed
        return (0..<count).map { _ in
            state = state &* 1_664_525 &+ 1_013_904_223
            return amplitude * (Float(state >> 8) / 8_388_608 - 1)
        }
    }

    private func settings(
        bands: Int32 = 32, spacing: bake.dsp.VocoderSpacing = .logarithmic,
        attack: Double = 10, release: Double = 80, sibilance: Double = 0
    ) -> Settings {
        var settings = Settings()
        settings.bands = bands
        settings.spacing = spacing
        settings.attackMilliseconds = attack
        settings.releaseMilliseconds = release
        settings.sibilance = sibilance
        return settings
    }

    private func vocode(
        _ settings: Settings, carrier: [Float], modulator: [Float],
        shift: Float = 0, mix: Float = 1, chunk: Int? = nil
    ) -> [Float] {
        let count = carrier.count
        let maxCount = chunk ?? count
        var scratch = [Double](repeating: 0, count: Int(bake.dsp.vocoderScratchDoubles(settings)))
        var envelope = [Float](repeating: 0, count: Int(bake.dsp.vocoderEnvelopeFloats(settings, count)))
        var analysisWork = [Float](repeating: 0, count: Int(bake.dsp.vocoderAnalysisWorkFloats()))
        var work = [Float](repeating: 0, count: Int(bake.dsp.vocoderWorkFloats(maxCount)))
        var output = [Float](repeating: 0, count: count)
        let shiftSignal = signal(shift, -12, 12)
        let mixSignal = signal(mix, 0, 1)
        modulator.withUnsafeBufferPointer { modulatorPointer in
            bake.dsp.vocoderAnalyseModulator(settings, sampleRate, modulatorPointer.baseAddress!, count, &envelope, &scratch, &analysisWork)
            carrier.withUnsafeBufferPointer { carrierPointer in
                output.withUnsafeMutableBufferPointer { outputPointer in
                    var start = 0
                    while start < count {
                        let length = min(maxCount, count - start)
                        bake.dsp.vocoderRender(
                            settings, sampleRate, shiftSignal, mixSignal,
                            carrierPointer.baseAddress!, modulatorPointer.baseAddress!, count, envelope,
                            outputPointer.baseAddress! + start, start, length, &scratch, &work
                        )
                        start += length
                    }
                }
            }
        }
        return output
    }

    private func rms(_ signal: [Float], _ range: Range<Int>) -> Float {
        let sum = signal[range].reduce(0.0) { $0 + Double($1) * Double($1) }
        return Float((sum / Double(range.count)).squareRoot())
    }

    /// Summed Goertzel power over a grid of frequencies from `low` to `high`.
    private func energy(_ signal: [Float], _ range: Range<Int>, from low: Double, to high: Double) -> Double {
        var total = 0.0
        var frequency = low
        while frequency < high {
            let w = 2 * Double.pi * frequency / sampleRate
            var s1 = 0.0
            var s2 = 0.0
            for index in range {
                let s = Double(signal[index]) + 2 * cos(w) * s1 - s2
                s2 = s1
                s1 = s
            }
            total += s1 * s1 + s2 * s2 - 2 * cos(w) * s1 * s2
            frequency += low * 0.05 + 10
        }
        return total
    }

    /// Noise through a resonant band-pass at `frequency`, scaled up to a usable level.
    private func bandNoise(_ count: Int, around frequency: Double) -> [Float] {
        let w = 2 * Double.pi * frequency / sampleRate
        let alpha = sin(w) / 16
        let (b0, b2, a0, a1, a2) = (alpha, -alpha, 1 + alpha, -2 * cos(w), 1 - alpha)
        var (x1, x2, y1, y2) = (0.0, 0.0, 0.0, 0.0)
        return noise(count, amplitude: 1, seed: 11).map { sample in
            let x = Double(sample)
            let y = (b0 * x + b2 * x2 - a1 * y1 - a2 * y2) / a0
            (x2, x1, y2, y1) = (x1, x, y1, y)
            return Float(4 * y)
        }
    }

    private let frames = 144_000

    @Test func theModulatorSetsTheLevelOfANoiseCarrier() {
        let modulator = noise(frames, amplitude: 0.4, seed: 2)
        let output = vocode(settings(), carrier: noise(frames, amplitude: 0.8, seed: 1), modulator: modulator)
        let ratio = rms(output, 24_000..<(frames - 24_000)) / rms(modulator, 24_000..<(frames - 24_000))
        #expect(ratio > 0.85 && ratio < 1.15)
    }

    @Test func aSilentModulatorGivesSilence() {
        let output = vocode(settings(), carrier: noise(frames, amplitude: 0.8, seed: 1), modulator: [Float](repeating: 0, count: frames))
        #expect(output.allSatisfy { abs($0) < 1e-6 })
    }

    @Test func aBandLimitedModulatorKeepsTheEnergyInThatBand() {
        let modulator = bandNoise(frames, around: 1_000)
        let output = vocode(settings(), carrier: noise(frames, amplitude: 0.8, seed: 1), modulator: modulator)
        let window = 72_000..<80_000
        let inBand = energy(output, window, from: 800, to: 1_250)
        let above = energy(output, window, from: 3_000, to: 6_000)
        #expect(inBand > 20 * above)
    }

    @Test func formantShiftMovesTheEnvelopeByTheInterval() {
        let carrier = noise(frames, amplitude: 0.8, seed: 1)
        let modulator = bandNoise(frames, around: 1_000)
        let window = 72_000..<80_000
        let up = vocode(settings(), carrier: carrier, modulator: modulator, shift: 12)
        #expect(energy(up, window, from: 1_600, to: 2_500) > 5 * energy(up, window, from: 800, to: 1_250))
        let down = vocode(settings(), carrier: carrier, modulator: modulator, shift: -12)
        #expect(energy(down, window, from: 400, to: 625) > 5 * energy(down, window, from: 800, to: 1_250))
    }

    @Test func anyChunkSizeGivesTheSameBits() {
        let carrier = noise(frames, amplitude: 0.8, seed: 1)
        let modulator = noise(frames, amplitude: 0.4, seed: 2)
        let configured = settings(bands: 48, spacing: .bark, sibilance: 0.7)
        let whole = vocode(configured, carrier: carrier, modulator: modulator, shift: 3.5, mix: 0.8)
        #expect(vocode(configured, carrier: carrier, modulator: modulator, shift: 3.5, mix: 0.8, chunk: 777) == whole)
        #expect(vocode(configured, carrier: carrier, modulator: modulator, shift: 3.5, mix: 0.8, chunk: 1_025) == whole)
    }

    @Test func mixZeroIsTheCarrierUntouched() {
        let carrier = noise(frames, amplitude: 0.8, seed: 1)
        #expect(vocode(settings(), carrier: carrier, modulator: noise(frames, amplitude: 0.4, seed: 2), mix: 0) == carrier)
    }

    @Test func releaseLengthensTheTailAfterABurst() {
        var burst = [Float](repeating: 0, count: frames)
        for (offset, sample) in noise(2_000, amplitude: 0.5, seed: 3).enumerated() { burst[40_000 + offset] = sample }
        let carrier = noise(frames, amplitude: 0.8, seed: 1)
        let fast = vocode(settings(release: 5), carrier: carrier, modulator: burst)
        let slow = vocode(settings(release: 2_000), carrier: carrier, modulator: burst)
        #expect(rms(slow, 60_000..<70_000) > 3 * rms(fast, 60_000..<70_000))
    }

    @Test func sibilanceBringsBackHighFrequencyNoise() {
        // A low sine has nothing up high for the envelope to scale; only sibilance can add it.
        let carrier = sine(frequency: 200, frames: frames)
        let modulator = noise(frames, amplitude: 0.4, seed: 2)
        let off = vocode(settings(sibilance: 0), carrier: carrier, modulator: modulator)
        let on = vocode(settings(sibilance: 1), carrier: carrier, modulator: modulator)
        let window = 72_000..<80_000
        #expect(energy(on, window, from: 5_000, to: 8_000) > 50 * energy(off, window, from: 5_000, to: 8_000) + 1)
    }

    @Test func everySpacingSoundsDifferentAndExtremesStayFinite() {
        let carrier = noise(frames, amplitude: 0.8, seed: 1)
        let modulator = noise(frames, amplitude: 0.4, seed: 2)
        let reference = vocode(settings(), carrier: carrier, modulator: modulator)
        for spacing in [bake.dsp.VocoderSpacing.linear, .bark, .mel] {
            let other = vocode(settings(spacing: spacing), carrier: carrier, modulator: modulator)
            #expect(zip(other, reference).contains { abs($0 - $1) > 1e-3 })
        }
        let extreme = vocode(settings(bands: 256, attack: 1, release: 2_000, sibilance: 1), carrier: carrier, modulator: modulator, shift: 12, chunk: 777)
        #expect(extreme.allSatisfy { $0.isFinite })
        let fewest = vocode(settings(bands: 16, attack: 1, release: 2_000, sibilance: 1), carrier: carrier, modulator: modulator, shift: -12, chunk: 777)
        #expect(fewest.allSatisfy { $0.isFinite })
    }

    @Test func bandCentresRunFromEightyHertzToSixteenKilohertz() {
        for spacing in [bake.dsp.VocoderSpacing.logarithmic, .linear, .bark, .mel] {
            let configured = settings(spacing: spacing)
            var centres = [Double](repeating: 0, count: Int(configured.bands))
            bake.dsp.vocoderBandCenters(configured, sampleRate, &centres)
            #expect(abs(centres[0] - 80) < 0.5)
            #expect(abs(centres[centres.count - 1] - 16_000) < 1)
            #expect(zip(centres, centres.dropFirst()).allSatisfy { $0 < $1 })
        }
    }

    @Test func theBandMatrixSharesEveryBinBetweenTwoBands() {
        let configured = settings()
        let bins = Int(bake.dsp.stftBinCount(bake.dsp.vocoderLayout()))
        var matrix = [Float](repeating: 0, count: Int(configured.bands) * bins)
        bake.dsp.vocoderBandMatrix(configured, sampleRate, &matrix)
        for bin in 0..<bins {
            let column = (0..<Int(configured.bands)).map { matrix[$0 * bins + bin] }
            #expect(abs(column.reduce(0, +) - 1) < 1e-5)
            #expect(column.filter { $0 > 0 }.count <= 2)
        }
    }
}

/// The Vocoder node end to end.
struct VocoderNodeTests {
    private let modulatorAsset = AssetID(testUUID(9_400))

    private func makePatch(in directory: URL, carrierChannels: Int = 1, frames: Int = 60_000) throws -> (Patch, NodeID) {
        var patch = Patch()
        try patch.source(sourceAsset, channels: carrierChannels, frames: frames, in: directory)
        let url = directory.appendingPathComponent("modulator.wav")
        var state: UInt32 = 77
        let modulator = (0..<frames).map { _ -> Float in
            state = state &* 1_664_525 &+ 1_013_904_223
            return 0.4 * (Float(state >> 8) / 8_388_608 - 1)
        }
        try TestAudio.write([modulator], to: url, sampleRate: 48_000)
        patch.assets[modulatorAsset] = url
        let carrier = patch.graph.add(.audio, asset: sourceAsset)
        let modulatorNode = patch.graph.add(.audio, asset: modulatorAsset)
        let vocoder = patch.graph.add(.vocoder)
        patch.wire(carrier, "out", to: vocoder, "carrier")
        patch.wire(modulatorNode, "out", to: vocoder, "modulator")
        return (patch, vocoder)
    }

    @Test func rendersTheCarriersLengthAndChannels() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var (patch, vocoder) = try makePatch(in: directory, carrierChannels: 2)
        patch.bake("vocoded", from: vocoder)

        let output = try #require(try await patch.render(in: directory)["vocoded"])

        #expect(output.count == 2)
        #expect(output.allSatisfy { $0.count == 60_000 })
        #expect(output.allSatisfy { $0.allSatisfy { $0.isFinite } })
        #expect(output[0].contains { abs($0) > 0.01 })
    }

    @Test func chunkSizeDoesNotChangeTheBake() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var (patch, vocoder) = try makePatch(in: directory)
        patch.bake("vocoded", from: vocoder)

        let small = try #require(try await patch.render(in: directory, chunkFrames: 777)["vocoded"])
        let large = try #require(try await patch.render(in: directory, chunkFrames: 65_536)["vocoded"])

        #expect(small == large)
    }

    @Test func bothInputsAreRequired() {
        let definition = NodeCatalog.definition(for: .vocoder)
        #expect(definition.pins.filter { $0.direction == .input }.allSatisfy { $0.isRequired })
        #expect(definition.pins.filter { $0.direction == .input }.map(\.id) == ["carrier", "modulator"])
        #expect(definition.lengthRule == .sameAsInput("carrier"))
    }
}

/// The card's band positions are the kernel's.
struct VocoderPlotTests {
    @Test(arguments: ["logarithmic", "linear", "bark", "mel"])
    func theSwiftCentresMatchTheKernel(spacing: String) {
        let spacingValue: bake.dsp.VocoderSpacing = switch spacing {
        case "linear": .linear
        case "bark": .bark
        case "mel": .mel
        default: .logarithmic
        }
        var settings = bake.dsp.VocoderSettings()
        settings.bands = 40
        settings.spacing = spacingValue
        var kernel = [Double](repeating: 0, count: 40)
        bake.dsp.vocoderBandCenters(settings, 48_000, &kernel)
        let plot = VocoderPlot.centres(bands: 40, spacing: spacing, sampleRate: 48_000)
        #expect(plot.count == 40)
        #expect(zip(plot, kernel).allSatisfy { abs($0 - $1) <= 1e-6 * $1 })
    }
}
