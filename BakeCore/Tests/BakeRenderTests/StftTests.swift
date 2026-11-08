import BakeDSP
import Foundation
import Testing

/// The reference STFT that the Metal spectral kernels will be tested against: audio as a matrix of
/// frames by bins, and back again.
struct StftTests {
    private typealias Layout = bake.dsp.StftLayout

    private func noise(_ count: Int, seed: UInt32 = 5) -> [Float] {
        var state = seed
        return (0..<count).map { _ in
            state = state &* 1_664_525 &+ 1_013_904_223
            return Float(state >> 8) / 16_777_216 - 0.5
        }
    }

    private func analyse(_ layout: Layout, _ input: [Float], first: Int = 0, count: Int? = nil) -> [Float] {
        let frames = count ?? bake.dsp.stftFrameCount(layout, input.count)
        var spectrum = [Float](repeating: 0, count: bake.dsp.stftSpectrumFloats(layout, frames))
        var scratch = [Double](repeating: 0, count: bake.dsp.stftScratchDoubles(layout))
        bake.dsp.stftForward(layout, input, input.count, first, frames, &spectrum, &scratch)
        return spectrum
    }

    /// Spectrum rows → time-domain rows → overlap-added samples `start..<start+count` using only the covering frames.
    private func synthesise(_ layout: Layout, _ spectrum: [Float], signalFrames: Int, start: Int, count: Int) -> [Float] {
        let range = bake.dsp.stftFramesCovering(layout, signalFrames, start, count)
        let bins = bake.dsp.stftBinCount(layout)
        var window = [Double](repeating: 0, count: Int(layout.fftSize))
        bake.dsp.stftWindow(layout, &window)
        var scratch = [Double](repeating: 0, count: bake.dsp.stftScratchDoubles(layout))
        var rows = [Float](repeating: 0, count: bake.dsp.stftRowFloats(layout, range.count))
        let slice = Array(spectrum[(range.first * bins * 2)..<((range.first + range.count) * bins * 2)])
        bake.dsp.stftInverseRows(layout, slice, range.count, &rows, &scratch)
        var output = [Float](repeating: 0, count: count)
        bake.dsp.stftOverlapAdd(layout, window, rows, range.first, range.count, signalFrames, start, count, &output)
        return output
    }

    // MARK: Layout

    @Test func layoutsAreValidatedAndCounted() {
        let layout = Layout(fftSize: 1_024, hop: 256)
        #expect(bake.dsp.stftLayoutIsValid(layout))
        #expect(!bake.dsp.stftLayoutIsValid(Layout(fftSize: 1_000, hop: 250)))   // not a power of two
        #expect(!bake.dsp.stftLayoutIsValid(Layout(fftSize: 1_024, hop: 300)))   // hop doesn't divide half a window
        #expect(!bake.dsp.stftLayoutIsValid(Layout(fftSize: 1_024, hop: 600)))
        #expect(!bake.dsp.stftLayoutIsValid(Layout(fftSize: 32, hop: 8)))        // too small
        #expect(bake.dsp.stftBinCount(layout) == 513 && bake.dsp.stftOverlap(layout) == 4)
        #expect(bake.dsp.stftFrameCount(layout, 0) == 0 && bake.dsp.stftFrameCount(layout, 1) == 4)
        #expect(bake.dsp.stftFrameCount(layout, 1_000) == 3 + 4)
        #expect(bake.dsp.stftFrameCenter(layout, 0) == -256 && bake.dsp.stftFrameCenter(layout, 1) == 0)
    }

    @Test func everyRealSampleHasTheFullOverlap() {
        let layout = Layout(fftSize: 1_024, hop: 256)
        for sample in [0, 1, 255, 256, 4_999] {
            let range = bake.dsp.stftFramesCovering(layout, 5_000, sample, 1)
            #expect(range.count == 4, "sample \(sample)")
        }
        let all = bake.dsp.stftFramesCovering(layout, 5_000, 0, 5_000)
        #expect(all.first == 0 && all.count == bake.dsp.stftFrameCount(layout, 5_000))
        #expect(bake.dsp.stftFramesCovering(layout, 0, 0, 10).count == 0)
        #expect(bake.dsp.stftFramesCovering(layout, 100, 5, 0).count == 0)
    }

    // MARK: Reconstruction

    @Test func analysisThenSynthesisGivesTheInputBack() {
        for fftSize: Int32 in [256, 1_024, 4_096] {
            for divisor: Int32 in [2, 4, 8] {
                let layout = Layout(fftSize: fftSize, hop: fftSize / divisor)
                for length in [1, 257, 5_000, 12_345] {
                    let input = noise(length)
                    let spectrum = analyse(layout, input)
                    let output = synthesise(layout, spectrum, signalFrames: length, start: 0, count: length)
                    #expect(zip(input, output).allSatisfy { abs($0 - $1) < 2e-6 }, "N=\(fftSize) hop=\(fftSize / divisor) length \(length)")
                }
            }
        }
    }

    @Test func anySampleRangeNeedsOnlyItsCoveringFrames() {
        let layout = Layout(fftSize: 1_024, hop: 256)
        let input = noise(10_000)
        let spectrum = analyse(layout, input)
        let whole = synthesise(layout, spectrum, signalFrames: input.count, start: 0, count: input.count)
        for (start, count) in [(0, 1), (0, 700), (3_000, 777), (9_500, 500), (9_999, 1), (1_234, 5_000)] {
            #expect(synthesise(layout, spectrum, signalFrames: input.count, start: start, count: count) == Array(whole[start..<start + count]))
        }
    }

    @Test func framesAreIndependentSoAnySplitGivesTheSameNumbers() {
        let layout = Layout(fftSize: 1_024, hop: 256)
        let input = noise(9_000)
        let frames = bake.dsp.stftFrameCount(layout, input.count)
        let whole = analyse(layout, input)
        var pieces: [Float] = []
        var first = 0
        while first < frames {
            let count = min(7, frames - first)
            pieces += analyse(layout, input, first: first, count: count)
            first += count
        }
        #expect(whole == pieces)
    }

    // MARK: What a spectrum means

    @Test func aSineLandsInItsOwnBinAtTheExpectedHeight() {
        let layout = Layout(fftSize: 4_096, hop: 1_024)
        let bin = 187
        let hertz = Double(bin) * 48_000 / 4_096
        let input = sine(frequency: hertz, frames: 48_000, amplitude: 0.5)
        let spectrum = analyse(layout, input)
        let bins = bake.dsp.stftBinCount(layout)
        let frame = 20
        let magnitudes = (0..<bins).map { Double(hypot(spectrum[(frame * bins + $0) * 2], spectrum[(frame * bins + $0) * 2 + 1])) }
        #expect(magnitudes.firstIndex(of: magnitudes.max() ?? 0) == bin)
        #expect(abs((magnitudes[bin]) - 0.5 * 4_096 / 4) < 0.5)    // a Hann window reads A·N/4
    }

    @Test func zeroingBinsFiltersTheSignal() {
        let layout = Layout(fftSize: 2_048, hop: 512)
        let input = (0..<48_000).map { Float(0.4 * sin(2 * Double.pi * 500 * Double($0) / 48_000) + 0.4 * sin(2 * Double.pi * 6_000 * Double($0) / 48_000)) }
        let frames = bake.dsp.stftFrameCount(layout, input.count)
        let bins = bake.dsp.stftBinCount(layout)
        var spectrum = analyse(layout, input)
        let gains = (0..<frames * bins).map { Float(Double($0 % bins) * 48_000 / 2_048 > 2_000 ? 0 : 1) }
        bake.dsp.stftApplyGains(&spectrum, frames, bins, gains)
        let output = synthesise(layout, spectrum, signalFrames: input.count, start: 0, count: input.count)
        var error = 0.0, wanted = 0.0
        for index in 4_000..<44_000 {
            let low = 0.4 * sin(2 * Double.pi * 500 * Double(index) / 48_000)
            error += (Double(output[index]) - low) * (Double(output[index]) - low)
            wanted += low * low
        }
        #expect(10 * log10(error / wanted) < -60)
    }

    // MARK: Bands as a matrix multiply

    @Test func triangularBandsAddUpToOneBetweenTheirEnds() {
        let layout = Layout(fftSize: 4_096, hop: 1_024)
        let bins = bake.dsp.stftBinCount(layout), bands = 32
        var matrix = [Float](repeating: 0, count: bands * bins)
        bake.dsp.stftTriangularBands(layout, 48_000, bands, 100, 12_000, &matrix)
        for bin in 0..<bins {
            let hertz = Double(bin) * 48_000 / 4_096
            guard hertz >= 100, hertz <= 12_000 else { continue }
            let sum = (0..<bands).reduce(Float(0)) { $0 + matrix[$1 * bins + bin] }
            #expect(abs(sum - 1) < 1e-5, "\(hertz) Hz")
        }
    }

    @Test func aToneEnergisesItsOwnBand() {
        let layout = Layout(fftSize: 4_096, hop: 1_024)
        let bins = bake.dsp.stftBinCount(layout), bands = 32
        var matrix = [Float](repeating: 0, count: bands * bins)
        bake.dsp.stftTriangularBands(layout, 48_000, bands, 100, 12_000, &matrix)
        let input = sine(frequency: 2_000, frames: 48_000, amplitude: 0.5)
        let spectrum = analyse(layout, input)
        let frames = bake.dsp.stftFrameCount(layout, input.count)
        var magnitudes = [Float](repeating: 0, count: frames * bins)
        bake.dsp.stftMagnitudes(spectrum, frames, bins, &magnitudes)
        var energy = [Float](repeating: 0, count: frames * bands)
        bake.dsp.stftApplyBands(magnitudes, frames, bins, matrix, bands, &energy)
        let row = Array(energy[(20 * bands)..<(21 * bands)])
        let best = row.firstIndex(of: row.max() ?? 0) ?? 0
        let centre = exp(log(100) + (log(12_000) - log(100)) * Double(best) / Double(bands - 1))
        #expect(abs(centre - 2_000) < 400)
    }

    // MARK: Safety

    @Test func nonFiniteInputStaysFinite() {
        let layout = Layout(fftSize: 256, hop: 64)
        #expect(analyse(layout, [Float](repeating: .nan, count: 100)).allSatisfy { $0.isFinite })
    }
}
