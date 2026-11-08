import BakeDSP
import Foundation
import Testing
@testable import BakeGraph
@testable import BakeRender

/// The Chorus swarm and Dual Filter card pictures must show what the kernels do.
@Suite(.serialized)
struct CardPlotUpgradeTests {
    @Test func theSwarmPlotMatchesTheKernelsVoiceDelays() {
        let sampleRate = 48_000.0
        for (voices, reach, spread) in [(16, 200.0, 0.7), (64, 0.0, 1.0), (1_024, 5_000.0, 0.3)] {
            var table = [Double](repeating: 0, count: bake.dsp.chorusSwarmTableDoubles(Int32(voices)))
            bake.dsp.buildChorusSwarmTable(Int32(voices), reach, sampleRate, 0, &table)
            let plot = ChorusPlot.swarmDelays(voices: voices, detuneCents: 0, spread: spread, driftRate: 0.3, reachMilliseconds: reach, cycles: 0)
            #expect(plot.count == voices)
            for voice in 0..<voices {
                // Left channel: the resting delay is the centre plus Spread × (fan + the shared push), all in samples.
                let samples = 0.012 * sampleRate + spread * (table[voice] + table[voices + voice])
                #expect(abs(plot[voice] - samples / sampleRate * 1_000) < 1e-9, "\(voices) voices, voice \(voice)")
            }
        }
    }

    @Test func theSwarmStartsAtMoreThanEightVoicesOrAnyReach() {
        #expect(!ChorusPlot.isSwarm(voices: 8, reachMilliseconds: 0))
        #expect(ChorusPlot.isSwarm(voices: 16, reachMilliseconds: 0))
        #expect(ChorusPlot.isSwarm(voices: 4, reachMilliseconds: 1))
    }

    private func render(_ parameters: [String: ParameterValue], hertz: Double) async throws -> [Float] {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var patch = Patch()
        let url = directory.appendingPathComponent("source.wav")
        let samples = (0..<48_000).map { Float(0.25 * sin(2.0 * Double.pi * hertz * Double($0) / 48_000)) }
        try TestAudio.write([samples], to: url, sampleRate: 48_000)
        patch.assets[sourceAsset] = url
        let audio = patch.graph.add(.audio, asset: sourceAsset)
        var merged = NodeCatalog.defaultParameters(for: .dualFilter)
        for (id, value) in parameters { merged[id] = value }
        merged["lfoDepth"] = .number(0)
        let node = patch.graph.add(.dualFilter, merged)
        patch.wire(audio, "out", to: node, "in")
        patch.bake("out", from: node)
        return try #require(try await patch.render(in: directory, chunkFrames: 4_096)["out"])[0]
    }

    @Test func theDualFilterPlotMatchesTheKernel() async throws {
        let cases: [(String, [String: ParameterValue], Bool, Int)] = [
            ("default", [:], false, 24),
            ("morphAlpha", ["morph": .number(0.1), "bandwidth": .number(2)], false, 24),
            ("bandAndNotch", ["alphaType": .choice("bandpass"), "betaType": .choice("notch"), "morph": .number(0.6)], false, 24),
            ("steep", ["slope": .choice("48"), "q": .number(2)], false, 48),
            ("zeroPhase", ["phase": .choice("zero")], true, 24),
            ("halfMix", ["mix": .number(0.4)], false, 24),
        ]
        var failures: [String] = []
        for (name, parameters, zero, slope) in cases {
            for hertz in [200.0, 700.0, 1_000.0, 2_500.0, 6_000.0] {
                let output = try await render(parameters, hertz: hertz)
                let middle = output[16_000..<32_000]
                let rms = (middle.map { Double($0 * $0) }.reduce(0, +) / Double(middle.count)).squareRoot()
                let measured = 20 * log10(max(rms / (0.25 / 2.0.squareRoot()), 1e-9))
                let values = NodeCatalog.defaultParameters(for: .dualFilter).merging(parameters) { _, new in new }
                func number(_ id: String) -> Double { values[id]?.numberValue ?? 0 }
                func choice(_ id: String) -> String { if case .choice(let value)? = values[id] { value } else { "" } }
                let cutoffs = FrequencyResponse.dualFilterCutoffs(cutoff: number("cutoff"), spread: number("bandwidth"), lfoDepth: 0, inverted: true, lfo: 0)
                let plotted = FrequencyResponse.dualFilterDecibels(
                    alphaType: choice("alphaType"), betaType: choice("betaType"), cutoffs: cutoffs, q: number("q"), morph: number("morph"),
                    sections: slope / 12, zeroPhase: zero, mix: number("mix"), at: hertz
                )
                // Very deep notches are limited by the measurement, so only compare where the response is audible.
                if plotted > -50, abs(measured - plotted) > 0.3 { failures.append("\(name) \(hertz) Hz: kernel \(measured) dB, plot \(plotted) dB") }
            }
        }
        #expect(failures.isEmpty, "\(failures)")
    }
}
