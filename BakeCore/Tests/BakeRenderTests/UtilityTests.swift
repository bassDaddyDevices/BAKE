import BakeDSP
import Foundation
import Testing
@testable import BakeGraph
@testable import BakeRender

struct UtilityTests {
    private static let rate = 48_000.0

    private static func sine(_ frequency: Double, peakDb: Double, seconds: Double = 12, offset: Float = 0) -> [Float] {
        let amplitude = pow(10, peakDb / 20)
        return (0..<Int(rate * seconds)).map { Float(amplitude * sin(2 * .pi * frequency * Double($0) / rate)) + offset }
    }

    private func signal(_ value: Float) -> bake.dsp.ParameterSignal {
        var signal = bake.dsp.ParameterSignal()
        signal.base = value
        signal.minimum = -96
        signal.maximum = 96
        return signal
    }

    /// One channel through the kernel in chunks of `chunk` frames.
    private func render(
        _ input: [Float], channel: Int = 0, channels: Int = 1, chunk: Int? = nil, dcOffset: Double = 0,
        configure: (inout bake.dsp.UtilityControls) -> Void = { _ in }
    ) -> [Float] {
        var controls = bake.dsp.UtilityControls()
        controls.gain = signal(0)
        controls.balance = signal(0)
        controls.totalFrames = input.count
        configure(&controls)
        var output = [Float](repeating: 0, count: input.count)
        input.withUnsafeBufferPointer { source in
            output.withUnsafeMutableBufferPointer { destination in
                var start = 0
                while start < input.count {
                    let count = min(chunk ?? input.count, input.count - start)
                    bake.dsp.renderUtility(
                        controls, Int32(channel), Int32(channels), source.baseAddress! + start, destination.baseAddress! + start,
                        dcOffset, start, count
                    )
                    start += count
                }
            }
        }
        return output
    }

    private func loudness(_ channels: [[Float]]) -> Double {
        let pointers: [UnsafePointer<Float>?] = channels.map { channel in channel.withUnsafeBufferPointer { $0.baseAddress } }
        // The arrays outlive the call below, so their buffers stay valid.
        return pointers.withUnsafeBufferPointer {
            bake.dsp.utilityIntegratedLoudness($0.baseAddress, Int32(channels.count), channels[0].count, nil, Self.rate)
        }
    }

    @Test func atRestTheOutputIsTheInputBitForBit() {
        let input = Self.sine(440, peakDb: -3, seconds: 1)
        #expect(render(input) == input)
    }

    @Test func gainScalesInDecibels() {
        let input = Self.sine(440, peakDb: -20, seconds: 1)
        let output = render(input) { $0.gain = signal(6) }
        let ratio = zip(output, input).filter { abs($0.1) > 0.05 }.map { Double($0.0 / $0.1) }
        #expect(ratio.allSatisfy { abs($0 - pow(10, 6.0 / 20)) < 1e-4 })
    }

    @Test func polarityInverts() {
        let input = Self.sine(440, peakDb: -6, seconds: 1)
        #expect(render(input) { $0.polarity = -1 } == input.map { -$0 })
    }

    @Test func balanceAttenuatesOnlyTheFarSide() {
        let input = [Float](repeating: 0.5, count: 1_000)
        func level(_ channel: Int, _ balance: Float) -> Float {
            render(input, channel: channel, channels: 2) { $0.balance = signal(balance) }[500]
        }
        #expect(level(0, 0) == 0.5 && level(1, 0) == 0.5)
        #expect(abs(level(0, -1) - 0.5) < 1e-6)            // hard left: the left stays at unity
        #expect(abs(level(1, -1)) < 1e-6)                  // and the right is gone
        #expect(abs(level(1, 1) - 0.5) < 1e-6 && abs(level(0, 1)) < 1e-6)
        #expect(level(0, 0.5) < 0.5 && level(0, 0.5) > 0)  // part way: the far side only partly
        #expect(level(1, 0.5) == 0.5)
    }

    @Test func balanceLeavesOtherChannelsAlone() {
        let input = [Float](repeating: 0.5, count: 100)
        #expect(render(input, channel: 2, channels: 4) { $0.balance = signal(1) } == input)
    }

    @Test(arguments: [UtilityFadeCase(shape: .linear), UtilityFadeCase(shape: .equalPower), UtilityFadeCase(shape: .smooth)])
    func fadesStartAtSilenceEndAtSilenceAndHoldUnityBetween(_ test: UtilityFadeCase) {
        let input = [Float](repeating: 1, count: 10_000)
        let output = render(input) {
            $0.fadeInFrames = 1_000
            $0.fadeOutFrames = 2_000
            $0.fadeCurve = test.shape
        }
        #expect(output[0] == 0)
        #expect(output[9_999] == 0)
        #expect(output[1_000] == 1 && output[5_000] == 1 && output[7_000] == 1)
        #expect(output[500] > 0 && output[500] < 1)
        #expect(output[9_000] > 0 && output[9_000] < 1)
        #expect(zip(output[0..<1_000], output[1..<1_001]).allSatisfy { $0 <= $1 })   // rising
    }

    @Test func equalPowerCrossedFadesKeepTheirPower() {
        let input = [Float](repeating: 1, count: 2_000)
        let fadeIn = render(input) { $0.fadeInFrames = 2_000; $0.fadeCurve = .equalPower }
        let fadeOut = render(input) { $0.fadeOutFrames = 1_999; $0.fadeCurve = .equalPower }
        for frame in stride(from: 0, to: 2_000, by: 97) {
            #expect(abs(fadeIn[frame] * fadeIn[frame] + fadeOut[frame] * fadeOut[frame] - 1) < 0.01)
        }
    }

    @Test func dcRemoveSubtractsTheMean() {
        let input = Self.sine(220, peakDb: -12, seconds: 1, offset: 0.2)
        let offset = input.withUnsafeBufferPointer { bake.dsp.utilityDcOffset($0.baseAddress, $0.count) }
        #expect(abs(offset - 0.2) < 1e-3)
        let output = render(input, dcOffset: offset)
        let mean = output.reduce(0.0) { $0 + Double($1) } / Double(output.count)
        #expect(abs(mean) < 1e-6)
    }

    private func normalizeGainDb(_ input: [Float], _ mode: bake.dsp.UtilityNormalize, _ target: Double, channels: Int = 1) -> Double {
        let pointers: [UnsafePointer<Float>?] = (0..<channels).map { _ in input.withUnsafeBufferPointer { $0.baseAddress } }
        let gain = pointers.withUnsafeBufferPointer {
            bake.dsp.utilityNormalizeGain($0.baseAddress, Int32(channels), input.count, nil, mode, target, Self.rate)
        }
        return 20 * log10(gain)
    }

    @Test func peakNormaliseBringsThePeakToTheTarget() {
        let input = Self.sine(440, peakDb: -20, seconds: 1)
        #expect(abs(normalizeGainDb(input, .peak, -1) - 19) < 0.01)
    }

    @Test func rmsNormaliseBringsTheRMSToTheTarget() {
        let input = Self.sine(440, peakDb: -20, seconds: 1)      // RMS of a sine is 3 dB under its peak
        #expect(abs(normalizeGainDb(input, .rms, -18) - 5) < 0.02)
    }

    @Test func loudnessMeterMatchesTheStandard() {
        // BS.1770: a 997 Hz sine at −23 dBFS peak in both channels reads −23.0 LUFS; in one channel, −26.0.
        let sine = Self.sine(997, peakDb: -23)
        #expect(abs(loudness([sine, sine]) + 23) < 0.05)
        #expect(abs(loudness([sine]) + 26.01) < 0.05)
    }

    @Test func theGateIgnoresQuietPassages() {
        let loud = Self.sine(997, peakDb: -20, seconds: 10)
        let quiet = Self.sine(997, peakDb: -60, seconds: 10)
        let gated = loudness([loud + quiet])
        let alone = loudness([loud])
        #expect(abs(gated - alone) < 0.3)
    }

    @Test func silenceNormalisesToUnityAndNeverBlowsUp() {
        let silence = [Float](repeating: 0, count: 48_000)
        for mode in [bake.dsp.UtilityNormalize.peak, .rms, .loudness] {
            #expect(normalizeGainDb(silence, mode, -14) == 0)
        }
    }

    @Test func loudnessNormaliseHitsItsTarget() {
        let sine = Self.sine(997, peakDb: -30)
        let gainDb = normalizeGainDb(sine, .loudness, -14, channels: 2)
        let scaled = sine.map { $0 * Float(pow(10, gainDb / 20)) }
        #expect(abs(loudness([scaled, scaled]) + 14) < 0.05)
    }

    @Test func anyChunkSizeGivesTheSameBits() {
        let input = Self.sine(330, peakDb: -9, seconds: 1)
        let whole = render(input, channel: 0, channels: 2) {
            $0.gain = signal(-3); $0.balance = signal(0.4); $0.polarity = -1
            $0.fadeInFrames = 3_000; $0.fadeOutFrames = 5_000; $0.fadeCurve = .smooth; $0.normalizeGain = 1.7
        }
        let chunked = render(input, channel: 0, channels: 2, chunk: 777) {
            $0.gain = signal(-3); $0.balance = signal(0.4); $0.polarity = -1
            $0.fadeInFrames = 3_000; $0.fadeOutFrames = 5_000; $0.fadeCurve = .smooth; $0.normalizeGain = 1.7
        }
        #expect(whole == chunked)
    }

    @Test func nonFiniteInputBecomesSilenceNotNaN() {
        let output = render([.nan, .infinity, 0.5]) { $0.gain = signal(6) }
        let finite = output.allSatisfy { $0.isFinite }
        #expect(finite)
        #expect(output[0] == 0 && output[1] == 0)
    }

    @Test func theCatalogDefaultsAreAtRest() {
        let defaults = NodeCatalog.defaultParameters(for: .utility)
        #expect(defaults["gain"]?.numberValue == 0)
        #expect(defaults["balance"]?.numberValue == 0)
        #expect(defaults["normalize"] == .choice("off"))
        #expect(defaults["dcRemove"] == .choice("off"))
        #expect(NodeCatalog.definition(for: .utility).lengthRule == .adjusted("in"))
        #expect(NodeKind.utility.category == .routing)
    }

    // MARK: Mono Sum, Trim and Pad

    /// `channels` through a Utility with `parameters`, rendered in chunks of `chunk` frames.
    private func through(
        _ channels: [[Float]], _ parameters: [ParameterID: ParameterValue], chunk: Int = 65_536
    ) async throws -> [[Float]] {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var patch = Patch()
        let url = directory.appendingPathComponent("input.wav")
        try TestAudio.write(channels, to: url, sampleRate: 48_000)
        patch.assets[sourceAsset] = url
        let source = patch.graph.add(.audio, asset: sourceAsset)
        let node = patch.graph.add(.utility, parameters)
        patch.wire(source, "out", to: node, "in")
        patch.bake("out", from: node)
        return try #require(try await patch.render(in: directory, chunkFrames: chunk)["out"])
    }

    /// A stereo ramp: left rises, right falls, so every frame is different.
    private func ramp(seconds: Double = 2) -> [[Float]] {
        let count = Int(Self.rate * seconds)
        let left = (0..<count).map { Float($0) / Float(count) * 0.5 + 0.1 }
        let right = (0..<count).map { 0.6 - Float($0) / Float(count) * 0.5 }
        return [left, right]
    }

    @Test func thePlanLaysOutTheOutput() {
        let plan = AdjustedPlan.frames(
            ["trimStart": .number(0.5), "trimEnd": .number(0.25), "padStart": .number(0.1), "padEnd": .number(0.2)], sampleRate: Self.rate
        )
        #expect(plan == AdjustedPlan.Frames(trimStart: 24_000, trimEnd: 12_000, padStart: 4_800, padEnd: 9_600))
        #expect(plan.kept(of: 96_000) == 60_000)
        #expect(plan.output(of: 96_000) == 74_400)
        #expect(AdjustedPlan.frames([:], sampleRate: Self.rate).isAtRest)
        #expect(AdjustedPlan.Frames(trimStart: 70_000, trimEnd: 30_000).kept(of: 96_000) == 0)
    }

    @Test func trimAndPadCutAndSurroundTheAudio() async throws {
        let input = ramp()
        let output = try await through(input, [
            "trimStart": .number(0.25), "trimEnd": .number(0.5), "padStart": .number(0.1), "padEnd": .number(0.2),
        ])
        let trim = 12_000, pad = 4_800, kept = 96_000 - 12_000 - 24_000
        #expect(output.count == 2)
        let expectedFrames: Int = pad + kept + 9_600
        #expect(output[0].count == expectedFrames)
        for channel in 0..<2 {
            #expect(output[channel][0..<pad].allSatisfy { $0 == 0 })
            #expect(output[channel][(pad + kept)...].allSatisfy { $0 == 0 })
            #expect(Array(output[channel][pad..<(pad + kept)]) == Array(input[channel][trim..<(trim + kept)]))
        }
    }

    @Test func fadesCountFromTheKeptAudioNotThePads() async throws {
        let ones = [[Float](repeating: 1, count: 48_000)]
        let output = try await through(ones, ["padStart": .number(0.25), "padEnd": .number(0.25), "fadeIn": .number(0.1), "fadeOut": .number(0.1)])
        let pad = 12_000
        #expect(output[0][pad - 1] == 0)
        #expect(output[0][pad] == 0)
        #expect(abs(output[0][pad + 2_400] - 0.5) < 0.001)
        #expect(output[0][pad + 4_800 + 100] == 1)
        let end = pad + 48_000 - 1
        #expect(output[0][end] == 0)
        #expect(abs(output[0][end - 2_400] - 0.5) < 0.001)
    }

    @Test func dcRemoveMeasuresTheKeptAudioAndNeverTouchesThePads() async throws {
        let offset: Float = 0.25
        let tone = [Self.sine(440, peakDb: -12, seconds: 1, offset: offset)]
        let output = try await through(tone, ["dcRemove": .choice("on"), "padStart": .number(0.1), "padEnd": .number(0.1)])
        let pad = 4_800
        #expect(output[0][0..<pad].allSatisfy { $0 == 0 })
        #expect(output[0][(pad + 48_000)...].allSatisfy { $0 == 0 })
        let kept = output[0][pad..<(pad + 48_000)]
        let mean = kept.reduce(0.0) { $0 + Double($1) } / Double(kept.count)
        #expect(abs(mean) < 1e-4)
    }

    @Test func trimmingAwayASilentIntroLeavesNormalizeToTheKeptAudio() async throws {
        let loud = Self.sine(440, peakDb: -20, seconds: 1)
        let quiet = [Float](repeating: 0, count: 48_000)
        let output = try await through([quiet + loud], ["trimStart": .number(1), "normalize": .choice("peak"), "target": .number(-6)])
        let peak = output[0].map { abs($0) }.max() ?? 0
        #expect(abs(Double(peak) - pow(10, -6.0 / 20)) < 0.002)
    }

    @Test func monoSumGivesEveryChannelTheMean() async throws {
        let left = [Float](repeating: 0.5, count: 4_800)
        let right = [Float](repeating: -0.1, count: 4_800)
        let output = try await through([left, right], ["monoSum": .choice("on")])
        #expect(output.count == 2)
        for channel in 0..<2 {
            #expect(output[channel].allSatisfy { abs($0 - 0.2) < 1e-6 })
        }
    }

    @Test func monoSumLeavesAMonoInputAlone() async throws {
        let input = [Self.sine(440, peakDb: -6, seconds: 0.2)]
        let output = try await through(input, ["monoSum": .choice("on")])
        #expect(output == input)
    }

    @Test func monoSumIsNormalizedAsTheMonoSignal() async throws {
        let output = try await through(ramp(seconds: 1), ["monoSum": .choice("on"), "normalize": .choice("peak"), "target": .number(-3)])
        let peak = output[0].map { abs($0) }.max() ?? 0
        #expect(abs(Double(peak) - pow(10, -3.0 / 20)) < 0.002)
        #expect(output[0] == output[1])
    }

    @Test func theNewSettingsAreNotModulatableAndChangeNothingAtRest() async throws {
        let definition = NodeCatalog.definition(for: .utility)
        for id in ["monoSum", "trimStart", "trimEnd", "padStart", "padEnd"] {
            let parameter = definition.parameters.first { $0.id == id }
            let found = parameter != nil
            #expect(found, "\(id) is missing")
            #expect(parameter?.isModulatable == false)
        }
        #expect(definition.lengthRule == .adjusted("in"))
        let input = ramp(seconds: 0.5)
        let output = try await through(input, [:])
        #expect(output == input)
    }

    @Test func everythingTogetherGivesTheSameBitsAtAnyChunkSize() async throws {
        let parameters: [ParameterID: ParameterValue] = [
            "monoSum": .choice("on"), "trimStart": .number(0.1), "trimEnd": .number(0.15), "padStart": .number(0.05), "padEnd": .number(0.07),
            "fadeIn": .number(0.05), "fadeOut": .number(0.05), "dcRemove": .choice("on"), "normalize": .choice("rms"), "target": .number(-18),
            "gain": .number(-2),
        ]
        let whole = try await through(ramp(), parameters)
        let pieces = try await through(ramp(), parameters, chunk: 777)
        #expect(whole == pieces)
    }
}

struct UtilityFadeCase: CustomTestStringConvertible, Sendable {
    let shape: bake.dsp.UtilityFadeCurve
    var testDescription: String { "\(shape.rawValue)" }

}
