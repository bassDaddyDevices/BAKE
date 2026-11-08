import BakeGraph
import Foundation
import Testing
@testable import BakeRender

/// Corpus Scatter's schedule and render, from its rules.
struct ScatterTests {
    private let rate = 48_000.0

    private func schedule(_ parameters: [ParameterID: ParameterValue], clips: Int = 3) -> [ScatterSchedule.Grain] {
        ScatterSchedule.grains(clips: clips, parameters: NodeCatalog.defaultParameters(for: .corpusScatter).merging(parameters) { $1 }, sampleRate: rate)
    }

    @Test func poissonGapsAverageOneOverDensityAndVaryLikeAnExponential() {
        let grains = schedule(["distribution": .choice("poisson"), "density": .number(20), "duration": .number(600)])
        let gaps = zip(grains.dropFirst(), grains).map { Double($0.start - $1.start) / rate }
        let mean = gaps.reduce(0, +) / Double(gaps.count)
        let spread = sqrt(gaps.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(gaps.count))
        #expect(gaps.count > 10_000)
        #expect(abs(mean - 1.0 / 20) < 0.05 / 20)
        #expect(abs(spread / mean - 1) < 0.05)  // an exponential's spread equals its mean
    }

    @Test func uniformWithoutJitterIsEvenlySpaced() {
        let grains = schedule(["distribution": .choice("uniform"), "density": .number(4), "duration": .number(2)])
        #expect(grains.map(\.start) == (0..<8).map { $0 * 12_000 })
    }

    @Test func euclideanSpreadsThePulsesAsEvenlyAsTheyGo() {
        let grains = schedule(["distribution": .choice("euclidean"), "steps": .number(16), "pulses": .number(5), "step": .number(125), "duration": .number(4)])
        let stepFrames = 6_000
        let hits = grains.map { $0.start / stepFrames }
        // Two cycles of 16 steps: 5 hits each, and every gap is 3 or 4 steps.
        #expect(hits.count == 10)
        #expect(Set(zip(hits.dropFirst(), hits).map { $0 - $1 }).isSubset(of: [3, 4]))
        #expect(Array(hits.prefix(5)).map { $0 + 16 } == Array(hits.suffix(5)))
    }

    @Test func inOrderCyclesAndRandomStaysInRange() {
        let ordered = schedule(["pick": .choice("inOrder"), "distribution": .choice("uniform"), "duration": .number(1)])
        #expect(ordered.map(\.clip) == (0..<8).map { $0 % 3 })
        let random = schedule(["pick": .choice("random"), "pitchJitter": .number(5), "panSpread": .number(40), "duration": .number(60)])
        #expect(Set(random.map(\.clip)) == [0, 1, 2])
        #expect(random.allSatisfy { abs($0.semitones) <= 5 && abs($0.pan) <= 0.4 })
        #expect(random.contains { abs($0.semitones) > 4 } && random.contains { abs($0.pan) > 0.3 })
    }

    @Test func theSameSeedGivesTheSameScatter() {
        let one = schedule(["seed": .number(4), "pitchJitter": .number(3)])
        #expect(one == schedule(["seed": .number(4), "pitchJitter": .number(3)]))
        #expect(one != schedule(["seed": .number(5), "pitchJitter": .number(3)]))
    }

    @Test func theRenderIsTotalDurationLongStereoAndDenserIsLouder() throws {
        let folder = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        var clips: [URL] = []
        for (index, hertz) in [300.0, 500.0, 700.0].enumerated() {
            let url = folder.appending(path: "clip \(index).wav")
            try TestAudio.write([(0..<2_400).map { Float(0.3 * sin(2 * .pi * hertz * Double($0) / rate)) }], to: url, sampleRate: rate)
            clips.append(url)
        }
        func energy(density: Double) throws -> Double {
            let url = folder.appending(path: "scatter \(density).wav")
            try Scatter.render(clips, parameters: ["duration": .number(3), "density": .number(density)], sampleRate: rate, to: url)
            let audio = try TestAudio.read(url).samples
            #expect(audio.count == 2 && audio[0].count == 3 * 48_000)
            #expect(audio[0].last == 0 && audio[1].last == 0)
            return audio.flatMap { $0 }.reduce(0) { $0 + Double($1 * $1) }
        }
        #expect(try energy(density: 20) > 2 * energy(density: 4))
    }
}
