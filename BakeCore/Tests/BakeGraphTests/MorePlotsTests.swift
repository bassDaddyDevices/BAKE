import Foundation
import Testing
@testable import BakeGraph

/// Known answers for the card pictures that don't need a kernel to check them.
struct MorePlotsTests {
    @Test func softDistortionAtUnityIsTanhAndHardIsAClip() {
        #expect(abs(DistortionPlot.transfer(mode: "soft", x: 0.5, driveDecibels: 0, ceilingDecibels: 0) - tanh(0.5)) < 1e-12)
        #expect(DistortionPlot.transfer(mode: "hard", x: 0.5, driveDecibels: 12, ceilingDecibels: 0) > 0.99)
        #expect(DistortionPlot.transfer(mode: "hard", x: 0.5, driveDecibels: 12, ceilingDecibels: -12) == pow(10, -12.0 / 20))
        #expect(DistortionPlot.transfer(mode: "soft", x: 0, driveDecibels: 36, ceilingDecibels: 0) == 0)
    }

    @Test func theFeedbackEchoPlotFollowsGainDelayAndDamping() {
        let echoes = FeedbackPlot.echoes(gainDecibels: -6, delayMilliseconds: 10, lowCut: 20, highCut: 20_000, count: 5)
        #expect(echoes.map(\.time) == [0, 10, 20, 30, 40])
        #expect(abs(echoes[1].amplitude - 0.5011872336272722) < 1e-12)
        #expect(abs(echoes[4].amplitude - pow(10, -6.0 / 20 * 4)) < 1e-12)
        #expect(echoes.allSatisfy { $0.brightness == 1 })
        let dark = FeedbackPlot.echoes(gainDecibels: -6, delayMilliseconds: 10, lowCut: 2_000, highCut: 1_000, count: 2)
        #expect(dark[1].amplitude == echoes[1].amplitude)
        #expect(dark[1].brightness < echoes[1].brightness)
        #expect(FeedbackPlot.echoes(gainDecibels: 6, delayMilliseconds: 0, lowCut: 20, highCut: 20_000, count: 1)[0].amplitude == 1)
    }

    @Test func reduxLevelsAreMultiplesOfTheStep() {
        // 2 bits: levels = 2, step 0.5.
        #expect(ReduxPlot.quantize(0.3, bits: 2) == 0.5)
        #expect(ReduxPlot.quantize(0.24, bits: 2) == 0)
        #expect(ReduxPlot.quantize(-0.9, bits: 2) == -1)
        let trace = ReduxPlot.trace(mode: "classic", bits: 3, divider: 1, linear: false, mask: 21_845, operatorName: "xor", samples: 128)
        #expect(Set(trace.output.map { ($0 * 4).rounded() / 4 }).count <= 9)     // 3 bits: step 0.25
        #expect(trace.output.allSatisfy { abs($0 * 4 - ($0 * 4).rounded()) < 1e-9 })
    }

    @Test func aRateDividerHoldsEachValue() {
        let trace = ReduxPlot.trace(mode: "classic", bits: 8, divider: 4, linear: false, mask: 21_845, operatorName: "xor", samples: 128)
        for start in stride(from: 0, to: 128, by: 4) {
            #expect(Set(trace.output[start..<start + 4]).count == 1)
        }
        let smooth = ReduxPlot.trace(mode: "classic", bits: 8, divider: 4, linear: true, mask: 21_845, operatorName: "xor", samples: 128)
        #expect(smooth.output != trace.output)
    }

    @Test func theResonatorPartialsFollowTheStiffStringSeries() {
        let harmonic = ResonatorPlot.partials(root: 110, fineCents: 0, inharmonicity: 0, bands: 8, sampleRate: 48_000)
        #expect(zip(harmonic, (1...8).map { 110.0 * Double($0) }).allSatisfy { abs($0 - $1) < 1e-9 })
        let bell = ResonatorPlot.partials(root: 110, fineCents: 0, inharmonicity: 1, bands: 8, sampleRate: 48_000)
        #expect(zip(bell, harmonic).dropFirst().allSatisfy { $0 > $1 })              // stretched upward
        #expect(abs(bell[0] - 110 * (1.001).squareRoot()) < 1e-9)
        let tuned = ResonatorPlot.partials(root: 110, fineCents: 1_200, inharmonicity: 0, bands: 1, sampleRate: 48_000)
        #expect(abs(tuned[0] - 220) < 1e-9)
        // Above 0.45 × the sample rate nothing rings.
        let many = ResonatorPlot.partials(root: 1_000, fineCents: 0, inharmonicity: 0, bands: 1_024, sampleRate: 48_000)
        #expect(many.count == 21 && many.last == 21_000)
    }

    @Test func theStretchWindowIsAsLongAsItsFFT() {
        #expect(abs(StretchPlot.windowMilliseconds(fftSize: 4_096, sampleRate: 48_000) - 85.333) < 0.001)
        #expect(StretchPlot.windowMilliseconds(fftSize: 1_024, sampleRate: 0) == 0)
    }

    @Test func theEnvelopeRisesFallsHoldsAndReleases() {
        let curve = EnvelopePlot.curve(attack: 0.1, decay: 0.2, sustain: 0.5, release: 0.3, timeScale: 1, shape: "linear", points: 601)
        #expect(curve.levels.first == 0)
        #expect(abs((curve.levels.max() ?? 0) - 1) < 1e-9)
        #expect(abs(curve.levels.last ?? 1) < 1e-9)
        let mid = curve.times.firstIndex { $0 >= curve.sustainStart + 0.01 } ?? 0
        #expect(abs(curve.levels[mid] - 0.5) < 1e-9)
        #expect(curve.sustainEnd > curve.sustainStart && curve.duration > curve.sustainEnd)
    }

    @Test func theTimeScaleStretchesTheEnvelope() {
        let normal = EnvelopePlot.curve(attack: 0.1, decay: 0.1, sustain: 0.5, release: 0.1, timeScale: 1, shape: "linear", points: 10)
        let slow = EnvelopePlot.curve(attack: 0.1, decay: 0.1, sustain: 0.5, release: 0.1, timeScale: 4, shape: "linear", points: 10)
        #expect(abs(slow.duration - normal.duration * 4) < 1e-9)
    }

    @Test func smoothAndLinearEnvelopesDiffer() {
        let linear = EnvelopePlot.curve(attack: 0.5, decay: 0.5, sustain: 0.5, release: 0.5, timeScale: 1, shape: "linear", points: 50)
        let smooth = EnvelopePlot.curve(attack: 0.5, decay: 0.5, sustain: 0.5, release: 0.5, timeScale: 1, shape: "exponential", points: 50)
        #expect(linear.levels != smooth.levels)
        #expect(smooth.levels[5] < linear.levels[5])      // a smoothstep starts slower
    }

    @Test func theQuantizerStairsSnapToTheScale() {
        let c = 1.0 / 24
        #expect(abs(QuantizerPlot.quantize(scale: "chromatic", root: 0, x: 3.4 * c) - 3 * c) < 1e-12)
        #expect(abs(QuantizerPlot.quantize(scale: "major", root: 0, x: 1.4 * c) - 2 * c) < 1e-12)
        #expect(abs(QuantizerPlot.quantize(scale: "pentatonic", root: 0, x: 5.9 * c) - 7 * c) < 1e-12)
        #expect(abs(QuantizerPlot.quantize(scale: "major", root: 2, x: 5.2 * c) - 6 * c) < 1e-12)
        #expect(QuantizerPlot.quantize(scale: "chromatic", root: 0, x: 5) == 1)
        #expect(QuantizerPlot.quantize(scale: "chromatic", root: 0, x: -5) == -1)
    }

    @Test func aFlangerWithNoFeedbackIsACombWithItsNotchesHalfAPeriodApart() {
        // 4 ms: the first null is at 125 Hz and the first peak (+6 dB) at 250 Hz.
        func gain(_ hz: Double) -> Double {
            FrequencyResponse.flangerDecibels(delayMilliseconds: 4, depth: 0, lfo: 0, feedback: 0, negativeFeedback: false, damping: 0, mix: 1, at: hz)
        }
        #expect(gain(125) < -40)
        #expect(abs(gain(250) - 6.0206) < 1e-3)
        #expect(abs(FrequencyResponse.flangerDecibels(delayMilliseconds: 4, depth: 0, lfo: 0, feedback: 0, negativeFeedback: false, damping: 0, mix: 0, at: 125)) < 1e-9)
    }

    @Test func theFlangerSweepMovesTheNotches() {
        func gain(lfo: Double, hz: Double) -> Double {
            FrequencyResponse.flangerDecibels(delayMilliseconds: 4, depth: 1, lfo: lfo, feedback: 0, negativeFeedback: false, damping: 0, mix: 1, at: hz)
        }
        // At LFO 0 the delay is the full 4 ms (null at 125 Hz); at LFO 0.5 it is 2 ms (null at 250 Hz).
        #expect(gain(lfo: 0, hz: 125) < -40 && gain(lfo: 0.5, hz: 250) < -40)
        #expect(gain(lfo: 0.5, hz: 125) > -10)
        #expect(FrequencyResponse.flangerSweep(rate: 1, at: 0) == 0.5)
        #expect(abs(FrequencyResponse.flangerSweep(rate: 1, at: 0.25) - 1) < 1e-12)
    }
}

struct MathAndChorusPlotTests {
    @Test func mathOperatorsKnownAnswers() {
        func result(_ name: String, a: Double, b: Double = 0.5, scale: Double = 1) -> Double {
            MathPlot.apply(operatorName: name, a: a, b: b, scale: scale, minimum: -16, maximum: 16)
        }
        #expect(result("add", a: 0.25) == 0.75)
        #expect(result("subtract", a: 0.25) == -0.25)
        #expect(result("multiply", a: 0.5) == 0.25)
        #expect(result("divide", a: 0.25) == 0.5)
        #expect(result("divide", a: 0.25, b: 0) == 0)
        #expect(result("abs", a: -0.5) == 0.5)
        #expect(result("invert", a: 0.5) == -0.5)
        #expect(result("modulo", a: 0.75) == 0.25)
        #expect(result("add", a: 1, scale: -4) == -6)
        #expect(MathPlot.apply(operatorName: "add", a: 1, b: 1, scale: 4, minimum: -1, maximum: 1) == 1)
    }

    @Test func chorusVoicesFanOutWithSpreadAndSwingWithDetune() {
        let still = ChorusPlot.voiceDelays(voices: 4, detuneCents: 0, spread: 0, driftRate: 0.3, cycles: 0.3)
        #expect(still.allSatisfy { abs($0 - 12) < 1e-9 })
        let fanned = ChorusPlot.voiceDelays(voices: 4, detuneCents: 0, spread: 1, driftRate: 0.3, cycles: 0)
        #expect(abs((fanned.max() ?? 0) - (fanned.min() ?? 0) - 9) < 1e-9)   // resting delays run from -6 ms (first voice) to +3 ms (fourth)
        #expect(ChorusPlot.voiceDelays(voices: 99, detuneCents: 5, spread: 0.5, driftRate: 0.3, cycles: 0).count == 8)
    }

    @Test func theWobbleBendsPitchByTheDetune() {
        // The delay's slope is the pitch change: a peak slope of (2^(cents/1200) - 1) is `cents` cents.
        let cents = 20.0
        let rate = 0.5
        let step = 1e-4
        var peak = 0.0
        var cycles = 0.0
        while cycles < 1 {
            let a = ChorusPlot.voiceDelays(voices: 2, detuneCents: cents, spread: 0, driftRate: rate, cycles: cycles)[0]
            let b = ChorusPlot.voiceDelays(voices: 2, detuneCents: cents, spread: 0, driftRate: rate, cycles: cycles + step)[0]
            peak = max(peak, abs(b - a) / 1_000 / (step / rate))   // seconds of delay per second
            cycles += step
        }
        #expect(abs(peak - (pow(2, cents / 1_200) - 1)) < 1e-3 * (pow(2, cents / 1_200) - 1) * 10)
    }
}

struct ResynthesisPlotTests {
    @Test func tiltPivotsAboutOneKilohertz() {
        #expect(ResynthesisPlot.tiltDecibels(frequency: 1_000, tilt: 9) == 0)
        #expect(abs(ResynthesisPlot.tiltDecibels(frequency: 2_000, tilt: 6) - 6) < 1e-9)
        #expect(abs(ResynthesisPlot.tiltDecibels(frequency: 250, tilt: 6) + 12) < 1e-9)
        #expect(ResynthesisPlot.tiltDecibels(frequency: 500, tilt: 0) == 0)
    }

    @Test func balanceHandsOverFromSinesToNoise() {
        #expect(ResynthesisPlot.levels(balance: 0) == (1, 0))
        #expect(ResynthesisPlot.levels(balance: 0.5) == (1, 1))
        #expect(ResynthesisPlot.levels(balance: 1) == (0, 1))
        #expect(ResynthesisPlot.levels(balance: 0.25) == (1, 0.5))
    }

    @Test func logicSwitchesAtItsEdgesAndCombinesLikeTheKernel() {
        #expect(LogicPlot.edges(threshold: 0.5, hysteresis: 0.1) == (0.6, 0.4))
        #expect(LogicPlot.edges(threshold: 0, hysteresis: -1) == (0, 0))
        let pairs = [(false, false), (false, true), (true, false), (true, true)]
        #expect(pairs.map { LogicPlot.gate("and", a: $0.0, b: $0.1) } == [false, false, false, true])
        #expect(pairs.map { LogicPlot.gate("or", a: $0.0, b: $0.1) } == [false, true, true, true])
        #expect(pairs.map { LogicPlot.gate("xor", a: $0.0, b: $0.1) } == [false, true, true, false])
        #expect(pairs.map { LogicPlot.gate("not", a: $0.0, b: $0.1) } == [true, true, false, false])
        #expect(pairs.map { LogicPlot.gate("threshold", a: $0.0, b: $0.1) } == [false, false, true, true])
    }

    @Test func gainVCAMapsItsAmountLikeTheKernel() {
        #expect(GainVCAPlot.multiplier(ringMod: false, gainDecibels: 0, control: -1) == 0)
        #expect(GainVCAPlot.multiplier(ringMod: false, gainDecibels: 0, control: 0) == 0.5)
        #expect(GainVCAPlot.multiplier(ringMod: false, gainDecibels: 0, control: 3) == 1)
        #expect(GainVCAPlot.multiplier(ringMod: true, gainDecibels: 0, control: -0.5) == -0.5)
        #expect(abs(GainVCAPlot.multiplier(ringMod: false, gainDecibels: -6, control: 1) - 0.501187) < 1e-6)
    }

    @Test func fractionalBitDepthKeepsItsFractionAndWholeBitsRoundIt() {
        #expect(ReduxPlot.levels(bits: 3.5, fractional: true) == pow(2, 2.5))
        #expect(ReduxPlot.levels(bits: 3.5, fractional: false) == 8)
        #expect(ReduxPlot.levels(bits: 4, fractional: true) == 8)
        let fractional = ReduxPlot.trace(mode: "bitReduction", bits: 3.5, fractionalBits: true, divider: 1, linear: false, mask: 0, operatorName: "xor", samples: 128)
        let whole = ReduxPlot.trace(mode: "bitReduction", bits: 3.5, fractionalBits: false, divider: 1, linear: false, mask: 0, operatorName: "xor", samples: 128)
        #expect(fractional.output != whole.output)
    }
}
