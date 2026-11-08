import BakeDSP
import Foundation
import Testing
@testable import BakeGraph
@testable import BakeRender

struct DelayTests {
    private static let rate = 48_000.0

    private func signal(_ value: Float, minimum: Float = -1_000_000, maximum: Float = 1_000_000) -> bake.dsp.ParameterSignal {
        var signal = bake.dsp.ParameterSignal()
        signal.base = value
        signal.minimum = minimum
        signal.maximum = maximum
        return signal
    }

    private struct Settings {
        var time: Float = 100, feedback: Float = 0.5, damping: Float = 20_000, mix: Float = 1, pingPong: Double = 0
        var taps: [(Double, Float)] = []
        var fade: (Double, Double) = (0, 0)
    }

    /// Renders `channels` (one array per channel) in chunks of `chunk` frames; the output is as long as the input.
    private func render(_ channels: [[Float]], _ settings: Settings = Settings(), chunk: Int? = nil) -> [[Float]] {
        let frames = channels[0].count
        var controls = bake.dsp.DelayControls()
        controls.time = signal(settings.time)
        controls.feedback = signal(settings.feedback)
        controls.damping = signal(settings.damping)
        controls.mix = signal(settings.mix)
        controls.pingPong = settings.pingPong
        controls.sampleRate = Self.rate
        controls.lineFrames = Int(bake.dsp.delayLineFrames(2_000, Self.rate))
        controls.tailFadeStart = settings.fade.0
        controls.tailFadeEnd = settings.fade.1
        var tapFrames = settings.taps.map(\.0), tapGains = settings.taps.map(\.1)
        if tapFrames.isEmpty { tapFrames = [0]; tapGains = [0] }
        var results = channels.map { _ in [Float](repeating: 0, count: frames) }
        var lines = channels.map { _ in [Float](repeating: 0, count: controls.lineFrames) }
        var states = [bake.dsp.DelayState](repeating: bake.dsp.DelayState(), count: channels.count)
        tapFrames.withUnsafeBufferPointer { frameBuffer in
            tapGains.withUnsafeBufferPointer { gainBuffer in
                controls.tapFrames = frameBuffer.baseAddress
                controls.tapGains = gainBuffer.baseAddress
                controls.tapCount = settings.taps.count
                var input = bake.dsp.AudioInput()
                input.channelCount = channels.count
                input.frames = frames
                var held = channels
                held[0].withUnsafeBufferPointer { zero in
                    input.channels.0 = zero.baseAddress
                    if channels.count > 1 {
                        held[1].withUnsafeBufferPointer { one in
                            input.channels.1 = one.baseAddress
                            run(&states, &lines, &results, input, controls, frames, chunk)
                        }
                    } else {
                        run(&states, &lines, &results, input, controls, frames, chunk)
                    }
                }
            }
        }
        return results
    }

    private func run(
        _ states: inout [bake.dsp.DelayState], _ lines: inout [[Float]], _ results: inout [[Float]],
        _ input: bake.dsp.AudioInput, _ controls: bake.dsp.DelayControls, _ frames: Int, _ chunk: Int?
    ) {
        let count = states.count
        let linePointers = UnsafeMutablePointer<UnsafeMutablePointer<Float>?>.allocate(capacity: count)
        let outPointers = UnsafeMutablePointer<UnsafeMutablePointer<Float>?>.allocate(capacity: count)
        defer { linePointers.deallocate(); outPointers.deallocate() }
        var lineStorage = lines.map { line -> UnsafeMutablePointer<Float> in
            let pointer = UnsafeMutablePointer<Float>.allocate(capacity: line.count)
            pointer.initialize(from: line, count: line.count)
            return pointer
        }
        var outStorage = results.map { _ in UnsafeMutablePointer<Float>.allocate(capacity: frames) }
        defer { lineStorage.forEach { $0.deallocate() }; outStorage.forEach { $0.deallocate() } }
        for channel in 0..<count { linePointers[channel] = lineStorage[channel] }
        var start = 0
        while start < frames {
            let length = min(chunk ?? frames, frames - start)
            for channel in 0..<count { outPointers[channel] = outStorage[channel] + start }
            states.withUnsafeMutableBufferPointer { buffer in
                bake.dsp.renderDelay(buffer.baseAddress, linePointers, outPointers, Int32(count), 0, input, controls, start, length)
            }
            start += length
        }
        for channel in 0..<count { results[channel] = Array(UnsafeBufferPointer(start: outStorage[channel], count: frames)) }
    }

    private func click(at frame: Int, frames: Int = 48_000) -> [Float] {
        var signal = [Float](repeating: 0, count: frames)
        signal[frame] = 1
        return signal
    }

    @Test func eachRepeatIsOneFeedbackStepQuieter() {
        let output = render([click(at: 1_000)], Settings(time: 100, feedback: 0.5))[0]
        #expect(abs(output[5_800] - 1) < 1e-5)       // 1,000 + 100 ms
        #expect(abs(output[10_600] - 0.5) < 1e-5)
        #expect(abs(output[15_400] - 0.25) < 1e-5)
        #expect(output[3_000] == 0)
    }

    @Test func mixZeroIsTheDrySignalExactly() {
        let input = click(at: 1_000)
        #expect(render([input], Settings(mix: 0))[0] == input)
    }

    @Test func dampingDarkensTheRepeats() {
        let bright = render([click(at: 1_000)], Settings(feedback: 0.8))[0]
        let dark = render([click(at: 1_000)], Settings(feedback: 0.8, damping: 800))[0]
        func peak(_ values: [Float], around frame: Int) -> Float { values[(frame - 600)..<(frame + 600)].map(abs).max() ?? 0 }
        #expect(peak(dark, around: 10_600) < peak(bright, around: 10_600) * 0.5)
    }

    @Test func pingPongBouncesBetweenTheChannels() {
        var left = [Float](repeating: 0, count: 48_000)
        left[1_000] = 1
        let right = [Float](repeating: 0, count: 48_000)
        let output = render([left, right], Settings(feedback: 0.8, pingPong: 1))
        #expect(abs(output[0][5_800] - 1) < 1e-5 && abs(output[1][5_800]) < 1e-6)
        #expect(abs(output[0][10_600]) < 1e-6 && abs(output[1][10_600] - 0.8) < 1e-5)
        #expect(abs(output[0][15_400] - 0.64) < 1e-5 && abs(output[1][15_400]) < 1e-6)
    }

    @Test func withoutPingPongTheChannelsStayApart() {
        var left = [Float](repeating: 0, count: 48_000)
        left[1_000] = 1
        let right = [Float](repeating: 0, count: 48_000)
        let output = render([left, right], Settings(feedback: 0.8, pingPong: 0))
        #expect(output[1].allSatisfy { $0 == 0 })
    }

    @Test func tapsAreExtraReadsAtTheirOwnTimesAndLevels() {
        let output = render([click(at: 1_000)], Settings(feedback: 0, taps: [(2_400, 0.5), (3_600, 0.25)]))[0]
        #expect(abs(output[5_800] - 1) < 1e-5)
        #expect(abs(output[3_400] - 0.5) < 1e-5)
        #expect(abs(output[4_600] - 0.25) < 1e-5)
    }

    @Test func theTailFadesToSilence() {
        let output = render([click(at: 1_000, frames: 4_000)], Settings(time: 2, feedback: 0.995, mix: 1, fade: (3_000, 4_000)))[0]
        // Echoes land every 96 frames, so compare the loudest frame of a stretch, not single frames between echoes.
        func peak(_ frames: Range<Int>) -> Float { output[frames].map(\.magnitude).max() ?? 0 }
        #expect(peak(3_900..<4_000) < peak(2_900..<3_000))
        #expect(peak(3_900..<4_000) < 0.01)
    }

    @Test func anyChunkSizeGivesTheSameBits() {
        let source = (0..<20_000).map { Float(sin(Double($0) * 0.05)) * 0.5 }
        let settings = Settings(time: 37, feedback: 0.7, damping: 3_000, mix: 0.6, taps: [(900, 0.5)])
        #expect(render([source, source.reversed()], settings, chunk: 20_000) == render([source, source.reversed()], settings, chunk: 777))
    }

    @Test func tapTextIsParsed() {
        let taps = DelayProcessor.parseTaps("375 500@-6, 750@-12 nonsense -5 0")
        #expect(taps.count == 3)
        #expect(taps[0].milliseconds == 375 && taps[0].gain == 1)
        #expect(abs(taps[1].gain - 0.5012) < 0.001)
        #expect(abs(taps[2].gain - 0.2512) < 0.001)
        #expect(DelayProcessor.parseTaps("").isEmpty)
    }

    @Test func theCatalogGivesItATailAndPutsItInTheTimeGroup() {
        let definition = NodeCatalog.definition(for: .delay)
        #expect(definition.lengthRule == .extendedInput("in", bySeconds: "tail"))
        #expect(NodeKind.delay.category == .time)
        #expect(NodeCatalog.isCausal(Node(kind: .delay, parameters: [:])))
    }
}
