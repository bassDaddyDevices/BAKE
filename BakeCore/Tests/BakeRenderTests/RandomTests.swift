import BakeDSP
import Foundation
import Testing
@testable import BakeGraph
@testable import BakeRender

struct RandomTests {
    private typealias Mode = bake.dsp.RandomMode
    private typealias Interpolation = bake.dsp.RandomInterpolation
    private typealias Distribution = bake.dsp.RandomDistribution

    /// Renders in the given chunk sizes (one call by default). `bangs` wires a Trigger.
    private func render(
        mode: Mode = .random, interpolation: Interpolation = .stepped, distribution: Distribution = .uniform,
        seed: UInt32 = 0, stepSize: Float = 0.15, glideMs: Double = 50, rate: Float = 100, minimum: Float = -1, maximum: Float = 1,
        smooth: Float = 0, bangs: [Int]? = nil, frames: Int = 4_800, chunk: Int? = nil
    ) -> [Float] {
        var settings = bake.dsp.RandomSettings()
        settings.mode = mode
        settings.interpolation = interpolation
        settings.distribution = distribution
        settings.seed = seed
        settings.stepSize = stepSize
        settings.glideFrames = glideMs / 1_000 * 48_000
        var state = bake.dsp.RandomState()
        var trigger = [Float](repeating: 0, count: frames)
        for start in bangs ?? [] { for frame in start..<min(start + 50, frames) { trigger[frame] = 1 } }
        var output = [Float](repeating: 0, count: frames)
        trigger.withUnsafeBufferPointer { triggerPointer in
            var input = bake.dsp.ControlInput()
            if bangs != nil { input.samples = triggerPointer.baseAddress; input.frames = triggerPointer.count }
            output.withUnsafeMutableBufferPointer { buffer in
                var start = 0
                while start < frames {
                    let count = min(chunk ?? frames, frames - start)
                    bake.dsp.renderRandom(
                        &state, settings, signal(rate, 0.01, 2_000, scale: .exponential), signal(minimum, -1, 1), signal(maximum, -1, 1),
                        signal(smooth, 0, 5_000), input, 48_000, buffer.baseAddress! + start, start, count
                    )
                    start += count
                }
            }
        }
        return output
    }

    private func runs(_ values: [Float]) -> Int {
        zip(values, values.dropFirst()).filter { $0 != $1 }.count + 1
    }

    @Test func stepsComeAtTheRate() {
        // 100 Hz at 48 kHz: a new value about every 480 frames, so 10 values in 4,700 frames.
        let output = render(rate: 100, frames: 4_700)
        #expect(runs(output) == 10)
        #expect(output[0] == output[470] && output[490] != output[470])
    }

    @Test func theSameSeedGivesTheSameSignalAndAnotherSeedADifferentOne() {
        #expect(render(seed: 5) == render(seed: 5))
        #expect(render(seed: 5) != render(seed: 6))
    }

    @Test func anyChunkSizeGivesTheSameBits() {
        let bangs = [700, 1_900, 2_000, 3_333, 4_700]
        for mode in [Mode.random, .walk] {
            for interpolation in [Interpolation.stepped, .linear, .cosine, .cubic] {
                for distribution in [Distribution.uniform, .gaussian, .coin] {
                    for trigger in [nil, bangs] {
                        let whole = render(mode: mode, interpolation: interpolation, distribution: distribution, seed: 9, smooth: 3, bangs: trigger)
                        for chunk in [1, 777, 4_096] {
                            #expect(
                                render(mode: mode, interpolation: interpolation, distribution: distribution, seed: 9, smooth: 3, bangs: trigger, chunk: chunk) == whole,
                                "\(mode) \(interpolation) \(distribution) trigger \(trigger != nil) chunk \(chunk)"
                            )
                        }
                    }
                }
            }
        }
    }

    @Test func valuesStayInsideMinAndMax() {
        for interpolation in [Interpolation.stepped, .linear, .cosine, .cubic] {
            for mode in [Mode.random, .walk] {
                let output = render(mode: mode, interpolation: interpolation, seed: 3, minimum: -0.25, maximum: 0.6, frames: 48_000)
                #expect(output.allSatisfy { $0 >= -0.25 - 1e-6 && $0 <= 0.6 + 1e-6 }, "\(mode) \(interpolation)")
            }
        }
    }

    @Test func aBangTakesTheNextStepAndTheFirstBangPlaysStepZero() {
        let output = render(bangs: [1_000, 3_000, 5_000], frames: 7_000)
        #expect(output[0] == output[999] && output[999] == output[1_000] && output[2_999] == output[1_000])   // the first bang keeps step 0
        #expect(output[3_000] != output[2_999] && output[4_999] == output[3_000])
        #expect(output[5_000] != output[4_999] && output[6_999] == output[5_000])
        #expect(runs(output) == 3)
    }

    @Test func linearInterpolationMovesSmoothly() {
        // The steps are 480 frames apart and differ by at most the full range (2): no sample may jump more than 2/480.
        let output = render(interpolation: .linear, seed: 4, frames: 24_000)
        let largest = zip(output, output.dropFirst()).map { abs($0 - $1) }.max() ?? 0
        #expect(largest <= 2.0 / 480.0 + 1e-5)
        #expect(runs(render(interpolation: .stepped, seed: 4, frames: 24_000)) < runs(output))
    }

    @Test func aTriggerGlideArrivesAndHoldsTheNewValue() {
        let stepped = render(interpolation: .stepped, seed: 8, bangs: [0, 2_000], frames: 6_000)
        let glided = render(interpolation: .cosine, seed: 8, glideMs: 10, bangs: [0, 2_000], frames: 6_000)
        #expect(glided[2_000] == stepped[1_999])                  // the glide starts where it was
        #expect(glided[2_000 + 480] == stepped[2_000 + 480])      // 10 ms later it has arrived
        #expect(glided[5_999] == stepped[5_999])
        #expect(glided[2_100] != stepped[2_100])                  // and between it was moving
    }

    @Test func aWalkMovesInSmallSteps() {
        let output = render(mode: .walk, stepSize: 0.15, frames: 96_000)
        let jumps = zip(output, output.dropFirst()).map { abs($0 - $1) }
        #expect((jumps.max() ?? 0) <= 2 * 0.15 + 1e-5)           // a step moves at most 0.15 of the 0…1 draw, which is 0.30 of the −1…1 range
        #expect(runs(output) > 150)                                // two seconds at 100 Hz
    }

    @Test func aCoinOnlyEverGivesMinOrMax() {
        let output = render(distribution: .coin, seed: 11, minimum: -0.5, maximum: 0.75, frames: 48_000)
        #expect(Set(output) == [-0.5, 0.75])
    }

    @Test func gaussianDrawsClusterAroundTheMiddle() {
        func variance(_ values: [Float]) -> Float {
            let mean = values.reduce(0, +) / Float(values.count)
            return values.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Float(values.count)
        }
        let uniform = render(distribution: .uniform, seed: 2, rate: 1_000, frames: 480_000)
        let gaussian = render(distribution: .gaussian, seed: 2, rate: 1_000, frames: 480_000)
        #expect(variance(gaussian) < variance(uniform) * 0.6)
    }

    @Test func smoothingSoftensTheSteps() {
        let hard = render(seed: 6, smooth: 0, frames: 24_000)
        let soft = render(seed: 6, smooth: 4, frames: 24_000)
        func largestJump(_ values: [Float]) -> Float { zip(values, values.dropFirst()).map { abs($0 - $1) }.max() ?? 0 }
        #expect(largestJump(soft) < largestJump(hard) * 0.5)
        #expect(soft != hard)
    }

    @Test func theCatalogDescribesRandom() {
        let definition = NodeCatalog.definition(for: .random)
        #expect(definition.pins.map(\.id) == ["trigger", "out"])
        #expect(definition.lengthRule == .followsConsumers)
        #expect(NodeKind.random.category == .modulation && NodeCatalog.outputSignals(of: .random).allSatisfy { $0 == .control })
        #expect(definition.parameter("rate")?.isModulatable == true)
        #expect(definition.parameter("seed")?.isInteger == true)
    }

    @Test func seededStepsReachTheRenderedFile() async throws {
        func bake(seed: Double) async throws -> [Float] {
            let directory = try makeTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let file = directory.appendingPathComponent("dc.wav")
            try TestAudio.write([[Float](repeating: 1, count: 24_000)], to: file, sampleRate: 48_000)
            var graph = TestProject()
            let audio = graph.add(.audio, asset: sourceAsset)
            let random = graph.add(.random, ["rate": .number(50), "seed": .number(seed), "min": .number(0), "max": .number(1)])
            let vca = graph.add(.gainVCA, NodeCatalog.defaultParameters(for: .gainVCA))
            let bakeNode = graph.add(.print, ["bitDepth": .choice("32f")])
            graph.connect(audio, to: vca)
            graph.connect(random, to: vca, "amount")
            graph.connect(vca, to: bakeNode)
            let output = directory.appendingPathComponent("out", isDirectory: true)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            let urls = [sourceAsset: file]
            let request = RenderRequest(plan: try compile(graph.project, assetURLs: urls), assetURLs: urls, outputDirectory: output)
            return try TestAudio.read(try #require(try await RenderEngine.render(request).outputs[bakeNode])).samples[0]
        }
        let first = try await bake(seed: 1), again = try await bake(seed: 1), other = try await bake(seed: 2)
        #expect(first == again && first != other)
        #expect(first.count == 24_000)
    }
}
