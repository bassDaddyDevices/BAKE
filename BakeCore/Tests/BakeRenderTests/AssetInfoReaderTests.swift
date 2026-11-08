import Foundation
import Testing
@testable import BakeGraph
@testable import BakeRender

struct AssetInfoReaderTests {
    @Test func readsLengthChannelsAndRate() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("stereo.wav")
        try TestAudio.write(TestAudio.samples(frames: 1_000, channels: 2), to: url, sampleRate: 44_100)

        #expect(try AssetInfoReader.info(for: url) == AssetInfo(frameCount: 1_000, channelCount: 2, sampleRate: 44_100))
    }

    @Test func unreadableFilesAreReported() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("not-audio.wav")
        try Data("hello".utf8).write(to: url)

        #expect(throws: RenderError.unreadableAsset(url)) {
            try AssetInfoReader.info(for: url)
        }
    }

    @Test func readsEveryAsset() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("mono.wav")
        try TestAudio.write(TestAudio.samples(frames: 480, channels: 1), to: url, sampleRate: 48_000)

        let infos = try AssetInfoReader.infos(for: [sourceAsset: url])
        #expect(infos == [sourceAsset: AssetInfo(frameCount: 480, channelCount: 1, sampleRate: 48_000)])
    }
}
