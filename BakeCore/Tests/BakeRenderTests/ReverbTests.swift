import BakeDSP
import Foundation
import Testing
@testable import BakeGraph
@testable import BakeRender

struct ReverbTests {
    private static let rate = 48_000.0

    private struct Settings {
        var size = 1.0, decay = 2.0, damping = 0.0, diffusion = 0.7, width = 1.0, mix: Float = 1
        var lines = 32, preDelayFrames = 0
        var fade: (Double, Double) = (0, 0)
    }

    /// Owns a network's buffers for as long as a test renders with it.
    private final class Rig {
        let settings: Settings
        let channels: Int
        var lengths: [[UInt32]] = [], gains: [[Double]] = [], storage: [[Float]] = [], filters: [[Double]] = []

        init(_ settings: Settings, channels: Int) {
            self.settings = settings
            self.channels = channels
            for channel in 0..<channels {
                var lengthList = [UInt32](repeating: 0, count: settings.lines)
                var gainList = [Double](repeating: 0, count: settings.lines)
                bake.dsp.reverbDesign(settings.size, settings.decay, settings.lines, Int32(channel), ReverbTests.rate, &lengthList, &gainList)
                let floats = Int(bake.dsp.reverbStorageFloats(lengthList, settings.lines, settings.preDelayFrames, ReverbTests.rate))
                lengths.append(lengthList)
                gains.append(gainList)
                storage.append([Float](repeating: 0, count: floats))
                filters.append([Double](repeating: 0, count: settings.lines))
            }
        }

        func render(_ input: [[Float]], chunk: Int? = nil) -> [[Float]] {
            let frames = input[0].count
            var controls = bake.dsp.ReverbControls()
            var mix = bake.dsp.ParameterSignal()
            mix.base = settings.mix
            mix.minimum = 0
            mix.maximum = 1
            controls.mix = mix
            controls.width = settings.width
            controls.diffusion = settings.diffusion
            controls.damping = settings.damping
            controls.decaySeconds = settings.decay
            controls.lines = settings.lines
            controls.preDelayFrames = settings.preDelayFrames
            controls.sampleRate = ReverbTests.rate
            controls.tailFadeStart = settings.fade.0
            controls.tailFadeEnd = settings.fade.1
            var input = input
            var results = input.map { _ in [Float](repeating: 0, count: frames) }
            let count = channels
            let lengthPointers = UnsafeMutablePointer<UnsafePointer<UInt32>?>.allocate(capacity: count)
            let gainPointers = UnsafeMutablePointer<UnsafePointer<Double>?>.allocate(capacity: count)
            let storagePointers = UnsafeMutablePointer<UnsafeMutablePointer<Float>?>.allocate(capacity: count)
            let filterPointers = UnsafeMutablePointer<UnsafeMutablePointer<Double>?>.allocate(capacity: count)
            let outputPointers = UnsafeMutablePointer<UnsafeMutablePointer<Float>?>.allocate(capacity: count)
            let sourceBuffers = input.indices.map { channel -> UnsafeMutablePointer<Float> in
                let pointer = UnsafeMutablePointer<Float>.allocate(capacity: frames)
                pointer.initialize(from: input[channel], count: frames)
                return pointer
            }
            let lengthBuffers = lengths.map { list -> UnsafeMutablePointer<UInt32> in
                let pointer = UnsafeMutablePointer<UInt32>.allocate(capacity: list.count); pointer.initialize(from: list, count: list.count); return pointer
            }
            let gainBuffers = gains.map { list -> UnsafeMutablePointer<Double> in
                let pointer = UnsafeMutablePointer<Double>.allocate(capacity: list.count); pointer.initialize(from: list, count: list.count); return pointer
            }
            let storageBuffers = storage.map { list -> UnsafeMutablePointer<Float> in
                let pointer = UnsafeMutablePointer<Float>.allocate(capacity: list.count); pointer.initialize(from: list, count: list.count); return pointer
            }
            let filterBuffers = filters.map { list -> UnsafeMutablePointer<Double> in
                let pointer = UnsafeMutablePointer<Double>.allocate(capacity: list.count); pointer.initialize(from: list, count: list.count); return pointer
            }
            let outputBuffers = results.map { _ in UnsafeMutablePointer<Float>.allocate(capacity: frames) }
            defer {
                sourceBuffers.forEach { $0.deallocate() }; lengthBuffers.forEach { $0.deallocate() }; gainBuffers.forEach { $0.deallocate() }
                storageBuffers.forEach { $0.deallocate() }; filterBuffers.forEach { $0.deallocate() }; outputBuffers.forEach { $0.deallocate() }
                lengthPointers.deallocate(); gainPointers.deallocate(); storagePointers.deallocate(); filterPointers.deallocate(); outputPointers.deallocate()
            }
            for channel in 0..<count {
                lengthPointers[channel] = UnsafePointer(lengthBuffers[channel])
                gainPointers[channel] = UnsafePointer(gainBuffers[channel])
                storagePointers[channel] = storageBuffers[channel]
                filterPointers[channel] = filterBuffers[channel]
            }
            var audio = bake.dsp.AudioInput()
            audio.channelCount = input.count
            audio.frames = frames
            audio.channels.0 = UnsafePointer(sourceBuffers[0])
            if input.count > 1 { audio.channels.1 = UnsafePointer(sourceBuffers[1]) }
            var start = 0
            while start < frames {
                let length = min(chunk ?? frames, frames - start)
                for channel in 0..<count { outputPointers[channel] = outputBuffers[channel] + start }
                bake.dsp.renderReverb(
                    lengthPointers, gainPointers, storagePointers, filterPointers, outputPointers, Int32(count), 0, audio, controls, start, length
                )
                start += length
            }
            for channel in 0..<count { results[channel] = Array(UnsafeBufferPointer(start: outputBuffers[channel], count: frames)) }
            input = []
            return results
        }
    }

    private func impulse(frames: Int) -> [[Float]] {
        var signal = [Float](repeating: 0, count: frames)
        signal[0] = 1
        return [signal]
    }

    private func noise(_ count: Int, seed: UInt64 = 1) -> [Float] {
        var state = seed
        return (0..<count).map { _ in
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Float(Int64(bitPattern: state) >> 40) / Float(1 << 23) * 0.4
        }
    }

    @Test(arguments: [0.5, 2.0, 5.0])
    func decayIsTheTimeToFallSixtyDecibels(_ decay: Double) {
        let frames = Int(Self.rate * (decay * 2.5 + 1))
        var settings = Settings()
        settings.decay = decay
        let response = Rig(settings, channels: 1).render(impulse(frames: frames))[0]
        // Schroeder backward integration; time between −5 and −35 dB, doubled.
        var remaining = [Double](repeating: 0, count: frames)
        var sum = 0.0
        for index in stride(from: frames - 1, through: 0, by: -1) {
            sum += Double(response[index]) * Double(response[index])
            remaining[index] = sum
        }
        func time(at decibels: Double) -> Double {
            let index = remaining.firstIndex { 10 * log10($0 / remaining[0]) < decibels } ?? frames
            return Double(index) / Self.rate
        }
        let measured = (time(at: -35) - time(at: -5)) * 2
        #expect(abs(measured - decay) < decay * 0.1, "measured \(measured) s for Decay \(decay)")
    }

    @Test func theResponseHasAboutUnitEnergyWhateverTheDecay() {
        for decay in [0.5, 4.0] {
            var settings = Settings()
            settings.decay = decay
            let response = Rig(settings, channels: 1).render(impulse(frames: Int(Self.rate * (decay * 2 + 1))))[0]
            let energy = response.reduce(0.0) { $0 + Double($1) * Double($1) }
            #expect(energy > 0.7 && energy < 1.4, "decay \(decay): energy \(energy)")
        }
    }

    @Test func steadyNoiseComesOutAboutAsLoudAsItWentIn() {
        var settings = Settings()
        settings.decay = 1.5
        settings.damping = 0.3
        let input = noise(Int(Self.rate * 8))
        let output = Rig(settings, channels: 1).render([input])[0]
        func power(_ values: ArraySlice<Float>) -> Double { values.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(values.count) }
        let half = input.count / 2
        let difference = 10 * log10(power(output[half...]) / power(input[half...]))
        #expect(abs(difference) < 3, "wet is \(difference) dB against the input")
    }

    @Test func mixZeroIsTheDrySignalExactly() {
        var settings = Settings()
        settings.mix = 0
        let input = noise(5_000)
        #expect(Rig(settings, channels: 1).render([input])[0] == input)
    }

    @Test func widthZeroMakesTheChannelsIdenticalAndWidthOneKeepsThemApart() {
        let input = [noise(20_000, seed: 3), noise(20_000, seed: 4)]
        var narrow = Settings()
        narrow.width = 0
        let mono = Rig(narrow, channels: 2).render(input)
        #expect(mono[0] == mono[1])
        let wide = Rig(Settings(), channels: 2).render(input)
        #expect(wide[0] != wide[1])
    }

    @Test func preDelayHoldsBackTheReverb() {
        var settings = Settings()
        settings.preDelayFrames = 4_800
        let response = Rig(settings, channels: 1).render(impulse(frames: 20_000))[0]
        #expect(response[0..<4_800].allSatisfy { $0 == 0 })
        #expect(response[4_800..<20_000].contains { abs($0) > 1e-6 })
    }

    @Test func aHugeNetworkWithALongDecayStaysBounded() {
        var settings = Settings()
        settings.lines = 256
        settings.decay = 300
        settings.size = 3
        let output = Rig(settings, channels: 1).render([noise(Int(Self.rate * 6), seed: 9)])[0]
        let finite = output.allSatisfy { $0.isFinite }
        #expect(finite)
        #expect((output.map { abs($0) }.max() ?? 0) < 4)
    }

    @Test func theTailFadesToSilence() {
        var settings = Settings()
        settings.fade = (30_000, 40_000)
        let output = Rig(settings, channels: 1).render(impulse(frames: 40_000))[0]
        #expect(abs(output[39_999]) < abs(output[29_999]) + 1e-9 || abs(output[39_999]) < 1e-5)
        #expect(abs(output[39_999]) < 1e-4)
    }

    @Test func anyChunkSizeGivesTheSameBits() {
        var settings = Settings()
        settings.width = 1.4
        settings.damping = 0.4
        settings.lines = 24
        settings.preDelayFrames = 123
        let input = [noise(30_000, seed: 5), noise(30_000, seed: 6)]
        let whole = Rig(settings, channels: 2).render(input)
        let chunked = Rig(settings, channels: 2).render(input, chunk: 777)
        #expect(whole == chunked)
    }

    @Test func theCatalogGivesItATailAndPutsItInTheTimeGroup() {
        #expect(NodeCatalog.definition(for: .reverb).lengthRule == .extendedInput("in", bySeconds: "tail"))
        #expect(NodeKind.reverb.category == .time)
        #expect(!NodeCatalog.isCausal(Node(kind: .reverb, parameters: [:])))
        #expect(NodeCatalog.definition(for: .reverb).parameter("lines") != nil)
    }
}
