import BakeDSP
import Foundation
import Testing

struct StretchTests {
    /// Runs a stretch session over `input`, rendering in steps of `chunk` frames.
    private func stretch(
        _ input: [[Float]], outputFrames: Int, chunk: Int = 4_096,
        semitones: Float = 0, cents: Float = 0, pitchModulation: [Float]? = nil, fftSize: Int32 = 4_096
    ) -> [[Float]] {
        let channels = input.count
        let inputs = input.map { samples -> UnsafeMutablePointer<Float> in
            let pointer = UnsafeMutablePointer<Float>.allocate(capacity: samples.count)
            pointer.initialize(from: samples, count: samples.count)
            return pointer
        }
        let outputs = (0..<channels).map { _ in
            let pointer = UnsafeMutablePointer<Float>.allocate(capacity: outputFrames)
            pointer.initialize(repeating: 0, count: outputFrames)
            return pointer
        }
        defer {
            inputs.forEach { $0.deallocate() }
            outputs.forEach { $0.deallocate() }
        }
        let inputPointers: [UnsafePointer<Float>?] = inputs.map { UnsafePointer($0) }
        let outputPointers: [UnsafeMutablePointer<Float>?] = outputs
        let modulation = pitchModulation ?? []
        modulation.withUnsafeBufferPointer { modulationPointer in
            var pitch = signal(semitones, -24, 24)
            if pitchModulation != nil {
                pitch.modulation = modulationPointer.baseAddress
                pitch.modulationFrames = modulationPointer.count
            }
            let session = inputPointers.withUnsafeBufferPointer { inputArray in
                outputPointers.withUnsafeBufferPointer { outputArray in
                    bake.dsp.createStretchSession(
                        Int32(channels), 48_000, fftSize, inputArray.baseAddress, input[0].count, outputArray.baseAddress, outputFrames
                    )
                }
            }
            // The session copied the pointer arrays, so rendering outside the closures is safe.
            var frame = 0
            while frame < outputFrames {
                frame = min(frame + chunk, outputFrames)
                bake.dsp.renderStretch(session, frame, pitch, cents)
            }
            bake.dsp.destroyStretchSession(session)
        }
        return outputs.map { Array(UnsafeBufferPointer(start: $0, count: outputFrames)) }
    }

    /// Frequency from the first and last upward zero crossings (linearly interpolated) in the
    /// middle half of the signal — sub-cent precision for a steady tone.
    private func frequency(of signal: ArraySlice<Float>) -> Double {
        let middle = Array(signal.dropFirst(signal.count / 4).dropLast(signal.count / 4))
        var crossings: [Double] = []
        for index in 1..<middle.count where middle[index - 1] < 0 && middle[index] >= 0 {
            let fraction = Double(-middle[index - 1] / (middle[index] - middle[index - 1]))
            crossings.append(Double(index - 1) + fraction)
        }
        guard let first = crossings.first, let last = crossings.last, crossings.count > 1 else { return 0 }
        return Double(crossings.count - 1) / ((last - first) / 48_000)
    }

    private func cents(_ measured: Double, from expected: Double) -> Double {
        1_200 * log2(measured / expected)
    }

    @Test(arguments: [0.5, 2.5, 100.0])
    func outputHasThePlannedLength(ratio: Double) {
        let input = [sine(frequency: 440, frames: 4_800)]
        let frames = Int((4_800 * ratio).rounded())
        let output = stretch(input, outputFrames: frames)
        #expect(output[0].count == frames)
        #expect(output[0].allSatisfy { $0.isFinite })
        #expect(TestAudio.rms(Array(output[0][(frames / 4)..<(frames * 3 / 4)])) > 0.05)
    }

    @Test func timeStretchKeepsThePitch() {
        let output = stretch([sine(frequency: 440, frames: 48_000)], outputFrames: 96_000)
        #expect(abs(cents(frequency(of: output[0][...]), from: 440)) < 0.1)
    }

    /// Within 5 cents across musical intervals. Without the vendored phase-alignment patch,
    /// several of these were 5–25 cents off.
    @Test(arguments: [(440.0, Float(12), Float(0)), (440, 7, 50), (220, -5, 0), (523.25, 3, -25), (440, -12, 0)])
    func pitchShiftLandsOnTheInterval(input: Double, semitones: Float, cents offset: Float) {
        let output = stretch([sine(frequency: input, frames: 96_000)], outputFrames: 96_000, semitones: semitones, cents: offset)
        let expected = input * pow(2, (Double(semitones) + Double(offset) / 100) / 12)
        #expect(abs(cents(frequency(of: output[0][...]), from: expected)) < 5)
    }

    @Test func pitchFollowsModulation() {
        // Pitch range −24…+24 st spans 48; +0.25 modulation adds an octave from the second half on.
        let modulation = (0..<96_000).map { $0 < 48_000 ? Float(0) : 0.25 }
        let output = stretch([sine(frequency: 440, frames: 96_000)], outputFrames: 96_000, pitchModulation: modulation)
        #expect(abs(cents(frequency(of: output[0][8_000..<40_000]), from: 440)) < 5)
        #expect(abs(cents(frequency(of: output[0][56_000..<88_000]), from: 880)) < 5)
    }

    @Test func rendersAreDeterministicAndChunkInvariant() {
        let input = TestAudio.samples(frames: 24_000, channels: 2)
        let first = stretch(input, outputFrames: 240_000, chunk: 777) // ×10 — above the 2× random-phase threshold
        #expect(stretch(input, outputFrames: 240_000, chunk: 777) == first)
        #expect(stretch(input, outputFrames: 240_000, chunk: 65_536) == first)
    }

    @Test func veryShortInputsStillProduceAudio() {
        let output = stretch([sine(frequency: 440, frames: 500)], outputFrames: 1_000)
        #expect(TestAudio.rms(output[0]) > 0.05)
    }
}
