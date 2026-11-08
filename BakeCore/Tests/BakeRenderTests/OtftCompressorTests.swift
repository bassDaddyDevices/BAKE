import BakeDSP
import Foundation
import Testing
@testable import BakeGraph
@testable import BakeRender

struct OtftCompressorTests {
    private static let rate = 48_000.0

    struct Settings {
        var downThreshold: Float = -20, downRatio: Float = 4, upThreshold: Float = -90, upRatio: Float = 1
        var maxBoost: Float = 24, attack: Float = 10, release: Float = 100, knee: Float = 0
        var anticipating = false
        var smoothTime = 0.0
        var smoothFreq = 0.0
    }

    private func signal(_ value: Float) -> bake.dsp.ParameterSignal {
        var signal = bake.dsp.ParameterSignal()
        signal.base = value
        signal.minimum = -1_000_000
        signal.maximum = 1_000_000
        return signal
    }

    private func layout() -> bake.dsp.StftLayout {
        var layout = bake.dsp.StftLayout()
        layout.fftSize = 4096
        layout.hop = 1024
        return layout
    }

    /// The whole CPU pipeline on one channel: levels, gains, render.
    private func compress(_ input: [Float], _ settings: Settings) -> [Float] {
        let layout = layout()
        let count = input.count
        let bins = Int(bake.dsp.stftBinCount(layout))
        let frames = Int(bake.dsp.stftFrameCount(layout, count))
        var edges = [UInt32](repeating: 0, count: bins + 1)
        bake.dsp.otftUnitEdges(layout, 0, &edges)
        var surface = [Float](repeating: bake.dsp.otftFloorDb, count: frames * bins)
        input.withUnsafeBufferPointer { buffer in
            var first = 0
            while first < frames {
                let blockCount = min(8, frames - first)
                var spectrum = [Float](repeating: 0, count: blockCount * bins * 2)
                var scratch = [Double](repeating: 0, count: Int(bake.dsp.otftScratchDoubles(layout)))
                bake.dsp.otftLevels(layout, buffer.baseAddress, count, first, blockCount, edges, bins, false, &surface, &spectrum, &scratch)
                first += blockCount
            }
        }
        var params = [bake.dsp.OtftFrameParams](repeating: bake.dsp.OtftFrameParams(), count: frames)
        bake.dsp.otftFrameParams(
            layout, count, frames, signal(settings.downThreshold), signal(settings.downRatio), signal(settings.upThreshold),
            signal(settings.upRatio), signal(settings.maxBoost), signal(settings.attack), signal(settings.release), &params
        )
        var timeScale = [Float](repeating: 1, count: bins)
        var offset = [Float](repeating: 0, count: bins)
        bake.dsp.otftUnitTables(layout, Self.rate, edges, bins, 0, nil, 0, &timeScale, &offset)
        var envelope = bake.dsp.OtftEnvelope()
        envelope.hopMilliseconds = Float(1000.0 * 1024.0 / Self.rate)
        envelope.kneeDb = settings.knee
        envelope.anticipating = settings.anticipating ? 1 : 0
        envelope.smoothFrames = UInt32((settings.smoothTime * 100.0 / Double(envelope.hopMilliseconds)).rounded())
        var column = [Float](repeating: 0, count: frames)
        bake.dsp.otftGainColumns(params, frames, bins, 0, bins, timeScale, offset, envelope, &surface, &column)
        var lower = [UInt32](repeating: 0, count: bins)
        var weight = [Float](repeating: 0, count: bins)
        bake.dsp.otftBinMap(layout, edges, bins, &lower, &weight)
        var window = [Double](repeating: 0, count: 4096)
        bake.dsp.stftWindow(layout, &window)
        var output = [Float](repeating: 0, count: count)
        let block = 8_192
        var floats = [Float](repeating: 0, count: Int(bake.dsp.otftRenderFloats(layout, block)))
        var scratch = [Double](repeating: 0, count: Int(bake.dsp.otftScratchDoubles(layout)))
        input.withUnsafeBufferPointer { buffer in
            var start = 0
            while start < count {
                let length = min(block, count - start)
                output.withUnsafeMutableBufferPointer { out in
                    bake.dsp.otftRenderBlock(
                        layout, window, buffer.baseAddress, count, surface, bins, lower, weight, settings.smoothFreq, start, length,
                        out.baseAddress.map { $0 + start }, &floats, &scratch
                    )
                }
                start += length
            }
        }
        return output
    }

    private func sine(_ amplitude: Float, seconds: Double = 3) -> [Float] {
        (0..<Int(Self.rate * seconds)).map { amplitude * Float(sin(2 * Double.pi * 1_000 * Double($0) / Self.rate)) }
    }

    private func noise(_ amplitude: Float, seconds: Double = 3) -> [Float] {
        var seed: UInt64 = 7
        return (0..<Int(Self.rate * seconds)).map { _ in
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return amplitude * Float(Int64(bitPattern: seed) >> 40) / Float(1 << 23)
        }
    }

    private func rmsDb(_ values: ArraySlice<Float>) -> Double {
        let sum = values.reduce(0.0) { $0 + Double($1) * Double($1) }
        return 10 * log10(sum / Double(values.count) + 1e-20)
    }

    @Test func aCompressorThatDoesNothingGivesTheInputBack() {
        var settings = Settings()
        settings.downThreshold = 0
        settings.upThreshold = -120
        let hiss = noise(0.01)
        let input = zip(sine(0.5), hiss).map { $0 + $1 }
        let output = compress(input, settings)
        var worst: Float = 0
        for index in 0..<input.count { worst = max(worst, abs(output[index] - input[index])) }
        #expect(worst < 1e-4)
    }

    @Test func downwardCompressionTamesALoudBin() {
        var settings = Settings()
        settings.downThreshold = -20
        settings.downRatio = 100
        settings.attack = 0.1
        settings.release = 1
        let input = sine(0.5)
        let output = compress(input, settings)
        let middle = (input.count / 3)..<(input.count * 2 / 3)
        let before = rmsDb(input[middle]), after = rmsDb(output[middle])
        #expect(after < before - 6, "\(before) → \(after) dB")
    }

    @Test func upwardCompressionLiftsQuietMaterial() {
        var settings = Settings()
        settings.downThreshold = 0
        settings.upThreshold = -60
        settings.upRatio = 20
        settings.maxBoost = 40
        settings.attack = 0.1
        settings.release = 1
        let input = noise(0.003)
        let output = compress(input, settings)
        let middle = (Int(Self.rate))..<(Int(Self.rate) * 2)
        #expect(rmsDb(output[middle]) > rmsDb(input[middle]) + 10)
    }

    @Test func maxBoostCapsTheLift() {
        var settings = Settings()
        settings.downThreshold = 0
        settings.upThreshold = -60
        settings.upRatio = 20
        settings.maxBoost = 6
        settings.attack = 0.1
        settings.release = 1
        let input = noise(0.003)
        let output = compress(input, settings)
        let middle = (Int(Self.rate))..<(Int(Self.rate) * 2)
        let lift = rmsDb(output[middle]) - rmsDb(input[middle])
        #expect(abs(lift - 6) < 1, "lift \(lift) dB")
    }

    @Test func lookAheadStartsTheGainBeforeALoudFrame() {
        let count = Int(Self.rate * 3)
        let step = (0..<count).map { index -> Float in
            (index < Int(Self.rate * 1.5) ? 0.01 : 0.8) * Float(sin(2 * Double.pi * 1_000 * Double(index) / Self.rate))
        }
        var settings = Settings()
        settings.downThreshold = -30
        settings.downRatio = 100
        settings.attack = 50
        settings.release = 50
        let causal = compress(step, settings)
        settings.anticipating = true
        let anticipating = compress(step, settings)
        let start = Int(Self.rate * 1.5) - Int(Self.rate * 0.04)
        let window = start..<(start + 800)
        #expect(rmsDb(anticipating[window]) < rmsDb(causal[window]))
    }

    @Test func groupingBinsGivesTheRequestedUnits() {
        let layout = layout()
        let units = Int(bake.dsp.otftUnitCount(layout, 16))
        #expect(units == 16)
        var edges = [UInt32](repeating: 0, count: 17)
        bake.dsp.otftUnitEdges(layout, 16, &edges)
        #expect(edges.first == 0)
        #expect(edges.last == UInt32(bake.dsp.stftBinCount(layout)))
        #expect(zip(edges, edges.dropFirst()).allSatisfy { $0 < $1 })
    }

    @Test func theThresholdCurveParsesAndSorts() {
        let points = OtftCompressorProcessor.parseCurve("8000:-55 100:-30, 1000:-40 junk 5")
        #expect(points.map { $0.hertz } == [100, 1_000, 8_000])
        #expect(points.map { $0.decibels } == [-30, -40, -55])
    }

    @Test func theCatalogPutsItInTheSpectralGroup() {
        let definition = NodeCatalog.definition(for: .otftCompressor)
        #expect(NodeKind.otftCompressor.category == .spectral)
        #expect(definition.pins.contains { $0.id == "sidechain" && !$0.isRequired })
        #expect(definition.parameter("engine") != nil)
        #expect(definition.lengthRule == .sameAsInput("in"))
        #expect(!NodeCatalog.isCausal(Node(kind: .otftCompressor, parameters: [:])))
    }
}
