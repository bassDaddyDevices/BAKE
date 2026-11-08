import BakeGraph
import Foundation
import Testing
@testable import BakeRender

/// Large Audio Processor's analysis on real files: where the long file is cut.
struct SliceAnalysisTests {
    private let rate = 48_000.0

    /// A stereo file: silence with 20 ms bursts of a 1 kHz sine at `seconds`, `length` seconds long.
    private func file(clicks seconds: [Double], length: Double, in folder: URL) throws -> URL {
        var samples = [Float](repeating: 0, count: Int(length * rate))
        for time in seconds {
            let start = Int(time * rate)
            for frame in 0..<Int(0.02 * rate) where start + frame < samples.count {
                samples[start + frame] = 0.5 * sin(2 * .pi * 1_000 * Float(frame) / Float(rate))
            }
        }
        let url = folder.appending(path: "take.wav")
        try TestAudio.write([samples, samples], to: url, sampleRate: rate)
        return url
    }

    private func slices(_ url: URL, _ parameters: [ParameterID: ParameterValue]) throws -> [Range<Int>] {
        try SliceAnalysis.slices(of: url, parameters: NodeCatalog.defaultParameters(for: .largeAudio).merging(parameters) { $1 })
    }

    @Test func transientSlicesStartAtEachHit() throws {
        let folder = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let times = [0.5, 1.2, 2.0, 3.1]
        let found = try slices(file(clicks: times, length: 4, in: folder), [:])
        #expect(found.count == 4)
        for (slice, time) in zip(found, times) {
            // Within a hop of the hit, plus the 5 ms zero-crossing snap.
            #expect(abs(slice.lowerBound - Int(time * rate)) <= 256 + 240, "slice at \(slice.lowerBound) for \(time) s")
        }
        // Each runs to the next hit; the last to the end of the file.
        #expect(abs((found.first?.upperBound ?? 0) - Int(1.2 * rate)) <= 496)
        #expect(found.last?.upperBound == Int(4 * rate))
    }

    @Test func aLongSilentTailIsLeftOut() throws {
        let folder = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        // One hit, then 9 s of silence cut every second: only the slice with the hit stays.
        let found = try slices(file(clicks: [0.5], length: 10, in: folder), ["maxLength": .number(1)])
        #expect(found.count == 1)
        #expect(found.first.map { $0.count <= Int(rate) + 480 } == true)
    }

    @Test func musicalTimeCutsEveryBar() throws {
        let folder = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        // 120 BPM, one 4/4 bar = 2 s: five slices of a 10 s file (silent, so nothing to snap to).
        let found = try slices(file(clicks: [], length: 10, in: folder), ["sliceMode": .choice("musical"), "bpm": .number(120), "bars": .choice("1")])
        let bar = Int(2 * rate)
        let expected: [Range<Int>] = (0..<5).map { index in (index * bar)..<((index + 1) * bar) }
        #expect(found == expected)
    }

    @Test func secondsLeavesAShorterLastSlice() throws {
        let folder = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let found = try slices(file(clicks: [], length: 10, in: folder), ["sliceMode": .choice("seconds"), "every": .number(3)])
        let second = Int(rate)
        #expect(found.map(\.count) == [3 * second, 3 * second, 3 * second, second])
    }

    @Test func theSameFileGivesTheSameSlices() throws {
        let folder = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = try file(clicks: [0.3, 0.9, 1.7, 2.2], length: 3, in: folder)
        let parameters: [ParameterID: ParameterValue] = ["jitter": .number(30), "seed": .number(4)]
        #expect(try slices(url, parameters) == slices(url, parameters))
    }

    @Test func anUnreadableFileIsAnError() throws {
        let folder = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appending(path: "broken.wav")
        try Data("not audio".utf8).write(to: url)
        #expect(throws: RenderError.self) { try SliceAnalysis.slices(of: url, parameters: [:]) }
    }
}
