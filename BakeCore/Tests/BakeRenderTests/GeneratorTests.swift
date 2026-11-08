import BakeDSP
import Foundation
import Testing
@testable import BakeGraph
@testable import BakeRender

struct GeneratorTests {
    private typealias Kind = bake.dsp.GeneratorType

    /// One channel of a Generator, rendered in the given chunk sizes (one call by default).
    private func render(
        _ type: Kind, channel: Int32 = 0, seed: UInt32 = 0, level: Float = -12, density: Float = 10, frames: Int = 240_000, chunk: Int? = nil
    ) -> [Float] {
        var settings = bake.dsp.GeneratorSettings()
        settings.type = type
        settings.seed = seed
        var state = bake.dsp.GeneratorState()
        var output = [Float](repeating: 0, count: frames)
        output.withUnsafeMutableBufferPointer { buffer in
            var start = 0
            while start < frames {
                let count = min(chunk ?? frames, frames - start)
                bake.dsp.renderGenerator(
                    &state, settings, channel, signal(level, -96, 0), signal(density, 0.1, 20_000, scale: .exponential), 48_000,
                    buffer.baseAddress! + start, start, count
                )
                start += count
            }
        }
        return output
    }

    private func rms(_ values: [Float]) -> Double {
        (values.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(values.count)).squareRoot()
    }

    /// Power at one frequency (Goertzel).
    private func power(_ values: [Float], at frequency: Double) -> Double {
        let omega = 2 * Double.pi * frequency / 48_000
        let coefficient = 2 * cos(omega)
        var previous = 0.0, beforePrevious = 0.0
        for sample in values {
            let current = Double(sample) + coefficient * previous - beforePrevious
            beforePrevious = previous
            previous = current
        }
        return (previous * previous + beforePrevious * beforePrevious - coefficient * previous * beforePrevious) / Double(values.count * values.count)
    }

    /// Mean power over tones across a band, in dB.
    private func bandDecibels(_ values: [Float], from low: Double, to high: Double, tones: Int = 40) -> Double {
        let total = (0..<tones).map { power(values, at: low + (high - low) * (Double($0) + 0.5) / Double(tones)) }.reduce(0, +)
        return 10 * log10(total / Double(tones))
    }

    @Test func eachNoiseColourHasTheLevelAsItsRMS() {
        let expected = pow(10.0, -12.0 / 20.0)
        for type in [Kind.white, .pink, .brown, .blue, .violet] {
            // Brown drifts slowly (a 0.2 s memory), so its level needs a long render to settle.
            let output = render(type, seed: 3, frames: type == .brown ? 2_880_000 : 240_000)
            #expect(abs(rms(output) / expected - 1) < 0.08, "\(type): \(rms(output)) vs \(expected)")
            #expect(output.allSatisfy { $0.isFinite })
        }
    }

    @Test func theColoursFallAndRiseByTheirSlopes() {
        // Power per tone from about 1 kHz to about 8 kHz, three octaves apart.
        let expected: [(Kind, Double)] = [(.white, 0), (.pink, -3), (.brown, -6), (.blue, 3), (.violet, 6)]
        for (type, slope) in expected {
            let output = render(type, seed: 1, frames: 192_000)
            let low = bandDecibels(output, from: 800, to: 1_250)
            let high = bandDecibels(output, from: 6_400, to: 10_000)
            #expect(abs((high - low) / 3 - slope) < 1.0, "\(type): \((high - low) / 3) dB/oct, wanted \(slope)")
        }
    }

    @Test func anyChunkSizeGivesTheSameBits() {
        for type in [Kind.white, .pink, .brown, .blue, .violet, .dust, .velvet, .impulse, .silence] {
            for channel: Int32 in [0, 1] {
                let whole = render(type, channel: channel, seed: 5, level: -6, density: 300, frames: 20_000)
                for chunk in [1, 777, 4_096] {
                    #expect(render(type, channel: channel, seed: 5, level: -6, density: 300, frames: 20_000, chunk: chunk) == whole, "\(type) channel \(channel) chunk \(chunk)")
                }
            }
        }
    }

    @Test func theSameSeedRepeatsAndAnotherSeedOrChannelDiffers() {
        for type in [Kind.white, .pink, .brown, .blue, .violet] {
            let first = render(type, seed: 9, frames: 20_000)
            #expect(first == render(type, seed: 9, frames: 20_000), "\(type)")
            #expect(first != render(type, seed: 10, frames: 20_000), "\(type) seed")
            #expect(first != render(type, channel: 1, seed: 9, frames: 20_000), "\(type) channel")
        }
        // Different channels are uncorrelated.
        let left = render(.white, channel: 0, seed: 2, frames: 100_000), right = render(.white, channel: 1, seed: 2, frames: 100_000)
        let correlation = zip(left, right).reduce(0.0) { $0 + Double($1.0) * Double($1.1) } / Double(left.count) / (rms(left) * rms(right))
        #expect(abs(correlation) < 0.02)
    }

    @Test func anImpulseTrainStartsOnFrameZeroAtTheDensity() {
        let output = render(.impulse, level: -6, density: 100, frames: 4_700)
        let positions = output.indices.filter { output[$0] != 0 }
        #expect(positions.count == 10 && positions[0] == 0)
        for (index, position) in positions.enumerated() { #expect(abs(position - index * 480) <= 1, "impulse \(index) at \(position)") }
        #expect(abs(output[0] - Float(pow(10.0, -6.0 / 20.0))) < 1e-6)
        // The same impulses on every channel.
        #expect(render(.impulse, channel: 1, level: -6, density: 100, frames: 4_700) == output)
    }

    @Test func dustAndVelvetClickAtTheDensity() {
        let peak = Float(pow(10.0, -6.0 / 20.0))
        let velvet = render(.velvet, seed: 4, level: -6, density: 1_000, frames: 480_000)
        let clicks = velvet.filter { $0 != 0 }
        #expect(clicks.count > 9_500 && clicks.count < 10_500, "\(clicks.count) clicks")
        #expect(Set(clicks) == [peak, -peak])
        let dust = render(.dust, seed: 4, level: -6, density: 1_000, frames: 480_000)
        let dustClicks = dust.filter { $0 != 0 }
        #expect(dustClicks.count > 9_500 && dustClicks.count < 10_500)
        #expect(dustClicks.allSatisfy { abs($0) <= peak } && Set(dustClicks.map { abs($0) }).count > 100)
    }

    @Test func silenceIsSilent() {
        #expect(render(.silence, frames: 10_000).allSatisfy { $0 == 0 })
    }

    @Test func theCatalogDescribesTheGenerator() {
        let definition = NodeCatalog.definition(for: .generator)
        #expect(definition.pins.map(\.id) == ["out"])
        #expect(definition.lengthRule == .seconds("length"))
        #expect(definition.channelRule == .parameter("channels"))
        #expect(NodeKind.generator.category == .inOut)
        #expect(definition.parameter("length")?.isModulatable == false)
        #expect(definition.parameter("level")?.isModulatable == true)
    }

    @Test func aRenderedGeneratorHasItsLengthAndChannels() async throws {
        func bake(_ parameters: [String: ParameterValue]) async throws -> [[Float]] {
            let directory = try makeTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            var graph = TestProject()
            let generator = graph.add(.generator, parameters)
            let bakeNode = graph.add(.print, ["bitDepth": .choice("32f")])
            graph.connect(generator, to: bakeNode)
            let output = directory.appendingPathComponent("out", isDirectory: true)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            let request = RenderRequest(plan: try compile(graph.project, assetURLs: [:]), assetURLs: [:], outputDirectory: output)
            return try TestAudio.read(try #require(try await RenderEngine.render(request).outputs[bakeNode])).samples
        }
        let stereo = try await bake(["type": .choice("pink"), "channels": .choice("2"), "length": .number(0.5), "seed": .number(3)])
        #expect(stereo.count == 2 && stereo.allSatisfy { $0.count == 24_000 && $0.allSatisfy(\.isFinite) })
        #expect(stereo[0] != stereo[1])
        let mono = try await bake(["type": .choice("silence"), "length": .number(0.25)])
        #expect(mono.count == 1 && mono[0].count == 12_000 && mono[0].allSatisfy { $0 == 0 })
    }
}
