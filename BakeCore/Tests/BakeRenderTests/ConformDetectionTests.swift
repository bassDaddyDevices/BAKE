import BakeDSP
import Foundation
import Testing

/// Batch Conform's tempo and key detection, from known answers.
struct ConformDetectionTests {
    private let rate = 48_000.0

    /// A short decaying tone burst every 60/`bpm` seconds for `seconds`.
    private func beat(_ bpm: Double, seconds: Double = 8, hertz: Double = 1_000, decay: Double = 60) -> [Float] {
        let period = 60 / bpm * rate
        return (0..<Int(seconds * rate)).map { i in
            let t = (Double(i).truncatingRemainder(dividingBy: period)) / rate
            return Float(exp(-t * decay) * sin(2 * .pi * hertz * t) * 0.5)
        }
    }

    private func tones(_ hertz: [Double], seconds: Double = 2) -> [Float] {
        (0..<Int(seconds * rate)).map { i in Float(hertz.reduce(0) { $0 + sin(2 * .pi * $1 * Double(i) / rate) } * 0.2) }
    }

    private func tempo(_ signal: [Float], target: Double) -> Double { bake.dsp.conformTempo(signal, signal.count, rate, target) }
    private func key(_ signal: [Float]) -> Int { Int(bake.dsp.conformKey(signal, signal.count, rate)) }

    @Test func aClickTrackReadsItsTempo() {
        #expect(abs(tempo(beat(128), target: 128) - 128) <= 0.5)
        #expect(abs(tempo(beat(100, hertz: 300), target: 100) - 100) <= 0.5)
    }

    @Test func theTempoIsFoldedToTheOneNearestTheTarget() {
        let fourOnTheFloor = beat(90, hertz: 60, decay: 20)
        #expect(abs(tempo(fourOnTheFloor, target: 90) - 90) <= 0.5)
        #expect(abs(tempo(fourOnTheFloor, target: 170) - 180) <= 1)
        #expect(abs(tempo(fourOnTheFloor, target: 50) - 45) <= 0.5)
    }

    @Test func aSingleHitOrAPadHasNoTempo() {
        var hit = [Float](repeating: 0, count: 4 * 48_000)
        for i in 0..<4_800 { hit[i] = Float(exp(-Double(i) / rate * 40) * sin(Double(i) * 0.3)) }
        #expect(tempo(hit, target: 120).isNaN)
        #expect(tempo(tones([220, 330]), target: 120).isNaN)
    }

    @Test func aTriadOrAScaleReadsItsKey() {
        // A minor: A C E. A key index is 0–11 major, 12–23 minor.
        #expect(key(tones([220, 261.63, 329.63])) == 12 + 9)
        // C major: C E G.
        #expect(key(tones([261.63, 329.63, 392.0])) == 0)
        // A C-major scale ending on a long C.
        let notes = [261.63, 293.66, 329.63, 349.23, 392.0, 440.0, 493.88]
        let scale = notes.flatMap { tones([$0], seconds: 0.3) } + tones([261.63], seconds: 1.2)
        #expect(key(scale) == 0)
    }

    @Test func noiseHasNoKey() {
        var seed: UInt32 = 5
        let noise = (0..<96_000).map { _ -> Float in
            seed = seed &* 1_664_525 &+ 1_013_904_223
            return Float(seed >> 8) / Float(1 << 24) - 0.5
        }
        #expect(key(noise) == -1)
        #expect(key([Float](repeating: 0, count: 48_000)) == -1)
    }
}
