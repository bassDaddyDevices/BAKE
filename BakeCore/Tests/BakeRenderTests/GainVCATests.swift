import BakeDSP
import Foundation
import Testing
@testable import BakeGraph
@testable import BakeRender

struct GainVCATests {
    private func render(_ input: [Float], gain: Float = 0, amount: [Float]? = nil, mode: bake.dsp.GainMode = .vca, chunk: Int? = nil) -> [Float] {
        var output = [Float](repeating: 0, count: input.count)
        let gainSignal = signal(gain, -60, 24)
        let control = amount ?? []
        control.withUnsafeBufferPointer { controlPointer in
            input.withUnsafeBufferPointer { source in
                output.withUnsafeMutableBufferPointer { destination in
                    var start = 0
                    while start < input.count {
                        let count = min(chunk ?? input.count, input.count - start)
                        var control = bake.dsp.ControlInput()
                        if amount != nil {
                            control.samples = controlPointer.baseAddress
                            control.frames = controlPointer.count
                        }
                        bake.dsp.renderGainVCA(
                            mode, gainSignal, source.baseAddress! + start, control,
                            destination.baseAddress! + start, start, count
                        )
                        start += count
                    }
                }
            }
        }
        return output
    }

    @Test func aBipolarLFOGivesASmoothTremolo() {
        let input = [Float](repeating: 1, count: 3)
        #expect(render(input, amount: [-1, 0, 1]) == [0, 0.5, 1])           // silent, half, full
        #expect(render(input, amount: [-1, 0, 1], mode: .ringMod) == [-1, 0, 1])
    }

    /// Review finding: a short Amount source (audio may drive a control input) was read past its end.
    @Test func aShortAmountSourceHoldsItsLastValue() {
        #expect(render([1, 1, 1, 1], amount: [1, -1]) == [1, 0, 0, 0])
    }

    @Test func unityGainAndDecibelsHaveKnownAnswers() {
        #expect(render([1, -0.5, 0.25]) == [1, -0.5, 0.25])
        #expect(abs(render([1, -1], gain: 6)[0] - Float(pow(10.0, 6.0 / 20.0))) < 2e-7)
        #expect(abs(render([1, -1], gain: 6)[1] + Float(pow(10.0, 6.0 / 20.0))) < 2e-7)
    }

    @Test func vcaAndRingModUseTheAmountSignal() {
        let input: [Float] = [1, 0.5, -1, -0.5]
        let amount: [Float] = [0, 0.25, 0.5, 1]
        // VCA maps −1…+1 to 0…1 (owner decision): 0 → 0.5, 0.25 → 0.625, 0.5 → 0.75, 1 → 1.
        #expect(render(input, amount: amount) == [0.5, 0.3125, -0.75, -0.5])
        #expect(render(input, amount: amount, mode: .ringMod) == [0, 0.125, -0.5, -0.5])
    }

    @Test func chunksOf777MatchOneWholeRender() {
        let input = TestAudio.samples(frames: 6_013, channels: 1)[0]
        let amount = (0..<input.count).map { Float(sin(Double($0) / 211)) }
        #expect(render(input, gain: 3, amount: amount) == render(input, gain: 3, amount: amount, chunk: 777))
    }

    @Test func repeatedRendersAreDeterministic() {
        let input = TestAudio.samples(frames: 2_048, channels: 1)[0]
        #expect(render(input, gain: 12) == render(input, gain: 12))
    }

    @Test func gainExtremesStayFinite() {
        let input = TestAudio.samples(frames: 1_024, channels: 1)[0]
        for gain in [Float(-60), 24] {
            #expect(render(input, gain: gain).allSatisfy { $0.isFinite })
        }
        #expect(render(input, amount: [Float](repeating: 1, count: input.count), mode: .ringMod).allSatisfy { $0.isFinite })
    }

    @Test func gainModulationChangesOutput() {
        let input: [Float] = [0.25, 0.5, -0.25, -0.5]
        var gainSignal = signal(0, -60, 24)
        let modulation = [Float](repeating: 1, count: input.count)
        modulation.withUnsafeBufferPointer { pointer in
            gainSignal.modulation = pointer.baseAddress
            gainSignal.modulationFrames = pointer.count
            var output = [Float](repeating: 0, count: input.count)
            input.withUnsafeBufferPointer { source in
                output.withUnsafeMutableBufferPointer { destination in
                    bake.dsp.renderGainVCA(.vca, gainSignal, source.baseAddress!, bake.dsp.ControlInput(), destination.baseAddress!, 0, input.count)
                }
            }
            #expect(output != input)
        }
    }

    @Test func audioVcaPrintKeepsStereoLength() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.wav")
        let samples = TestAudio.samples(frames: 2_048, channels: 2)
        try TestAudio.write(samples, to: source, sampleRate: 48_000)
        let output = directory.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var graph = TestProject()
        let audio = graph.add(.audio, asset: sourceAsset)
        let gain = graph.add(.gainVCA, ["gain": .number(6)])
        let print = graph.add(.print, ["bitDepth": .choice("32f")])
        graph.connect(audio, to: gain)
        graph.connect(gain, to: print)
        let urls = [sourceAsset: source]
        let request = RenderRequest(plan: try compile(graph.project, assetURLs: urls), assetURLs: urls, outputDirectory: output)
        let written = try #require(try await RenderEngine.render(request).outputs[print])
        let rendered = try TestAudio.read(written).samples
        #expect(rendered.count == 2)
        #expect(rendered.allSatisfy { $0.count == 2_048 })
        #expect(rendered.allSatisfy { $0.allSatisfy { $0.isFinite } })
        #expect(rendered[0][100] != samples[0][100])
    }
}
