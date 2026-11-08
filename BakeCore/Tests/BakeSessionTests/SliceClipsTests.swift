import BakeGraph
import Foundation
import Testing
@testable import BakeSession

struct SliceClipsTests {
    /// Every 1 s of a 3.5 s, 48 kHz stereo sine, with a 2 ms fade.
    private let parameters: [ParameterID: ParameterValue] = NodeCatalog.defaultParameters(for: .largeAudio)
        .merging(["sliceMode": .choice("seconds"), "every": .number(1), "minLength": .number(100), "fade": .number(2)]) { $1 }

    @Test func clipsAreTheSlicesWithRaisedCosineFades() throws {
        let folder = try makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appending(path: "take 1.wav")
        try writeSine(to: source, seconds: 3.5)
        let cache = folder.appending(path: "cache", directoryHint: .isDirectory)
        let slices = try SliceClips.slices(for: source, parameters: parameters, in: cache)
        let clips = try SliceClips.clips(for: source, parameters: parameters, in: cache)
        #expect(slices.count == 4)
        #expect(clips.map(\.name) == ["take 1 001", "take 1 002", "take 1 003", "take 1 004"])
        let original = try samples(source)
        let fade = 96  // 2 ms at 48 kHz
        for (slice, clip) in zip(slices, clips) {
            let audio = try samples(URL(filePath: clip.path))
            #expect(audio.count == 2)
            #expect(audio[0].count == slice.count)
            for frame in [0, 1, fade / 2, fade - 1, fade, slice.count / 2, slice.count - fade, slice.count - 1] {
                let gain = SliceClips.fadeGain(frame, fadeFrames: fade) * SliceClips.fadeGain(slice.count - 1 - frame, fadeFrames: fade)
                #expect(abs(audio[0][frame] - original[0][slice.lowerBound + frame] * gain) < 1e-6, "frame \(frame)")
            }
            #expect(audio[0][0] == 0 && audio[0][slice.count - 1] == 0)
        }
        #expect(SliceClips.fadeGain(48, fadeFrames: 96) == 0.5)
    }

    @Test func clipsAreReusedUntilASettingChanges() throws {
        let folder = try makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appending(path: "take.wav")
        try writeSine(to: source, seconds: 2.5)
        let cache = folder.appending(path: "cache", directoryHint: .isDirectory)
        let first = try SliceClips.clips(for: source, parameters: parameters, in: cache)
        let date = try FileManager.default.attributesOfItem(atPath: first[0].path)[.modificationDate] as? Date
        let again = try SliceClips.clips(for: source, parameters: parameters, in: cache)
        #expect(again == first)
        #expect(try FileManager.default.attributesOfItem(atPath: again[0].path)[.modificationDate] as? Date == date)
        var changed = parameters
        changed["every"] = .number(0.5)
        let other = try SliceClips.clips(for: source, parameters: changed, in: cache)
        #expect(other.count == 5)
        #expect(Set(other.map(\.path)).isDisjoint(with: first.map(\.path)))
        // Gain doesn't change the clips: it applies when they play.
        var louder = parameters
        louder["gain"] = .number(6)
        #expect(try SliceClips.clips(for: source, parameters: louder, in: cache) == first)
    }
}
