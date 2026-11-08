import BakeDSP
import Foundation
import Testing
@testable import BakeGraph
@testable import BakeRender

/// Spectral Sorter's measures and routes, from known answers.
struct SortMeasureTests {
    private let rate = 48_000.0

    private func measure(_ kind: bake.dsp.SortMeasure, _ signal: [Float]) -> Double {
        bake.dsp.sortMeasure(kind, signal, signal.count, rate)
    }

    private func sine(_ hertz: Double, level: Double = 0.5, seconds: Double = 0.5) -> [Float] {
        (0..<Int(seconds * rate)).map { Float(level * sin(2 * .pi * hertz * Double($0) / rate)) }
    }

    @Test func aSinesCentroidIsItsFrequency() {
        for hertz in [200.0, 1_000.0, 6_000.0] {
            #expect(abs(measure(.centroid, sine(hertz)) / hertz - 1) < 0.01, "\(hertz) Hz")
        }
        // A brighter mix has a higher centroid.
        let dull = zip(sine(200), sine(400)).map { $0 + $1 }
        let bright = zip(sine(200), sine(4_000)).map { $0 + $1 }
        #expect(measure(.centroid, bright) > measure(.centroid, dull))
    }

    @Test func loudnessIsTheRMSInDecibels() {
        // A sine of peak a has RMS a/√2.
        #expect(abs(measure(.loudness, sine(1_000, level: 0.5)) - 20 * log10(0.5 / sqrt(2))) < 0.01)
        #expect(abs(measure(.loudness, [Float](repeating: 0.25, count: 1_000)) - 20 * log10(0.25)) < 1e-6)
    }

    @Test func pitchIsTheTonesFrequency() {
        for hertz in [110.0, 220.0, 880.0] {
            #expect(abs(measure(.pitch, sine(hertz)) / hertz - 1) < 0.02, "\(hertz) Hz")
        }
    }

    @Test func decayIsTheTimeToFallTwentyDecibels() {
        // e^(−t/τ) is 20 dB down at τ·ln 10; the measure works in 5 ms windows.
        for tau in [0.02, 0.1] {
            let signal = (0..<Int(rate)).map { Float(exp(-Double($0) / rate / tau) * sin(2 * .pi * 1_000 * Double($0) / rate)) }
            #expect(abs(measure(.decay, signal) - tau * log(10) * 1_000) <= 6, "τ \(tau)")
        }
    }

    @Test func silenceHasNoMeasure() {
        let silence = [Float](repeating: 0, count: 4_800)
        for kind in [bake.dsp.SortMeasure.centroid, .loudness, .pitch, .decay] {
            #expect(measure(kind, silence).isNaN)
        }
        // Noise has no clear pitch.
        var seed: UInt32 = 3
        let noise = (0..<24_000).map { _ -> Float in
            seed = seed &* 1_664_525 &+ 1_013_904_223
            return Float(seed >> 8) / Float(1 << 24) - 0.5
        }
        #expect(measure(.pitch, noise).isNaN)
    }

    @Test func routesFollowTheCutoffs() {
        let parameters = NodeCatalog.defaultParameters(for: .spectralSorter)  // Centroid, 150 Hz and 3 kHz
        #expect(SorterRoute.route(80, parameters: parameters) == "low")
        #expect(SorterRoute.route(150, parameters: parameters) == "mid")
        #expect(SorterRoute.route(2_999, parameters: parameters) == "mid")
        #expect(SorterRoute.route(3_000, parameters: parameters) == "high")
        #expect(SorterRoute.route(nil, parameters: parameters) == nil)  // dropped
        var mid = parameters
        mid["unmeasured"] = .choice("mid")
        #expect(SorterRoute.route(nil, parameters: mid) == "mid")
        var decay = parameters
        decay["measure"] = .choice("decay")
        #expect(SorterRoute.route(300, parameters: decay) == "mid")
    }
}
