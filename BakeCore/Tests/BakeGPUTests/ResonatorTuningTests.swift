import Foundation
import Testing
@testable import BakeGPU

struct ResonatorTuningTests {
    @Test func fundamentalDelayMatchesTheRoot() throws {
        let bands = ResonatorTuning.bands(for: ResonatorSettings(rootHz: 480), sampleRate: 48_000)
        let first = try #require(bands.first)
        #expect(first.frequency == 480)
        #expect(first.delay == 100)
    }

    @Test func fineTuneIsInCents() throws {
        let bands = ResonatorTuning.bands(for: ResonatorSettings(rootHz: 480, fineCents: 100), sampleRate: 48_000)
        #expect(abs(try #require(bands.first).frequency - 480 * pow(2, 1.0 / 12)) < 1e-9)
    }

    @Test func withoutInharmonicityBandsFormAHarmonicSeries() {
        let bands = ResonatorTuning.bands(for: ResonatorSettings(rootHz: 100), sampleRate: 48_000)
        #expect(bands.count == 64)
        for (index, band) in bands.enumerated() {
            #expect(abs(band.frequency - 100 * Double(index + 1)) < 1e-9)
        }
    }

    @Test func inharmonicityStretchesUpperPartials() {
        let bands = ResonatorTuning.bands(for: ResonatorSettings(rootHz: 100, inharmonicity: 1), sampleRate: 48_000)
        let tenth = bands[9].frequency
        #expect(tenth > 1_000)
        #expect(abs(tenth - 1_000 * (1 + 0.001 * 100).squareRoot()) < 1e-9)
    }

    @Test func partialsNearNyquistAreSilenced() {
        let bands = ResonatorTuning.bands(for: ResonatorSettings(rootHz: 1_000), sampleRate: 48_000)
        // 0.45 × 48 kHz = 21.6 kHz, so harmonics 1…21 are active and 22…64 are not.
        #expect(bands.filter(\.isActive).count == 21)
        #expect(bands.filter(\.isActive).allSatisfy { $0.delay >= 2 })
    }

    @Test func feedbackRingsDownSixtyDecibelsOverTheDecay() throws {
        let settings = ResonatorSettings(rootHz: 480, decaySeconds: 0.5)
        let band = try #require(ResonatorTuning.bands(for: settings, sampleRate: 48_000).first)
        let trips = 0.5 * 48_000 / Double(band.delay)
        #expect(abs(pow(Double(band.feedback), trips) - 0.001) < 1e-6)
    }

    @Test func delayLinesHoldTheLongestActiveDelay() {
        let bands = ResonatorTuning.bands(for: ResonatorSettings(rootHz: 20, bands: 1_024), sampleRate: 48_000)
        let capacity = ResonatorTuning.delayCapacity(for: bands)
        #expect(capacity >= 2_400 + 2)
        #expect(bands.filter(\.isActive).allSatisfy { Double($0.delay) <= Double(capacity - 2) })
    }
}
