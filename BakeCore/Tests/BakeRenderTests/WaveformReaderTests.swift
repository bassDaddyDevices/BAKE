import BakeGraph
import Foundation
import Testing
@testable import BakeRender

struct WaveformReaderTests {
    @Test func peaksFollowTheLoudestSampleInEachSlice() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("spikes.wav")
        // 4 slices of 100 frames: silence, 0.5, silence, −1 (a negative peak counts by size).
        var samples = [Float](repeating: 0, count: 400)
        samples[150] = 0.5
        samples[399] = -1
        try TestAudio.write([samples], to: url, sampleRate: 48_000)

        let waveform = try WaveformReader.peaks(of: url, buckets: 4)

        #expect(waveform.peaks == [0, 0.5, 0, 1])
    }

    @Test func stereoPeaksTakeTheLouderChannel() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("stereo.wav")
        try TestAudio.write([[0.25, 0], [0, -0.75]], to: url, sampleRate: 48_000)

        #expect(try WaveformReader.peaks(of: url, buckets: 2).peaks == [0.25, 0.75])
    }

    @Test func shortFilesGiveOnePeakPerFrame() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("short.wav")
        try TestAudio.write([[0.25, -0.75]], to: url, sampleRate: 48_000)

        #expect(try WaveformReader.peaks(of: url, buckets: 160).peaks == [0.25, 0.75])
    }

    @Test func unreadableFilesAreReported() {
        let url = URL(filePath: "/nonexistent/nothing.wav")
        #expect(throws: RenderError.unreadableAsset(url)) { try WaveformReader.peaks(of: url) }
    }
}
