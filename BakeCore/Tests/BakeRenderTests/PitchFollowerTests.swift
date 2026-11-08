import BakeDSP
import Foundation
import Testing
@testable import BakeGraph
@testable import BakeRender

/// The Pitch Follower kernel (BakeDSP/PitchFollower.h), at 48 kHz.
struct PitchFollowerTests {
    private typealias Output = bake.dsp.PitchFollowerOutput
    private typealias Unvoiced = bake.dsp.PitchFollowerUnvoiced
    private let sampleRate = 48_000.0

    private struct Settings {
        var minFreq: Float = 60, maxFreq: Float = 1_000, glide: Float = 15, threshold: Float = 0.6
        var output = Output.log, unvoiced = Unvoiced.hold
        var modulation: [String: [Float]] = [:]
    }

    private func settings(_ change: (inout Settings) -> Void = { _ in }) -> Settings {
        var settings = Settings()
        change(&settings)
        return settings
    }

    /// Renders `channels` (one or two) and returns the pitch and confidence outputs.
    private func follow(_ channels: [[Float]], _ settings: Settings = Settings(), chunk: Int? = nil) -> (pitch: [Float], confidence: [Float]) {
        let frames = channels[0].count
        var buffers: [UnsafeMutableBufferPointer<Float>] = []
        defer { buffers.forEach { $0.deallocate() } }
        func control(_ id: String, _ base: Float, _ minimum: Float, _ maximum: Float, scale: bake.dsp.ModulationScale = .linear) -> bake.dsp.ParameterSignal {
            var control = signal(base, minimum, maximum, scale: scale)
            if let values = settings.modulation[id] {
                let buffer = UnsafeMutableBufferPointer<Float>.allocate(capacity: values.count)
                _ = buffer.initialize(from: values)
                buffers.append(buffer)
                control.modulation = UnsafePointer(buffer.baseAddress)
                control.modulationFrames = buffer.count
            }
            return control
        }
        var controls = bake.dsp.PitchFollowerControls()
        controls.minFreq = control("minFreq", settings.minFreq, 30, 2_000, scale: .exponential)
        controls.maxFreq = control("maxFreq", settings.maxFreq, 100, 4_000, scale: .exponential)
        controls.glide = control("glide", settings.glide, 0, 500)
        controls.threshold = control("threshold", settings.threshold, 0, 1)
        controls.output = control("output", Float(settings.output.rawValue), 0, 2)
        controls.unvoiced = control("unvoiced", Float(settings.unvoiced.rawValue), 0, 2)
        controls.fixedOutput = settings.output
        controls.fixedUnvoiced = settings.unvoiced
        controls.sampleRate = sampleRate

        let count = Int(bake.dsp.pitchFollowerEstimateCount(frames, sampleRate))
        var estimates = [Float](repeating: 0, count: max(count, 1) * Int(bake.dsp.pitchFollowerFloatsPerEstimate()))
        var scratch = [Double](repeating: 0, count: Int(bake.dsp.pitchFollowerScratchDoubles(sampleRate)))
        var state = bake.dsp.PitchFollowerState()
        var pitch = [Float](repeating: 0, count: frames)
        var confidence = [Float](repeating: 0, count: frames)
        let right = channels.count > 1 ? channels[1] : []
        channels[0].withUnsafeBufferPointer { left in
            right.withUnsafeBufferPointer { rightPointer in
                var input = bake.dsp.AudioInput()
                input.channels.0 = left.baseAddress
                input.channelCount = 1
                input.frames = frames
                if channels.count > 1 {
                    input.channels.1 = rightPointer.baseAddress
                    input.channelCount = 2
                }
                pitch.withUnsafeMutableBufferPointer { pitchPointer in
                    confidence.withUnsafeMutableBufferPointer { confidencePointer in
                        var start = 0
                        while start < frames {
                            let length = min(chunk ?? frames, frames - start)
                            bake.dsp.renderPitchFollower(
                                &state, controls, input, &estimates, count, &scratch,
                                pitchPointer.baseAddress! + start, confidencePointer.baseAddress! + start, start, length
                            )
                            start += length
                        }
                    }
                }
            }
        }
        return (pitch, confidence)
    }

    private func note(_ frequency: Double) -> Double { (69 + 12 * log2(frequency / 440)) / 127 }

    private func mean(_ values: ArraySlice<Float>) -> Double { values.reduce(0.0) { $0 + Double($1) } / Double(values.count) }

    private func saw(frequency: Double, frames: Int) -> [Float] {
        (0..<frames).map { index in
            let phase = (frequency * Double(index) / sampleRate).truncatingRemainder(dividingBy: 1)
            return Float(0.5 * (2 * phase - 1))
        }
    }

    /// Seeded white noise, amplitude ±0.5.
    private func noise(frames: Int, seed: UInt32 = 7) -> [Float] {
        var value = seed
        return (0..<frames).map { _ in
            value = value &* 1_664_525 &+ 1_013_904_223
            return Float(value) / Float(UInt32.max) - 0.5
        }
    }

    /// 220 Hz until frame 24000, then 440 Hz, one second in all.
    private func step() -> [Float] {
        let low = sine(frequency: 220, frames: 48_000)
        let high = sine(frequency: 440, frames: 48_000)
        return Array(low[0..<24_000]) + Array(high[24_000..<48_000])
    }

    // MARK: known answers

    @Test(arguments: [110.0, 220, 440, 880])
    func sineReadsItsPitch(frequency: Double) {
        let output = follow([sine(frequency: frequency, frames: 48_000)], settings { $0.output = .note })
        let middle = output.pitch[12_000..<36_000]
        let fiveCents = 0.05 / 127
        #expect(middle.allSatisfy { abs(Double($0) - note(frequency)) < fiveCents }, "\(frequency) Hz read \(mean(middle) * 127) MIDI")
    }

    @Test func logAndLinearOutputsSpanMinToMax() {
        let tone = [sine(frequency: 220, frames: 48_000)]
        let log = follow(tone, settings { $0.minFreq = 110; $0.maxFreq = 440 })
        let linear = follow(tone, settings { $0.minFreq = 110; $0.maxFreq = 440; $0.output = .linear })
        #expect(abs(mean(log.pitch[12_000..<36_000]) - 0.5) < 0.002)
        #expect(abs(mean(linear.pitch[12_000..<36_000]) - 110.0 / 330.0) < 0.002)
    }

    @Test func sawReadsItsFundamental() {
        let output = follow([saw(frequency: 150, frames: 48_000)], settings { $0.output = .note })
        let read = mean(output.pitch[12_000..<36_000])
        #expect(abs(read - note(150)) < 0.1 / 127, "a 150 Hz saw read \(read * 127) MIDI")
    }

    @Test func silenceAndNoiseAreUnvoiced() {
        let silence = follow([[Float](repeating: 0, count: 24_000)])
        #expect(silence.confidence.allSatisfy { $0 == 0 })
        let noisy = follow([noise(frames: 48_000)])
        #expect(mean(noisy.confidence[4_800..<43_200]) < 0.5)
        let tone = follow([sine(frequency: 220, frames: 48_000)])
        #expect(mean(tone.confidence[12_000..<36_000]) > 0.9)
    }

    @Test func unvoicedModes() {
        let tone = sine(frequency: 220, frames: 19_200)
        let file = [tone + [Float](repeating: 0, count: 19_200) + tone]
        let gap = 28_800
        let held = follow(file)
        let expected = log2(220.0 / 60) / log2(1_000.0 / 60)
        #expect(abs(Double(held.pitch[gap]) - expected) < 0.002)
        // The default 15 ms Glide is still easing in (a one-pole never quite arrives).
        #expect(follow(file, settings { $0.unvoiced = .fallToMin }).pitch[gap] < 1e-4)
        #expect(follow(file, settings { $0.unvoiced = .zero; $0.output = .note }).pitch[gap] < 1e-4)
        let fallen = follow(file, settings { $0.unvoiced = .fallToMin; $0.output = .note }).pitch[gap]
        #expect(abs(Double(fallen) - note(60)) < 0.001)
    }

    @Test func aStepLandsOnTime() throws {
        let output = follow([step()], settings { $0.minFreq = 110; $0.maxFreq = 880; $0.glide = 0 })
        let crossing = try #require(output.pitch.indices.first { $0 > 6_000 && output.pitch[$0] > 0.5 })
        #expect(abs(crossing - 24_000) <= 1_200, "crossed at \(crossing)")
        #expect(abs(Double(output.pitch[12_000]) - 1.0 / 3) < 0.002)
        #expect(abs(Double(output.pitch[36_000]) - 2.0 / 3) < 0.002)
    }

    @Test func glideSmoothsAStep() {
        let quick = follow([step()], settings { $0.minFreq = 110; $0.maxFreq = 880; $0.glide = 0 })
        let slow = follow([step()], settings { $0.minFreq = 110; $0.maxFreq = 880; $0.glide = 100 })
        #expect(quick.pitch[24_000 + 1_920] - slow.pitch[24_000 + 1_920] > 0.1)
    }

    @Test func stereoUsesTheMonoSum() {
        let left = sine(frequency: 330, frames: 48_000)
        let output = follow([left, [Float](repeating: 0, count: 48_000)], settings { $0.output = .note })
        #expect(abs(mean(output.pitch[12_000..<36_000]) - note(330)) < 0.05 / 127)
    }

    // MARK: guarantees

    @Test func chunksOf777MatchOneRender() {
        let channels = TestAudio.samples(frames: 30_011, channels: 2)
        let whole = follow(channels)
        let chunked = follow(channels, chunk: 777)
        #expect(whole.pitch == chunked.pitch)
        #expect(whole.confidence == chunked.confidence)
    }

    @Test func rendersAreBitIdentical() {
        let channels = [step()]
        #expect(follow(channels).pitch == follow(channels).pitch)
    }

    @Test func extremesAreFinite() {
        let input = TestAudio.samples(frames: 12_000, channels: 1)
        for minFreq: Float in [30, 2_000] {
            for maxFreq: Float in [100, 4_000] {
                for glide: Float in [0, 500] {
                    for threshold: Float in [0, 1] {
                        for output in [Output.log, .linear, .note] {
                            for unvoiced in [Unvoiced.hold, .fallToMin, .zero] {
                                let result = follow(input, Settings(
                                    minFreq: minFreq, maxFreq: maxFreq, glide: glide, threshold: threshold, output: output, unvoiced: unvoiced
                                ))
                                #expect(result.pitch.allSatisfy { $0.isFinite && (0...1).contains($0) })
                                #expect(result.confidence.allSatisfy { $0.isFinite && (0...1).contains($0) })
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: the node

    /// Audio (220 Hz, 440 Hz, then silence) → Pitch Follower: Pitch drives a Filters cutoff, and
    /// both outputs are read through Gain/VCA ring mod on a steady 1.0 carrier (a Bake node takes
    /// audio, not control).
    private func melodyPatch(in directory: URL, wired: Bool) throws -> Patch {
        let melodyAsset = AssetID(testUUID(9_800)), carrierAsset = AssetID(testUUID(9_801))
        let melody = directory.appendingPathComponent("melody.wav")
        let carrier = directory.appendingPathComponent("carrier.wav")
        try TestAudio.write([step() + [Float](repeating: 0, count: 24_000)], to: melody, sampleRate: 48_000)
        try TestAudio.write([[Float](repeating: 1, count: 72_000)], to: carrier, sampleRate: 48_000)
        var patch = Patch()
        patch.assets = [melodyAsset: melody, carrierAsset: carrier]
        let audio = patch.graph.add(.audio, asset: melodyAsset)
        let steady = patch.graph.add(.audio, asset: carrierAsset)
        let follower = patch.graph.add(.pitchFollower)
        let filters = patch.graph.add(.filters, ["cutoff": .number(500)], modulated: ["cutoff"])
        patch.wire(audio, "out", to: follower)
        patch.wire(audio, "out", to: filters)
        if wired {
            patch.wire(follower, "out", to: filters, "mod.cutoff")
        }
        for pin: PinID in ["out", "confidence"] {
            let reader = patch.graph.add(.gainVCA, ["mode": .choice("ringMod")])
            patch.wire(steady, "out", to: reader)
            patch.wire(follower, pin, to: reader, "amount")
            patch.bake(pin, from: reader)
        }
        patch.bake("filtered", from: filters)
        return patch
    }

    @Test func pitchDrivesAFilterAndConfidenceGates() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let wiredDirectory = directory.appendingPathComponent("wired", isDirectory: true)
        let plainDirectory = directory.appendingPathComponent("plain", isDirectory: true)
        try FileManager.default.createDirectory(at: wiredDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: plainDirectory, withIntermediateDirectories: true)
        let wired = try await melodyPatch(in: wiredDirectory, wired: true).render(in: wiredDirectory)
        let plain = try await melodyPatch(in: plainDirectory, wired: false).render(in: plainDirectory)

        let filtered = try #require(wired["filtered"]?.first)
        #expect(filtered.count == 72_000 && filtered.allSatisfy(\.isFinite))
        #expect(filtered != plain["filtered"]?.first)
        let pitch = try #require(wired["out"]?.first)
        let expected = log2(220.0 / 60) / log2(1_000.0 / 60)
        #expect(abs(Double(pitch[12_000]) - expected) < 0.003)
        let confidence = try #require(wired["confidence"]?.first)
        #expect(mean(confidence[6_000..<42_000]) > 0.9)
        #expect(confidence[60_000..<72_000].allSatisfy { $0 == 0 })
    }

    @Test func theNodeIsChunkInvariant() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let patch = try melodyPatch(in: directory, wired: true)
        let whole = try await patch.render(in: directory, chunkFrames: 4_096)
        let chunked = try await patch.render(in: directory, chunkFrames: 777)
        #expect(whole["out"] == chunked["out"])
        #expect(whole["confidence"] == chunked["confidence"])
    }

    @Test(arguments: [("minFreq", Float(0.3)), ("maxFreq", 0.3), ("glide", 0.3), ("threshold", 0.4), ("output", 0.3), ("unvoiced", 0.3)])
    func modulationMovesEveryControl(id: String, amount: Float) {
        let input = [sine(frequency: 220, frames: 14_400) + noise(frames: 14_400)]
        let plain = follow(input)
        let moved = follow(input, settings { $0.modulation[id] = [Float](repeating: amount, count: 28_800) })
        #expect(plain.pitch != moved.pitch, "\(id)")
    }
}
