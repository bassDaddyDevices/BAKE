import BakeDSP
import Foundation
import Testing
@testable import BakeGraph
@testable import BakeRender

struct TransientDetectorTests {
    private static let rate = 48_000.0

    /// Deterministic white noise in −1…1.
    private static func noise(_ count: Int, seed: UInt64 = 1) -> [Float] {
        var state = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return (0..<count).map { _ in
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Float(Int64(bitPattern: state) >> 11) / Float(1 << 52)
        }
    }

    /// A quiet noise floor with a decaying noise burst at each of `starts` (frames); `amplitudes` default to 0.5.
    private static func bursts(
        at starts: [Int], amplitudes: [Float]? = nil, seconds: Double = 6, length: Double = 0.3, decay: Double = 0.05
    ) -> [Float] {
        let count = Int(rate * seconds)
        var signal = noise(count, seed: 7).map { $0 * 0.001 }
        let hits = noise(Int(rate * length), seed: 9)
        for (index, start) in starts.enumerated() {
            let amplitude = amplitudes?[index] ?? 0.5
            for i in 0..<hits.count where start + i < count {
                signal[start + i] += amplitude * hits[i] * Float(exp(-Double(i) / (rate * decay)))
            }
        }
        return signal
    }

    private static let truth = [24_000, 72_000, 120_000, 168_000, 216_000]

    private func settings(
        _ mode: bake.dsp.TransientMode = .energy, sensitivity: Double = 0.5, gap: Double = 80, backTrack: Bool = true
    ) -> bake.dsp.TransientSettings {
        var settings = bake.dsp.TransientSettings()
        settings.mode = mode
        settings.sensitivity = sensitivity
        settings.minGapMilliseconds = gap
        settings.backTrack = backTrack
        settings.sampleRate = Self.rate
        return settings
    }

    private func input(_ samples: [Float], _ body: (bake.dsp.AudioInput) -> Void) {
        samples.withUnsafeBufferPointer { buffer in
            var input = bake.dsp.AudioInput()
            input.channels.0 = buffer.baseAddress
            input.channelCount = 1
            input.frames = buffer.count
            body(input)
        }
    }

    private func detection(_ samples: [Float], _ settings: bake.dsp.TransientSettings, split: Int = 1) -> [Double] {
        var detection = [Double]()
        input(samples) { input in
            let hops = Int(bake.dsp.transientHopCount(input.frames, Self.rate))
            detection = [Double](repeating: 0, count: hops)
            var scratch = [Double](repeating: 0, count: Int(bake.dsp.transientScratchDoubles(Self.rate)))
            let piece = (hops + split - 1) / split
            for first in stride(from: 0, to: hops, by: piece) {
                bake.dsp.transientDetection(input, settings, first, min(piece, hops - first), &scratch, &detection)
            }
        }
        return detection
    }

    private func detect(_ samples: [Float], _ settings: bake.dsp.TransientSettings) -> (onsets: [Int], strengths: [Float]) {
        let found = detection(samples, settings)
        var onsets = [Int](), strengths = [Float]()
        input(samples) { input in
            let capacity = Int(bake.dsp.transientMaxOnsets(input.frames, settings.minGapMilliseconds, Self.rate))
            onsets = [Int](repeating: 0, count: capacity)
            strengths = [Float](repeating: 0, count: capacity)
            let count = Int(bake.dsp.transientPick(input, settings, found, found.count, &onsets, &strengths, capacity))
            onsets = Array(onsets.prefix(count))
            strengths = Array(strengths.prefix(count))
        }
        return (onsets, strengths)
    }

    private func nearest(_ onset: Int) -> Int { Self.truth.map { abs($0 - onset) }.min() ?? Int.max }

    @Test(arguments: [bake.dsp.TransientMode.energy, .spectralFlux, .highFrequency])
    func findsEveryBurstAndNothingElse(_ mode: bake.dsp.TransientMode) {
        let loud = detect(Self.bursts(at: Self.truth), settings(mode))
        #expect(loud.onsets.count == 5, "\(mode) found \(loud.onsets)")
        #expect(loud.onsets.allSatisfy { nearest($0) < 480 })
    }

    @Test func backTrackPlacesTheBangAtTheStartOfTheAttack() {
        let signal = Self.bursts(at: Self.truth)
        let early = detect(signal, settings(backTrack: true)).onsets
        let late = detect(signal, settings(backTrack: false)).onsets
        #expect(early.count == 5 && late.count == 5)
        #expect(early.allSatisfy { nearest($0) < 96 })              // within 2 ms of the real start
        #expect(zip(early, late).allSatisfy { $0 < $1 })            // and always ahead of where the detector noticed it
    }

    @Test func aQuietBurstNeedsEnoughSensitivity() {
        // The fourth burst is 20 dB under the rest. At full sensitivity it is found (the noise tails may add stray hits).
        let signal = Self.bursts(at: Self.truth, amplitudes: [0.5, 0.5, 0.5, 0.05, 0.5])
        func foundQuietOne(_ sensitivity: Double) -> Bool {
            detect(signal, settings(sensitivity: sensitivity)).onsets.contains { abs($0 - Self.truth[3]) < 480 }
        }
        #expect(foundQuietOne(1))
        #expect(!foundQuietOne(0.1))
        #expect(detect(signal, settings(sensitivity: 0.1)).onsets.count == 4)
    }

    @Test func silenceAndSteadyNoiseHaveNoOnsets() {
        #expect(detect([Float](repeating: 0, count: 100_000), settings()).onsets.isEmpty)
        #expect(detect(Self.noise(200_000).map { $0 * 0.1 }, settings()).onsets.isEmpty)
    }

    @Test func theMinimumGapThinsCloseOnsets() {
        let close = (0..<12).map { 24_000 + $0 * 3_600 }                    // 75 ms apart
        let signal = Self.bursts(at: close, seconds: 2, length: 0.025, decay: 0.005)
        let all = detect(signal, settings(gap: 20)).onsets
        let thinned = detect(signal, settings(gap: 400)).onsets
        #expect(all.count > thinned.count)
        #expect(zip(thinned, thinned.dropFirst()).allSatisfy { $1 - $0 >= Int(0.4 * Self.rate) })
    }

    @Test func strengthsAreZeroToOneAndTheStrongestIsOne() {
        let found = detect(Self.bursts(at: Self.truth, amplitudes: [0.5, 0.1, 0.3, 0.5, 0.2]), settings())
        #expect(found.strengths.allSatisfy { $0 >= 0 && $0 <= 1 })
        #expect(found.strengths.max() == 1)
    }

    @Test func detectionFramesGiveTheSameAnswerSplitAnyWay() {
        let signal = Self.bursts(at: Self.truth)
        #expect(detection(signal, settings(.spectralFlux), split: 1) == detection(signal, settings(.spectralFlux), split: 7))
    }

    @Test func nonFiniteInputIsHarmless() {
        var signal = Self.bursts(at: Self.truth)
        signal[1_000] = .nan
        signal[2_000] = .infinity
        let found = detect(signal, settings())
        #expect(found.onsets.count == 5)
    }

    private func render(_ onsets: [Int], _ strengths: [Float], pulse: Int, frames: Int, chunk: Int) -> (bang: [Float], strength: [Float]) {
        var bang = [Float](repeating: 0, count: frames), strength = [Float](repeating: 0, count: frames)
        var start = 0
        while start < frames {
            let count = min(chunk, frames - start)
            bang.withUnsafeMutableBufferPointer { b in
                strength.withUnsafeMutableBufferPointer { s in
                    bake.dsp.transientRender(onsets, strengths, onsets.count, pulse, b.baseAddress! + start, s.baseAddress! + start, start, count)
                }
            }
            start += count
        }
        return (bang, strength)
    }

    @Test func eachOnsetIsARisingEdgeEvenWhenPulsesWouldOverlap() {
        let output = render([100, 105, 400], [1, 0.5, 0.25], pulse: 50, frames: 1_000, chunk: 1_000)
        #expect(output.bang[99] == 0 && output.bang[100] == 1)
        #expect(output.bang[104] == 0 && output.bang[105] == 1)    // the first pulse stops a frame short of the next onset
        #expect(output.bang[154] == 1 && output.bang[155] == 0)
        #expect(output.bang[400] == 1 && output.bang[449] == 1 && output.bang[450] == 0)
        let risingEdges = zip(output.bang, output.bang.dropFirst()).filter { $0 < 0.5 && $1 > 0.5 }.count
        #expect(risingEdges == 3)
    }

    @Test func strengthIsHeldUntilTheNextOnset() {
        let output = render([100, 400], [1, 0.25], pulse: 10, frames: 1_000, chunk: 1_000)
        #expect(output.strength[99] == 0)
        #expect(output.strength[100] == 1 && output.strength[399] == 1)
        #expect(output.strength[400] == 0.25 && output.strength[999] == 0.25)
    }

    @Test func anyChunkSizeGivesTheSameBits() {
        let onsets = [10, 700, 701, 5_000]
        let strengths: [Float] = [1, 0.5, 0.2, 0.9]
        let whole = render(onsets, strengths, pulse: 40, frames: 9_000, chunk: 9_000)
        let chunked = render(onsets, strengths, pulse: 40, frames: 9_000, chunk: 333)
        #expect(whole.bang == chunked.bang && whole.strength == chunked.strength)
    }

    @Test func theCatalogDescribesTwoControlOutputs() {
        #expect(NodeKind.transientDetector.category == .modulation)
        #expect(NodeCatalog.outputSignal("out", of: .transientDetector) == .control)
        #expect(NodeCatalog.outputSignal("strength", of: .transientDetector) == .control)
        #expect(NodeCatalog.defaultParameters(for: .transientDetector)["backTrack"] == .choice("on"))
    }
}
