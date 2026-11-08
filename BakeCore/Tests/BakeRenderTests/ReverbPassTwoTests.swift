import BakeDSP
import Foundation
import Testing
@testable import BakeGraph
@testable import BakeRender

/// Early reflections, Modulation, Low/High Decay and Freeze, run straight through the kernel.
struct ReverbPassTwoTests {
    private static let rate = 48_000.0

    private struct Options {
        var size = 1.0, decay = 2.0, damping = 0.0, width = 1.0
        var mix: Float = 1
        var lines = 32, preDelay = 0
        var early = 0.0, modulation = 0.0, lowDecay = 1.0, highDecay = 1.0, crossover = 800.0
        /// Seconds at which the tail freezes; negative for never.
        var freezeAt = -1.0
    }

    /// `input` through a fresh network in chunks of `chunk` frames; the output is as long as the input.
    private func render(_ input: [[Float]], _ options: Options = Options(), chunk: Int) -> [[Float]] {
        let frames = input[0].count
        let count = input.count
        let lines = options.lines
        var controls = bake.dsp.ReverbControls()
        var mix = bake.dsp.ParameterSignal()
        mix.base = options.mix
        mix.minimum = 0
        mix.maximum = 1
        controls.mix = mix
        controls.width = options.width
        controls.diffusion = 0.7
        controls.damping = options.damping
        controls.decaySeconds = options.decay
        controls.lines = lines
        controls.preDelayFrames = options.preDelay
        controls.sampleRate = Self.rate
        controls.size = options.size
        if options.early > 0 {
            controls.earlyLevel = options.early
            controls.earlyFrames = Int(bake.dsp.reverbEarlyFrames(options.size, Self.rate))
        }
        var margin = 0
        if options.modulation > 0 {
            margin = Int((options.modulation * 0.001 * Self.rate).rounded(.up)) + 8
            controls.modulationDepth = options.modulation
            controls.modulationMargin = margin
        }
        controls.lowDecayScale = options.lowDecay
        controls.highDecayScale = options.highDecay
        controls.crossoverHz = options.crossover
        if options.freezeAt >= 0 {
            controls.freezeFrame = (options.freezeAt * Self.rate).rounded()
            controls.freezeFade = 0.05 * Self.rate
        }

        let lengthPointers = UnsafeMutablePointer<UnsafePointer<UInt32>?>.allocate(capacity: count)
        let gainPointers = UnsafeMutablePointer<UnsafePointer<Double>?>.allocate(capacity: count)
        let storagePointers = UnsafeMutablePointer<UnsafeMutablePointer<Float>?>.allocate(capacity: count)
        let filterPointers = UnsafeMutablePointer<UnsafeMutablePointer<Double>?>.allocate(capacity: count)
        let outputPointers = UnsafeMutablePointer<UnsafeMutablePointer<Float>?>.allocate(capacity: count)
        var lengthBuffers: [UnsafeMutablePointer<UInt32>] = [], gainBuffers: [UnsafeMutablePointer<Double>] = []
        var storageBuffers: [UnsafeMutablePointer<Float>] = [], filterBuffers: [UnsafeMutablePointer<Double>] = []
        for channel in 0..<count {
            var lengthList = [UInt32](repeating: 0, count: lines)
            var gainList = [Double](repeating: 0, count: lines)
            bake.dsp.reverbDesign(options.size, options.decay, lines, Int32(channel), Self.rate, &lengthList, &gainList)
            let base = Int(bake.dsp.reverbStorageFloats(lengthList, lines, options.preDelay, Self.rate))
            let floats = base + lines * margin + controls.earlyFrames + 8
            let lengthBuffer = UnsafeMutablePointer<UInt32>.allocate(capacity: lines)
            lengthBuffer.initialize(from: lengthList, count: lines)
            let gainBuffer = UnsafeMutablePointer<Double>.allocate(capacity: lines)
            gainBuffer.initialize(from: gainList, count: lines)
            let storageBuffer = UnsafeMutablePointer<Float>.allocate(capacity: floats)
            storageBuffer.initialize(repeating: 0, count: floats)
            let filterBuffer = UnsafeMutablePointer<Double>.allocate(capacity: 2 * lines)
            filterBuffer.initialize(repeating: 0, count: 2 * lines)
            lengthBuffers.append(lengthBuffer)
            gainBuffers.append(gainBuffer)
            storageBuffers.append(storageBuffer)
            filterBuffers.append(filterBuffer)
            lengthPointers[channel] = UnsafePointer(lengthBuffer)
            gainPointers[channel] = UnsafePointer(gainBuffer)
            storagePointers[channel] = storageBuffer
            filterPointers[channel] = filterBuffer
        }
        let sourceBuffers = input.map { channel -> UnsafeMutablePointer<Float> in
            let pointer = UnsafeMutablePointer<Float>.allocate(capacity: frames)
            pointer.initialize(from: channel, count: frames)
            return pointer
        }
        let outputBuffers = input.map { _ -> UnsafeMutablePointer<Float> in
            let pointer = UnsafeMutablePointer<Float>.allocate(capacity: frames)
            pointer.initialize(repeating: 0, count: frames)
            return pointer
        }
        defer {
            lengthBuffers.forEach { $0.deallocate() }; gainBuffers.forEach { $0.deallocate() }
            storageBuffers.forEach { $0.deallocate() }; filterBuffers.forEach { $0.deallocate() }
            sourceBuffers.forEach { $0.deallocate() }; outputBuffers.forEach { $0.deallocate() }
            lengthPointers.deallocate(); gainPointers.deallocate(); storagePointers.deallocate()
            filterPointers.deallocate(); outputPointers.deallocate()
        }
        var audio = bake.dsp.AudioInput()
        audio.channelCount = count
        audio.frames = frames
        audio.channels.0 = UnsafePointer(sourceBuffers[0])
        if count > 1 { audio.channels.1 = UnsafePointer(sourceBuffers[1]) }
        var start = 0
        while start < frames {
            let length = min(chunk, frames - start)
            for channel in 0..<count { outputPointers[channel] = outputBuffers[channel] + start }
            bake.dsp.renderReverb(
                lengthPointers, gainPointers, storagePointers, filterPointers, outputPointers, Int32(count), 0, audio, controls, start, length
            )
            start += length
        }
        return outputBuffers.map { Array(UnsafeBufferPointer(start: $0, count: frames)) }
    }

    private func impulse(seconds: Double = 8) -> [[Float]] {
        var signal = [Float](repeating: 0, count: Int(Self.rate * seconds))
        signal[0] = 1
        return [signal]
    }

    private func noise(_ count: Int, seed: UInt64 = 1, level: Float = 0.4) -> [Float] {
        var state = seed
        return (0..<count).map { _ in
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Float(Int64(bitPattern: state) >> 40) / Float(1 << 23) * level
        }
    }

    private func energy(_ samples: some Sequence<Float>) -> Double {
        samples.reduce(0.0) { $0 + Double($1) * Double($1) }
    }

    private func decibels(_ ratio: Double) -> Double { 10 * log10(ratio) }

    // MARK: Early reflections

    @Test func earlyReflectionsAreTwelveTapsOfUnitEnergy() {
        var frames = [Int](repeating: 0, count: Int(bake.dsp.reverbEarlyTapCount))
        var gains = [Double](repeating: 0, count: Int(bake.dsp.reverbEarlyTapCount))
        bake.dsp.reverbEarlyDesign(1, 0, Self.rate, &frames, &gains)
        #expect(frames.count == 12)
        #expect(zip(frames, frames.dropFirst()).allSatisfy { $0 < $1 })
        #expect(abs(gains.reduce(0) { $0 + $1 * $1 } - 1) < 1e-9)
        let last = Double(frames.last ?? 0) / Self.rate
        #expect(last > 0.05 && last < 0.08, "last tap at \(last) s")
        #expect(frames.last ?? Int.max < Int(bake.dsp.reverbEarlyFrames(1, Self.rate)))
        var wide = frames, wideGains = gains
        bake.dsp.reverbEarlyDesign(4, 0, Self.rate, &wide, &wideGains)
        #expect(Double(wide.last ?? 0) / Self.rate > 3.5 * last)
        #expect(wide.last ?? Int.max < Int(bake.dsp.reverbEarlyFrames(4, Self.rate)))
        var other = frames, otherGains = gains
        bake.dsp.reverbEarlyDesign(1, 1, Self.rate, &other, &otherGains)
        #expect(other != frames, "the two channels use the same reflections")
    }

    @Test func earlyReflectionsAddOnlyTheirTapsAndLeaveTheTailAlone() {
        var off = Options()
        off.decay = 0.5
        var on = off
        on.early = 1
        let plain = render(impulse(), off, chunk: 4_096)[0]
        let with = render(impulse(), on, chunk: 4_096)[0]
        let difference = zip(with, plain).map { $0 - $1 }
        let sounding = difference.filter { abs($0) > 1e-9 }.count
        #expect(sounding == 12)
        var frames = [Int](repeating: 0, count: 12)
        var gains = [Double](repeating: 0, count: 12)
        bake.dsp.reverbEarlyDesign(1, 0, Self.rate, &frames, &gains)
        for index in 0..<12 {
            #expect(abs(Double(difference[frames[index]]) - gains[index]) < 1e-6)
        }
        #expect(abs(energy(difference) - 1) < 1e-4)
    }

    @Test func earlyLevelScalesTheReflections() {
        var one = Options()
        one.decay = 0.5
        one.early = 1
        var half = one
        half.early = 0.5
        var none = one
        none.early = 0
        let base = render(impulse(), none, chunk: 4_096)[0]
        let full = zip(render(impulse(), one, chunk: 4_096)[0], base).map { $0 - $1 }
        let low = zip(render(impulse(), half, chunk: 4_096)[0], base).map { $0 - $1 }
        #expect(abs(energy(low) / energy(full) - 0.25) < 0.001)
    }

    // MARK: Modulation

    @Test func modulationLeavesTheLoudnessAlone() {
        let input = [noise(Int(Self.rate * 8))]
        var plain = Options()
        plain.damping = 0.3
        plain.decay = 3
        var moving = plain
        moving.modulation = 0.5
        let steady = render(input, plain, chunk: 4_096)[0]
        let swept = render(input, moving, chunk: 4_096)[0]
        let from = Int(Self.rate)
        let change = decibels(energy(swept[from...]) / energy(steady[from...]))
        #expect(abs(change) < 0.5, "loudness changed by \(change) dB")
        #expect(swept != steady)
    }

    @Test func modulationKeepsTheDecayTime() {
        var plain = Options()
        plain.decay = 2
        var moving = plain
        moving.modulation = 0.8
        let a = render(impulse(), plain, chunk: 4_096)[0]
        let b = render(impulse(), moving, chunk: 4_096)[0]
        func level(_ samples: [Float], _ from: Double, _ to: Double) -> Double {
            decibels(energy(samples[Int(from * Self.rate)..<Int(to * Self.rate)]))
        }
        let fall = (level(a, 0.5, 1.0) - level(a, 2.0, 2.5)) - (level(b, 0.5, 1.0) - level(b, 2.0, 2.5))
        // Reading between frames darkens every pass a little, so the highs fall about 1.6 dB faster over these 1.5 s
        // (an RT60 about 3.5% shorter, under the ~5% anyone hears).
        #expect(abs(fall) < 2, "the fall differs by \(fall) dB")
    }

    @Test func modulationNeverTouchesTheFuture() {
        // The first sound can't come before the input does, even with the read points swinging.
        var moving = Options()
        moving.modulation = 1
        var late = [Float](repeating: 0, count: Int(Self.rate * 2))
        late[24_000] = 1
        let output = render([late], moving, chunk: 1_000)[0]
        let silent = output[0..<24_000].allSatisfy { $0 == 0 }
        #expect(silent)
    }

    // MARK: Low / High decay

    /// One-pole low-pass, cascaded `poles` times.
    private func lowPass(_ samples: [Float], hertz: Double, poles: Int = 3) -> [Float] {
        let coefficient = 1 - exp(-2 * Double.pi * hertz / Self.rate)
        var values = samples.map(Double.init)
        for _ in 0..<poles {
            var state = 0.0
            for index in values.indices {
                state += coefficient * (values[index] - state)
                values[index] = state
            }
        }
        return values.map(Float.init)
    }

    /// One-pole high-pass, cascaded `poles` times. (Subtracting a cascaded low-pass from the input is only first order,
    /// and lets the slow low band into the high one.)
    private func highPass(_ samples: [Float], hertz: Double, poles: Int = 3) -> [Float] {
        var values = samples
        for _ in 0..<poles {
            values = zip(values, lowPass(values, hertz: hertz, poles: 1)).map { $0 - $1 }
        }
        return values
    }

    private func bands(_ ir: [Float]) -> (low: [Float], high: [Float]) {
        (lowPass(ir, hertz: 200), highPass(ir, hertz: 4_000))
    }

    @Test func eachBandDecaysByItsOwnScale() {
        var flat = Options()
        flat.decay = 2
        var split = flat
        split.lowDecay = 2
        split.highDecay = 0.5
        let reference = bands(render(impulse(), flat, chunk: 4_096)[0])
        let result = bands(render(impulse(), split, chunk: 4_096)[0])
        let window = Int(Self.rate)..<Int(1.5 * Self.rate)
        let lowGain = decibels(energy(result.low[window]) / energy(reference.low[window]))
        let highGain = decibels(energy(result.high[window]) / energy(reference.high[window]))
        // Low decays twice as slowly, high twice as fast: after a second the bands have moved apart by tens of dB.
        #expect(lowGain > 10, "low band changed by \(lowGain) dB")
        #expect(highGain < -20, "high band changed by \(highGain) dB")
    }

    @Test func aSplitKeepsTheResponseNearUnitEnergy() {
        var flat = Options()
        flat.decay = 2
        let base = energy(render(impulse(), flat, chunk: 4_096)[0])
        for (low, high) in [(2.0, 0.5), (0.5, 2.0), (3.0, 1.0), (1.0, 3.0)] {
            var split = flat
            split.lowDecay = low
            split.highDecay = high
            let change = decibels(energy(render(impulse(), split, chunk: 4_096)[0]) / base)
            #expect(abs(change) < 1.5, "low ×\(low), high ×\(high) moved the loudness by \(change) dB")
        }
    }

    // MARK: Freeze

    @Test func aFrozenTailHoldsItsLevelAndIgnoresLaterInput() {
        var burst = [Float](repeating: 0, count: Int(Self.rate * 8))
        let hiss = noise(Int(Self.rate * 0.3), seed: 7, level: 0.5)
        for index in hiss.indices { burst[index] = hiss[index] }
        var options = Options()
        options.decay = 1.5
        options.freezeAt = 0.5
        let frozen = render([burst], options, chunk: 977)[0]
        func rms(_ seconds: Double) -> Double {
            let from = Int((seconds - 0.1) * Self.rate), to = Int((seconds + 0.1) * Self.rate)
            return (energy(frozen[from..<to]) / Double(to - from)).squareRoot()
        }
        #expect(rms(1) > 0.02)
        #expect(abs(decibels(rms(7) / rms(1))) < 1.0, "the level moved from \(rms(1)) to \(rms(7))")
        var free = options
        free.freezeAt = -1
        let decaying = render([burst], free, chunk: 977)[0]
        let late = energy(decaying[Int(4.9 * Self.rate)..<Int(5.1 * Self.rate)])
        #expect(late < 1e-6)
        var withLater = burst
        let more = noise(Int(Self.rate * 0.3), seed: 9, level: 0.5)
        for index in more.indices { withLater[Int(Self.rate * 2) + index] = more[index] }
        let again = render([withLater], options, chunk: 977)[0]
        let from = Int(0.55 * Self.rate) + 10
        let same = (from..<frozen.count).allSatisfy { frozen[$0] == again[$0] }
        #expect(same)
    }

    @Test func aFrozenTailStaysFlatWithEverythingElseOn() {
        var burst = [Float](repeating: 0, count: Int(Self.rate * 8))
        let hiss = noise(Int(Self.rate * 0.3), seed: 11, level: 0.5)
        for index in hiss.indices { burst[index] = hiss[index] }
        var options = Options()
        options.decay = 1.5
        options.freezeAt = 0.5
        options.lowDecay = 2
        options.highDecay = 0.5
        options.modulation = 0.6
        options.early = 0.5
        let output = render([burst], options, chunk: 977)[0]
        func rms(_ seconds: Double) -> Double {
            let from = Int((seconds - 0.1) * Self.rate), to = Int((seconds + 0.1) * Self.rate)
            return (energy(output[from..<to]) / Double(to - from)).squareRoot()
        }
        #expect(abs(decibels(rms(7) / rms(3))) < 1.0)
    }

    // MARK: Together

    @Test func everythingOnGivesTheSameBitsAtAnyChunkSize() {
        let left = noise(Int(Self.rate * 3), seed: 3, level: 0.3)
        let right = noise(Int(Self.rate * 3), seed: 4, level: 0.3)
        var options = Options()
        options.lines = 16
        options.width = 1.5
        options.preDelay = 300
        options.early = 0.7
        options.modulation = 0.5
        options.lowDecay = 1.8
        options.highDecay = 0.6
        options.freezeAt = 1.4
        options.decay = 1.2
        let whole = render([left, right], options, chunk: left.count)
        let pieces = render([left, right], options, chunk: 777)
        let singles = render([left, right], options, chunk: 1)
        #expect(whole == pieces)
        #expect(whole == singles)
        let finite = whole.joined().allSatisfy(\.isFinite)
        #expect(finite)
    }

    @Test func theNewSettingsAreStaticAndDefaultToTheOldBehaviour() {
        let definition = NodeCatalog.definition(for: .reverb)
        func parameter(_ id: String) -> ParameterDefinition? { definition.parameters.first { $0.id == id } }
        func number(_ id: String) -> Double? {
            guard let kind = parameter(id)?.kind, case .number(_, let value, _) = kind else { return nil }
            return value
        }
        for id in ["early", "modulation", "lowDecay", "highDecay", "crossover", "freeze", "freezeStart"] {
            let found = parameter(id)
            #expect(found != nil, "\(id) is missing")
            #expect(found?.isModulatable == false)
        }
        #expect(number("early") == 0)
        #expect(number("modulation") == 0)
        #expect(number("lowDecay") == 1)
        #expect(number("highDecay") == 1)
        var freeze: String?
        if case .choice(_, let value)? = parameter("freeze")?.kind { freeze = value }
        #expect(freeze == "off")
        #expect(definition.lengthRule == .extendedInput("in", bySeconds: "tail"))
    }
}
