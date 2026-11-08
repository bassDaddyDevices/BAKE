import BakeDSP
import Foundation
import Testing

/// The Large Audio Processor's slicing kernel, from its rules (not from its output).
struct SlicingTests {
    private let rate = 48_000.0
    private let hop = 256

    private func energy(_ samples: [Float]) -> [Double] {
        var energy = [Double](repeating: 0, count: (samples.count + hop - 1) / hop)
        samples.withUnsafeBufferPointer { mono in
            energy.withUnsafeMutableBufferPointer { out in
                bake.dsp.sliceEnergy(mono.baseAddress, samples.count, hop, out.baseAddress)
            }
        }
        return energy
    }

    private func onsets(_ samples: [Float], threshold: Double = -40, sensitivity: Double = 6, backTrack: Bool = true) -> [Int] {
        let energy = energy(samples)
        var settings = bake.dsp.SliceSettings()
        settings.thresholdDb = threshold
        settings.sensitivityDb = sensitivity
        settings.hop = hop
        settings.sampleRate = rate
        settings.backTrack = backTrack
        var onsets = [Int](repeating: 0, count: 64)
        let count = energy.withUnsafeBufferPointer { energy in
            onsets.withUnsafeMutableBufferPointer { out in
                bake.dsp.sliceOnsets(energy.baseAddress, energy.count, settings, out.baseAddress, out.count)
            }
        }
        return Array(onsets.prefix(count))
    }

    private func ranges(
        _ boundaries: [Int], total: Int, min: Int = 1, max: Int = .max, jitter: Double = 0, seed: UInt32 = 1
    ) -> [Range<Int>] {
        var starts = [Int](repeating: 0, count: 256)
        var ends = [Int](repeating: 0, count: 256)
        let count = boundaries.withUnsafeBufferPointer { boundaries in
            starts.withUnsafeMutableBufferPointer { starts in
                ends.withUnsafeMutableBufferPointer { ends in
                    bake.dsp.sliceRanges(
                        boundaries.baseAddress, boundaries.count, total, min, max, jitter, seed,
                        starts.baseAddress, ends.baseAddress, starts.count
                    )
                }
            }
        }
        return (0..<count).map { starts[$0]..<ends[$0] }
    }

    /// Silence with 20 ms bursts of a 0.5 sine (−9 dBFS) at these seconds.
    private func clicks(at seconds: [Double], length: Double = 4, amplitude: Float = 0.5) -> [Float] {
        var samples = [Float](repeating: 0, count: Int(length * rate))
        for time in seconds {
            let start = Int(time * rate)
            for frame in 0..<Int(0.02 * rate) where start + frame < samples.count {
                samples[start + frame] = amplitude * sin(2 * .pi * 1_000 * Float(frame) / Float(rate))
            }
        }
        return samples
    }

    @Test func energyIsTheMeanSquarePerHop() {
        let sine = (0..<(hop * 8)).map { 0.5 * sin(2 * .pi * Float($0) / Float(hop)) }
        let values = energy(sine)
        #expect(values.count == 8)
        #expect(values.allSatisfy { abs($0 - 0.125) < 1e-6 })
        #expect(energy([1, 1, 1]).count == 1)
        #expect(energy([1, 1, 1]) == [1])
    }

    @Test func eachClickStartsASliceWithinAHop() {
        let times = [0.5, 1.2, 2.0, 3.1]
        let found = onsets(clicks(at: times))
        #expect(found.count == 4)
        for (onset, time) in zip(found, times) {
            #expect(abs(onset - Int(time * rate)) <= hop, "onset \(onset) for \(time) s")
        }
    }

    @Test func aClickBelowTheThresholdIsIgnored() {
        var samples = clicks(at: [0.5, 2.0])
        let quiet = clicks(at: [1.2], amplitude: 0.002)  // about −57 dBFS
        for index in samples.indices { samples[index] += quiet[index] }
        #expect(onsets(samples).count == 2)
        #expect(onsets(samples, threshold: -70).count == 3)
    }

    @Test func backTrackMovesTheOnsetToTheStartOfTheAttack() {
        // A steady floor (DC 0.005, −46 dBFS), then from 1 s a 40 ms ramp up to a 0.5 sine on top of it: the
        // level is 12 dB over the 100 ms before it a hop or two into the ramp, and the attack starts at 1 s.
        var samples = [Float](repeating: 0.005, count: Int(2 * rate))
        let start = Int(rate)
        for frame in start..<samples.count {
            let ramp = min(1, Float(frame - start) / Float(0.04 * rate))
            samples[frame] += 0.5 * ramp * sin(2 * .pi * 1_000 * Float(frame) / Float(rate))
        }
        let tracked = onsets(samples, sensitivity: 12)
        let untracked = onsets(samples, sensitivity: 12, backTrack: false)
        #expect(tracked.count == 1 && untracked.count == 1)
        guard let trackedOnset = tracked.first, let untrackedOnset = untracked.first else { return }
        #expect(abs(trackedOnset - start) <= hop)
        #expect(untrackedOnset > trackedOnset)
    }

    @Test func shortSlicesJoinTheNextAndTheLastJoinsThePrevious() {
        let total = Int(4 * rate)
        let boundaries = [0.5, 1.2, 2.0, 3.1, 3.9].map { Int($0 * rate) }
        let joined = ranges(boundaries, total: total, min: Int(1 * rate))
        // 0.5–1.2 joins 1.2–2.0; 3.1–3.9 joins 3.9–4.0, which is still short and joins 2.0–3.1 as the last.
        #expect(joined == [Int(0.5 * rate)..<Int(2.0 * rate), Int(2.0 * rate)..<total])
    }

    @Test func longSlicesAreCutAtMaxLength() {
        let total = Int(2 * rate)
        let cut = ranges([0], total: total, max: Int(0.5 * rate))
        #expect(cut.count == 4)
        #expect(cut.map(\.count) == Array(repeating: Int(0.5 * rate), count: 4))
        #expect(cut.first?.lowerBound == 0 && cut.last?.upperBound == total)
        // A remainder is a shorter last piece.
        #expect(ranges([0], total: 1_000, max: 300).map(\.count) == [300, 300, 300, 100])
    }

    @Test func jitterIsTheSameForASeedAndStaysInItsRange() {
        let boundaries = stride(from: 0, to: 100_000, by: 10_000).map { $0 }
        let a = ranges(boundaries, total: 100_000, jitter: 0.5, seed: 7)
        #expect(a == ranges(boundaries, total: 100_000, jitter: 0.5, seed: 7))
        #expect(a != ranges(boundaries, total: 100_000, jitter: 0.5, seed: 8))
        #expect(a.map(\.lowerBound) == boundaries)
        #expect(a.allSatisfy { $0.count >= 5_000 && $0.count <= 15_000 })
        #expect(Set(a.map(\.count)).count > 1)
    }

    @Test func snapFindsTheNearestZeroCrossing() {
        // A sine with period 100 frames crosses zero at 0, 50, 100, …; the buffer starts at frame 1_000.
        let samples = (0..<400).map { sin(2 * .pi * Float($0) / 100 + 0.3) }
        let snapped = samples.withUnsafeBufferPointer { bake.dsp.sliceSnap($0.baseAddress, 1_000, $0.count, 1_140, 30) }
        // sin(2πf/100 + 0.3) = 0 where f ≈ 45.2 + 50k → crossings at 1_046, 1_096, 1_146, …
        #expect(snapped == 1_146)
        let none = samples.withUnsafeBufferPointer { bake.dsp.sliceSnap($0.baseAddress, 1_000, $0.count, 1_120, 2) }
        #expect(none == 1_120)
    }
}
