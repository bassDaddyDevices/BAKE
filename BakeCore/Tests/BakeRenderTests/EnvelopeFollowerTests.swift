import BakeDSP
import Foundation
import Testing
@testable import BakeGraph
@testable import BakeRender

struct EnvelopeFollowerTests {
    private func follow(
        // Attack and Release in milliseconds, as the catalog stores them.
        _ channels: [[Float]], sampleRate: Double = 1_000, attack: Float = 100, release: Float = 100,
        gain: Float = 0, detection: bake.dsp.EnvelopeFollowerDetection = .peak, chunk: Int? = nil
    ) -> [Float] {
        let frames = channels.first?.count ?? 0
        var state = bake.dsp.EnvelopeFollowerState()
        var output = [Float](repeating: 0, count: frames)
        let attackSignal = signal(attack, 0.1, 500, scale: .exponential)
        let releaseSignal = signal(release, 1, 5_000, scale: .exponential)
        let gainSignal = signal(gain, -24, 24)
        let right = channels.count > 1 ? channels[1] : []
        channels[0].withUnsafeBufferPointer { leftPointer in
            right.withUnsafeBufferPointer { rightPointer in
                output.withUnsafeMutableBufferPointer { destination in
                    var input = bake.dsp.AudioInput()
                    input.channels.0 = leftPointer.baseAddress
                    input.channelCount = 1
                    input.frames = frames
                    if channels.count > 1 {
                        input.channels.1 = rightPointer.baseAddress
                        input.channelCount = 2
                    }
                    var start = 0
                    while start < frames {
                        let count = min(chunk ?? frames, frames - start)
                        bake.dsp.renderEnvelopeFollower(
                            &state, detection, input, attackSignal, releaseSignal, gainSignal, sampleRate,
                            destination.baseAddress! + start, start, count
                        )
                        start += count
                    }
                }
            }
        }
        return output
    }

    @Test func attackAndReleaseFollowTheirTimeConstants() {
        let input = [Float](repeating: 0.5, count: 2_000)
        var signal = [Float](repeating: 0, count: 2_000)
        signal.replaceSubrange(100..<1_100, with: input[0..<1_000])
        let output = follow([signal], attack: 100, release: 100)
        #expect(abs(output[199] / 0.5 - (1 - exp(-1))) < 0.01)
        #expect(abs(output[1_200] / output[1_099] - exp(-1)) < 0.01)
    }

    @Test func rmsAndPeakDifferByThreeDecibelsOnASine() {
        let tone = sine(frequency: 100, frames: 20_000, amplitude: 0.5, sampleRate: 10_000)
        let peak = follow([tone], sampleRate: 10_000, attack: 1, release: 200)
        let rms = follow([tone], sampleRate: 10_000, attack: 1, release: 200, detection: .rms)
        let peakLevel = peak[19_999]
        let rmsLevel = rms[19_999]
        #expect(abs(decibels(rmsLevel / peakLevel) + 3) < 0.3)
    }

    @Test func silenceIsExactlyZeroAndStereoUsesLoudestChannel() {
        #expect(follow([[Float](repeating: 0, count: 256)]).allSatisfy { $0 == 0 })
        let quiet = [Float](repeating: 0.2, count: 1_000)
        let loud = [Float](repeating: 0.6, count: 1_000)
        #expect(follow([quiet, loud], attack: 10)[999] > 0.59)
        #expect(follow([loud, quiet], attack: 10)[999] > 0.59)
    }

    @Test func repeatedRendersAreBitIdentical() {
        let channels = TestAudio.samples(frames: 2_048, channels: 2)
        let first = follow(channels, detection: .rms)
        let second = follow(channels, detection: .rms)
        #expect(first == second)
    }

    @Test func chunksOf777MatchOneWholeRender() {
        let left = TestAudio.samples(frames: 6_013, channels: 2)[0]
        let right = TestAudio.samples(frames: 6_013, channels: 2)[1]
        #expect(follow([left, right], detection: .rms) == follow([left, right], detection: .rms, chunk: 777))
    }

    @Test func parameterExtremesStayFiniteAndBounded() {
        let input = [[Float](repeating: 0.9, count: 1_000)]
        for attack in [Float(0.1), 500] {
            for release in [Float(1), 5_000] {
                for gain in [Float(-24), 24] {
                    for detection in [bake.dsp.EnvelopeFollowerDetection.peak, .rms] {
                        let result = follow(input, attack: attack, release: release, gain: gain, detection: detection)
                        #expect(result.allSatisfy { $0.isFinite && (0...1).contains($0) })
                    }
                }
            }
        }
    }

    @Test func rendersAsAudioDrivenVCAControl() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.wav")
        let sourceSignal = [Float](repeating: 0.5, count: 4_800)
        try TestAudio.write([sourceSignal], to: source, sampleRate: 48_000)
        let output = directory.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        var graph = TestProject()
        let audio = graph.add(.audio, asset: sourceAsset)
        let follower = graph.add(.envelopeFollower, ["attack": .number(1), "release": .number(10)])
        let gain = graph.add(.gainVCA)
        let print = graph.add(.print, ["bitDepth": .choice("32f")])
        graph.connect(audio, to: follower)
        graph.connect(follower, to: gain, "amount")
        graph.connect(audio, to: gain)
        graph.connect(gain, to: print)
        let urls = [sourceAsset: source]
        let plan = try compile(graph.project, assetURLs: urls)
        let request = RenderRequest(plan: plan, assetURLs: urls, outputDirectory: output, chunkFrames: 777)

        let written = try #require(try await RenderEngine.render(request).outputs[print])
        let rendered = try TestAudio.read(written)
        #expect(rendered.samples.count == 1)
        #expect(rendered.samples[0].count == sourceSignal.count)
        #expect(rendered.samples[0][4_000] > sourceSignal[4_000] * 0.55)
    }

    /// Review fix: Gain was applied twice (to the detected level and again to the output).
    @Test func sixDecibelsOfGainDoublesASteadyLevel() {
        let steady = [[Float](repeating: 0.25, count: 2_000)]
        let plain = follow(steady, attack: 1, release: 100)[1_999]
        let boosted = follow(steady, attack: 1, release: 100, gain: 6.0206)[1_999]
        #expect(abs(plain - 0.25) < 0.002)
        #expect(abs(boosted - 0.5) < 0.005, "+6 dB gave \(boosted)")
    }

    /// Review fix: the catalog's Attack and Release are milliseconds but were used as seconds, so
    /// the defaults (10 ms, 100 ms) became 5 s. Through the processor, with the catalog's defaults.
    @Test func catalogDefaultsRespondInMilliseconds() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        // Followed: silence for 0.1 s, then 0.5. Carrier: steady 1.0, so ring mod passes the follower's level.
        let followed = directory.appendingPathComponent("step.wav")
        try TestAudio.write([[Float](repeating: 0, count: 4_800) + [Float](repeating: 0.5, count: 43_200)], to: followed, sampleRate: 48_000)
        let carrierAsset = AssetID(testUUID(9_700))
        let carrier = directory.appendingPathComponent("carrier.wav")
        try TestAudio.write([[Float](repeating: 1, count: 48_000)], to: carrier, sampleRate: 48_000)
        let output = directory.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        var graph = TestProject()
        let step = graph.add(.audio, asset: sourceAsset)
        let follower = graph.add(.envelopeFollower, NodeCatalog.defaultParameters(for: .envelopeFollower))
        let gain = graph.add(.gainVCA, ["mode": .choice("ringMod")])
        let print = graph.add(.print, ["bitDepth": .choice("32f")])
        graph.connect(step, to: follower)
        graph.connect(follower, to: gain, "amount")
        graph.connect(graph.add(.audio, asset: carrierAsset), to: gain)
        graph.connect(gain, to: print)
        let urls = [sourceAsset: followed, carrierAsset: carrier]
        let request = RenderRequest(plan: try compile(graph.project, assetURLs: urls), assetURLs: urls, outputDirectory: output)
        let level = try TestAudio.read(try #require(try await RenderEngine.render(request).outputs[print])).samples[0]

        // Default attack 10 ms: 63 % of 0.5 after 480 frames; settled after 100 ms.
        #expect(abs(level[4_800 + 480] - 0.316) < 0.03, "10 ms after the step: \(level[4_800 + 480])")
        #expect(level[4_800 + 4_800] > 0.49)
    }

    @Test func catalogDeclaresMonoControlOutputAndParameters() {
        let definition = NodeCatalog.definition(for: .envelopeFollower)
        #expect(definition.pins.map(\.id) == ["in", "out"])
        #expect(definition.pins[1].signal == .control)
        #expect(definition.pins[1].channels == .mono)
        #expect(definition.lengthRule == .sameAsInput("in"))
        #expect(definition.parameters.map(\.id) == ["attack", "release", "gain", "detection"])
        #expect(NodeKind.envelopeFollower.category == .modulation)
    }
}
