import BakeDSP
import BakeGraph
import Foundation
import Testing
@testable import BakeRender

/// Ensemble Averager's bin averages, Griffin-Lim and render, from known answers.
struct EnsembleAveragerTests {
    private let rate = 48_000.0

    private func bin(_ values: [Double], _ mode: bake.dsp.AverageMode, trim: Double = 0) -> Double {
        var values = values
        return bake.dsp.ensembleBin(&values, values.count, mode, trim)
    }

    @Test func theBinAveragesGiveTheirKnownAnswers() {
        #expect(bin([1, 2, 6], .mean) == 3)
        #expect(bin([1, 2, 100], .median) == 2)
        #expect(bin([4, 1, 3, 2], .median) == 2.5)
        #expect(bin([1, 2, 100], .mean, trim: 0.34) == 2)
        #expect(bin([1, 2, 100], .mean, trim: 0.3) == 103.0 / 3)  // 30 % of 3 rounds down to none
        #expect(abs(bin([1, 4], .geometric) - 2) < 1e-12)
        #expect(bin([0, 4], .geometric) == 0)
    }

    @Test func moreGriffinLimRoundsNeverRaiseTheSpectralError() {
        var layout = bake.dsp.StftLayout()
        layout.fftSize = 512
        layout.hop = 128
        let frames = 6_000
        let signal: [Float] = (0..<frames).map { Float(sin(Double($0) * 0.05) * 0.5 + sin(Double($0) * 0.31) * 0.3) }
        let frameCount = bake.dsp.stftFrameCount(layout, frames)
        let bins = bake.dsp.stftBinCount(layout)
        var scratch = [Double](repeating: 0, count: bake.dsp.ensembleScratchDoubles(layout))
        var spectrum = [Float](repeating: 0, count: bake.dsp.stftSpectrumFloats(layout, frameCount))
        var target = [Float](repeating: 0, count: frameCount * bins)
        bake.dsp.stftForward(layout, signal, frames, 0, frameCount, &spectrum, &scratch)
        bake.dsp.stftMagnitudes(spectrum, frameCount, bins, &target)

        func error(after iterations: Int) -> Double {
            // Start from a scrambled phase, the same for every count.
            var start = [Float](repeating: 0, count: spectrum.count)
            for i in 0..<(start.count / 2) {
                let phase = Double(ScatterSchedule.hash(UInt64(i)) >> 11) * 0x1.0p-53 * 2 * .pi
                start[2 * i] = Float(cos(phase))
                start[2 * i + 1] = Float(sin(phase))
            }
            var rows = [Float](repeating: 0, count: bake.dsp.stftRowFloats(layout, frameCount))
            var out = [Float](repeating: 0, count: frames)
            bake.dsp.ensembleGriffinLim(layout, target, &start, frameCount, frames, iterations, &rows, &out, &scratch)
            var again = [Float](repeating: 0, count: spectrum.count)
            var magnitudes = [Float](repeating: 0, count: target.count)
            bake.dsp.stftForward(layout, out, frames, 0, frameCount, &again, &scratch)
            bake.dsp.stftMagnitudes(again, frameCount, bins, &magnitudes)
            return zip(magnitudes, target).reduce(0) { $0 + Double(($1.0 - $1.1) * ($1.0 - $1.1)) }
        }
        let errors = [0, 1, 2, 4, 8, 16].map(error(after:))
        #expect(zip(errors.dropFirst(), errors).allSatisfy { $0 <= $1 * (1 + 1e-6) })
        #expect(errors.last! < errors.first! * 0.5)
    }

    // MARK: Render

    /// A decaying chord: something with a spectrum worth averaging.
    private var clip: [Float] {
        (0..<12_000).map { i in
            let t = Double(i) / rate
            return Float(exp(-t * 8) * (0.4 * sin(2 * .pi * 220 * t) + 0.2 * sin(2 * .pi * 1_330 * t) + 0.1 * sin(2 * .pi * 4_100 * t)))
        }
    }

    private func average(_ clips: [[[Float]]], _ parameters: [ParameterID: ParameterValue] = [:]) throws -> [[Float]] {
        let folder = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let urls = try clips.enumerated().map { index, channels in
            let url = folder.appending(path: "capture \(index).wav")
            try TestAudio.write(channels, to: url, sampleRate: rate)
            return url
        }
        let output = folder.appending(path: "average.wav")
        let all = NodeCatalog.defaultParameters(for: .ensembleAverager).merging(parameters) { $1 }
        try EnsembleAverager.render(urls, parameters: all, sampleRate: rate, to: output)
        return try TestAudio.read(output).samples
    }

    private func scaled(_ gain: Float) -> [[Float]] { [clip.map { $0 * gain }] }

    /// The largest difference from `expected`, as a fraction of its peak.
    private func error(_ output: [Float], _ expected: [Float]) -> Float {
        let peak = expected.map(abs).max() ?? 1
        return zip(output, expected).map { abs($0 - $1) }.max()! / peak
    }

    @Test func copiesOfOneClipAverageToThatClip() throws {
        let out = try average([scaled(1), scaled(1), scaled(1), scaled(1)])
        #expect(out.count == 1 && out[0].count == clip.count)
        #expect(error(out[0], clip) < 1e-4)
    }

    @Test func eachAveragingGivesItsKnownGain() throws {
        #expect(error(try average([scaled(1), scaled(3)], ["mode": .choice("mean")])[0], scaled(2)[0]) < 1e-4)
        let outlier = [scaled(0.1), scaled(0.2), scaled(10)]
        #expect(error(try average(outlier, ["mode": .choice("median")])[0], scaled(0.2)[0]) < 1e-4)
        #expect(error(try average(outlier, ["mode": .choice("mean"), "trim": .number(34)])[0], scaled(0.2)[0]) < 1e-4)
        #expect(error(try average([scaled(1), scaled(4)], ["mode": .choice("geometric")])[0], scaled(2)[0]) < 1e-4)
    }

    @Test func stereoStaysStereoOnlyWhenEveryCaptureIsStereo() throws {
        let stereo = [clip, clip.map { $0 * 0.5 }]
        #expect(try average([stereo, stereo]).count == 2)
        #expect(try average([stereo, scaled(1)]).count == 1)
    }

    @Test func onsetAndPeakLineUpCopiesAndTrimTheLeadInTheyShare() throws {
        let early = [[Float](repeating: 0, count: 4_800) + clip]
        let late = [[Float](repeating: 0, count: 9_600) + clip]  // 100 ms later
        // Both line the copies up, then drop all but 5 ms (240 frames) of the silence they share. The clip's own
        // first sample is sin 0 = 0, so 239 frames of padding plus it make the 240 before the first sound.
        let expected = [Float](repeating: 0, count: 239) + clip
        for mode in ["onset", "peak"] {
            let lined = try average([early, late], ["align": .choice(mode)])
            #expect(lined[0].count == expected.count, "\(mode)")
            #expect(error(lined[0], expected) < 1e-3, "\(mode)")
        }
        // Start moves and trims nothing.
        let unaligned = try average([early, late], ["align": .choice("start")])
        #expect(unaligned[0].count == late[0].count)
        #expect(unaligned[0].map(abs).max()! < 0.8 * clip.map(abs).max()!)
    }

    @Test func onsetLinesUpWhereSoundsStartNotWhereTheyPeak() {
        // A slow attack peaking 20 ms in, and a sharp hit peaking at once, both starting at frame 1 000.
        let rate = 48_000.0
        let slow: [Float] = [Float](repeating: 0, count: 1_000) + (0..<4_800).map { i in Float(min(1, Double(i) / 960) * exp(-Double(max(0, i - 960)) / rate * 20)) }
        let sharp: [Float] = [Float](repeating: 0, count: 1_000) + (0..<4_800).map { i in Float(exp(-Double(i) / rate * 20)) }
        let onset = EnsembleAverager.align([[slow], [sharp]], "onset", sampleRate: rate)
        #expect(abs(onset.offsets[0] - onset.offsets[1]) <= 96)  // within 2 ms: −20 dB of a 20 ms ramp is 2 ms in
        let peak = EnsembleAverager.align([[slow], [sharp]], "peak", sampleRate: rate)
        #expect(peak.offsets[1] - peak.offsets[0] >= 900)  // Peak moves the sharp hit about 20 ms later
        #expect(onset.trim > 0)
    }
}
