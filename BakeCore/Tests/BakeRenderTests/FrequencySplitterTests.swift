import BakeDSP
import Foundation
import Testing
@testable import BakeGraph
@testable import BakeRender

struct FrequencySplitterTests {
    struct Settings {
        var bands: Int32 = 3
        var splits: [Float] = [200, 2_000, 6_000, 12_000]
        var modulation: [Int: [Float]] = [:] // split index → signal
    }

    /// Renders one channel into every band, in `chunk`-frame calls.
    private func split(_ input: [Float], _ settings: Settings, chunk: Int? = nil) -> [[Float]] {
        var controls = bake.dsp.FrequencySplitterControls()
        controls.split1 = signal(settings.splits[0], 20, 20_000, scale: .exponential)
        controls.split2 = signal(settings.splits[1], 20, 20_000, scale: .exponential)
        controls.split3 = signal(settings.splits[2], 20, 20_000, scale: .exponential)
        controls.split4 = signal(settings.splits[3], 20, 20_000, scale: .exponential)
        controls.bands = settings.bands
        controls.sampleRate = 48_000
        var buffers: [UnsafeMutableBufferPointer<Float>] = []
        defer { buffers.forEach { $0.deallocate() } }
        for (index, values) in settings.modulation {
            let buffer = UnsafeMutableBufferPointer<Float>.allocate(capacity: values.count)
            _ = buffer.initialize(from: values)
            buffers.append(buffer)
            let pointer = UnsafePointer(buffer.baseAddress)
            switch index {
            case 0: controls.split1.modulation = pointer; controls.split1.modulationFrames = values.count
            case 1: controls.split2.modulation = pointer; controls.split2.modulationFrames = values.count
            case 2: controls.split3.modulation = pointer; controls.split3.modulationFrames = values.count
            default: controls.split4.modulation = pointer; controls.split4.modulationFrames = values.count
            }
        }
        let bands = Int(settings.bands)
        var outputs = (0..<bands).map { _ in UnsafeMutableBufferPointer<Float>.allocate(capacity: input.count) }
        defer { outputs.forEach { $0.deallocate() } }
        var state = bake.dsp.FrequencySplitterState()
        input.withUnsafeBufferPointer { source in
            var start = 0
            while start < input.count {
                let count = min(chunk ?? input.count, input.count - start)
                var targets = bake.dsp.FrequencySplitterOutputs()
                func at(_ band: Int) -> UnsafeMutablePointer<Float>? { band < bands ? outputs[band].baseAddress! + start : nil }
                targets.bands = (at(0), at(1), at(2), at(3), at(4))
                bake.dsp.renderFrequencySplitter(&state, controls, source.baseAddress! + start, targets, start, count)
                start += count
            }
        }
        _ = outputs.count
        return outputs.map { Array($0) }
    }

    private func rms(_ samples: ArraySlice<Float>) -> Float {
        sqrt(samples.reduce(0) { $0 + $1 * $1 } / Float(max(samples.count, 1)))
    }

    private func noise(frames: Int, amplitude: Float = 0.5) -> [Float] {
        var seed: UInt32 = 17
        return (0..<frames).map { _ in
            seed = seed &* 1_664_525 &+ 1_013_904_223
            return amplitude * (Float(seed >> 8) / Float(1 << 23) - 1)
        }
    }

    @Test(arguments: [Int32(2), 3, 4, 5])
    func bandsSumBackToTheInput(bands: Int32) {
        let input = noise(frames: 9_600)
        var settings = Settings(bands: bands)
        let plain = split(input, settings)
        for frame in 0..<input.count {
            let sum = plain.reduce(Float(0)) { $0 + $1[frame] }
            #expect(abs(sum - input[frame]) < 1e-6)
        }
        // Modulated splits too.
        settings.modulation = [0: (0..<9_600).map { Float($0) / 9_600 }, 1: [Float](repeating: -0.3, count: 9_600)]
        let moving = split(input, settings)
        for frame in 0..<input.count {
            let sum = moving.reduce(Float(0)) { $0 + $1[frame] }
            #expect(abs(sum - input[frame]) < 1e-6)
        }
    }

    @Test func lowsGoToTheFirstBand() {
        let input = sine(frequency: 50, frames: 48_000)
        let bands = split(input, Settings())
        #expect(rms(bands[0][24_000...]) > 0.9 * rms(input[24_000...]))
    }

    @Test func highsGoToTheLastBand() {
        let input = sine(frequency: 15_000, frames: 48_000)
        let bands = split(input, Settings())
        #expect(rms(bands[2][24_000...]) > 0.9 * rms(input[24_000...]))
    }

    @Test func unsortedSplitsAreSorted() {
        // Split 1 above Split 2: the bands still run low to high.
        let low = sine(frequency: 100, frames: 48_000)
        let bands = split(low, Settings(splits: [5_000, 300, 6_000, 12_000]))
        #expect(rms(bands[0][24_000...]) > 0.9 * rms(low[24_000...]))
    }

    @Test func chunksOf777MatchOneRender() {
        let input = noise(frames: 9_600)
        let settings = Settings(bands: 5, splits: [80, 400, 3_000, 9_000], modulation: [2: [Float](repeating: 0.2, count: 9_600)])
        #expect(split(input, settings, chunk: 777) == split(input, settings))
    }

    @Test func extremesAreFinite() {
        let input = noise(frames: 4_800, amplitude: 1)
        for splits: [Float] in [[20, 20, 20, 20], [20_000, 20_000, 20_000, 20_000], [20, 20_000, 20, 20_000]] {
            let bands = split(input, Settings(bands: 5, splits: splits))
            #expect(bands.allSatisfy { $0.allSatisfy { $0.isFinite } })
        }
    }

    @Test(arguments: [0, 1, 2, 3])
    func modulationMovesEverySplit(index: Int) {
        let input = noise(frames: 9_600)
        let base = Settings(bands: 5, splits: [100, 800, 3_000, 9_000])
        var moved = base
        moved.modulation[index] = [Float](repeating: 0.2, count: 9_600)
        #expect(split(input, moved, chunk: 777) != split(input, base, chunk: 777))
    }

    @Test func audioFrequencySplitterBakesEveryBand() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var patch = Patch()
        try patch.source(sourceAsset, channels: 2, frames: 24_000, in: directory)
        let audio = patch.graph.add(.audio, asset: sourceAsset)
        let splitter = patch.graph.add(.frequencySplitter, NodeCatalog.defaultParameters(for: .frequencySplitter))
        patch.wire(audio, "out", to: splitter)
        patch.bake("dry", from: audio)
        for band in 1...3 {
            patch.bake("band\(band)", from: splitter, "out\(band)")
        }
        let rendered = try await patch.render(in: directory)
        let small = try await patch.render(in: directory, chunkFrames: 777)
        #expect(rendered == small)
        let dry = try #require(rendered["dry"])
        for channel in 0..<2 {
            for frame in 0..<24_000 {
                let sum = (1...3).reduce(Float(0)) { $0 + rendered["band\($1)"]![channel][frame] }
                #expect(abs(sum - dry[channel][frame]) < 1e-5)
            }
        }
    }
}
