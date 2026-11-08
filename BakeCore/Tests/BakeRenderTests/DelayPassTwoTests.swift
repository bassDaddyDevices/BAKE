import BakeDSP
import Foundation
import Testing
@testable import BakeGraph
@testable import BakeRender

/// Reverse taps, Pitch per Repeat and Freeze, run straight through the kernel with a small helper of their own.
struct DelayPassTwoTests {
    private static let rate = 48_000.0

    private struct Setup {
        var time: Float = 300, feedback: Float = 0, damping: Float = 20_000, mix: Float = 1, pingPong: Double = 0
        var tapFrames: [Double] = [], tapGains: [Float] = [], tapReversed: [UInt8] = []
        var pitch: Double = 0
        /// Seconds at which the loop freezes; negative for never.
        var freezeAt: Double = -1
    }

    private func signal(_ value: Float, minimum: Float, maximum: Float) -> bake.dsp.ParameterSignal {
        var signal = bake.dsp.ParameterSignal()
        signal.base = value
        signal.minimum = minimum
        signal.maximum = maximum
        return signal
    }

    /// `channels` through the kernel in chunks of `chunk` frames; the output is as long as the input.
    private func render(_ channels: [[Float]], _ setup: Setup, chunk: Int) -> [[Float]] {
        let frames = channels[0].count
        let count = channels.count
        var controls = bake.dsp.DelayControls()
        controls.time = signal(setup.time, minimum: 1, maximum: 60_000)
        controls.feedback = signal(setup.feedback, minimum: 0, maximum: 1)
        controls.damping = signal(setup.damping, minimum: 200, maximum: 20_000)
        controls.mix = signal(setup.mix, minimum: 0, maximum: 1)
        controls.pingPong = setup.pingPong
        controls.sampleRate = Self.rate
        let lineFrames = Int(bake.dsp.delayLineFrames(4_000, Self.rate))
        controls.lineFrames = lineFrames

        let taps = max(setup.tapFrames.count, 1)
        let tapFrames = UnsafeMutablePointer<Double>.allocate(capacity: taps)
        let tapGains = UnsafeMutablePointer<Float>.allocate(capacity: taps)
        let tapReversed = UnsafeMutablePointer<UInt8>.allocate(capacity: taps)
        tapFrames.initialize(repeating: 0, count: taps)
        tapGains.initialize(repeating: 0, count: taps)
        tapReversed.initialize(repeating: 0, count: taps)
        for index in setup.tapFrames.indices {
            tapFrames[index] = setup.tapFrames[index]
            tapGains[index] = setup.tapGains[index]
            tapReversed[index] = setup.tapReversed[index]
        }
        controls.tapFrames = UnsafePointer(tapFrames)
        controls.tapGains = UnsafePointer(tapGains)
        controls.tapReversed = UnsafePointer(tapReversed)
        controls.tapCount = setup.tapFrames.count

        let lines = (0..<count).map { _ -> UnsafeMutablePointer<Float> in
            let pointer = UnsafeMutablePointer<Float>.allocate(capacity: lineFrames)
            pointer.initialize(repeating: 0, count: lineFrames)
            return pointer
        }
        let linePointers = UnsafeMutablePointer<UnsafeMutablePointer<Float>?>.allocate(capacity: count)
        for channel in 0..<count { linePointers[channel] = lines[channel] }

        let window = min(max(Double(setup.time) * 0.001 * Self.rate * 0.5, 256), 0.04 * Self.rate).rounded(.down)
        let shifterFrames = Int(window) + 64
        let shifters = (0..<count).map { _ -> UnsafeMutablePointer<Float> in
            let pointer = UnsafeMutablePointer<Float>.allocate(capacity: shifterFrames)
            pointer.initialize(repeating: 0, count: shifterFrames)
            return pointer
        }
        let shifterPointers = UnsafeMutablePointer<UnsafeMutablePointer<Float>?>.allocate(capacity: count)
        for channel in 0..<count { shifterPointers[channel] = shifters[channel] }
        if setup.pitch != 0 {
            controls.pitchSemitones = setup.pitch
            controls.shifterWindow = window
            controls.shifterFrames = shifterFrames
            controls.shifterLines = UnsafePointer(shifterPointers)
        }
        if setup.freezeAt >= 0 {
            controls.freezeFrame = (setup.freezeAt * Self.rate).rounded()
            controls.freezeFade = 0.02 * Self.rate
        }

        let inputs = channels.map { channel -> UnsafeMutablePointer<Float> in
            let pointer = UnsafeMutablePointer<Float>.allocate(capacity: frames)
            pointer.initialize(from: channel, count: frames)
            return pointer
        }
        var input = bake.dsp.AudioInput()
        input.channelCount = count
        input.frames = frames
        input.channels.0 = UnsafePointer(inputs[0])
        if count > 1 { input.channels.1 = UnsafePointer(inputs[1]) }

        let outputs = (0..<count).map { _ -> UnsafeMutablePointer<Float> in
            let pointer = UnsafeMutablePointer<Float>.allocate(capacity: frames)
            pointer.initialize(repeating: 0, count: frames)
            return pointer
        }
        let outputPointers = UnsafeMutablePointer<UnsafeMutablePointer<Float>?>.allocate(capacity: count)
        let states = UnsafeMutablePointer<bake.dsp.DelayState>.allocate(capacity: count)
        states.initialize(repeating: bake.dsp.DelayState(), count: count)
        defer {
            tapFrames.deallocate(); tapGains.deallocate(); tapReversed.deallocate()
            lines.forEach { $0.deallocate() }; linePointers.deallocate()
            shifters.forEach { $0.deallocate() }; shifterPointers.deallocate()
            inputs.forEach { $0.deallocate() }
            outputs.forEach { $0.deallocate() }; outputPointers.deallocate()
            states.deallocate()
        }

        var start = 0
        while start < frames {
            let length = min(chunk, frames - start)
            for channel in 0..<count { outputPointers[channel] = outputs[channel] + start }
            bake.dsp.renderDelay(states, linePointers, outputPointers, Int32(count), 0, input, controls, start, length)
            start += length
        }
        return outputs.map { Array(UnsafeBufferPointer(start: $0, count: frames)) }
    }

    /// A sine's frequency from its zero crossings over `range`.
    private func frequency(_ samples: [Float], _ range: Range<Int>) -> Double {
        var crossings = 0
        for index in (range.lowerBound + 1)..<range.upperBound where (samples[index - 1] < 0) != (samples[index] < 0) {
            crossings += 1
        }
        return Double(crossings) / 2 / (Double(range.count) / Self.rate)
    }

    private func burst(_ hertz: Double, seconds: Double, total: Double) -> [Float] {
        let count = Int(Self.rate * total), length = Int(Self.rate * seconds)
        return (0..<count).map { $0 < length ? Float(0.8 * sin(2 * Double.pi * hertz * Double($0) / Self.rate)) : 0 }
    }

    // MARK: Reverse taps

    @Test func aReversedTapPlaysTheLastStretchBackwards() {
        var clicks = [Float](repeating: 0, count: 96_000)
        clicks[10_000] = 1
        clicks[10_500] = 0.5
        var setup = Setup()
        setup.time = 1_800
        setup.tapFrames = [4_800]
        setup.tapGains = [1]
        setup.tapReversed = [1]
        let output = render([clicks], setup, chunk: 4_096)[0]
        func weight(_ n: Double) -> Float { Float(0.5 - 0.5 * cos(2 * Double.pi * n / 4_800)) }
        // The grain that starts at frame 12 000 plays frames 11 999, 11 998, … so a click at p sounds at 2·12 000 − 1 − p.
        #expect(abs(output[13_499] - 0.5 * weight(12_000 - 1 - 10_500)) < 1e-5)
        #expect(abs(output[13_999] - weight(12_000 - 1 - 10_000)) < 1e-5)
        // The later click comes first: that is what backwards means.
        #expect(abs(output[13_499]) > 0.3 && abs(output[13_999]) > 0.9)
        #expect(abs(output[18_799] - weight(14_400 - 1 - 10_000)) < 1e-5)
        let sounding = output[0..<48_000].filter { abs($0) > 1e-7 }.count
        #expect(sounding == 4)
    }

    @Test func aReversedTapNeverReadsTheFuture() {
        // A click at frame 20 000 must not be heard before it happens, whatever the tap's length.
        var clicks = [Float](repeating: 0, count: 96_000)
        clicks[20_000] = 1
        var setup = Setup()
        setup.time = 1_800
        setup.tapFrames = [9_600]
        setup.tapGains = [1]
        setup.tapReversed = [1]
        let output = render([clicks], setup, chunk: 1_000)[0]
        let silent = output[0..<20_000].allSatisfy { $0 == 0 }
        #expect(silent)
    }

    @Test func tapTextMarksReversedTaps() {
        let taps = DelayProcessor.parseTaps("375 500r@-6, 750R 1000@-12 r")
        #expect(taps.count == 4)
        #expect(taps[0].reversed == false)
        #expect(taps[1].reversed == true && taps[1].milliseconds == 500 && abs(taps[1].gain - 0.5012) < 0.001)
        #expect(taps[2].reversed == true && taps[2].milliseconds == 750)
        #expect(taps[3].reversed == false && taps[3].milliseconds == 1_000)
    }

    // MARK: Pitch per repeat

    @Test(arguments: [12.0, -12.0, 7.0])
    func theFirstRepeatIsShiftedByThePitch(semitones: Double) {
        var setup = Setup()
        setup.pitch = semitones
        let output = render([burst(1_000, seconds: 0.4, total: 1.5)], setup, chunk: 1_013)[0]
        let expected = 1_000 * pow(2, semitones / 12)
        let measured = frequency(output, Int(0.34 * Self.rate)..<Int(0.42 * Self.rate))
        #expect(abs(measured - expected) / expected < 0.03, "\(measured) Hz against \(expected) Hz")
        let peak = output[Int(0.3 * Self.rate)..<Int(0.7 * Self.rate)].map { abs($0) }.max() ?? 0
        #expect(abs(peak - 0.8) < 0.05, "peak \(peak)")
    }

    @Test func everyRepeatIsShiftedFurtherThanTheLast() {
        var setup = Setup()
        setup.pitch = 12
        setup.feedback = 0.9
        let output = render([burst(1_000, seconds: 0.4, total: 1.5)], setup, chunk: 1_013)[0]
        let second = frequency(output, Int(0.66 * Self.rate)..<Int(0.72 * Self.rate))
        #expect(abs(second - 4_000) / 4_000 < 0.05, "\(second) Hz")
    }

    @Test func withNoPitchTheRepeatIsUntouched() {
        let input = burst(1_000, seconds: 0.4, total: 1.0)
        let plain = render([input], Setup(), chunk: 1_013)[0]
        let delayed = [Float](repeating: 0, count: 14_400) + Array(input.dropLast(14_400))
        #expect(plain == delayed)
    }

    @Test func theShiftedRepeatArrivesCloseToTime() {
        var setup = Setup()
        setup.pitch = 12
        let output = render([burst(1_000, seconds: 0.4, total: 1.5)], setup, chunk: 1_013)[0]
        let first = output.firstIndex { abs($0) > 0.05 } ?? 0
        let milliseconds = Double(first) * 1_000 / Self.rate
        #expect(abs(milliseconds - 300) < 25, "first repeat at \(milliseconds) ms")
    }

    // MARK: Freeze

    @Test func aFrozenLoopRepeatsBitForBitAndIgnoresLaterInput() {
        let count = Int(Self.rate * 4)
        var noise = [Float](repeating: 0, count: count)
        var state: UInt32 = 12_345
        func next() -> Float {
            state = state &* 1_664_525 &+ 1_013_904_223
            return Float(Int32(bitPattern: state) >> 8) / Float(1 << 23) * 0.3
        }
        for index in 0..<Int(Self.rate * 0.5) { noise[index] = next() }
        for index in Int(Self.rate * 2)..<Int(Self.rate * 2.5) { noise[index] = next() }
        var setup = Setup()
        setup.time = 200
        setup.freezeAt = 0.4
        let output = render([noise], setup, chunk: 977)[0]
        let period = 9_600
        let from = Int(0.4 * Self.rate) + 960 + period + 10
        let repeats = (from..<(count - period)).allSatisfy { output[$0] == output[$0 + period] }
        #expect(repeats)
        let energy = output[from..<(from + period)].reduce(0.0) { $0 + Double($1 * $1) } / Double(period)
        #expect(energy.squareRoot() > 0.1)
    }

    @Test func withoutFreezeTheSameLineGoesSilent() {
        var noise = [Float](repeating: 0, count: Int(Self.rate * 3))
        for index in 0..<Int(Self.rate * 0.5) { noise[index] = Float(sin(Double(index) * 0.37)) * 0.3 }
        var setup = Setup()
        setup.time = 200
        let output = render([noise], setup, chunk: 977)[0]
        let quiet = output[Int(1.2 * Self.rate)..<Int(1.9 * Self.rate)].allSatisfy { $0 == 0 }
        #expect(quiet)
    }

    @Test func aFrozenLoopStillSoundsThroughPitch() {
        var noise = [Float](repeating: 0, count: Int(Self.rate * 4))
        for index in 0..<Int(Self.rate * 0.5) { noise[index] = Float(sin(Double(index) * 0.21)) * 0.3 }
        var setup = Setup()
        setup.time = 200
        setup.freezeAt = 0.4
        setup.pitch = 7
        let output = render([noise], setup, chunk: 977)[0]
        let slice = output[Int(3 * Self.rate)..<Int(3.5 * Self.rate)]
        let energy = slice.reduce(0.0) { $0 + Double($1 * $1) } / Double(slice.count)
        #expect(energy.squareRoot() > 0.05)
    }

    // MARK: Together

    @Test func everythingOnGivesTheSameBitsAtAnyChunkSize() {
        let count = Int(Self.rate * 3)
        let left = (0..<count).map { Float(sin(Double($0) * 0.013) * cos(Double($0) * 0.0007)) * 0.4 }
        let right = (0..<count).map { Float(sin(Double($0) * 0.021)) * 0.3 }
        var setup = Setup()
        setup.time = 230
        setup.feedback = 0.7
        setup.damping = 5_000
        setup.mix = 0.6
        setup.pingPong = 0.8
        setup.pitch = 5
        setup.freezeAt = 1.7
        setup.tapFrames = [0.375 * Self.rate, 0.5 * Self.rate]
        setup.tapGains = [1, 0.5]
        setup.tapReversed = [0, 1]
        let whole = render([left, right], setup, chunk: count)
        let pieces = render([left, right], setup, chunk: 777)
        let singles = render([left, right], setup, chunk: 1)
        #expect(whole == pieces)
        #expect(whole == singles)
        let finite = whole.joined().allSatisfy(\.isFinite)
        #expect(finite)
    }

    @Test func theNewSettingsAreStaticAndDefaultToTheOldBehaviour() {
        let definition = NodeCatalog.definition(for: .delay)
        func parameter(_ id: String) -> ParameterDefinition? { definition.parameters.first { $0.id == id } }
        for id in ["pitch", "freeze", "freezeStart"] {
            let found = parameter(id)
            #expect(found != nil, "\(id) is missing")
            #expect(found?.isModulatable == false)
        }
        var pitch: Double?
        if case .number(_, let value, _)? = parameter("pitch")?.kind { pitch = value }
        var freeze: String?
        if case .choice(_, let value)? = parameter("freeze")?.kind { freeze = value }
        #expect(pitch == 0)
        #expect(freeze == "off")
        #expect(NodeCatalog.isCausal(Node(kind: .delay, parameters: [:])))
    }
}
