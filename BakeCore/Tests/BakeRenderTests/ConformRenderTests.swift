import BakeDSP
import Foundation
import Testing
@testable import BakeGraph
@testable import BakeRender

/// Batch Conform's stretch, shift and formants, rendered.
struct ConformRenderTests {
    private let rate = 48_000.0

    private func render(_ signal: [Float], _ parameters: [ParameterID: ParameterValue]) async throws -> [Float] {
        let folder = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        var patch = Patch()
        let asset = AssetID(testUUID(7_000))
        let url = folder.appending(path: "in.wav")
        try TestAudio.write([signal], to: url, sampleRate: rate)
        patch.assets[asset] = url
        let audio = patch.graph.add(.audio, asset: asset)
        let conform = patch.graph.add(.batchConform, parameters)
        patch.wire(audio, "out", to: conform)
        patch.bake("out", from: conform)
        return try #require(try await patch.render(in: folder)["out"]?.first)
    }

    private func tone(_ hertz: Double, seconds: Double = 1) -> [Float] {
        (0..<Int(seconds * rate)).map { Float(0.4 * sin(2 * .pi * hertz * Double($0) / rate)) }
    }

    /// Frequency from rising zero crossings over the middle of the signal.
    private func frequency(_ signal: [Float]) -> Double {
        let middle = Array(signal[signal.count / 4..<(3 * signal.count / 4)])
        let crossings = (1..<middle.count).filter { middle[$0 - 1] < 0 && middle[$0] >= 0 }
        guard let first = crossings.first, let last = crossings.last, last > first else { return 0 }
        return Double(crossings.count - 1) * rate / Double(last - first)
    }

    @Test func nothingToDoIsAnExactCopy() async throws {
        let input = tone(330)
        #expect(try await render(input, [:]) == input)
    }

    @Test func theRatioSetsTheLengthAndTheShiftThePitch() async throws {
        let stretched = try await render(tone(220), ["ratio": .number(1.25)])
        #expect(stretched.count == 60_000)
        #expect(abs(frequency(stretched) / 220 - 1) < 0.01)
        // A to C: +3 semitones, 220 → 261.63 Hz, the length unchanged.
        let shifted = try await render(tone(220), ["shift": .number(3)])
        #expect(shifted.count == 48_000)
        #expect(abs(frequency(shifted) / 261.63 - 1) < 0.01)
        // Key Offset adds on top: +3 and −3 is no change in pitch.
        let back = try await render(tone(220), ["shift": .number(3), "keyOffset": .number(-3)])
        #expect(abs(frequency(back) / 220 - 1) < 0.01)
    }

    @Test func preservedFormantsStayWhereTheyWere() async throws {
        // A 110 Hz buzz with a formant around 800 Hz: harmonics weighted by a bell curve.
        let buzz: [Float] = (0..<48_000).map { i in
            let t = Double(i) / rate
            return Float((1...40).reduce(0.0) { sum, h in
                let f = 110.0 * Double(h)
                return sum + exp(-pow((f - 800) / 300, 2)) * sin(2 * .pi * f * t)
            } * 0.1)
        }
        func centroid(_ signal: [Float]) -> Double { bake.dsp.sortMeasure(.centroid, signal, signal.count, rate) }
        let original = centroid(buzz)
        let kept = centroid(try await render(buzz, ["shift": .number(12), "formants": .choice("preserve")]))
        let moved = centroid(try await render(buzz, ["shift": .number(12), "formants": .choice("shift")]))
        #expect(abs(kept / original - 1) < 0.25, "kept \(kept) vs \(original)")
        #expect(moved / original > 1.6, "moved \(moved) vs \(original)")
    }
}
