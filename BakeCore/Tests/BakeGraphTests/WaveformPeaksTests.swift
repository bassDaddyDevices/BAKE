import Testing
@testable import BakeGraph

struct WaveformPeaksTests {
    @Test func peaksAreClampedIntoZeroToOne() {
        #expect(WaveformPeaks(peaks: [-0.5, 0.25, 2, .nan]).peaks == [0.5, 0.25, 1, 0])
    }
}
