import BakeDSP
import Foundation
import Testing
@testable import BakeGraph
@testable import BakeRender

struct HalfTimeTests {
    private typealias Mode = bake.dsp.HalfTimeMode

    /// Renders Half Time over a whole source channel. Window, Smooth and Grain in frames.
    private func render(
        _ source: [Float], speed: Float = 0.5, window: Double = 24_000, mode: Mode = .repitch,
        smooth: Double = 0, grain: Int32 = 1_920, mix: Float = 1, sync: [Float]? = nil,
        speedModulation: [Float]? = nil, chunk: Int? = nil
    ) -> [Float] {
        var state = bake.dsp.HalfTimeState()
        var output = [Float](repeating: 0, count: source.count)
        var speedSignal = signal(speed, 0.001, 1, scale: .exponential)
        let mixSignal = signal(mix, 0, 1)
        let syncValues = sync ?? [], modulation = speedModulation ?? []
        modulation.withUnsafeBufferPointer { modulationPointer in
            if speedModulation != nil { speedSignal.modulation = modulationPointer.baseAddress; speedSignal.modulationFrames = modulationPointer.count }
            syncValues.withUnsafeBufferPointer { syncPointer in
                source.withUnsafeBufferPointer { sourcePointer in
                    output.withUnsafeMutableBufferPointer { destination in
                        var syncInput = bake.dsp.ControlInput()
                        if sync != nil { syncInput.samples = syncPointer.baseAddress; syncInput.frames = syncPointer.count }
                        var start = 0
                        while start < source.count {
                            let count = min(chunk ?? source.count, source.count - start)
                            bake.dsp.renderHalfTime(
                                &state, mode, speedSignal, mixSignal, window, smooth, grain, syncInput,
                                sourcePointer.baseAddress, sourcePointer.count, destination.baseAddress! + start, start, count
                            )
                            start += count
                        }
                    }
                }
            }
        }
        return output
    }

    private func ramp(_ frames: Int) -> [Float] { (0..<frames).map { Float($0) / Float(frames) } }

    /// Zero crossings per second over a range: twice the frequency of a sine.
    private func frequency(_ signal: [Float], in range: Range<Int>) -> Double {
        let crossings = range.dropFirst().filter { (signal[$0 - 1] < 0) != (signal[$0] < 0) }.count
        return Double(crossings) / 2 / (Double(range.count) / 48_000)
    }

    // MARK: the engine

    @Test func hermiteReadsALineExactlyAndOutsideIsSilent() {
        let line: [Float] = [0, 1, 2, 3, 4, 5]
        line.withUnsafeBufferPointer { pointer in
            #expect(abs(bake.dsp.timeMapRead(pointer.baseAddress, 6, 2.5) - 2.5) < 1e-6)
            #expect(bake.dsp.timeMapRead(pointer.baseAddress, 6, 3) == 3)
            #expect(bake.dsp.timeMapRead(pointer.baseAddress, 6, -1) == 0)
            #expect(bake.dsp.timeMapRead(pointer.baseAddress, 6, 6) == 0)
        }
    }

    // MARK: Half Time

    @Test func speedOneIsTheIdentity() {
        let source = sine(frequency: 330, frames: 30_000)
        #expect(render(source, speed: 1, smooth: 240) == source)
        let granular = render(source, speed: 1, mode: .granular)
        #expect(zip(granular[2_000..<28_000], source[2_000..<28_000]).allSatisfy { abs($0 - $1) < 1e-4 })
    }

    @Test func halfSpeedPlaysEachWindowAtHalfTheRate() {
        let source = ramp(48_000)
        let output = render(source, window: 24_000)
        // On a ramp the value at a source position is position / length, even between samples.
        func at(_ position: Double) -> Float { Float(position / 48_000) }
        for t in [100, 5_000, 23_999] {
            #expect(abs(output[t] - at(Double(t) / 2)) < 1e-5, "frame \(t)")      // first window starts at 0
        }
        for t in [24_000, 30_000, 47_999] {
            #expect(abs(output[t] - at(24_000 + Double(t - 24_000) / 2)) < 1e-5, "frame \(t)")   // re-synced at 24000
        }
    }

    @Test func repitchHalvesThePitchAndGranularKeepsIt() {
        let source = sine(frequency: 440, frames: 48_000, amplitude: 0.8)
        let repitched = render(source, window: 48_000)
        #expect(abs(frequency(repitched, in: 4_000..<44_000) - 220) < 3)
        let granular = render(source, window: 48_000, mode: .granular)
        #expect(abs(frequency(granular, in: 4_000..<44_000) - 440) < 6)
    }

    @Test func syncBangsStartTheWindows() {
        let source = ramp(48_000)
        var sync = [Float](repeating: 0, count: 48_000)
        for start in [0, 10_000, 30_000] { for frame in start..<(start + 10) { sync[frame] = 1 } }
        let output = render(source, window: 24_000, sync: sync)
        func at(_ position: Double) -> Float { Float(position / 48_000) }
        #expect(abs(output[10_000] - at(10_000)) < 1e-5)                          // re-synced at the bang
        #expect(abs(output[20_000] - at(15_000)) < 1e-5)
        #expect(abs(output[29_999] - at(10_000 + 19_999.0 / 2)) < 1e-5)           // the 24000 timer is ignored
    }

    @Test func smoothingRemovesTheClickAtEachJump() {
        // At 225 Hz the jump at 24000 goes from a peak (source 12000 = 56.25 cycles) to a zero (24000 = 112.5).
        let source = sine(frequency: 225, frames: 72_000, amplitude: 0.8)
        func largestStep(_ output: [Float]) -> Float {
            (23_000..<26_000).map { abs(output[$0] - output[$0 - 1]) }.max() ?? 0
        }
        #expect(largestStep(render(source, smooth: 0)) > 0.2)          // the jump clicks without smoothing
        #expect(largestStep(render(source, smooth: 240)) < 0.05)       // a 225 Hz sine never steps more than ~0.024
    }

    @Test func chunksOf777MatchOneWholeRender() {
        let source = sine(frequency: 190, frames: 40_000, amplitude: 0.7)
        let modulation = (0..<40_000).map { Float(sin(Double($0) / 3_000)) }
        for mode in [Mode.repitch, .granular] {
            let whole = render(source, window: 7_777, mode: mode, smooth: 240, speedModulation: modulation)
            #expect(render(source, window: 7_777, mode: mode, smooth: 240, speedModulation: modulation, chunk: 777) == whole)
        }
    }

    @Test func modulatedSpeedAndMixChangeTheOutput() {
        let source = sine(frequency: 300, frames: 20_000)
        let modulation = (0..<20_000).map { Float(sin(Double($0) / 900)) }
        #expect(render(source, speedModulation: modulation) != render(source))
        let halfWet = render(source, mix: 0.5)
        let wet = render(source)
        #expect(zip(halfWet, zip(source, wet)).allSatisfy { abs($0 - ($1.0 + $1.1) / 2) < 1e-5 })
    }

    @Test func extremesStayFinite() {
        let source = sine(frequency: 500, frames: 10_000, amplitude: 1)
        for speed in [Float(0.001), 1] {
            for mode in [Mode.repitch, .granular] {
                for window in [480.0, 384_000] {
                    let output = render(source, speed: speed, window: window, mode: mode, smooth: 2_400, grain: 240)
                    let finite = output.allSatisfy { $0.isFinite }
                    #expect(finite)
                }
            }
        }
    }

    @Test func rendersEndToEndKeepingLengthAndChannels() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("source.wav")
        try TestAudio.write(TestAudio.samples(frames: 30_000, channels: 2), to: file, sampleRate: 48_000)
        let output = directory.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var graph = TestProject()
        let audio = graph.add(.audio, asset: sourceAsset)
        let halfTime = graph.add(.halfTime, NodeCatalog.defaultParameters(for: .halfTime))
        let print = graph.add(.print, ["bitDepth": .choice("32f")])
        graph.connect(audio, to: halfTime)
        graph.connect(halfTime, to: print)
        let urls = [sourceAsset: file]
        let request = RenderRequest(plan: try compile(graph.project, assetURLs: urls), assetURLs: urls, outputDirectory: output, chunkFrames: 777)
        let rendered = try TestAudio.read(try #require(try await RenderEngine.render(request).outputs[print]))
        #expect(rendered.samples.count == 2 && rendered.samples[0].count == 30_000)
        #expect(rendered.samples[0] != TestAudio.samples(frames: 30_000, channels: 2)[0])
    }

    @Test func theCatalogDescribesHalfTime() {
        let definition = NodeCatalog.definition(for: .halfTime)
        #expect(definition.pins.map(\.id) == ["in", "sync", "out"])
        #expect(definition.lengthRule == .sameAsInput("in"))
        #expect(NodeKind.halfTime.category == .time)
        #expect(definition.parameter("speed")?.isModulatable == true)
    }
}
