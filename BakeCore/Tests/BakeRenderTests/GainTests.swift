import Testing
@testable import BakeRender

struct GainTests {
    @Test func scalesSamplesInPlaceThroughCxx() {
        var samples: [Float] = [1, -0.5, 0.25, 0]
        Gain.apply(2, to: &samples)
        #expect(samples == [2, -1, 0.5, 0])
    }

    @Test func emptyBufferIsANoOp() {
        var samples: [Float] = []
        Gain.apply(2, to: &samples)
        #expect(samples.isEmpty)
    }

    @Test func largeBufferIsProcessedCompletely() {
        var samples = [Float](repeating: 1, count: 1 << 20)
        Gain.apply(0.5, to: &samples)
        #expect(samples.allSatisfy { $0 == 0.5 })
    }
}
