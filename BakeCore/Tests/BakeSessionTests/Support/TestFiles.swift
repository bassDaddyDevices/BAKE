import AVFAudio
import Foundation
import Testing

/// A fresh folder in the temporary directory; delete it when done.
func makeTemporaryFolder() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "bake-session-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Writes a 220 Hz sine as 32-bit float WAV (or AIFF, by the extension), at 48 kHz unless told otherwise.
func writeSine(to url: URL, seconds: Double, channels: Int = 2, sampleRate: Double = 48_000) throws {
    let format = try #require(AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: AVAudioChannelCount(channels)))
    let frames = AVAudioFrameCount(seconds * sampleRate)
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
    buffer.frameLength = frames
    let data = try #require(buffer.floatChannelData)
    for channel in 0..<channels {
        for frame in 0..<Int(frames) {
            data[channel][frame] = 0.5 * sin(2 * .pi * 220 * Float(frame) / Float(sampleRate))
        }
    }
    let file = try AVAudioFile(forWriting: url, settings: format.settings)
    try file.write(from: buffer)
}

/// Same file, ignoring /var ↔ /private/var.
func samePath(_ a: URL, _ b: URL) -> Bool {
    a.resolvingSymlinksInPath().path(percentEncoded: false) == b.resolvingSymlinksInPath().path(percentEncoded: false)
}

/// Every sample of a WAV, channel by channel, as AVAudioFile reads it. One `read(into:)` can return fewer
/// frames than asked for, so it loops.
func samples(_ url: URL) throws -> [[Float]] {
    let file = try AVAudioFile(forReading: url)
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 65_536))
    var channels = [[Float]](repeating: [], count: Int(file.processingFormat.channelCount))
    while file.framePosition < file.length {
        try file.read(into: buffer)
        guard buffer.frameLength > 0, let data = buffer.floatChannelData else { break }
        for channel in channels.indices {
            channels[channel].append(contentsOf: UnsafeBufferPointer(start: data[channel], count: Int(buffer.frameLength)))
        }
    }
    return channels
}
