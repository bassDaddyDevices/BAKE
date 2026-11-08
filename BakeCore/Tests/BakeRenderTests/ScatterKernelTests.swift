import BakeDSP
import Foundation
import Testing

/// Corpus Scatter's grain placement, from its rules.
struct ScatterKernelTests {
    /// Places `clip` (one array per channel) into a fresh stereo output of `frames`.
    private func place(
        _ clip: [[Float]], into frames: Int, start: Int = 0, ratio: Double = 1, pan: Double = 0, gain: Double = 1, fade: Int = 0,
        over existing: ([Float], [Float])? = nil
    ) -> (left: [Float], right: [Float], length: Int) {
        var left = existing?.0 ?? [Float](repeating: 0, count: frames)
        var right = existing?.1 ?? [Float](repeating: 0, count: frames)
        let length = clip[0].withUnsafeBufferPointer { first in
            (clip.count > 1 ? clip[1] : clip[0]).withUnsafeBufferPointer { second in
                let pointers: [UnsafePointer<Float>?] = clip.count > 1 ? [first.baseAddress, second.baseAddress] : [first.baseAddress]
                return pointers.withUnsafeBufferPointer { channels in
                    left.withUnsafeMutableBufferPointer { l in
                        right.withUnsafeMutableBufferPointer { r in
                            bake.dsp.scatterPlace(channels.baseAddress, clip.count, clip[0].count, l.baseAddress, r.baseAddress, frames,
                                                  start, ratio, pan, gain, fade)
                        }
                    }
                }
            }
        }
        return (left, right, length)
    }

    private func sine(_ hertz: Double, frames: Int) -> [Float] {
        (0..<frames).map { Float(sin(2 * .pi * hertz * Double($0) / 48_000)) }
    }

    @Test func atUnitySpeedAndCentreAMonoGrainIsTheClipAtMinusThreeDecibelsEachSide() {
        let clip: [Float] = (0..<100).map { Float($0) / 100 }
        let out = place([clip], into: 200, start: 50)
        #expect(out.length == 100)
        let side = Float(sqrt(0.5))
        for i in 0..<100 {
            #expect(abs(out.left[50 + i] - clip[i] * side) < 1e-6)
            #expect(abs(out.right[50 + i] - clip[i] * side) < 1e-6)
        }
        #expect(out.left[0..<50].allSatisfy { $0 == 0 } && out.left[150...].allSatisfy { $0 == 0 })
    }

    @Test func panHardLeftPutsAMonoGrainOnlyLeftAndAStereoGrainKeepsItsChannels() {
        let clip = [Float](repeating: 0.5, count: 64)
        let left = place([clip], into: 64, pan: -1)
        #expect(left.left.allSatisfy { abs($0 - 0.5) < 1e-6 } && left.right.allSatisfy { abs($0) < 1e-6 })
        let stereo = place([[Float](repeating: 0.25, count: 64), [Float](repeating: 0.75, count: 64)], into: 64)
        #expect(stereo.left.allSatisfy { $0 == 0.25 } && stereo.right.allSatisfy { $0 == 0.75 })
    }

    @Test func doubleSpeedIsHalfAsLongAndAnOctaveUp() {
        let clip = sine(1_000, frames: 4_800)
        let out = place([clip], into: 4_800, ratio: 2)
        #expect(out.length == 2_400)
        #expect(out.left[2_400...].allSatisfy { $0 == 0 })
        // A 1 kHz sine read twice as fast is 2 kHz: 4 rising zero crossings per 2 ms instead of 2.
        let crossings = (1..<2_400).filter { out.left[$0 - 1] < 0 && out.left[$0] >= 0 }.count
        #expect(abs(crossings - 100) <= 1)
    }

    @Test func fadesAreRaisedCosinesAndTheGrainIsCutAtTheEnd() {
        let clip = [Float](repeating: 1, count: 100)
        let out = place([clip], into: 100, pan: -1, fade: 10)
        #expect(out.left[0] == 0 && out.left[99] == 0)
        #expect(abs(out.left[5] - Float(0.5 * (1 - cos(Double.pi * 5 / 10)))) < 1e-6)
        #expect(out.left[50] == 1)
        let cut = place([clip], into: 60, start: 30, pan: -1)
        #expect(cut.left[30..<60].allSatisfy { $0 == 1 })
    }

    @Test func grainsAddUp() {
        let clip = [Float](repeating: 0.25, count: 10)
        let first = place([clip], into: 20, pan: -1)
        let both = place([clip], into: 20, start: 5, pan: -1, over: (first.left, first.right))
        #expect(both.left[0..<5].allSatisfy { $0 == 0.25 })
        #expect(both.left[5..<10].allSatisfy { $0 == 0.5 })
        #expect(both.left[10..<15].allSatisfy { $0 == 0.25 })
    }
}
