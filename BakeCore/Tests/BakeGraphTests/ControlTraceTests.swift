import Testing
@testable import BakeGraph

struct ControlTraceTests {
    private func trace(_ samples: [Float], sampleRate: Double = 48_000) -> [Float] {
        samples.withUnsafeBufferPointer { NodeSummary.detailTrace(of: $0, sampleRate: sampleRate) }
    }

    @Test func aOneSampleBangSurvives() {
        var samples = [Float](repeating: 0, count: 48_000 * 2)
        samples[10_000] = 1
        let points = trace(samples)
        // 250 points a second: 192 frames each at 48 kHz, so frame 10000 lands in point 52.
        #expect(points[52] == 1)
        #expect(points.enumerated().allSatisfy { $0.offset == 52 || $0.element == 0 })
    }

    @Test func itCoversTheFirstFourSecondsAtMost() {
        #expect(trace([Float](repeating: 0.5, count: 48_000 * 10)).count == 1_000)
        #expect(trace([Float](repeating: 0.5, count: 48_000)).count == 250)
        #expect(trace([0.25, 0.5]).count == 1)                  // a partial window still counts
        #expect(trace([]).isEmpty)
    }

    @Test func eachPointKeepsTheSignOfItsStrongestSample() {
        var samples = [Float](repeating: 0.2, count: 192 * 2)
        samples[50] = -0.9                                       // stronger than 0.2, and negative
        let points = trace(samples)
        #expect(points == [-0.9, 0.2])
    }

    @Test func pointsLineUpInTime() {
        // A step at 1 s appears at point 250, independent of the sample rate.
        for rate in [44_100.0, 48_000, 96_000] {
            let frames = Int(rate * 2)
            let samples = (0..<frames).map { Float($0 >= Int(rate) ? 1 : 0) }
            let points = trace(samples, sampleRate: rate)
            #expect(points[249] == 0 && points[250] == 1, "\(rate)")
        }
    }
}
