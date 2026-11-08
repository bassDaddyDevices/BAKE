import BakeDSP
import Foundation
import Testing
@testable import BakeGraph
@testable import BakeRender

struct FeatureFollowerTests {
    private static let rate = 48_000.0

    private func sweep(seconds: Double) -> [Float] {
        let count = Int(Self.rate * seconds)
        var phase = 0.0
        return (0..<count).map { index in
            let frequency = 200 + 3_800 * Double(index) / Double(count)
            phase += 2 * Double.pi * frequency / Self.rate
            return Float(0.4 * sin(phase))
        }
    }

    private func series(_ input: [Float], _ feature: bake.dsp.Feature, smooth: Double = 0) -> [Double] {
        var settings = bake.dsp.FeatureSettings()
        settings.feature = feature
        settings.sampleRate = Self.rate
        var shape = bake.dsp.FeatureShape()
        shape.smoothMilliseconds = smooth
        shape.sampleRate = Self.rate
        let hops = Int(bake.dsp.featureHopCount(input.count, Self.rate))
        var values = [Double](repeating: 0, count: hops)
        var scratch = [Double](repeating: 0, count: Int(bake.dsp.featureScratchDoubles(Self.rate)))
        input.withUnsafeBufferPointer { buffer in
            var audio = bake.dsp.AudioInput()
            audio.channelCount = 1
            audio.frames = input.count
            audio.channels.0 = buffer.baseAddress
            if feature == .loudness {
                bake.dsp.featureLoudness(audio, settings, hops, &values)
            } else {
                bake.dsp.featureFrames(audio, settings, 0, hops, &scratch, &values)
            }
        }
        _ = bake.dsp.featureShape(&values, hops, shape)
        return values
    }

    @Test func centroidRisesWithARisingSweep() {
        let values = series(sweep(seconds: 2), .centroid)
        let early = values[10], middle = values[values.count / 2], late = values[values.count - 10]
        #expect(early < middle)
        #expect(middle < late)
        #expect(early < 0.15)
        #expect(late > 0.85)
    }

    @Test func loudnessFollowsTheLevel() {
        let tone = sweep(seconds: 2)
        let stepped = tone.enumerated().map { $0.offset < tone.count / 2 ? $0.element * 0.05 : $0.element }
        let values = series(stepped, .loudness)
        let quiet = values[40], loud = values[values.count - 40]
        #expect(quiet < 0.1)
        #expect(loud > 0.9)
    }

    @Test func smoothingHasNoLag() {
        let raw = series(sweep(seconds: 2), .centroid)
        let smooth = series(sweep(seconds: 2), .centroid, smooth: 200)
        // A zero-phase smoother leaves a straight ramp's midpoint where it was.
        let middle = raw.count / 2
        #expect(abs(raw[middle] - smooth[middle]) < 0.02)
    }

    @Test func silenceGivesAConstantNotNaN() {
        let values = series([Float](repeating: 0, count: 48_000), .centroid)
        let finite = values.allSatisfy { $0.isFinite }
        #expect(finite)
    }

    @Test func anyChunkSizeGivesTheSameBits() {
        let values = series(sweep(seconds: 1), .centroid, smooth: 30)
        let hop = Int(bake.dsp.featureHop(Self.rate))
        var whole = [Float](repeating: 0, count: 20_000)
        var chunked = [Float](repeating: 0, count: 20_000)
        values.withUnsafeBufferPointer { buffer in
            bake.dsp.featureRender(buffer.baseAddress, buffer.count, hop, &whole, 0, 20_000)
            var start = 0
            while start < 20_000 {
                let count = min(777, 20_000 - start)
                chunked.withUnsafeMutableBufferPointer { out in
                    bake.dsp.featureRender(buffer.baseAddress, buffer.count, hop, out.baseAddress.map { $0 + start }, start, count)
                }
                start += count
            }
        }
        #expect(whole == chunked)
    }

    @Test func theCatalogPlacesItInTheModulationGroup() {
        let definition = NodeCatalog.definition(for: .featureFollower)
        #expect(NodeKind.featureFollower.category == .modulation)
        #expect(definition.lengthRule == .sameAsInput("in"))
        #expect(definition.parameter("feature") != nil)
        #expect(!NodeCatalog.isCausal(Node(kind: .featureFollower, parameters: [:])))
    }
}
