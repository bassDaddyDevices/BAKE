import AVFAudio
import BakeGraph
import Foundation
import Testing
@testable import BakeSession

/// Concatenate's join, from its rules: clips end to end, Gap as silence, Crossfade as equal power.
struct ConcatenationTests {
    /// A 48 kHz 32-bit float WAV holding `value` in every sample.
    private func constant(_ value: Float, frames: Int, channels: Int = 1, in folder: URL, name: String) throws -> URL {
        let url = folder.appending(path: "\(name).wav")
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: AVAudioChannelCount(channels)))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
        buffer.frameLength = AVAudioFrameCount(frames)
        let data = try #require(buffer.floatChannelData)
        for channel in 0..<channels { for frame in 0..<frames { data[channel][frame] = value } }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        return url
    }

    private func joined(_ clips: [URL], _ parameters: [ParameterID: ParameterValue], in folder: URL) throws -> [[Float]] {
        let output = folder.appending(path: "joined-\(UUID().uuidString).wav")
        try Concatenation.join(clips, parameters: parameters, to: output)
        return try samples(output)
    }

    private func clips(in folder: URL) throws -> [URL] {
        try [(0.25, 100), (0.5, 200), (0.75, 300)].enumerated().map { index, clip in
            try constant(Float(clip.0), frames: clip.1, in: folder, name: "clip \(index)")
        }
    }

    @Test func clipsAreJoinedEndToEnd() throws {
        let folder = try makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let out = try joined(clips(in: folder), ["gap": .number(0), "crossfade": .number(0)], in: folder)
        let expected = [Float](repeating: 0.25, count: 100) + [Float](repeating: 0.5, count: 200) + [Float](repeating: 0.75, count: 300)
        #expect(out == [expected])
    }

    @Test func gapPutsExactSilenceBetweenClips() throws {
        let folder = try makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        // 10 ms at 48 kHz is 480 frames; Crossfade doesn't apply with a gap.
        let out = try joined(clips(in: folder), ["gap": .number(10), "crossfade": .number(50)], in: folder)
        let silence = [Float](repeating: 0, count: 480)
        let expected = [Float](repeating: 0.25, count: 100) + silence + [Float](repeating: 0.5, count: 200) + silence
            + [Float](repeating: 0.75, count: 300)
        #expect(out == [expected])
    }

    @Test func crossfadesOverlapNeighboursWithEqualPower() throws {
        let folder = try makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        // 2 ms is 96 frames, limited to half the shorter neighbour: 50 between the first two, 96 between the last two.
        let out = try joined(clips(in: folder), ["gap": .number(0), "crossfade": .number(2)], in: folder)[0]
        #expect(out.count == 600 - 50 - 96)
        func fade(_ a: Float, _ b: Float, _ i: Int, _ length: Int) -> Float {
            let theta = Double.pi / 2 * (Double(i) + 0.5) / Double(length)
            return Float(Double(a) * cos(theta) + Double(b) * sin(theta))
        }
        #expect(out[0..<50].allSatisfy { $0 == 0.25 })
        for i in 0..<50 { #expect(abs(out[50 + i] - fade(0.25, 0.5, i, 50)) < 1e-6, "first overlap \(i)") }
        #expect(out[100..<154].allSatisfy { $0 == 0.5 })
        for i in 0..<96 { #expect(abs(out[154 + i] - fade(0.5, 0.75, i, 96)) < 1e-6, "second overlap \(i)") }
        #expect(out[250...].allSatisfy { $0 == 0.75 })
    }

    @Test func ordersAreByLengthOrASeededShuffle() {
        let lengths = [300, 100, 200, 100]
        #expect(Concatenation.order(lengths, parameters: [:]) == [0, 1, 2, 3])
        #expect(Concatenation.order(lengths, parameters: ["order": .choice("shortest")]) == [1, 3, 2, 0])
        #expect(Concatenation.order(lengths, parameters: ["order": .choice("longest")]) == [0, 2, 1, 3])
        let many = [Int](repeating: 10, count: 12)
        let one = Concatenation.order(many, parameters: ["order": .choice("random"), "seed": .number(1)])
        #expect(Set(one) == Set(0..<12))
        #expect(one == Concatenation.order(many, parameters: ["order": .choice("random"), "seed": .number(1)]))
        #expect(one != Concatenation.order(many, parameters: ["order": .choice("random"), "seed": .number(2)]))
    }

    @Test func aMonoClipFillsEveryChannelOfAStereoJoin() throws {
        let folder = try makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let mono = try constant(0.5, frames: 10, in: folder, name: "mono")
        let stereo = try constant(0.25, frames: 10, channels: 2, in: folder, name: "stereo")
        let out = try joined([mono, stereo], ["crossfade": .number(0)], in: folder)
        #expect(out.count == 2)
        #expect(out[0] == [Float](repeating: 0.5, count: 10) + [Float](repeating: 0.25, count: 10))
        #expect(out[1] == out[0])
    }
}
